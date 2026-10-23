import Foundation

/// The connection speed test. Spec: the server repo's
/// `docs/design/2026-10-17-buffering-quality.md`, "Connection speed test";
/// the vectors' `probe_cases` pin its arithmetic (``BandwidthProbeMeter``).
///
/// It measures the path the media takes over one connection, because playback
/// reads through one connection: one `AVIOReader` pump, or one Aether relay
/// request per AVPlayer request.
enum BandwidthProbe {
    /// `PROBE_WINDOW_MS`: bytes count in the window they arrive in.
    static let windowMs = 500
    /// `QUICK_PROBE_BYTES`, `QUICK_PROBE_MAX_MS`, `QUICK_SETTLE_WINDOWS`.
    static let quickBytes = 100_000_000
    static let quickMaxMs = 3_000
    static let quickSettleWindows = 2
    /// `ACCURATE_PROBE_BYTES`, `ACCURATE_PROBE_MAX_MS`,
    /// `ACCURATE_SETTLE_WINDOWS`.
    static let accurateBytes = 1_000_000_000
    static let accurateMaxMs = 10_000
    static let accurateSettleWindows = 6
    /// `PROBE_FIRST_BYTE_DEADLINE_MS`: a test whose first byte has not arrived
    /// by then is abandoned.
    static let firstByteDeadlineMs = 10_000
    /// `MIN_PROBE_KBPS`: a slower result measured nothing.
    static let minKbps = 100
    /// `MAX_PROBE_KBPS`: a faster result is reported as this, as a lower
    /// bound. It is also the contract's ceiling on `bandwidth_estimate_kbps`.
    static let maxKbps = 1_000_000

    /// The URL a test downloads: `url`, the resolved `bandwidth_probe_url`,
    /// asking for `bytes`. The download carries the account's credentials, so
    /// an `https` server's test never goes to a cleartext `http` URL, as for
    /// stream URLs (``StreamRequest``).
    static func downloadURL(_ url: URL, serverURL: URL, bytes: Int) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && serverURL.scheme?.lowercased() == "http") else {
            return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "size" }
        items.append(URLQueryItem(name: "size", value: String(bytes)))
        components.queryItems = items
        return components.url
    }
}

/// One test download, timed: a rate, or why there is none.
enum BandwidthProbeResult: Equatable {
    /// The rate, from the windows it came from or the whole transfer. A
    /// `lowerBound` says the link is at least this fast.
    case measured(BandwidthProbeMeter.Measurement)
    /// HTTP 429: the server allows another test after `retryAfterSeconds`.
    case rateLimited(retryAfterSeconds: Int)
    /// The server refused the download with `status`, for example a
    /// proxy-only policy with no proxy that serves probes. The test never
    /// falls back to measuring another path.
    case unavailable(status: Int)
    /// No complete window after window 0 and not every requested byte, or a
    /// rate under the floor.
    case tooLittleData
    /// The request failed, or no byte arrived by
    /// ``BandwidthProbe/firstByteDeadlineMs``.
    case networkError(String)
}

/// The speed test's arithmetic, apart from any I/O, as the spec's
/// "Measuring" defines it and `probe_cases` pins it. Times are milliseconds
/// after the first byte.
///
/// Window `k` covers `[500k, 500k + 500)`. Window 0 is TCP ramp-up and never
/// counts; a window counts once the clock passes its end, at 0 if nothing
/// arrived in it, so a stalled transfer lowers the result.
/// - A quick test with a target stops at the end of the first window after
///   window 0 whose rate reaches the target, and reports the target as a
///   lower bound. Otherwise it reports the settled rate.
/// - The settled rate is over the last complete windows after window 0 that
///   fill the span (2 quick, 6 accurate), or all of them when there are fewer.
/// - A transfer that delivers every requested byte before a window after
///   window 0 completes is measured over the whole transfer, which includes
///   the ramp and so can only read low: a lower bound, or the target when a
///   quick test's average reaches it.
struct BandwidthProbeMeter {
    enum Mode: Equatable {
        /// Automatic. `targetKbps` is the server's `bandwidth_probe_target_kbps`.
        case quick(targetKbps: Int?)
        /// **Test speed** only.
        case accurate
    }

    struct Measurement: Equatable {
        let kbps: Int
        let lowerBound: Bool
        /// The bytes and span of the windows the rate came from.
        let bytes: Int
        let durationMs: Int
    }

    let mode: Mode
    /// The quick test's target, held to 100..1,000,000 kbps so a reported
    /// target is always a value the server accepts.
    private var target: Int? {
        guard case .quick(let target?) = mode else { return nil }
        return min(max(target, BandwidthProbe.minKbps), BandwidthProbe.maxKbps)
    }
    /// `size=` for the request.
    let requestedBytes: Int
    /// The test stops this long after the first byte.
    let maxMs: Int
    private let settleWindows: Int

    /// Bytes per window, by index.
    private var windowBytes: [Int] = []
    /// Every byte that counted.
    private var receivedBytes = 0
    /// Whether the transfer's end, not a limit or the target, stopped the test.
    private var transferDidEnd = false
    /// Windows whose end the clock has passed.
    private(set) var closedWindows = 0
    /// When the test stopped reading; nil while it runs.
    private(set) var stoppedAt: Int?
    /// The window that reached the quick test's target.
    private var targetWindow: Int?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .quick:
            requestedBytes = BandwidthProbe.quickBytes
            maxMs = BandwidthProbe.quickMaxMs
            settleWindows = BandwidthProbe.quickSettleWindows
        case .accurate:
            requestedBytes = BandwidthProbe.accurateBytes
            maxMs = BandwidthProbe.accurateMaxMs
            settleWindows = BandwidthProbe.accurateSettleWindows
        }
    }

    /// The clock reached `t`: closes every window that ended by then, which
    /// can stop a quick test on its target, and stops any test at its limit.
    /// True once the test has stopped.
    @discardableResult
    mutating func advance(to t: Int) -> Bool {
        guard stoppedAt == nil else { return true }
        let now = min(t, maxMs)
        while (closedWindows + 1) * BandwidthProbe.windowMs <= now {
            let window = closedWindows
            closedWindows += 1
            if window > 0, let target, rate(of: window) >= target {
                targetWindow = window
                stoppedAt = closedWindows * BandwidthProbe.windowMs
                return true
            }
        }
        if t >= maxMs {
            stoppedAt = maxMs
            return true
        }
        return false
    }

    /// `bytes` arrived at `t`. Bytes after the test stopped do not count.
    mutating func receive(_ bytes: Int, at t: Int) {
        guard !advance(to: t) else { return }
        let window = t / BandwidthProbe.windowMs
        if windowBytes.count <= window {
            windowBytes.append(contentsOf: repeatElement(0, count: window + 1 - windowBytes.count))
        }
        windowBytes[window] += bytes
        receivedBytes += bytes
    }

    /// The transfer ended at `t`. A window it cut short does not count.
    mutating func transferEnded(at t: Int) {
        guard !advance(to: t) else { return }
        stoppedAt = t
        transferDidEnd = true
    }

    /// What the test measured once it stopped; nil when it measured nothing.
    var result: Measurement? {
        guard stoppedAt != nil else { return nil }
        if let targetWindow, let target {
            return Measurement(
                kbps: target, lowerBound: true,
                bytes: bytes(of: targetWindow), durationMs: BandwidthProbe.windowMs
            )
        }
        let complete = closedWindows - 1
        guard complete > 0 else { return wholeTransfer }
        let count = min(settleWindows, complete)
        let bytes = (closedWindows - count..<closedWindows).reduce(0) { $0 + self.bytes(of: $1) }
        let durationMs = count * BandwidthProbe.windowMs
        let kbps = bytes * 8 / durationMs
        guard kbps >= BandwidthProbe.minKbps else { return nil }
        if kbps > BandwidthProbe.maxKbps {
            return Measurement(kbps: BandwidthProbe.maxKbps, lowerBound: true, bytes: bytes, durationMs: durationMs)
        }
        return Measurement(kbps: kbps, lowerBound: false, bytes: bytes, durationMs: durationMs)
    }

    /// `floor(bytes × 8 / ms)` from the first byte to the last, when the
    /// transfer delivered every requested byte; nil otherwise.
    private var wholeTransfer: Measurement? {
        guard transferDidEnd, receivedBytes >= requestedBytes, let durationMs = stoppedAt, durationMs > 0 else {
            return nil
        }
        let kbps = receivedBytes * 8 / durationMs
        if let target, kbps >= target {
            return Measurement(kbps: target, lowerBound: true, bytes: receivedBytes, durationMs: durationMs)
        }
        return Measurement(
            kbps: min(kbps, BandwidthProbe.maxKbps), lowerBound: true,
            bytes: receivedBytes, durationMs: durationMs
        )
    }

    private func bytes(of window: Int) -> Int {
        window < windowBytes.count ? windowBytes[window] : 0
    }

    /// `floor(bytes × 8 / 500)` kbps.
    private func rate(of window: Int) -> Int {
        bytes(of: window) * 8 / BandwidthProbe.windowMs
    }
}

/// Runs one test on its own session, reading bytes as they arrive and timing
/// them with a ``BandwidthProbeMeter``.
///
/// The meter's clock starts at the first byte of the body, so request latency
/// does not count. A tick every window closes windows in which nothing
/// arrived. A test whose first byte has not arrived within
/// ``BandwidthProbe/firstByteDeadlineMs`` is abandoned. Stopping cancels the
/// transfer, and the server stops at its next write.
///
/// The session refuses cellular, expensive and constrained paths, so a test
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
    private var meter: BandwidthProbeMeter
    private var firstByteAt: Int?
    private var tick: DispatchSourceTimer?
    private var session: URLSession?
    private var continuation: CheckedContinuation<BandwidthProbeResult?, Never>?
    private var isFinished = false

    init(
        mode: BandwidthProbeMeter.Mode,
        configuration: URLSessionConfiguration = BandwidthProbeDownload.defaultConfiguration(),
        clock: @escaping @Sendable () -> Int = { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    ) {
        meter = BandwidthProbeMeter(mode: mode)
        self.configuration = configuration
        self.clock = clock
    }

    /// The `size=` this test asks for.
    var requestedBytes: Int { meter.requestedBytes }

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
            guard !self.isFinished, self.firstByteAt == nil else { return }
            self.finish(.networkError("No probe byte arrived in time."))
        }
    }

    /// Milliseconds since the first byte.
    private var elapsed: Int {
        clock() - (firstByteAt ?? clock())
    }

    /// The test stopped: its measurement, or why there is none.
    private func finishMeasured() {
        finish(meter.result.map(BandwidthProbeResult.measured) ?? .tooLittleData)
    }

    /// Resumes the caller once, with `result` or nil for a cancellation, and
    /// tears the session down, which also releases this delegate.
    private func finish(_ result: BandwidthProbeResult?) {
        guard !isFinished else { return }
        isFinished = true
        tick?.cancel()
        tick = nil
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
            // A missing or unreadable header counts as 30 s, one under 1 s as 1 s.
            finish(.rateLimited(retryAfterSeconds: max(retryAfter ?? 30, 1)))
        default:
            completionHandler(.cancel)
            finish(.unavailable(status: status))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        if firstByteAt == nil {
            firstByteAt = clock()
            startTick()
        }
        meter.receive(data.count, at: elapsed)
        if meter.stoppedAt != nil { finishMeasured() }
    }

    /// Closes windows on the clock, not only when data arrives.
    private func startTick() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let window = DispatchTimeInterval.milliseconds(BandwidthProbe.windowMs)
        timer.schedule(deadline: .now() + window, repeating: window, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            if self.meter.advance(to: self.elapsed) { self.finishMeasured() }
        }
        tick = timer
        timer.resume()
    }

    /// The error's domain and code, safe to log: a description can name the
    /// host, as a certificate error's does.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if let error {
            finish(.networkError(Self.describe(error)))
        } else if firstByteAt == nil {
            finish(.tooLittleData)
        } else {
            meter.transferEnded(at: elapsed)
            finishMeasured()
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
