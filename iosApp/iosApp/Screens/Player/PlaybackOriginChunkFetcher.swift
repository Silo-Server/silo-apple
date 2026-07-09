import Foundation
import OSLog

/// Discrete range fetches for random-access misses, borrowed from
/// AetherEngine's chunk session: matroska head/tail probes, subtitle
/// extractor reads, and far seeks are served with exact `Range` GETs over
/// one shared keep-alive URLSession instead of retargeting the streaming
/// window connection. Each chunk is stored (and its waiters woken) when the
/// response body completes — at most one chunk of latency for a probe read.
final class PlaybackOriginChunkFetcher {
    /// Interactive detour/probe fetches must fail fast enough for the source
    /// window or outage coordinator to recover. Long outage survival is owned
    /// by `PlaybackOriginReconnectPolicy`, not by one blocked range request.
    static let interactiveRequestTimeoutSeconds: TimeInterval = 4.0

    struct Callbacks {
        /// Store delivered bytes (invoked on the session delegate queue).
        let store: (Int64, Data, Int64?) -> Void
        /// Bytes for this range are now cached; wake matching waiters.
        let didStore: (ClosedRange<Int64>) -> Void
        /// First response headers (total length if known).
        let didReceiveResponse: (Int64?) -> Void
        let didDetectSessionMissing: () -> Void
        /// A chunk failed terminally; waiters inside the range must fail.
        let didFail: (Range<Int64>, PlaybackOriginReconnectPolicy.EndCause, Int?) -> Void
        /// Pairs the cache's active-origin-request gauge.
        let beginRequest: () -> Void
        let endRequest: () -> Void
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackOriginChunkFetcher"
    )

    private let originURL: URL
    private let originHeaders: [String: String]
    private let callbacks: Callbacks

    private let lock = NSLock()
    private var cancelled = false
    private var inFlight: [UUID: Range<Int64>] = [:]
    private var session: URLSession?

    init(originURL: URL, originHeaders: [String: String], callbacks: Callbacks) {
        self.originURL = originURL
        self.originHeaders = originHeaders
        self.callbacks = callbacks
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let open = inFlight.count
        inFlight.removeAll()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        for _ in 0..<open {
            callbacks.endRequest()
        }
    }

    /// Whether an in-flight chunk will (eventually) deliver `offset`.
    func coversInFlight(offset: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.values.contains { $0.contains(offset) }
    }

    /// Fetch `chunkBytes` starting at `offset` unless an in-flight chunk
    /// already covers it. `totalLength` (when known) caps the range at EOF.
    func ensureFetch(covering offset: Int64, totalLength: Int64?) {
        let start = offset
        var end = start + PlaybackOriginRoutingPolicy.chunkBytes
        if let totalLength {
            end = min(end, totalLength)
        }
        guard end > start else { return }
        let range = start..<end

        let id = UUID()
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        if inFlight.values.contains(where: { $0.contains(offset) }) {
            lock.unlock()
            return
        }
        inFlight[id] = range
        lock.unlock()

        callbacks.beginRequest()
        Self.logger.info("[CMP-SOURCE-CACHE] chunk fetch start=\(start, privacy: .public) len=\(end - start, privacy: .public)")
        run(id: id, range: range, attempt: 1)
    }

    private func makeSessionLocked() -> URLSession {
        if let session { return session }
        // One keep-alive session for every chunk: per-request sessions pay a
        // fresh TCP+TLS handshake per probe, which is the cost this class
        // exists to avoid.
        let config = Self.makeSessionConfiguration()
        let created = URLSession(configuration: config)
        session = created
        return created
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = interactiveRequestTimeoutSeconds
        return config
    }

    private func run(id: UUID, range: Range<Int64>, attempt: Int) {
        lock.lock()
        guard !cancelled, inFlight[id] != nil else {
            lock.unlock()
            return
        }
        let session = makeSessionLocked()
        lock.unlock()

        var request = URLRequest(url: originURL)
        request.httpMethod = "GET"
        for (key, value) in originHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.handleResult(id: id, range: range, attempt: attempt, data: data, response: response, error: error)
        }
        task.resume()
    }

    private func handleResult(
        id: UUID,
        range: Range<Int64>,
        attempt: Int,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        lock.lock()
        let stillWanted = !cancelled && inFlight[id] != nil
        lock.unlock()
        guard stillWanted else { return }

        if let error {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCancelled {
                finish(id: id)
                return
            }
            retryOrFail(id: id, range: range, attempt: attempt, cause: .network, statusCode: nil)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            retryOrFail(id: id, range: range, attempt: attempt, cause: .network, statusCode: nil)
            return
        }

        switch http.statusCode {
        case 206:
            let contentRange = http.value(forHTTPHeaderField: "Content-Range")
            let total = PlaybackOriginStream.totalLength(fromContentRange: contentRange)
            if let rangeStart = PlaybackOriginStream.rangeStart(fromContentRange: contentRange),
               rangeStart != range.lowerBound {
                Self.logger.warning("[CMP-SOURCE-CACHE] chunk range mismatch expected=\(range.lowerBound, privacy: .public) got=\(rangeStart, privacy: .public)")
                fail(id: id, range: range, cause: .rangeIgnored, statusCode: 206)
                return
            }
            callbacks.didReceiveResponse(total)
            storeAndFinish(id: id, range: range, body: data ?? Data(), total: total)
        case 200 where range.lowerBound == 0:
            // Origin ignored the Range but the chunk starts at 0, so a
            // truncated prefix of the body is exactly the requested bytes
            // (Data's prefix is a no-copy slice).
            let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            callbacks.didReceiveResponse(total)
            let body = (data ?? Data()).prefix(Int(range.upperBound - range.lowerBound))
            storeAndFinish(id: id, range: range, body: body, total: total)
        case 200:
            // Accepting head bytes at a nonzero offset would corrupt the cache.
            fail(id: id, range: range, cause: .rangeIgnored, statusCode: 200)
        case 404:
            let body = data.flatMap { String(data: $0.prefix(4096), encoding: .utf8) }
            if PlaybackOriginStream.isPlaybackSessionMissing(statusCode: 404, body: body) {
                callbacks.didDetectSessionMissing()
            }
            fail(id: id, range: range, cause: .httpFatal(404), statusCode: 404)
        case 502, 503, 504:
            retryOrFail(id: id, range: range, attempt: attempt, cause: .httpOutage(http.statusCode), statusCode: http.statusCode)
        case 416:
            if let total = PlaybackOriginStream.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                callbacks.didReceiveResponse(total)
            }
            fail(id: id, range: range, cause: .httpFatal(416), statusCode: 416)
        default:
            fail(id: id, range: range, cause: .httpFatal(http.statusCode), statusCode: http.statusCode)
        }
    }

    private func storeAndFinish(id: UUID, range: Range<Int64>, body: Data, total: Int64?) {
        guard !body.isEmpty else {
            // A 206 with an empty body is an origin bug; a repeat request
            // will not do better.
            fail(id: id, range: range, cause: .prematureEOF, statusCode: nil)
            return
        }
        callbacks.store(range.lowerBound, body, total)
        finish(id: id)
        callbacks.didStore(range.lowerBound...(range.lowerBound + Int64(body.count) - 1))
    }

    /// Transient failures share the window stream's retry/backoff policy
    /// (`PlaybackOriginReconnectPolicy`) so "how often and how long to retry
    /// an origin read" has one definition. Chunks are never "productive" in
    /// the streak sense — each is a fresh short request.
    private func retryOrFail(
        id: UUID,
        range: Range<Int64>,
        attempt: Int,
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?
    ) {
        switch PlaybackOriginReconnectPolicy.decide(
            cause: cause,
            unproductiveStreak: attempt - 1,
            everProductive: false
        ) {
        case .giveUp:
            fail(id: id, range: range, cause: cause, statusCode: statusCode)
        case .retry(let delay):
            Self.logger.info("[CMP-SOURCE-CACHE] chunk retry start=\(range.lowerBound, privacy: .public) attempt=\(attempt + 1, privacy: .public) cause=\(String(describing: cause), privacy: .public)")
            Task.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.run(id: id, range: range, attempt: attempt + 1)
            }
        }
    }

    private func fail(
        id: UUID,
        range: Range<Int64>,
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?
    ) {
        Self.logger.warning("[CMP-SOURCE-CACHE] chunk failed start=\(range.lowerBound, privacy: .public) cause=\(String(describing: cause), privacy: .public) status=\(statusCode ?? 0, privacy: .public)")
        finish(id: id)
        callbacks.didFail(range, cause, statusCode)
    }

    private func finish(id: UUID) {
        lock.lock()
        let removed = inFlight.removeValue(forKey: id) != nil
        lock.unlock()
        if removed {
            callbacks.endRequest()
        }
    }
}
