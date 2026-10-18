import Foundation

/// The bandwidth probe, ported from the web player's `bandwidth-probe.ts`
/// (and Android's `BandwidthProbe.kt`) with its constants and windowing
/// unchanged. Spec: the server repo's
/// `docs/design/2026-10-17-buffering-quality.md`, "Probe on Android and Apple".
enum BandwidthProbe {
    /// Bytes requested (`?size=`); the time budget usually ends the transfer
    /// first.
    static let requestedBytes = 40_000_000
    /// How long to keep timing once bytes flow: enough to see past TCP
    /// ramp-up.
    static let timeBudgetMs = 2_000
    /// A probe that has not delivered its first byte by then is abandoned.
    static let firstByteDeadlineMs = 10_000
    /// Slack past the time budget before a read that has stopped returning is
    /// cut off; the rate is then taken from the bytes that did arrive.
    static let stalledReadGraceMs = 500
    /// Ramp-up excluded from the rate when the probe ran long enough to spare
    /// it.
    static let warmupMs = 300
    /// The shortest timed window, or smallest byte count, that yields a
    /// usable rate.
    static let minWindowMs = 200
    static let minBytes = 1_000_000
    /// How long a measurement stands in for the network before it is
    /// re-taken.
    static let estimateLifetime: TimeInterval = 30 * 60
    /// The contract bounds `bandwidth_estimate_kbps` to this range.
    static let minEstimateKbps = 100
    static let maxEstimateKbps = 1_000_000

    /// The URL a probe downloads: the advertised `bandwidth_probe_url`,
    /// resolved against `serverURL` when it is relative, asking for
    /// ``requestedBytes``.
    static func downloadURL(serverURL: URL, advertised: String) -> URL? {
        guard let resolved = URL(string: advertised, relativeTo: serverURL)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https" else {
            return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "size" }
        items.append(URLQueryItem(name: "size", value: String(requestedBytes)))
        components.queryItems = items
        return components.url
    }

    /// `kbps` rounded and capped to the contract's range, or nil below its
    /// floor.
    static func clampKbps(_ kbps: Double) -> Int? {
        guard kbps.isFinite, kbps >= Double(minEstimateKbps) else { return nil }
        return min(Int(kbps.rounded()), maxEstimateKbps)
    }
}

/// One probe download, timed: a rate, or why there is none.
enum BandwidthProbeResult: Equatable {
    /// `kbps` measured from `bytes` over `durationMs`, the window the rate
    /// was taken over.
    case measured(kbps: Int, bytes: Int, durationMs: Int)
    /// HTTP 429: the server allows another probe after `retryAfterSeconds`.
    case rateLimited(retryAfterSeconds: Int)
    /// The server refused the download with `status`, for example a
    /// proxy-only policy with no proxy that serves probes. The probe never
    /// falls back to measuring another path.
    case unavailable(status: Int)
    /// The transfer moved too little data, in too short a window, to mean
    /// anything.
    case tooLittleData
    /// The request failed, or no byte arrived by
    /// ``BandwidthProbe/firstByteDeadlineMs``.
    case networkError(String)
}

/// The window arithmetic of one probe, apart from any I/O. Feed it each chunk
/// with the time it arrived (``onChunk(at:size:)``), or the time a stalled
/// read was cut off (``cutOff(at:)``), then read ``result()``. Times are
/// milliseconds on a monotonic clock.
///
/// The clock starts at the first chunk, so request latency and server setup do
/// not count against the link; that chunk's bytes are not counted either,
/// since they arrived before the window opened.
struct BandwidthProbeWindow {
    private(set) var start: Int?
    private var warmAt: Int?
    private var warmBytes = 0
    private var bytes = 0
    private var now = 0

    /// Records `size` bytes arriving at `at`. True once the time budget is
    /// spent.
    mutating func onChunk(at: Int, size: Int) -> Bool {
        now = at
        guard let start else {
            self.start = at
            return false
        }
        bytes += size
        if warmAt == nil, at - start >= BandwidthProbe.warmupMs {
            warmAt = at
            warmBytes = bytes
        }
        return at - start >= BandwidthProbe.timeBudgetMs
    }

    /// Ends the window at `at`: the silent stretch of a stalled read counts
    /// against the rate.
    mutating func cutOff(at: Int) {
        now = at
    }

    func result() -> BandwidthProbeResult {
        guard let start, now > start else { return .tooLittleData }
        let elapsed = now - start
        if elapsed < BandwidthProbe.minWindowMs, bytes < BandwidthProbe.minBytes { return .tooLittleData }
        // Prefer the rate after ramp-up when at least as much time followed it.
        if let warmAt, now - warmAt >= warmAt - start {
            let timed = bytes - warmBytes
            guard let kbps = BandwidthProbe.clampKbps(Double(timed) * 8 / Double(now - warmAt)) else {
                return .tooLittleData
            }
            return .measured(kbps: kbps, bytes: timed, durationMs: now - warmAt)
        }
        // bytes × 8 bits / ms = kbit/s.
        guard let kbps = BandwidthProbe.clampKbps(Double(bytes) * 8 / Double(elapsed)) else {
            return .tooLittleData
        }
        return .measured(kbps: kbps, bytes: bytes, durationMs: elapsed)
    }
}

/// Times one probe download on its own session, reading bytes as they arrive.
///
/// A probe that has not delivered its first byte within
/// ``BandwidthProbe/firstByteDeadlineMs`` of being asked for is abandoned.
/// Once bytes flow it is timed for ``BandwidthProbe/timeBudgetMs``; a transfer
/// that stops delivering is cut off ``BandwidthProbe/stalledReadGraceMs`` after
/// that, and the rate is taken from what arrived. Finishing cancels the
/// transfer, and the server stops at its next write.
///
/// The session refuses cellular, expensive and constrained paths, so a probe
/// cannot spend metered data even if the caller's check raced a network
/// change. A redirect, to the proxy that serves the media, is followed
/// without the account's credentials: the proxy URL carries its own token.
final class BandwidthProbeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Headers a redirect drops.
    static let credentialHeaders: Set<String> = ["authorization", "x-profile-id", "x-profile-token"]

    private let configuration: URLSessionConfiguration
    /// Milliseconds on a monotonic clock.
    private let clock: @Sendable () -> Int
    /// Everything below is confined to this queue.
    private let queue = DispatchQueue(label: "org.siloserver.silo.bandwidth-probe")
    private var window = BandwidthProbeWindow()
    private var session: URLSession?
    private var continuation: CheckedContinuation<BandwidthProbeResult?, Never>?
    private var isFinished = false

    init(
        configuration: URLSessionConfiguration = BandwidthProbeDownload.defaultConfiguration(),
        clock: @escaping @Sendable () -> Int = { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = TimeInterval(BandwidthProbe.firstByteDeadlineMs) / 1000
        return configuration
    }

    /// Downloads `request` and times it. Throws `CancellationError` when the
    /// calling task is cancelled. Call once per instance.
    func measure(_ request: URLRequest) async throws -> BandwidthProbeResult {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { self.begin(request, continuation: continuation) }
            }
        } onCancel: {
            queue.async { self.finish(nil) }
        }
        guard let result else { throw CancellationError() }
        return result
    }

    private func begin(_ request: URLRequest, continuation: CheckedContinuation<BandwidthProbeResult?, Never>) {
        guard !isFinished else {
            // Cancelled before it began.
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        session.dataTask(with: request).resume()
        queue.asyncAfter(deadline: .now() + .milliseconds(BandwidthProbe.firstByteDeadlineMs)) {
            guard !self.isFinished, self.window.start == nil else { return }
            self.finish(.networkError("No probe byte arrived in time."))
        }
    }

    /// Resumes the caller once, with `result` or nil for a cancellation, and
    /// tears the session down, which also releases this delegate.
    private func finish(_ result: BandwidthProbeResult?) {
        guard !isFinished else { return }
        isFinished = true
        session?.invalidateAndCancel()
        session = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            completionHandler(.allow)
        case 429:
            let retryAfter = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            completionHandler(.cancel)
            finish(.rateLimited(retryAfterSeconds: max(retryAfter ?? 60, 1)))
        default:
            completionHandler(.cancel)
            finish(.unavailable(status: status))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        let firstChunk = window.start == nil
        if window.onChunk(at: clock(), size: data.count) {
            finish(window.result())
            return
        }
        guard firstChunk else { return }
        // Ends a transfer that stops delivering, which the budget check above
        // would never reach. The silent stretch counts against the rate.
        let cutOff = BandwidthProbe.timeBudgetMs + BandwidthProbe.stalledReadGraceMs
        queue.asyncAfter(deadline: .now() + .milliseconds(cutOff)) {
            guard !self.isFinished else { return }
            self.window.cutOff(at: self.clock())
            self.finish(self.window.result())
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if let error {
            finish(.networkError(error.localizedDescription))
        } else {
            // The server sent every byte before the budget ran out.
            finish(window.result())
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.withoutCredentials(request))
    }

    /// The advertised URL is on the origin the API answered from, which can be
    /// a pinned local route.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        LocalRouteTrust.handle(challenge, completionHandler: completionHandler)
    }

    static func withoutCredentials(_ request: URLRequest) -> URLRequest {
        var stripped = request
        for name in (request.allHTTPHeaderFields ?? [:]).keys
        where credentialHeaders.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }
}
