import Foundation
import OSLog

/// Routing for byte demands, borrowed from AetherEngine's AVIOReader split:
/// ONE long-lived streaming window connection serves the sequential playback
/// read (pays TCP slow-start once, then rides the congestion window at line
/// rate), and every random-access miss — matroska head/tail probes, subtitle
/// extractor reads, attachment seeks — is served by discrete keep-alive
/// range chunks that never touch the window. The window moves only when the
/// consumer itself moves: a serve connection that has already streamed
/// `windowClaimBytes` sequentially is the playback reader, and its miss
/// re-anchors the window (a seek); probe connections read far less before
/// closing and can never steal it. The previous N-slot pool retargeted the
/// warm playback connection on every probe (2026-07-05 device log: retarget
/// storm, gen 1→79 in two minutes, ingest pinned ~12 Mbps under a
/// 20 Mbps-peak source while the same file played fine in AetherEngine).
enum PlaybackOriginRoutingPolicy {
    /// A miss this close ahead of the window's cursor waits for the window
    /// instead of fetching a chunk.
    static let rideThroughBytes: Int64 = 8 * 1024 * 1024
    /// Discrete range-fetch size for random-access misses. AetherEngine
    /// ships 4 MB (8 MB chunks with per-request sessions bled throughput).
    static let chunkBytes: Int64 = 4 * 1024 * 1024
    /// Sequential bytes a single serve connection must have consumed before
    /// its miss may re-anchor the window. Probe reads (mkv head, cues at
    /// tail, subtitle extractor) stay well below this; the producer's
    /// open-ended read passes it within seconds.
    static let windowClaimBytes: Int64 = 8 * 1024 * 1024

    enum Route: Equatable {
        /// Wait for the window connection to deliver the byte.
        case rideWindow
        /// Fetch a discrete chunk; the window is not disturbed.
        case chunk
        /// The sequential consumer moved: re-anchor (or spawn) the window at
        /// the demand offset.
        case claimWindow
    }

    static func route(
        demandOffset: Int64,
        windowCursor: Int64?,
        servedSequentialBytes: Int64
    ) -> Route {
        if let cursor = windowCursor,
           demandOffset >= cursor,
           demandOffset - cursor <= rideThroughBytes {
            return .rideWindow
        }
        if servedSequentialBytes >= windowClaimBytes {
            return .claimWindow
        }
        return .chunk
    }
}

/// Pause/backpressure decisions for the window stream plus its snapshot
/// type. (Routing across multiple streams lived here before the
/// window+chunk split — see `PlaybackOriginRoutingPolicy`.)
enum PlaybackOriginStreamPolicy {
    /// The window's fetch region: where it started and how far it has
    /// filled. All the state the routing and hint paths need.
    struct StreamSnapshot: Equatable {
        let startOffset: Int64
        let writeCursor: Int64
    }

    /// Whether the window should stop filling forward: only when the global
    /// readahead budget is exhausted AND no demand is blocked at or ahead of
    /// the cursor. A demand at/ahead of the cursor is blocked on bytes only
    /// this connection will deliver, and budget pressure must never park it:
    /// the budget frees through reads, and the read is exactly what is
    /// blocked — parking here wedges playback permanently.
    static func shouldPause(
        writeCursor: Int64,
        demandMark: Int64,
        globalBudgetAvailable: Bool
    ) -> Bool {
        if demandMark >= writeCursor { return false }
        return !globalBudgetAvailable
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

/// Ride-through decisions for an origin that has stopped delivering
/// (workstream B of docs/superpowers/plans/2026-07-07-playback-continuity-client.md).
/// When the reconnect ladder gives up on a retryable cause, the resource
/// parks the blocked byte demands instead of failing them, keeps re-probing
/// the origin on a slow cadence, and lets the player ride its buffered
/// runway. Visibility is the view model's decision (runway-gated), not the
/// transport's.
enum PlaybackOriginOutagePolicy {
    /// Delay between origin re-probes while parked in an outage. The view
    /// model's server-health poll nudges an immediate re-probe when the
    /// health endpoint comes back, so this cadence is only the fallback.
    /// `var` so tests can compress it.
    static var probeDelaySeconds: Double = 5.0

    /// Kill switch: setting SILO_DISABLE_OUTAGE_RIDE_THROUGH=1 restores the
    /// legacy behavior (give-up fails waiters and escalates to the visible
    /// outage recovery immediately).
    static func rideThroughEnabled() -> Bool {
        ProcessInfo.processInfo.environment["SILO_DISABLE_OUTAGE_RIDE_THROUGH"] != "1"
    }

    /// Whether a give-up with this cause parks the failed byte demands
    /// (outage ride-through) instead of failing them.
    ///
    /// `httpFatal(404)` parks only when the session-missing sentinel was
    /// observed: the silent background session renewal is in flight and its
    /// retarget will re-drive the parked demands against the renewed
    /// session. Every other fatal cause keeps the legacy fail-fast path.
    static func shouldPark(
        cause: PlaybackOriginReconnectPolicy.EndCause,
        sessionMissingObserved: Bool,
        rideThroughEnabled: Bool
    ) -> Bool {
        guard rideThroughEnabled else { return false }
        switch cause {
        case .network, .stalled, .httpOutage:
            return true
        case .httpFatal(let code):
            return code == 404 && sessionMissingObserved
        case .prematureEOF, .rangeIgnored:
            return false
        }
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
        /// First byte at or after the given offset that the cache does not
        /// already hold (nil when everything to the known EOF is cached);
        /// used to jump the connection over long already-cached runs instead
        /// of re-downloading them.
        let nextMissingByte: (Int64) -> Int64?
        let store: (Int64, Data, Int64?) -> Void
    }

    /// While filling, every this many delivered bytes the stream checks
    /// whether an already-cached run starts at its cursor.
    static let cachedRunCheckStrideBytes: Int64 = 1 * 1024 * 1024
    /// A cached run at least this long is worth a reconnect to jump over
    /// instead of re-downloading through it (a back-scrubbed forward cache
    /// can hold hundreds of megabytes the stream would otherwise re-pull).
    /// High deliberately: partial-coverage swiss cheese from earlier
    /// sessions produced a reconnect every few MB at the old 8 MB
    /// threshold, and each reconnect restarts TCP slow-start — reading
    /// through a modest cached run on the warm connection is cheaper
    /// (AetherEngine's window never skips at all).
    static let cachedRunSkipBytes: Int64 = 64 * 1024 * 1024

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
    private var skipCheckCursor: Int64
    private var parked = false
    private var cancelled = false
    private var finished = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var currentTaskID: Int?
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
        self.skipCheckCursor = startOffset + Self.cachedRunCheckStrideBytes
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
            startOffset: startOffset,
            writeCursor: writeCursor
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
        currentTaskID = nil
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
        let oldTask = task
        task = nil
        currentTaskID = nil
        let reconnect = reconnectTask
        reconnectTask = nil
        startOffset = offset
        writeCursor = offset
        demandMark = offset
        demandOrder = order
        skipCheckCursor = offset + Self.cachedRunCheckStrideBytes
        parked = false
        bytesSinceConnect = 0
        unproductiveStreak = 0
        lock.unlock()
        oldTask?.cancel()
        reconnect?.cancel()
        openConnection()
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
        let oldTask = task
        parked = false
        bytesSinceConnect = 0
        lastDataAt = Date()
        responseValidatedForGeneration = nil
        errorBody.removeAll(keepingCapacity: false)
        errorStatusCode = nil

        if session == nil {
            // One session for the stream's whole lifetime. Invalidating a
            // session destroys its connection pool, so per-attempt sessions
            // would pay a fresh TCP+TLS handshake plus slow-start on every
            // reconnect and retarget — the per-request cost this engine
            // exists to eliminate. Replacement range GETs on the shared
            // session reuse the warm connection where the transport allows.
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
            session = URLSession(
                configuration: config,
                delegate: ConnectionDelegate(stream: self),
                delegateQueue: delegateQueue
            )
        }

        var request = URLRequest(url: originURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3600
        for (key, value) in originHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(cursor)-", forHTTPHeaderField: "Range")
        let newTask = session?.dataTask(with: request)
        task = newTask
        currentTaskID = newTask?.taskIdentifier
        lock.unlock()

        oldTask?.cancel()
        Self.logger.info("[CMP-SOURCE-CACHE] origin stream connect offset=\(cursor, privacy: .public) gen=\(gen, privacy: .public)")
        newTask?.resume()
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
        let stalled = !cancelled && !finished && !parked && session != nil && task != nil
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

    fileprivate func handleResponse(_ response: URLResponse, taskID: Int) -> Bool {
        lock.lock()
        guard taskID == currentTaskID, !cancelled else {
            lock.unlock()
            return false
        }
        let gen = generation
        let cursor = writeCursor
        lock.unlock()
        guard let http = response as? HTTPURLResponse else {
            connectionEnded(generation: gen, cause: .network, statusCode: nil)
            return false
        }

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

    fileprivate func handleData(_ data: Data, taskID: Int) {
        lock.lock()
        guard taskID == currentTaskID, !cancelled else {
            lock.unlock()
            return
        }
        let gen = generation
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
        let total = knownTotalLength
        lock.unlock()

        // Store before publishing the advanced cursor: a snapshot taken
        // between the two would show these bytes as behind the cursor
        // (never arriving on this stream) while they are still in flight to
        // the cache, misrouting the demand onto a fresh connection.
        callbacks.store(start, data, total)

        lock.lock()
        guard gen == generation, !cancelled else {
            lock.unlock()
            return
        }
        writeCursor += Int64(data.count)
        let cursor = writeCursor
        let mark = demandMark
        lastDataAt = Date()
        bytesSinceConnect += Int64(data.count)
        if bytesSinceConnect >= PlaybackOriginReconnectPolicy.productiveBytesFloor {
            everProductive = true
            unproductiveStreak = 0
        }
        let checkCachedRun = cursor >= skipCheckCursor
        if checkCachedRun {
            skipCheckCursor = cursor + Self.cachedRunCheckStrideBytes
        }
        lock.unlock()

        callbacks.didStore(self, start...(cursor - 1))

        if let total, cursor >= total {
            finishStream(expectedGeneration: gen)
            return
        }
        if checkCachedRun {
            let nextMissing = callbacks.nextMissingByte(cursor)
            if nextMissing == nil {
                // Everything from here to the known EOF is already cached;
                // the stream's region is done.
                finishStream(expectedGeneration: gen)
                return
            }
            if let nextMissing, nextMissing - cursor >= Self.cachedRunSkipBytes {
                Self.logger.info("[CMP-SOURCE-CACHE] origin stream skipping cached run \(cursor, privacy: .public)-\(nextMissing, privacy: .public)")
                retarget(to: nextMissing, order: currentDemandOrder)
                return
            }
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

    fileprivate func handleCompletion(error: Error?, taskID: Int) {
        lock.lock()
        guard taskID == currentTaskID, !cancelled, !finished else {
            lock.unlock()
            return
        }
        let gen = generation
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

    /// Shared terminal teardown for finish/give-up. Returns false when this
    /// generation already ended or the stream is already terminal, so each
    /// caller fires its callback exactly once.
    private func terminate(expectedGeneration: UInt64) -> Bool {
        lock.lock()
        guard generation == expectedGeneration, !finished, !cancelled else {
            lock.unlock()
            return false
        }
        finished = true
        generation &+= 1
        let session = self.session
        self.session = nil
        self.task = nil
        currentTaskID = nil
        let reconnect = reconnectTask
        reconnectTask = nil
        let watchdog = watchdogTask
        watchdogTask = nil
        lock.unlock()
        session?.invalidateAndCancel()
        reconnect?.cancel()
        watchdog?.cancel()
        return true
    }

    private func finishStream(expectedGeneration: UInt64) {
        guard terminate(expectedGeneration: expectedGeneration) else { return }
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
        let oldTask = task
        task = nil
        currentTaskID = nil
        parked = false
        if bytesSinceConnect < PlaybackOriginReconnectPolicy.productiveBytesFloor {
            unproductiveStreak += 1
        } else {
            unproductiveStreak = 0
        }
        let streak = unproductiveStreak
        let productive = everProductive
        lock.unlock()
        oldTask?.cancel()

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
        guard terminate(expectedGeneration: expectedGeneration) else { return }
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

    /// One delegate for the stream's single long-lived session. Staleness is
    /// per data task: events carry the task identifier (unique within a
    /// session) and the stream ignores anything that is not its current task,
    /// so a cancelled attempt's late deliveries can never corrupt the cursor.
    private final class ConnectionDelegate: NSObject, URLSessionDataDelegate {
        private weak var stream: PlaybackOriginStream?

        init(stream: PlaybackOriginStream) {
            self.stream = stream
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let stream, stream.handleResponse(response, taskID: dataTask.taskIdentifier) else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            stream?.handleData(data, taskID: dataTask.taskIdentifier)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            stream?.handleCompletion(error: error, taskID: task.taskIdentifier)
        }
    }
}
