import Foundation
import OSLog

/// Routing decisions for byte demands across the (at most two) live origin
/// streams. Pure so ride-through/spawn/retarget behavior is testable.
///
/// Why streams instead of ranged chunks: a strictly sequential range-chunk
/// fetcher pays one RTT of dead air plus a fresh TCP slow-start per chunk, so
/// effective throughput collapses on high-latency links even when raw
/// bandwidth is plentiful (gigabit fiber at 150 ms RTT delivered ~14 Mbps).
/// A long-lived open-ended range GET pays slow-start once and then rides the
/// congestion window at line rate, which is what ordinary direct-play clients
/// do. Two stream slots exist so the matroska open pattern (head probe ↔ cues
/// at tail) and demuxer recycling never churn the warm playback connection.
enum PlaybackOriginStreamPolicy {
    struct StreamSnapshot: Equatable {
        let id: UUID
        let startOffset: Int64
        let writeCursor: Int64
        let lastDemandOrder: UInt64
    }

    enum Action: Equatable {
        /// Demand is at or just ahead of this stream's cursor; wait for it.
        case rideThrough(UUID)
        case spawn
        case retarget(UUID)
    }

    /// A miss this close ahead of a live cursor waits for the stream instead
    /// of opening a new connection.
    static let rideThroughBytes: Int64 = 8 * 1024 * 1024
    static let maxStreams = 2
    /// A stream that is not the most recently demanded stops filling once it
    /// is this far past the last offset anything asked it for.
    static let secondaryForwardCapBytes: Int64 = 16 * 1024 * 1024

    static func action(demandOffset: Int64, streams: [StreamSnapshot]) -> Action {
        if let covered = streams.first(where: {
            demandOffset >= $0.writeCursor && demandOffset - $0.writeCursor <= rideThroughBytes
        }) {
            return .rideThrough(covered.id)
        }
        if streams.count < maxStreams {
            return .spawn
        }
        guard let victim = streams.min(by: { $0.lastDemandOrder < $1.lastDemandOrder }) else {
            return .spawn
        }
        return .retarget(victim.id)
    }

    /// The stream whose fetch region contains `offset`, for demand hints
    /// from cached reads. Prefers the nearest region start so a tail stream
    /// never absorbs demand that belongs to the playback stream.
    static func coveringStream(offset: Int64, streams: [StreamSnapshot]) -> UUID? {
        streams
            .filter { offset >= $0.startOffset && offset <= $0.writeCursor + rideThroughBytes }
            .max(by: { $0.startOffset < $1.startOffset })?
            .id
    }

    static func shouldPause(
        writeCursor: Int64,
        demandMark: Int64,
        isMostRecentlyDemanded: Bool,
        globalBudgetAvailable: Bool
    ) -> Bool {
        if !globalBudgetAvailable { return true }
        if isMostRecentlyDemanded { return false }
        return writeCursor - demandMark >= secondaryForwardCapBytes
    }
}

/// Retry/give-up decisions for a dropped origin connection. Transient WAN
/// errors (radio blips, one RST, a server restart) must reconnect quietly at
/// the write cursor instead of tearing playback down — with a full forward
/// cache the user never notices. Progress-aware: only connections that
/// delivered fewer than `productiveBytesFloor` bytes count toward the streak,
/// so a link that keeps limping forward never gives up.
enum PlaybackOriginReconnectPolicy {
    static let productiveBytesFloor: Int64 = 512 * 1024
    /// No bytes for this long on an unparked connection means the transfer is
    /// wedged (half-open socket, hung origin) and it should be reconnected.
    static let stallSeconds: TimeInterval = 20

    enum EndCause: Equatable {
        case network
        case stalled
        case httpOutage(Int)
        case httpFatal(Int)
        case prematureEOF
        case rangeIgnored
    }

    enum Decision: Equatable {
        case retry(afterSeconds: Double)
        case giveUp
    }

    static func decide(cause: EndCause, unproductiveStreak: Int, everProductive: Bool) -> Decision {
        let cap: Int
        switch cause {
        case .network, .stalled:
            cap = everProductive ? 8 : 4
        case .httpOutage:
            cap = 4
        case .httpFatal, .rangeIgnored:
            cap = 1
        case .prematureEOF:
            cap = 3
        }
        guard unproductiveStreak < cap else { return .giveUp }
        return .retry(afterSeconds: backoffSeconds(streak: unproductiveStreak))
    }

    static func backoffSeconds(streak: Int) -> Double {
        min(8.0, 0.5 * pow(2.0, Double(max(0, streak))))
    }
}

/// One long-lived streaming origin connection: an open-ended
/// `Range: bytes=<cursor>-` GET whose body is stored into the span cache
/// incrementally as each URLSession delivery arrives. Throttling is
/// suspend-based: when the owner reports the readahead budget is full the
/// data task is suspended, TCP flow control parks the connection server-side,
/// and resume is instant — the connection is never closed and re-requested.
final class PlaybackOriginStream {
    struct Callbacks {
        /// Invoked on the session delegate queue after bytes are stored.
        let didStore: (PlaybackOriginStream, ClosedRange<Int64>) -> Void
        /// First response headers for a connection (total length if known).
        let didReceiveResponse: (PlaybackOriginStream, Int64?) -> Void
        let didDetectSessionMissing: (PlaybackOriginStream) -> Void
        let didFinish: (PlaybackOriginStream) -> Void
        let didGiveUp: (PlaybackOriginStream, PlaybackOriginReconnectPolicy.EndCause, Int?) -> Void
        /// Budget/park decision; called with the stream's current cursor and
        /// demand mark, outside the stream's internal lock.
        let mayContinueFilling: (PlaybackOriginStream, Int64, Int64) -> Bool
        let store: (Int64, Data, Int64?) -> Void
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackOriginStream"
    )

    let id = UUID()
    private let originURL: URL
    private let originHeaders: [String: String]
    private let callbacks: Callbacks

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var startOffset: Int64
    private var writeCursor: Int64
    private var demandMark: Int64
    private var demandOrder: UInt64
    private var parked = false
    private var cancelled = false
    private var finished = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastDataAt = Date()
    private var bytesSinceConnect: Int64 = 0
    private var everProductive = false
    private var unproductiveStreak = 0
    private var knownTotalLength: Int64?
    private var responseValidatedForGeneration: UInt64?
    private var errorBody = Data()
    private var errorStatusCode: Int?

    init(
        originURL: URL,
        originHeaders: [String: String],
        startOffset: Int64,
        demandOrder: UInt64,
        callbacks: Callbacks
    ) {
        self.originURL = originURL
        self.originHeaders = originHeaders
        self.startOffset = startOffset
        self.writeCursor = startOffset
        self.demandMark = startOffset
        self.demandOrder = demandOrder
        self.callbacks = callbacks
    }

    deinit {
        // Backstop: a stream dropped without cancel() would otherwise leave
        // its URLSession (which retains itself until invalidated) pulling
        // the file into a deallocated delegate forever.
        cancel()
    }

    func snapshot() -> PlaybackOriginStreamPolicy.StreamSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PlaybackOriginStreamPolicy.StreamSnapshot(
            id: id,
            startOffset: startOffset,
            writeCursor: writeCursor,
            lastDemandOrder: demandOrder
        )
    }

    var currentDemandOrder: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return demandOrder
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func start() {
        openConnection()
        startWatchdog()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        generation &+= 1
        let session = self.session
        self.session = nil
        self.task = nil
        let reconnect = reconnectTask
        reconnectTask = nil
        let watchdog = watchdogTask
        watchdogTask = nil
        lock.unlock()
        session?.invalidateAndCancel()
        reconnect?.cancel()
        watchdog?.cancel()
    }

    /// Repoint this stream at a new offset (seek/demand moved outside every
    /// stream's coverage). Reconnects immediately; reconnect bookkeeping
    /// resets because this is a new region, not a failing one. Returns
    /// false if the stream already finished or gave up — a terminal stream
    /// must never be revived, because its removal from the owner's pool is
    /// already in flight and a revived connection would leak.
    @discardableResult
    func retarget(to offset: Int64, order: UInt64) -> Bool {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return false
        }
        generation &+= 1
        let oldSession = session
        session = nil
        task = nil
        let reconnect = reconnectTask
        reconnectTask = nil
        startOffset = offset
        writeCursor = offset
        demandMark = offset
        demandOrder = order
        parked = false
        bytesSinceConnect = 0
        unproductiveStreak = 0
        lock.unlock()
        oldSession?.invalidateAndCancel()
        reconnect?.cancel()
        openConnection()
        startWatchdog()
        return true
    }

    /// Record a demand landing in this stream's region and unpark if the
    /// budget allows.
    func noteDemand(offset: Int64, order: UInt64) {
        lock.lock()
        demandMark = max(demandMark, max(startOffset, offset))
        demandOrder = max(demandOrder, order)
        lock.unlock()
        resumeFillingIfNeeded()
    }

    func resumeFillingIfNeeded() {
        lock.lock()
        let shouldConsider = parked && !cancelled && !finished
        let cursor = writeCursor
        let mark = demandMark
        lock.unlock()
        guard shouldConsider else { return }
        guard callbacks.mayContinueFilling(self, cursor, mark) else { return }
        lock.lock()
        if parked, !cancelled {
            parked = false
            task?.resume()
        }
        lock.unlock()
    }

    // MARK: - Connection lifecycle

    private func openConnection() {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return
        }
        generation &+= 1
        let gen = generation
        let cursor = writeCursor
        let oldSession = session
        parked = false
        bytesSinceConnect = 0
        lastDataAt = Date()
        responseValidatedForGeneration = nil
        errorBody.removeAll(keepingCapacity: false)
        errorStatusCode = nil

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        // The long-lived request is paused via task suspension for
        // arbitrarily long stretches; the idle-based request timeout must
        // never fire underneath it. Wedged transfers are detected by the
        // stall watchdog instead.
        config.timeoutIntervalForRequest = 3600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        let delegate = ConnectionDelegate(stream: self, generation: gen)
        let newSession = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)

        var request = URLRequest(url: originURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3600
        for (key, value) in originHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(cursor)-", forHTTPHeaderField: "Range")
        let newTask = newSession.dataTask(with: request)
        session = newSession
        task = newTask
        lock.unlock()

        oldSession?.invalidateAndCancel()
        Self.logger.info("[CMP-SOURCE-CACHE] origin stream connect offset=\(cursor, privacy: .public) gen=\(gen, privacy: .public)")
        newTask.resume()
    }

    private func startWatchdog() {
        lock.lock()
        guard watchdogTask == nil, !cancelled else {
            lock.unlock()
            return
        }
        watchdogTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                self.reconnectIfStalled()
            }
        }
        lock.unlock()
    }

    private func reconnectIfStalled() {
        lock.lock()
        let stalled = !cancelled && !finished && !parked && session != nil
            && Date().timeIntervalSince(lastDataAt) > PlaybackOriginReconnectPolicy.stallSeconds
        lock.unlock()
        guard stalled else { return }
        Self.logger.warning("[CMP-SOURCE-CACHE] origin stream stalled; reconnecting cursor=\(self.snapshot().writeCursor, privacy: .public)")
        connectionEnded(generation: currentGeneration(), cause: .stalled, statusCode: nil)
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    // MARK: - Delegate plumbing (called on the session delegate queue)

    fileprivate func handleResponse(_ response: URLResponse, generation gen: UInt64) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            connectionEnded(generation: gen, cause: .network, statusCode: nil)
            return false
        }
        lock.lock()
        guard gen == generation, !cancelled else {
            lock.unlock()
            return false
        }
        let cursor = writeCursor
        lock.unlock()

        switch http.statusCode {
        case 206:
            let total = Self.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            if let rangeStart = Self.rangeStart(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")),
               rangeStart != cursor {
                Self.logger.warning("[CMP-SOURCE-CACHE] origin stream range mismatch expected=\(cursor, privacy: .public) got=\(rangeStart, privacy: .public)")
                connectionEnded(generation: gen, cause: .rangeIgnored, statusCode: http.statusCode)
                return false
            }
            noteResponse(total: total, generation: gen)
            return true
        case 200 where cursor == 0:
            let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            noteResponse(total: total, generation: gen)
            return true
        case 200:
            // The origin ignored the Range header; accepting the body would
            // silently corrupt the cache with head bytes at a nonzero offset.
            connectionEnded(generation: gen, cause: .rangeIgnored, statusCode: 200)
            return false
        case 416:
            // Requested past the end. If the origin tells us the real total,
            // learn it and finish cleanly so waiters re-drive to EOF.
            if let total = Self.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                noteResponse(total: total, generation: gen)
                finishStream(expectedGeneration: gen)
                return false
            }
            connectionEnded(generation: gen, cause: .httpFatal(416), statusCode: 416)
            return false
        default:
            // Keep the (small) error body so session-missing 404s can be
            // classified at completion.
            lock.lock()
            errorStatusCode = http.statusCode
            lock.unlock()
            return true
        }
    }

    private func noteResponse(total: Int64?, generation gen: UInt64) {
        lock.lock()
        guard gen == generation else {
            lock.unlock()
            return
        }
        responseValidatedForGeneration = gen
        if let total { knownTotalLength = total }
        lock.unlock()
        callbacks.didReceiveResponse(self, total)
    }

    fileprivate func handleData(_ data: Data, generation gen: UInt64) {
        lock.lock()
        guard gen == generation, !cancelled else {
            lock.unlock()
            return
        }
        if errorStatusCode != nil {
            if errorBody.count < 4096 {
                errorBody.append(data.prefix(4096 - errorBody.count))
            }
            lock.unlock()
            return
        }
        guard responseValidatedForGeneration == gen else {
            lock.unlock()
            return
        }
        let start = writeCursor
        writeCursor += Int64(data.count)
        let cursor = writeCursor
        let mark = demandMark
        lastDataAt = Date()
        bytesSinceConnect += Int64(data.count)
        if bytesSinceConnect >= PlaybackOriginReconnectPolicy.productiveBytesFloor {
            everProductive = true
            unproductiveStreak = 0
        }
        let total = knownTotalLength
        lock.unlock()

        callbacks.store(start, data, total)
        callbacks.didStore(self, start...(cursor - 1))

        if let total, cursor >= total {
            finishStream(expectedGeneration: gen)
            return
        }
        if !callbacks.mayContinueFilling(self, cursor, mark) {
            lock.lock()
            let didPark = !parked && !cancelled && gen == generation
            if didPark {
                // Suspend while still holding the lock so `parked` and the
                // task state can never be observed inconsistent: a resume
                // racing this park would otherwise fire against a
                // still-running task (no-op) and be lost.
                parked = true
                task?.suspend()
            }
            lock.unlock()
            if didPark {
                // A demand may have raised the mark between the decision
                // above and the park; its unpark attempt saw parked ==
                // false and did nothing. Re-run the decision with fresh
                // marks so that demand is honored.
                resumeFillingIfNeeded()
            }
        }
    }

    fileprivate func handleCompletion(error: Error?, generation gen: UInt64) {
        lock.lock()
        guard gen == generation, !cancelled, !finished else {
            lock.unlock()
            return
        }
        let status = errorStatusCode
        let body = String(data: errorBody, encoding: .utf8)
        let cursor = writeCursor
        let total = knownTotalLength
        lock.unlock()

        if let status {
            if Self.isPlaybackSessionMissing(statusCode: status, body: body) {
                callbacks.didDetectSessionMissing(self)
                giveUp(cause: .httpFatal(status), statusCode: status, expectedGeneration: gen)
                return
            }
            let cause: PlaybackOriginReconnectPolicy.EndCause =
                [502, 503, 504].contains(status) ? .httpOutage(status) : .httpFatal(status)
            connectionEnded(generation: gen, cause: cause, statusCode: status)
            return
        }
        if let error {
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorCancelled {
                return
            }
            connectionEnded(generation: gen, cause: .network, statusCode: nil)
            return
        }
        // Clean close. Either we reached the promised end or the origin
        // stopped early.
        if let total, cursor >= total {
            finishStream(expectedGeneration: gen)
            return
        }
        connectionEnded(generation: gen, cause: .prematureEOF, statusCode: nil)
    }

    private func finishStream(expectedGeneration: UInt64) {
        lock.lock()
        guard generation == expectedGeneration, !finished, !cancelled else {
            lock.unlock()
            return
        }
        finished = true
        generation &+= 1
        let session = self.session
        self.session = nil
        self.task = nil
        let watchdog = watchdogTask
        watchdogTask = nil
        lock.unlock()
        session?.invalidateAndCancel()
        watchdog?.cancel()
        callbacks.didFinish(self)
    }

    private func connectionEnded(
        generation gen: UInt64,
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?
    ) {
        lock.lock()
        guard gen == generation, !cancelled, !finished else {
            lock.unlock()
            return
        }
        generation &+= 1
        let newGeneration = generation
        let oldSession = session
        session = nil
        task = nil
        parked = false
        if bytesSinceConnect < PlaybackOriginReconnectPolicy.productiveBytesFloor {
            unproductiveStreak += 1
        } else {
            unproductiveStreak = 0
        }
        let streak = unproductiveStreak
        let productive = everProductive
        lock.unlock()
        oldSession?.invalidateAndCancel()

        // The streak was already advanced for this failure; decide() gets the
        // pre-failure count so caps mean "attempts before giving up".
        switch PlaybackOriginReconnectPolicy.decide(
            cause: cause,
            unproductiveStreak: streak - 1,
            everProductive: productive
        ) {
        case .giveUp:
            giveUp(cause: cause, statusCode: statusCode, expectedGeneration: newGeneration)
        case .retry(let delay):
            Self.logger.info("[CMP-SOURCE-CACHE] origin stream reconnect in \(delay, privacy: .public)s cause=\(String(describing: cause), privacy: .public) streak=\(streak, privacy: .public)")
            lock.lock()
            reconnectTask?.cancel()
            reconnectTask = Task.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.openConnection()
            }
            lock.unlock()
        }
    }

    private func giveUp(
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?,
        expectedGeneration: UInt64
    ) {
        lock.lock()
        guard generation == expectedGeneration, !cancelled, !finished else {
            lock.unlock()
            return
        }
        finished = true
        generation &+= 1
        let session = self.session
        self.session = nil
        self.task = nil
        let watchdog = watchdogTask
        watchdogTask = nil
        lock.unlock()
        session?.invalidateAndCancel()
        watchdog?.cancel()
        Self.logger.warning("[CMP-SOURCE-CACHE] origin stream gave up cause=\(String(describing: cause), privacy: .public)")
        callbacks.didGiveUp(self, cause, statusCode)
    }

    // MARK: - Parsing helpers

    static func totalLength(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let suffix = header[header.index(after: slash)...]
        guard suffix != "*", let total = Int64(suffix) else { return nil }
        return total
    }

    static func rangeStart(fromContentRange header: String?) -> Int64? {
        guard let header else { return nil }
        // "bytes 123-456/789"
        guard let spaceIdx = header.firstIndex(of: " ") else { return nil }
        let afterUnit = header[header.index(after: spaceIdx)...]
        guard let dash = afterUnit.firstIndex(of: "-") else { return nil }
        return Int64(afterUnit[..<dash])
    }

    static func isPlaybackSessionMissing(statusCode: Int, body: String?) -> Bool {
        guard statusCode == 404 else { return false }
        let text = body ?? ""
        return text.contains("playback_session_not_found")
            || text.contains("Playback session not found")
    }

    // MARK: - URLSession delegate bridge

    private final class ConnectionDelegate: NSObject, URLSessionDataDelegate {
        private weak var stream: PlaybackOriginStream?
        private let generation: UInt64

        init(stream: PlaybackOriginStream, generation: UInt64) {
            self.stream = stream
            self.generation = generation
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let stream, stream.handleResponse(response, generation: generation) else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            stream?.handleData(data, generation: generation)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            stream?.handleCompletion(error: error, generation: generation)
        }
    }
}
