import Foundation
import OSLog

/// Discrete range fetches for random-access misses, borrowed from
/// AetherEngine's chunk session: matroska head/tail probes, subtitle
/// extractor reads, and far seeks are served with exact `Range` GETs over
/// one shared keep-alive URLSession instead of retargeting the streaming
/// window connection. Each chunk is stored (and its waiters woken) when the
/// requested interval completes — at most one chunk of latency for a probe read.
final class PlaybackOriginChunkFetcher: @unchecked Sendable {
    /// Interactive detour/probe fetches must fail fast enough for the source
    /// window or outage coordinator to recover. Long outage survival is owned
    /// by `PlaybackOriginReconnectPolicy`, not by one blocked range request.
    static let interactiveRequestTimeoutSeconds: TimeInterval = 4.0

    struct Callbacks {
        /// Atomically validate and store delivered bytes (invoked on the
        /// session callback queue). A returned cause rejects the response.
        let store: (
            Int64,
            Data,
            Int64?,
            String?
        ) -> PlaybackOriginReconnectPolicy.EndCause?
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

    private enum AcceptedResponse {
        case media(total: Int64?, entityETag: String?, byteLimit: Int)
        case notFound
    }

    private struct ContentRange {
        let start: Int64
        let end: Int64
        let total: Int64

        var count: Int64 { end - start + 1 }
    }

    private struct AttemptState {
        let id: UUID
        let range: Range<Int64>
        let attempt: Int
        let expectedEntityETag: String?
        var response: AcceptedResponse?
        var body = Data()
    }

    private let originURL: URL
    private let originHeaders: [String: String]
    /// Resolved for every request and response rather than captured at
    /// construction: an early seek can create this long-lived fetcher before
    /// the streaming window publishes its first response validator.
    private let entityETagProvider: () -> String?
    /// Resume-capable resources cannot combine independently fetched chunks
    /// unless the streaming window has established a strong validator.
    private let requiresEntityValidation: Bool
    private let callbacks: Callbacks

    /// State transitions and every externally supplied callback share this
    /// executor. An external `cancel()` synchronously joins it, so once cancel
    /// returns no callback can still be running and late delegate events cannot
    /// start another one. The queue-specific fast path avoids self-deadlock
    /// when a callback synchronously invalidates its owning source resource.
    private let stateQueue = DispatchQueue(
        label: "com.continuum.PlaybackOriginChunkFetcher.state",
        qos: .userInitiated
    )
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    /// `PlaybackSourceResource` queries coverage while holding its own state
    /// lock. Publish only this callback-free snapshot behind a tiny lock so it
    /// never waits for `stateQueue`, whose callbacks may need that outer lock.
    private let coverageLock = NSLock()
    private var publishedInFlight: [UUID: Range<Int64>] = [:]
    private var cancelled = false
    private var inFlight: [UUID: Range<Int64>] = [:]
    private var attempts: [Int: AttemptState] = [:]
    private var session: URLSession?

    init(
        originURL: URL,
        originHeaders: [String: String],
        entityETagProvider: @escaping () -> String? = { nil },
        requiresEntityValidation: Bool = false,
        callbacks: Callbacks
    ) {
        self.originURL = originURL
        self.originHeaders = originHeaders
        self.entityETagProvider = entityETagProvider
        self.requiresEntityValidation = requiresEntityValidation
        self.callbacks = callbacks
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    func cancel() {
        let session: URLSession? = withState {
            guard !cancelled else { return nil }
            cancelled = true
            attempts.removeAll()
            let open = inFlight.count
            inFlight.removeAll()
            coverageLock.lock()
            publishedInFlight.removeAll()
            coverageLock.unlock()
            let session = self.session
            self.session = nil
            for _ in 0..<open {
                callbacks.endRequest()
            }
            return session
        }
        session?.invalidateAndCancel()
    }

    /// Whether an in-flight chunk will (eventually) deliver `offset`.
    func coversInFlight(offset: Int64) -> Bool {
        coverageLock.lock()
        defer { coverageLock.unlock() }
        return publishedInFlight.values.contains { $0.contains(offset) }
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

        withState {
            guard !cancelled,
                  !inFlight.values.contains(where: { $0.contains(offset) }) else {
                return
            }
            let id = UUID()
            inFlight[id] = range
            coverageLock.lock()
            publishedInFlight[id] = range
            coverageLock.unlock()
            // Begin is serialized with admission. Cancellation therefore can
            // neither observe this request before begin nor deliver end first.
            callbacks.beginRequest()
            Self.logger.info("[CMP-SOURCE-CACHE] chunk fetch start=\(start, privacy: .public) len=\(end - start, privacy: .public)")
            runLocked(id: id, range: range, attempt: 1)
        }
    }

    private func makeSessionLocked() -> URLSession {
        if let session { return session }
        // One keep-alive session for every chunk: per-request sessions pay a
        // fresh TCP+TLS handshake per probe, which is the cost this class
        // exists to avoid.
        let config = Self.makeSessionConfiguration()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let created = URLSession(
            configuration: config,
            delegate: ConnectionDelegate(fetcher: self),
            delegateQueue: delegateQueue
        )
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
        withState {
            runLocked(id: id, range: range, attempt: attempt)
        }
    }

    /// Must run on `stateQueue`.
    private func runLocked(id: UUID, range: Range<Int64>, attempt: Int) {
        guard !cancelled, inFlight[id] != nil else { return }
        let session = makeSessionLocked()

        var request = URLRequest(url: originURL)
        request.httpMethod = "GET"
        for (key, value) in originHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        // Unlike If-Range, If-Match never turns a stale validator into a
        // potentially multi-gigabyte 200 response. A changed entity fails as
        // a bodyless 412 before the origin sends any file bytes.
        let expectedEntityETag = entityETagProvider()
        if let expectedEntityETag {
            request.setValue(expectedEntityETag, forHTTPHeaderField: "If-Match")
        }

        let task = session.dataTask(with: request)
        guard !cancelled, inFlight[id] != nil else {
            task.cancel()
            return
        }
        attempts[task.taskIdentifier] = AttemptState(
            id: id,
            range: range,
            attempt: attempt,
            expectedEntityETag: expectedEntityETag,
            response: nil
        )
        task.resume()
    }

    private func withState<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return body()
        }
        return stateQueue.sync(execute: body)
    }

    /// Validate headers before URLSession is allowed to deliver body bytes.
    /// Returning false causes the delegate to cancel the response; the attempt
    /// has already been removed so its cancellation completion is a no-op.
    fileprivate func handleResponse(_ response: URLResponse, taskID: Int) -> Bool {
        withState {
            handleResponseLocked(response, taskID: taskID)
        }
    }

    /// Must run on `stateQueue`.
    private func handleResponseLocked(_ response: URLResponse, taskID: Int) -> Bool {
        guard let state = attempts[taskID],
              !cancelled,
              inFlight[state.id] != nil else {
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            rejectAttemptLocked(taskID: taskID, cause: .network, statusCode: nil, retryable: true)
            return false
        }

        switch http.statusCode {
        case 206:
            let contentRange = http.value(forHTTPHeaderField: "Content-Range")
            guard let parsed = Self.parseContentRange(contentRange),
                  parsed.start == state.range.lowerBound,
                  parsed.end < state.range.upperBound else {
                let receivedRange = contentRange ?? "missing"
                Self.logger.warning(
                    "[CMP-SOURCE-CACHE] chunk invalid content-range expected=\(state.range.lowerBound, privacy: .public)-\(state.range.upperBound - 1, privacy: .public) received=\(receivedRange, privacy: .public)"
                )
                rejectAttemptLocked(taskID: taskID, cause: .rangeIgnored, statusCode: 206, retryable: false)
                return false
            }
            if let cause = entityValidationFailure(
                for: http,
                expectedEntityETag: state.expectedEntityETag
            ) {
                rejectAttemptLocked(taskID: taskID, cause: cause, statusCode: 206, retryable: true)
                return false
            }
            // Preserve entity-change precedence for a syntactically safe
            // partial response: callers must invalidate the old resource even
            // when the changed origin also returns less than the requested
            // interval. Only a response from the expected entity reaches this
            // coverage check.
            guard parsed.end == state.range.upperBound - 1
                    || parsed.end == parsed.total - 1 else {
                let receivedRange = contentRange ?? "missing"
                Self.logger.warning(
                    "[CMP-SOURCE-CACHE] chunk incomplete content-range expected=\(state.range.lowerBound, privacy: .public)-\(state.range.upperBound - 1, privacy: .public) received=\(receivedRange, privacy: .public)"
                )
                rejectAttemptLocked(taskID: taskID, cause: .rangeIgnored, statusCode: 206, retryable: false)
                return false
            }
            acceptResponseLocked(
                .media(
                    total: parsed.total,
                    entityETag: PlaybackOriginStream.strongETag(
                        http.value(forHTTPHeaderField: "ETag")
                    ),
                    byteLimit: Int(min(parsed.count, Int64(state.range.count)))
                ),
                taskID: taskID
            )
            return true
        case 200 where state.range.lowerBound == 0:
            if let cause = entityValidationFailure(
                for: http,
                expectedEntityETag: state.expectedEntityETag
            ) {
                rejectAttemptLocked(taskID: taskID, cause: cause, statusCode: 200, retryable: true)
                return false
            }
            // Origin ignored the Range but the chunk starts at 0, so a
            // bounded prefix of the body is exactly the requested bytes. The
            // delegate cancels as soon as that prefix is complete.
            let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            let byteLimit = http.expectedContentLength > 0
                ? Int(min(Int64(state.range.count), http.expectedContentLength))
                : state.range.count
            acceptResponseLocked(
                .media(
                    total: total,
                    entityETag: PlaybackOriginStream.strongETag(
                        http.value(forHTTPHeaderField: "ETag")
                    ),
                    byteLimit: byteLimit
                ),
                taskID: taskID
            )
            return true
        case 200:
            // Accepting head bytes at a nonzero offset would corrupt the cache.
            let cause = entityValidationFailure(
                for: http,
                expectedEntityETag: state.expectedEntityETag
            ) ?? .rangeIgnored
            rejectAttemptLocked(taskID: taskID, cause: cause, statusCode: 200, retryable: false)
            return false
        case 412:
            // If-Match failed. The origin guarantees no representation body
            // was selected, so invalidate the resource immediately.
            rejectAttemptLocked(taskID: taskID, cause: .entityChanged, statusCode: 412, retryable: false)
            return false
        case 404:
            acceptResponseLocked(.notFound, taskID: taskID)
            return true
        case 502, 503, 504:
            rejectAttemptLocked(
                taskID: taskID,
                cause: .httpOutage(http.statusCode),
                statusCode: http.statusCode,
                retryable: true
            )
            return false
        case 416:
            if let total = PlaybackOriginStream.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                callbacks.didReceiveResponse(total)
            }
            rejectAttemptLocked(taskID: taskID, cause: .httpFatal(416), statusCode: 416, retryable: false)
            return false
        default:
            rejectAttemptLocked(
                taskID: taskID,
                cause: .httpFatal(http.statusCode),
                statusCode: http.statusCode,
                retryable: false
            )
            return false
        }
    }

    /// Parses exactly `bytes start-end/total`. A satisfiable 206 cannot use a
    /// wildcard total, negative positions, an inverted interval, or an end at
    /// or beyond the complete representation length.
    private static func parseContentRange(_ header: String?) -> ContentRange? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return nil
        }
        let unit = trimmed[..<separator]
        guard unit.lowercased() == "bytes" else { return nil }
        let value = trimmed[separator...].trimmingCharacters(in: .whitespaces)
        let slashParts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard slashParts.count == 2,
              slashParts[1] != "*",
              let total = Int64(slashParts[1]),
              total > 0 else {
            return nil
        }
        let bounds = slashParts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              start <= end,
              end < total else {
            return nil
        }
        return ContentRange(start: start, end: end, total: total)
    }

    /// Must run on `stateQueue`.
    private func acceptResponseLocked(_ response: AcceptedResponse, taskID: Int) {
        guard var state = attempts[taskID] else { return }
        state.response = response
        switch response {
        case .media(_, _, let byteLimit):
            state.body.reserveCapacity(byteLimit)
        case .notFound:
            state.body.reserveCapacity(4096)
        }
        attempts[taskID] = state
    }

    /// Append one delegate delivery while enforcing a strict per-response
    /// memory ceiling. Returns true when the URLSession task should be
    /// cancelled because the requested prefix (or 404 diagnostic prefix) is
    /// complete and all callbacks have already been delivered.
    fileprivate func handleData(_ data: Data, taskID: Int) -> Bool {
        withState {
            handleDataLocked(data, taskID: taskID)
        }
    }

    /// Must run on `stateQueue`.
    private func handleDataLocked(_ data: Data, taskID: Int) -> Bool {
        guard var state = attempts[taskID], state.response != nil else {
            return true
        }
        switch state.response {
        case .media(_, _, let byteLimit):
            let remaining = max(0, byteLimit - state.body.count)
            if remaining > 0 {
                state.body.append(contentsOf: data.prefix(remaining))
            }
            if state.body.count == byteLimit {
                attempts.removeValue(forKey: taskID)
                completeMediaLocked(state)
                return true
            } else {
                attempts[taskID] = state
            }
        case .notFound:
            let remaining = max(0, 4096 - state.body.count)
            if remaining > 0 {
                state.body.append(contentsOf: data.prefix(remaining))
            }
            if state.body.count == 4096 {
                attempts.removeValue(forKey: taskID)
                completeNotFoundLocked(state)
                return true
            } else {
                attempts[taskID] = state
            }
        case nil:
            break
        }
        return false
    }

    fileprivate func handleCompletion(error: Error?, taskID: Int) {
        withState {
            handleCompletionLocked(error: error, taskID: taskID)
        }
    }

    /// Must run on `stateQueue`.
    private func handleCompletionLocked(error: Error?, taskID: Int) {
        guard let state = attempts.removeValue(forKey: taskID),
              !cancelled,
              inFlight[state.id] != nil else { return }

        if let error {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCancelled {
                finishLocked(id: state.id)
                return
            }
            retryOrFailLocked(
                id: state.id,
                range: state.range,
                attempt: state.attempt,
                cause: .network,
                statusCode: nil
            )
            return
        }
        switch state.response {
        case .media(_, _, let byteLimit):
            guard state.body.count == byteLimit else {
                failLocked(
                    id: state.id,
                    range: state.range,
                    cause: .prematureEOF,
                    statusCode: nil
                )
                return
            }
            completeMediaLocked(state)
        case .notFound:
            completeNotFoundLocked(state)
        case nil:
            retryOrFailLocked(
                id: state.id,
                range: state.range,
                attempt: state.attempt,
                cause: .network,
                statusCode: nil
            )
        }
    }

    private func completeMediaLocked(_ state: AttemptState) {
        guard case .media(let total, let responseETag, _) = state.response else { return }
        storeAndFinishLocked(
            id: state.id,
            range: state.range,
            attempt: state.attempt,
            body: state.body,
            total: total,
            responseETag: responseETag
        )
    }

    private func completeNotFoundLocked(_ state: AttemptState) {
        let body = String(data: state.body, encoding: .utf8)
        if PlaybackOriginStream.isPlaybackSessionMissing(statusCode: 404, body: body) {
            callbacks.didDetectSessionMissing()
            guard !cancelled else { return }
        }
        failLocked(id: state.id, range: state.range, cause: .httpFatal(404), statusCode: 404)
    }

    private func rejectAttemptLocked(
        taskID: Int,
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?,
        retryable: Bool
    ) {
        let state = attempts.removeValue(forKey: taskID)
        guard let state else { return }
        if retryable {
            retryOrFailLocked(
                id: state.id,
                range: state.range,
                attempt: state.attempt,
                cause: cause,
                statusCode: statusCode
            )
        } else {
            failLocked(id: state.id, range: state.range, cause: cause, statusCode: statusCode)
        }
    }

    private func entityValidationFailure(
        for response: HTTPURLResponse,
        expectedEntityETag: String?
    ) -> PlaybackOriginReconnectPolicy.EndCause? {
        guard let expectedEntityETag else {
            return requiresEntityValidation ? .rangeIgnored : nil
        }
        let responseETagHeader = response.value(forHTTPHeaderField: "ETag")
        guard let responseETag = PlaybackOriginStream.strongETag(responseETagHeader) else {
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] chunk entity-unverifiable expectedETag=\(expectedEntityETag, privacy: .public) responseETag=\(responseETagHeader ?? "missing", privacy: .public)"
            )
            return .rangeIgnored
        }
        guard responseETag == expectedEntityETag else {
            Self.logger.error(
                "[CMP-SOURCE-CACHE] chunk entity-changed expectedETag=\(expectedEntityETag, privacy: .public) responseETag=\(responseETagHeader ?? "missing", privacy: .public)"
            )
            return .entityChanged
        }
        return nil
    }

    /// Must run on `stateQueue`.
    private func storeAndFinishLocked(
        id: UUID,
        range: Range<Int64>,
        attempt: Int,
        body: Data,
        total: Int64?,
        responseETag: String?
    ) {
        guard !body.isEmpty else {
            // A 206 with an empty body is an origin bug; a repeat request
            // will not do better.
            failLocked(id: id, range: range, cause: .prematureEOF, statusCode: nil)
            return
        }
        if let cause = callbacks.store(
            range.lowerBound,
            body,
            total,
            responseETag
        ) {
            guard !cancelled else { return }
            retryOrFailLocked(
                id: id,
                range: range,
                attempt: attempt,
                cause: cause,
                statusCode: nil
            )
            return
        }
        guard !cancelled else { return }
        callbacks.didReceiveResponse(total)
        guard !cancelled else { return }
        finishLocked(id: id)
        guard !cancelled else { return }
        callbacks.didStore(range.lowerBound...(range.lowerBound + Int64(body.count) - 1))
    }

    /// Transient failures share the window stream's retry/backoff policy
    /// (`PlaybackOriginReconnectPolicy`) so "how often and how long to retry
    /// an origin read" has one definition. Chunks are never "productive" in
    /// the streak sense — each is a fresh short request.
    /// Must run on `stateQueue`.
    private func retryOrFailLocked(
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
            failLocked(id: id, range: range, cause: cause, statusCode: statusCode)
        case .retry(let delay):
            Self.logger.info("[CMP-SOURCE-CACHE] chunk retry start=\(range.lowerBound, privacy: .public) attempt=\(attempt + 1, privacy: .public) cause=\(String(describing: cause), privacy: .public)")
            Task.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.run(id: id, range: range, attempt: attempt + 1)
            }
        }
    }

    /// Must run on `stateQueue`.
    private func failLocked(
        id: UUID,
        range: Range<Int64>,
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?
    ) {
        Self.logger.warning("[CMP-SOURCE-CACHE] chunk failed start=\(range.lowerBound, privacy: .public) cause=\(String(describing: cause), privacy: .public) status=\(statusCode ?? 0, privacy: .public)")
        finishLocked(id: id)
        guard !cancelled else { return }
        callbacks.didFail(range, cause, statusCode)
    }

    /// Must run on `stateQueue`.
    private func finishLocked(id: UUID) {
        let removed = inFlight.removeValue(forKey: id) != nil
        if removed {
            coverageLock.lock()
            publishedInFlight.removeValue(forKey: id)
            coverageLock.unlock()
            callbacks.endRequest()
        }
    }

    private final class ConnectionDelegate: NSObject, URLSessionDataDelegate {
        private weak var fetcher: PlaybackOriginChunkFetcher?

        init(fetcher: PlaybackOriginChunkFetcher) {
            self.fetcher = fetcher
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let fetcher,
                  fetcher.handleResponse(response, taskID: dataTask.taskIdentifier) else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if fetcher?.handleData(data, taskID: dataTask.taskIdentifier) == true {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            fetcher?.handleCompletion(error: error, taskID: task.taskIdentifier)
        }
    }
}
