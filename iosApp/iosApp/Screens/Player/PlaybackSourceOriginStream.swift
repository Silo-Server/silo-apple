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

/// Who may re-anchor the streaming window when a qualified (≥
/// `windowClaimBytes`) demand misses. Two concurrent long-lived readers —
/// e.g. the demuxer's video read plus a second full-rate audio/extractor
/// read — can BOTH pass the claim threshold; letting each steal the window
/// on every miss produced a retarget storm (production tvOS logs,
/// 2026-07-29: an origin cancel + fresh range request every 1–2 s, each
/// discarding 10–30 MB of delivered bytes). The window belongs to one serve
/// connection at a time; a contested claim is served by a discrete chunk,
/// which never disturbs the window. A live owner's miss just behind the
/// productive cursor is also served discretely: this is commonly the race
/// where origin storage lands between the response's cache check and claim.
/// That diversion is bounded to one chunk's distance. A farther-behind owner
/// may re-anchor so cache eviction or reader lag cannot strand sequential
/// playback on RTT-bound chunks. Ownership frees when the owning serve
/// connection ends, so a new response created by an ordinary seek can still
/// re-anchor immediately.
enum PlaybackWindowClaimPolicy {
    /// A nearby miss costs at most one discrete fetch. Beyond this distance,
    /// preserving the ahead window would make a lagging sequential reader
    /// issue an unbounded series of RTT-bound chunk requests.
    static let sameOwnerChunkBehindBytes = PlaybackOriginRoutingPolicy.chunkBytes

    enum ChunkReason: String, Equatable {
        /// Another live response owns the streaming window.
        case liveOwnerConflict = "live_owner_conflict"
        /// The owning response missed just behind the productive cursor.
        case sameOwnerBehindWindow = "same_owner_behind_window"
    }

    enum Verdict: Equatable {
        /// The claimant may re-anchor (or spawn) the window.
        case retarget
        /// Preserve the productive window and serve this demand discretely.
        case chunk(ChunkReason)
    }

    static func arbitrate(
        claimant: UUID?,
        owner: UUID?,
        ownerIsAlive: Bool,
        demandOffset: Int64,
        windowCursor: Int64?
    ) -> Verdict {
        guard let owner, ownerIsAlive else { return .retarget }
        guard let claimant else { return .chunk(.liveOwnerConflict) }
        guard claimant == owner else { return .chunk(.liveOwnerConflict) }
        if let windowCursor,
           demandOffset < windowCursor,
           windowCursor - demandOffset <= sameOwnerChunkBehindBytes {
            return .chunk(.sameOwnerBehindWindow)
        }
        return .retarget
    }
}

/// Pause/backpressure decisions for the window stream plus its snapshot
/// type. (Routing across multiple streams lived here before the
/// window+chunk split — see `PlaybackOriginRoutingPolicy`.)
enum PlaybackOriginStreamPolicy {
    /// A budget-parked direct stream stays warm briefly, then deliberately
    /// closes before ordinary reverse-proxy client-send timeouts can reap it.
    /// `var` so tests can drive the lifecycle without wall-clock waits.
    static var detachAfterSeconds: TimeInterval = 25
    /// Upper bound for the adaptive grace below: parked connections must
    /// still close before common reverse-proxy client-send timeouts (60 s)
    /// can reap them mid-park.
    static var detachGraceCeilingSeconds: TimeInterval = 45
    /// Headroom added to the computed drain time so the low-water resume
    /// always lands before the detach timer, not in a race with it.
    static let detachDrainMarginSeconds: TimeInterval = 5

    /// Grace before a budget-parked stream detaches, sized to the cache
    /// hysteresis drain time when the source bitrate is known. The fixed
    /// 25 s grace detached ~2.7 s BEFORE the low-water resume for a
    /// 19.4 Mbps source draining the 64 MiB hysteresis gap (~27.7 s), so
    /// every park cycle paid a full reconnect instead of a task resume —
    /// and every title under ~21.5 Mbps hit the same cliff. The cache
    /// drains at the CONSUMPTION rate, not the nominal file rate: slow-speed
    /// playback (0.75×) stretches the drain proportionally, so the grace
    /// scales by `playbackRate` (non-positive/unknown rates fall back to 1×).
    static func detachGraceSeconds(
        hysteresisGapBytes: Int64,
        sourceBitrateBps: Double?,
        playbackRate: Double = 1.0
    ) -> TimeInterval {
        guard let bps = sourceBitrateBps, bps > 0, hysteresisGapBytes > 0 else {
            return detachAfterSeconds
        }
        let rate = playbackRate > 0 ? playbackRate : 1.0
        let drainSeconds = Double(hysteresisGapBytes) * 8.0 / (bps * rate)
        let ceiling = max(detachAfterSeconds, detachGraceCeilingSeconds)
        return min(max(drainSeconds + detachDrainMarginSeconds, detachAfterSeconds), ceiling)
    }

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
        case entityChanged
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
        case .entityChanged:
            cap = 0
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
/// (see `docs/tvos-player/10-playback-continuity.md`).
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
        case .prematureEOF, .rangeIgnored, .entityChanged:
            return false
        }
    }
}

/// Time seam for the origin watchdog. Production uses wall time and a
/// five-second cadence; tests advance both deterministically.
protocol PlaybackOriginStreamClock: AnyObject {
    func now() -> Date
    func sleepUntilNextWatchdogTick() async
}

final class SystemPlaybackOriginStreamClock: PlaybackOriginStreamClock {
    func now() -> Date {
        .now
    }

    func sleepUntilNextWatchdogTick() async {
        try? await Task.sleep(for: .seconds(5))
    }
}

/// One long-lived streaming origin connection: an open-ended
/// `Range: bytes=<cursor>-` GET whose body is stored into the span cache
/// incrementally as each URLSession delivery arrives. Byte-stable direct
/// streams briefly suspend when the readahead budget is full, then detach and
/// reopen at the exact write cursor when demand returns. Non-resumable
/// deliveries retain the legacy indefinite suspension behavior.
final class PlaybackOriginStream {
    struct Callbacks {
        /// Invoked on the session delegate queue after bytes are stored.
        let didStore: (PlaybackOriginStream, ClosedRange<Int64>) -> Void
        /// First response headers for a connection (total length and captured
        /// strong entity validator, when known).
        let didReceiveResponse: (PlaybackOriginStream, Int64?, String?) -> Void
        let didDetectSessionMissing: (PlaybackOriginStream) -> Void
        let didFinish: (PlaybackOriginStream) -> Void
        let didGiveUp: (PlaybackOriginStream, PlaybackOriginReconnectPolicy.EndCause, Int?) -> Void
        /// Budget/park decision; called with the stream's current cursor and
        /// demand mark, outside the stream's internal lock.
        let mayContinueFilling: (PlaybackOriginStream, Int64, Int64) -> Bool
        /// Current bytes cached ahead of playback, used only for park
        /// diagnostics.
        let cachedAheadBytes: () -> Int64
        /// First byte at or after the given offset that the cache does not
        /// already hold (nil when everything to the known EOF is cached);
        /// used to jump the connection over long already-cached runs instead
        /// of re-downloading them.
        let nextMissingByte: (Int64) -> Int64?
        let store: (Int64, Data, Int64?) -> Void
    }

    struct DiagnosticsSnapshot: Equatable {
        let writeCursor: Int64
        let parked: Bool
        let detached: Bool
        let unproductiveStreak: Int
    }

    private enum OpenReason: Equatable {
        case initial
        case reconnect
        case retarget
        case detachResume
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
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlaybackOriginStream"
    )

    let id = UUID()
    private let originURL: URL
    private let originHeaders: [String: String]
    private let callbacks: Callbacks
    private let resumeCapable: Bool
    private let clock: PlaybackOriginStreamClock
    /// Grace before a park becomes a detach. Supplied by the owner when it
    /// can size the grace to the cache drain time; nil falls back to the
    /// fixed `PlaybackOriginStreamPolicy.detachAfterSeconds`.
    private let detachGraceSecondsProvider: (() -> TimeInterval)?

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var startOffset: Int64
    private var writeCursor: Int64
    private var demandMark: Int64
    private var demandOrder: UInt64
    private var skipCheckCursor: Int64
    private var parked = false
    private var parkedAt: Date?
    private var detached = false
    private var cancelled = false
    private var finished = false
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var currentTaskID: Int?
    private var expectedCancellationTaskIDs: Set<Int> = []
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastDataAt: Date
    private var bytesSinceConnect: Int64 = 0
    private var everProductive = false
    private var unproductiveStreak = 0
    private var knownTotalLength: Int64?
    private var responseValidatedForGeneration: UInt64?
    /// Whether this stream has already accepted any response body. A first
    /// response may establish the resource validator; every later connection
    /// in resume-capable mode must already have that strong validator.
    private var hasAcceptedResponse = false
    /// A replacement window shares the resource cache with an earlier window,
    /// so even its first response must prove that it is the same entity.
    private let initialResponseRequiresEntityValidation: Bool
    private var entityETag: String?
    private var ifRangeGeneration: UInt64?
    private var sentIfRangeValue: String?
    private var currentOpenReason: OpenReason = .initial
    private var errorBody = Data()
    private var errorStatusCode: Int?

    init(
        originURL: URL,
        originHeaders: [String: String],
        startOffset: Int64,
        demandOrder: UInt64,
        callbacks: Callbacks,
        resumeCapable: Bool = false,
        initialEntityETag: String? = nil,
        initialResponseRequiresEntityValidation: Bool = false,
        clock: PlaybackOriginStreamClock = SystemPlaybackOriginStreamClock(),
        detachGraceSecondsProvider: (() -> TimeInterval)? = nil
    ) {
        self.originURL = originURL
        self.originHeaders = originHeaders
        self.startOffset = startOffset
        self.writeCursor = startOffset
        self.demandMark = startOffset
        self.demandOrder = demandOrder
        self.skipCheckCursor = startOffset + Self.cachedRunCheckStrideBytes
        self.callbacks = callbacks
        self.resumeCapable = resumeCapable
        self.entityETag = initialEntityETag
        self.initialResponseRequiresEntityValidation = initialResponseRequiresEntityValidation
        self.clock = clock
        self.detachGraceSecondsProvider = detachGraceSecondsProvider
        self.lastDataAt = clock.now()
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

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticsSnapshot(
            writeCursor: writeCursor,
            parked: parked,
            detached: detached,
            unproductiveStreak: unproductiveStreak
        )
    }

    func start() {
        openConnection(reason: .initial)
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
        expectedCancellationTaskIDs.removeAll()
        parkedAt = nil
        detached = false
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
        reopenConnection(at: offset, order: order, reason: .retarget)
    }

    /// Shared ranged-reopen seam for seeks/retargets and detach-resume.
    /// Retarget starts a new routing region and resets its failure streak;
    /// detach-resume preserves the existing region and reconnect history.
    @discardableResult
    private func reopenConnection(at offset: Int64, order: UInt64, reason: OpenReason) -> Bool {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return false
        }
        let oldTask: URLSessionDataTask?
        let reconnect: Task<Void, Never>?
        switch reason {
        case .retarget:
            generation &+= 1
            oldTask = task
            task = nil
            currentTaskID = nil
            reconnect = reconnectTask
            reconnectTask = nil
            startOffset = offset
            writeCursor = offset
            demandMark = offset
            demandOrder = order
            skipCheckCursor = offset + Self.cachedRunCheckStrideBytes
            parked = false
            parkedAt = nil
            detached = false
            bytesSinceConnect = 0
            unproductiveStreak = 0
        case .detachResume:
            guard detached, task == nil, currentTaskID == nil, reconnectTask == nil else {
                lock.unlock()
                return false
            }
            oldTask = nil
            reconnect = nil
            writeCursor = offset
            demandOrder = max(demandOrder, order)
            parked = false
            parkedAt = nil
            detached = false
        case .initial, .reconnect:
            lock.unlock()
            return false
        }
        lock.unlock()
        oldTask?.cancel()
        reconnect?.cancel()
        if reason == .detachResume {
            Self.logger.info(
                "[CMP-SOURCE-CACHE] origin stream detach-resume cursor=\(offset, privacy: .public) outcome=opening"
            )
        }
        openConnection(reason: reason)
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
        let shouldConsider = (parked || detached) && !cancelled && !finished
        let cursor = writeCursor
        let mark = demandMark
        let order = demandOrder
        lock.unlock()
        guard shouldConsider else { return }
        guard callbacks.mayContinueFilling(self, cursor, mark) else { return }
        var reopenDetached = false
        lock.lock()
        if parked, !cancelled {
            parked = false
            parkedAt = nil
            task?.resume()
        } else if detached, !cancelled, !finished, reconnectTask == nil, task == nil {
            reopenDetached = true
        }
        lock.unlock()
        if reopenDetached {
            _ = reopenConnection(at: cursor, order: order, reason: .detachResume)
        }
    }

    // MARK: - Connection lifecycle

    private func openConnection(reason: OpenReason) {
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
        parkedAt = nil
        detached = false
        bytesSinceConnect = 0
        lastDataAt = clock.now()
        responseValidatedForGeneration = nil
        currentOpenReason = reason
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
            // Non-resumable deliveries can still be suspended indefinitely,
            // so the idle-based request timeout must never fire underneath
            // them. Wedged transfers are detected by the watchdog.
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
        // The first response may establish the strong validator. Reopens send
        // it with If-Range; a resume-capable reopen without one is rejected
        // before any response bytes can be appended.
        let ifRange = cursor > 0 ? entityETag : nil
        if let ifRange {
            request.setValue(ifRange, forHTTPHeaderField: "If-Range")
            ifRangeGeneration = gen
            sentIfRangeValue = ifRange
        } else {
            ifRangeGeneration = nil
            sentIfRangeValue = nil
        }
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
                guard let clock = self?.clock else { return }
                await clock.sleepUntilNextWatchdogTick()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.detachIfParkedPastGrace()
                guard !Task.isCancelled else { return }
                self.reconnectIfStalled()
            }
        }
        lock.unlock()
    }

    private func detachIfParkedPastGrace() {
        let now = clock.now()
        let grace = detachGraceSecondsProvider?() ?? PlaybackOriginStreamPolicy.detachAfterSeconds
        lock.lock()
        guard resumeCapable,
              parked,
              !detached,
              !cancelled,
              !finished,
              let parkedAt,
              now.timeIntervalSince(parkedAt) >= grace,
              let oldTask = task,
              let oldTaskID = currentTaskID else {
            lock.unlock()
            return
        }
        let cursor = writeCursor
        generation &+= 1
        expectedCancellationTaskIDs.insert(oldTaskID)
        task = nil
        currentTaskID = nil
        parked = false
        self.parkedAt = nil
        detached = true
        responseValidatedForGeneration = nil
        ifRangeGeneration = nil
        sentIfRangeValue = nil
        lock.unlock()

        oldTask.cancel()
        Self.logger.info(
            "[CMP-SOURCE-CACHE] origin stream detached cursor=\(cursor, privacy: .public)"
        )
    }

    private func reconnectIfStalled() {
        let now = clock.now()
        lock.lock()
        let stalled = !cancelled && !finished && !parked && session != nil && task != nil
            && now.timeIntervalSince(lastDataAt) > PlaybackOriginReconnectPolicy.stallSeconds
        let gen = generation
        lock.unlock()
        guard stalled else { return }
        cmpLog("[CMP-SOURCE-CACHE] origin stream stalled; reconnecting cursor=\(self.snapshot().writeCursor)")
        connectionEnded(generation: gen, cause: .stalled, statusCode: nil)
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
        let openReason = currentOpenReason
        let sentIfRange = ifRangeGeneration == gen ? sentIfRangeValue : nil
        let expectedETag = resumeCapable ? entityETag : nil
        let requiresEntityValidation = resumeCapable
            && (
                expectedETag != nil
                    || hasAcceptedResponse
                    || initialResponseRequiresEntityValidation
            )
        lock.unlock()
        guard let http = response as? HTTPURLResponse else {
            connectionEnded(generation: gen, cause: .network, statusCode: nil)
            return false
        }

        switch http.statusCode {
        case 206:
            let total = Self.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            guard let rangeStart = Self.rangeStart(
                fromContentRange: http.value(forHTTPHeaderField: "Content-Range")
            ), rangeStart == cursor else {
                let receivedRange = http.value(forHTTPHeaderField: "Content-Range") ?? "missing"
                Self.logger.warning(
                    "[CMP-SOURCE-CACHE] origin stream invalid content-range expectedStart=\(cursor, privacy: .public) received=\(receivedRange, privacy: .public)"
                )
                logDetachResumeOutcomeIfNeeded(openReason, cursor: cursor, outcome: "range_mismatch")
                connectionEnded(generation: gen, cause: .rangeIgnored, statusCode: http.statusCode)
                return false
            }
            if requiresEntityValidation,
               let failure = entityValidationFailure(
                   http: http,
                   expectedETag: expectedETag,
                   cursor: cursor
               ) {
                logDetachResumeOutcomeIfNeeded(
                    openReason,
                    cursor: cursor,
                    outcome: failure.outcome
                )
                connectionEnded(
                    generation: gen,
                    cause: failure.cause,
                    statusCode: http.statusCode
                )
                return false
            }
            noteResponse(
                total: total,
                etag: http.value(forHTTPHeaderField: "ETag"),
                generation: gen
            )
            logDetachResumeOutcomeIfNeeded(openReason, cursor: cursor, outcome: "accepted_206")
            return true
        case 200 where cursor == 0:
            if requiresEntityValidation,
               let failure = entityValidationFailure(
                   http: http,
                   expectedETag: expectedETag,
                   cursor: cursor
               ) {
                connectionEnded(
                    generation: gen,
                    cause: failure.cause,
                    statusCode: http.statusCode
                )
                return false
            }
            let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            noteResponse(
                total: total,
                etag: http.value(forHTTPHeaderField: "ETag"),
                generation: gen
            )
            logDetachResumeOutcomeIfNeeded(openReason, cursor: cursor, outcome: "accepted_200")
            return true
        case 200:
            if let sentIfRange {
                let responseETagHeader = http.value(forHTTPHeaderField: "ETag")
                if let responseETag = Self.strongETag(responseETagHeader),
                   responseETag != sentIfRange {
                    Self.logger.error(
                        "[CMP-SOURCE-CACHE] origin stream entity-changed cursor=\(cursor, privacy: .public) ifRange=\(sentIfRange, privacy: .public) responseETag=\(responseETagHeader ?? "missing", privacy: .public)"
                    )
                    logDetachResumeOutcomeIfNeeded(openReason, cursor: cursor, outcome: "entity_changed")
                    connectionEnded(generation: gen, cause: .entityChanged, statusCode: 200)
                    return false
                }
            }
            // The origin ignored the Range header; accepting the body would
            // silently corrupt the cache with head bytes at a nonzero offset.
            logDetachResumeOutcomeIfNeeded(openReason, cursor: cursor, outcome: "range_ignored")
            connectionEnded(generation: gen, cause: .rangeIgnored, statusCode: 200)
            return false
        case 416:
            // Requested past the end. If the origin tells us the real total,
            // learn it and finish cleanly so waiters re-drive to EOF.
            if let total = Self.totalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                noteResponse(
                    total: total,
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    generation: gen
                )
                finishStream(expectedGeneration: gen)
                return false
            }
            logDetachResumeOutcomeIfNeeded(openReason, cursor: cursor, outcome: "http_416")
            connectionEnded(generation: gen, cause: .httpFatal(416), statusCode: 416)
            return false
        default:
            // Keep the (small) error body so session-missing 404s can be
            // classified at completion.
            lock.lock()
            errorStatusCode = http.statusCode
            lock.unlock()
            logDetachResumeOutcomeIfNeeded(
                openReason,
                cursor: cursor,
                outcome: "http_\(http.statusCode)"
            )
            return true
        }
    }

    private func entityValidationFailure(
        http: HTTPURLResponse,
        expectedETag: String?,
        cursor: Int64
    ) -> (cause: PlaybackOriginReconnectPolicy.EndCause, outcome: String)? {
        guard let expectedETag else {
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] origin stream entity-unverifiable cursor=\(cursor, privacy: .public) expectedETag=missing"
            )
            return (.rangeIgnored, "entity_unverifiable")
        }
        let responseETagHeader = http.value(forHTTPHeaderField: "ETag")
        guard let responseETag = Self.strongETag(responseETagHeader) else {
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] origin stream entity-unverifiable cursor=\(cursor, privacy: .public) expectedETag=\(expectedETag, privacy: .public) responseETag=\(responseETagHeader ?? "missing", privacy: .public)"
            )
            return (.rangeIgnored, "entity_unverifiable")
        }
        guard responseETag == expectedETag else {
            Self.logger.error(
                "[CMP-SOURCE-CACHE] origin stream entity-changed cursor=\(cursor, privacy: .public) expectedETag=\(expectedETag, privacy: .public) responseETag=\(responseETagHeader ?? "missing", privacy: .public)"
            )
            return (.entityChanged, "entity_changed")
        }
        return nil
    }

    private func noteResponse(total: Int64?, etag: String?, generation gen: UInt64) {
        lock.lock()
        guard gen == generation else {
            lock.unlock()
            return
        }
        responseValidatedForGeneration = gen
        hasAcceptedResponse = true
        if let total { knownTotalLength = total }
        if entityETag == nil, let etag = Self.strongETag(etag) {
            entityETag = etag
        }
        let validator = entityETag
        lock.unlock()
        callbacks.didReceiveResponse(self, total, validator)
    }

    /// `If-Range` performs a strong validator comparison; a weak ETag would
    /// force a compliant origin to return 200 even when the entity is
    /// unchanged, which would look like a false replacement.
    static func strongETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.lowercased().hasPrefix("w/") else {
            return nil
        }
        return candidate
    }

    private func logDetachResumeOutcomeIfNeeded(
        _ reason: OpenReason,
        cursor: Int64,
        outcome: String
    ) {
        guard reason == .detachResume else { return }
        Self.logger.info(
            "[CMP-SOURCE-CACHE] origin stream detach-resume cursor=\(cursor, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
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
        lastDataAt = clock.now()
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
                parkedAt = clock.now()
                task?.suspend()
            }
            lock.unlock()
            if didPark {
                let cachedAhead = callbacks.cachedAheadBytes()
                cmpLog(
                    "[CMP-SOURCE-CACHE] origin stream parked cursor=\(cursor) cachedAheadBytes=\(cachedAhead)"
                )
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
        if expectedCancellationTaskIDs.remove(taskID) != nil {
            lock.unlock()
            return
        }
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
        expectedCancellationTaskIDs.removeAll()
        parkedAt = nil
        detached = false
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
        parkedAt = nil
        detached = false
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
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.openScheduledReconnect(expectedGeneration: newGeneration)
            }
            lock.unlock()
        }
    }

    private func openScheduledReconnect(expectedGeneration: UInt64) {
        lock.lock()
        guard generation == expectedGeneration,
              !cancelled,
              !finished,
              task == nil else {
            lock.unlock()
            return
        }
        reconnectTask = nil
        lock.unlock()
        openConnection(reason: .reconnect)
    }

    private func giveUp(
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?,
        expectedGeneration: UInt64
    ) {
        guard terminate(expectedGeneration: expectedGeneration) else { return }
        cmpLog("[CMP-SOURCE-CACHE] origin stream gave up cause=\(String(describing: cause))")
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
