import Foundation
import OSLog

struct LoopbackSegmentStoreStats: Equatable {
    let generation: UInt64
    let memoryBytes: Int64
    let memoryBudgetBytes: Int64
    let tempSpillBytes: Int64
    let tempSpillBudgetBytes: Int64
    let debugMirrorBytes: Int64
    let generatedMediaSeconds: Double
    let segmentCount: Int
    let spilledSegmentCount: Int
    let requestCount: Int64
    let bytesServed: Int64
    let lastRequestLatencyMs: Double?
    let waitCount: Int64
}

final class LoopbackSegmentStore {
    enum SpillPolicy: Equatable {
        case disabled(reason: String)
        case enabled(reason: String, maxBytes: Int64)

        var isEnabled: Bool {
            if case .enabled = self { return true }
            return false
        }

        var reason: String {
            switch self {
            case .disabled(let reason), .enabled(let reason, _):
                return reason
            }
        }

        var maxBytes: Int64 {
            switch self {
            case .enabled(_, let maxBytes): return maxBytes
            case .disabled: return 0
            }
        }
    }

    enum ResourceResult {
        case found(Resource)
        case missing
        case gone
    }

    enum Resource {
        case memory(data: Data, mimeType: String)
        case disk(url: URL, byteCount: Int, mimeType: String)
        /// A segment the producer is still writing: the server streams it
        /// read-until-close via `readProgressiveSegment(named:from:deadline:)`.
        case progressive(name: String, mimeType: String)

        var mimeType: String {
            switch self {
            case .memory(_, let mimeType), .disk(_, _, let mimeType),
                 .progressive(_, let mimeType):
                return mimeType
            }
        }

        var byteCount: Int {
            switch self {
            case .memory(let data, _):
                return data.count
            case .disk(_, let byteCount, _):
                return byteCount
            case .progressive:
                return 0
            }
        }
    }

    private struct Segment {
        let data: Data
        let duration: Double
        let createdAt: Date
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "LoopbackSegmentStore"
    )
    let generation: UInt64
    private let memoryBudgetBytes: Int
    /// Byte budget for VOD retention. Always positive (a non-positive request
    /// is floored to `vodRetentionBudgetFloorBytes`), so every append is
    /// disk-first and every prune path is live — there is no second,
    /// unretained storage mode.
    private let vodRetentionBudgetBytes: Int64
    private let vodForwardWindow: Int
    private let vodBackwardWindow: Int
    private let debugDirectory: URL?
    private let lock = NSCondition()
    private var initSegment: Data?
    private var mediaPlaylist: Data?
    private var masterPlaylist: Data?
    private var segments: [String: Segment] = [:]
    /// Anchor segments the producer is still writing, published fragment by
    /// fragment so the server can stream them before the cut completes
    /// (seek-latency: AVPlayer only needs the first ~2 s of a 10 s anchor
    /// segment to render). Not counted against `memoryBytes`, though they are
    /// a second resident copy of the writer's own pending buffer: the writer
    /// caps how much of an open segment it publishes here; see its
    /// progressive-publish ceiling. Replaced wholesale by
    /// `beginProgressiveSegment` (a
    /// restarted producer re-publishing the same name must not append to a
    /// dead predecessor's prefix) and cleared when the complete segment
    /// arrives via `append` or the name leaves the VOD window.
    private var progressiveSegments: [String: Data] = [:]
    private var spilledSegments: [String: URL] = [:]
    private var spilledSegmentSizes: [String: Int] = [:]
    private var evictedResources: Set<String> = []
    private var memoryBytes = 0
    private var generatedMediaSeconds: Double = 0
    private var requestCount: Int64 = 0
    private var bytesServed: Int64 = 0
    private var lastRequestLatencyMs: Double?
    private var waitCount: Int64 = 0
    private var tempSpillBytes: Int64 = 0
    private var debugMirrorBytes: Int64 = 0
    private let spillDirectory: URL?
    private let spillPolicy: SpillPolicy

    init(
        generation: UInt64,
        memoryBudgetBytes: Int = 128 * 1024 * 1024,
        spillPolicy: SpillPolicy = .disabled(reason: "default"),
        vodRetentionBudgetBytes: Int64 = LoopbackSegmentStore.vodRetentionBudgetFloorBytes,
        vodForwardWindow: Int = 10,
        vodBackwardWindow: Int = 20,
        debugDirectory: URL? = nil
    ) {
        self.generation = generation
        self.memoryBudgetBytes = memoryBudgetBytes
        self.vodRetentionBudgetBytes = vodRetentionBudgetBytes > 0
            ? vodRetentionBudgetBytes
            : Self.vodRetentionBudgetFloorBytes
        self.vodForwardWindow = max(1, vodForwardWindow)
        self.vodBackwardWindow = max(0, vodBackwardWindow)
        self.debugDirectory = debugDirectory
        self.spillPolicy = spillPolicy
        _ = PlaybackDiskBudget.sweepOrphanedSpillDirectories
        var resolvedSpillDirectory: URL?
        if spillPolicy.isEnabled {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("silo-dv-hls", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                resolvedSpillDirectory = dir
            } catch {
                cmpLog("[CMP-HLS-STORE] spill directory create failed")
                Self.logger.error(
                    "[CMP-HLS-STORE] spill directory create failed error=\(String(describing: error), privacy: .private)"
                )
            }
        }
        self.spillDirectory = resolvedSpillDirectory
        if let debugDirectory {
            try? FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        }
        Self.logger.info("[CMP-HLS-STORE] generation=\(self.generation, privacy: .public) spillPolicy=\(spillPolicy.isEnabled ? "enabled" : "memory", privacy: .public) reason=\(spillPolicy.reason, privacy: .public) maxBytes=\(spillPolicy.maxBytes, privacy: .public)")
    }

    deinit {
        if let spillDirectory {
            try? FileManager.default.removeItem(at: spillDirectory)
        }
    }

    func putInitSegment(_ data: Data) {
        replaceSpecialResource(name: "init.mp4", old: &initSegment, new: data)
        mirror(data, name: "init.mp4")
    }

    func putMediaPlaylist(_ body: String) {
        let data = Data(body.utf8)
        replaceSpecialResource(name: "playlist.m3u8", old: &mediaPlaylist, new: data)
        mirror(data, name: "playlist.m3u8")
    }

    func putMasterPlaylist(_ body: String) {
        let data = Data(body.utf8)
        replaceSpecialResource(name: "master.m3u8", old: &masterPlaylist, new: data)
        mirror(data, name: "master.m3u8")
    }

    /// Segments are disk-first, matching the producer/cache model AVPlayer is
    /// consuming. Keeping only file URLs in the store avoids a second full
    /// encoded-media copy in the tvOS heap and makes the forward window a
    /// disk/demux policy rather than a resident-memory budget. If an
    /// asynchronous stale-session cleanup or filesystem race removes the UUID
    /// directory, recreate it and retry once before falling back to memory for
    /// this active segment.
    func putSegment(
        name: String,
        data: Data,
        duration: Double
    ) {
        guard let spillDirectory else {
            putSegmentInMemoryWithoutEviction(name: name, data: data, duration: duration)
            return
        }
        let destination = spillDirectory.appendingPathComponent(name)
        var writeError: Error?
        var stored = false
        for attempt in 1...2 {
            do {
                if attempt > 1 {
                    try FileManager.default.createDirectory(
                        at: spillDirectory,
                        withIntermediateDirectories: true
                    )
                }
                try data.write(to: destination, options: .atomic)
                stored = true
                break
            } catch {
                writeError = error
            }
        }
        guard stored else {
            let description = String(describing: writeError)
            cmpLog("[CMP-HLS-STORE] VOD disk write failed after retry; retaining active segment in memory")
            Self.logger.error(
                "[CMP-HLS-STORE] VOD disk write failed after retry error=\(description, privacy: .private); retaining active segment in memory"
            )
            putSegmentInMemoryWithoutEviction(name: name, data: data, duration: duration)
            return
        }

        lock.lock()
        var doomed: [URL] = []
        if let old = segments.removeValue(forKey: name) {
            memoryBytes -= old.data.count
        }
        if let oldURL = spilledSegments.removeValue(forKey: name) {
            tempSpillBytes -= Int64(spilledSegmentSizes.removeValue(forKey: name) ?? 0)
            if oldURL != destination { doomed.append(oldURL) }
        }
        spilledSegments[name] = destination
        spilledSegmentSizes[name] = data.count
        tempSpillBytes += Int64(data.count)
        generatedMediaSeconds += duration
        evictedResources.remove(name)
        progressiveSegments.removeValue(forKey: name)
        if let index = Self.segmentIndex(fromName: name) {
            vodHighWaterIndex = max(vodHighWaterIndex, index)
        }
        doomed.append(contentsOf: vodPruneLocked())
        tempSpillBytes = max(0, tempSpillBytes)
        lock.broadcast()
        lock.unlock()

        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
        mirror(data, name: name)
    }

    /// A filesystem failure must not turn an active VOD segment into a
    /// permanent `.gone` response. Retain the segment in RAM so AVPlayer can
    /// keep moving; the producer's segment-count window bounds additional
    /// work while diagnostics expose the underlying storage failure.
    private func putSegmentInMemoryWithoutEviction(
        name: String,
        data: Data,
        duration: Double
    ) {
        lock.lock()
        if let old = segments[name] {
            memoryBytes -= old.data.count
        }
        segments[name] = Segment(data: data, duration: duration, createdAt: Date())
        memoryBytes += data.count
        generatedMediaSeconds += duration
        evictedResources.remove(name)
        progressiveSegments.removeValue(forKey: name)
        if let index = Self.segmentIndex(fromName: name) {
            vodHighWaterIndex = max(vodHighWaterIndex, index)
        }
        let doomed = vodPruneLocked()
        lock.broadcast()
        lock.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
        mirror(data, name: name)
    }

    #if DEBUG
    var spillDirectoryForTesting: URL? { spillDirectory }
    #endif

    // MARK: - VOD retention (loopback-primary plan, 1e)

    private var vodTargetIndex = 0
    private var vodHighWaterIndex = -1
    /// Counts `declareVODTarget` calls so waiters can tell "a real consumer
    /// target exists" apart from the fresh-store default of index 0.
    private var vodTargetDeclarationCount: UInt64 = 0

    static func segmentIndex(fromName name: String) -> Int? {
        guard name.hasPrefix("seg_"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }

    /// Fallback for a degenerate (non-positive) retention budget: 0 would
    /// leave `vodRetentionBudgetBytes == 0`, which every prune path treats
    /// as "retention not configured" — pruning would silently never run and
    /// the producer would eventually deadlock (living-room spill-exhaustion
    /// freeze). The store must always retain *some* positive budget; small
    /// explicit budgets stay honored as-is (aggressive eviction is a valid
    /// mode — tests use it).
    static let vodRetentionBudgetFloorBytes: Int64 = 256 << 20

    /// Consumer fetch high-water: every segment GET declares its index. The
    /// hard retention window follows the newest target (a backward scrub is
    /// a valid non-monotonic move) and pruning re-runs around it.
    func declareVODTarget(_ index: Int) {
        lock.lock()
        vodTargetIndex = index
        vodTargetDeclarationCount += 1
        let doomed = vodPruneLocked()
        lock.broadcast()
        lock.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether any consumer segment GET has declared a fetch target this
    /// session. The producer's park-wedge escape uses this to distinguish
    /// "consumer is slow/paused" (park is healthy backpressure) from
    /// "consumer never attached" (park would deadlock: only consumer fetches
    /// ever advance the target).
    func vodConsumerHasFetchedSegment() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return vodTargetDeclarationCount > 0
    }

    /// Producer/cache coupling: appends past `target + forwardWindow` wait,
    /// and the same window is protected by VOD pruning. One segment-count
    /// policy therefore controls both how far the producer may race and what
    /// AVPlayer is guaranteed to be able to fetch, matching AetherEngine's
    /// disk-backed SegmentCache model.
    func vodProducerMayAppend(segmentIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return segmentIndex <= vodTargetIndex + vodForwardWindow
    }

    // MARK: - Progressive anchor segments

    /// Opens (or wholesale-replaces) the progressive buffer for a segment
    /// the producer is about to publish fragment by fragment.
    func beginProgressiveSegment(named name: String) {
        lock.lock()
        progressiveSegments[name] = Data()
        lock.unlock()
    }

    /// Appends published fragment bytes and wakes waiters/readers.
    func appendProgressiveSegment(named name: String, bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        if progressiveSegments[name] != nil {
            progressiveSegments[name]?.append(bytes)
            lock.broadcast()
        }
        lock.unlock()
    }

    /// Blocking incremental read for a streaming response. Returns the
    /// bytes available at `offset` plus a completion marker:
    /// - complete segment stored → (remaining bytes, true)
    /// - more progressive bytes  → (delta, false)
    /// - nothing new by deadline → (empty, false) — caller re-polls
    /// - entry gone / offset past a replaced buffer → (empty, true) —
    ///   caller closes; the consumer refetches and gets the fresh state.
    func readProgressiveSegment(
        named name: String,
        from offset: Int,
        deadline: Date,
        waitForStart: Bool = false
    ) -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let segment = segments[name] {
                guard offset <= segment.data.count else { return (Data(), true) }
                return (segment.data.subdata(in: offset..<segment.data.count), true)
            }
            // mmap + .uncached: spilled segments are immutable after their
            // atomic write; let the kernel page them instead of the heap.
            if let url = spilledSegments[name],
               let data = try? Data(contentsOf: url, options: [.alwaysMapped, .uncached]) {
                guard offset <= data.count else { return (Data(), true) }
                return (data.subdata(in: offset..<data.count), true)
            }
            guard let partial = progressiveSegments[name] else {
                if waitForStart, !evictedResources.contains(name) {
                    guard Date() < deadline else {
                        return (Data(), false)
                    }
                    lock.wait(until: deadline)
                    continue
                }
                return (Data(), true)
            }
            if offset > partial.count {
                return (Data(), true)
            }
            if partial.count > offset {
                return (partial.subdata(in: offset..<partial.count), false)
            }
            guard Date() < deadline else {
                return (Data(), false)
            }
            lock.wait(until: deadline)
        }
    }

    /// Bounded wait used by the server's miss resolver while a producer
    /// restart fills the requested segment.
    ///
    /// Supersede early-exit: the wait is kept alive only while the newest
    /// declared consumer target T keeps the waited segment N inside the
    /// producer band `[T - forwardWindow, T + forwardWindow]`. An
    /// out-of-band wait is almost always an abandoned fetch (the consumer
    /// scrubbed away), but one observation is not proof: the restart this
    /// very miss triggered re-declares its target at N, and a producer may
    /// still append below a newer far-above target, so a transient far GET
    /// (e.g. a fresh AVPlayerItem probing position 0 during in-place
    /// recovery) must not permanently kill a live wait. The waiter therefore
    /// tolerates a single out-of-band check and exits only when the band is
    /// still violated on the next bounded wakeup — abandoned fetches still
    /// leave within ~250 ms instead of riding the full deadline, while the
    /// miss's own restart gets a window to swing the target back to N.
    /// `declareVODTarget` broadcasts on the condition, so target moves wake
    /// the waiter immediately.
    func waitForSegment(named name: String, deadline: Date) -> ResourceResult {
        let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let waitedIndex = Self.segmentIndex(fromName: normalized)
        let started = CFAbsoluteTimeGetCurrent()
        var superseded = false
        var outOfBandChecks = 0
        lock.lock()
        cmpLog("[CMP-HLS-STORE] waitForSegment enter name=\(normalized) evicted=\(evictedResources.contains(normalized) ? 1 : 0) present=\(segments[normalized] != nil ? 1 : 0)", verbose: true)
        while segments[normalized] == nil,
              progressiveSegments[normalized] == nil,
              spilledSegments[normalized] == nil,
              Date() < deadline {
            // Checked before every wait (including the first); a second
            // consecutive out-of-band observation exits the wait.
            if let index = waitedIndex,
               vodTargetDeclarationCount > 0,
               abs(index - vodTargetIndex) > vodForwardWindow {
                outOfBandChecks += 1
                if outOfBandChecks >= 2 {
                    superseded = true
                    break
                }
            } else {
                outOfBandChecks = 0
            }
            _ = lock.wait(until: min(deadline, Date().addingTimeInterval(0.25)))
        }
        lock.unlock()
        let result = resource(path: normalized, waitForNearFuture: false)
        let found: Bool
        if case .found = result { found = true } else { found = false }
        cmpLog("[CMP-HLS-STORE] waitForSegment exit name=\(normalized) found=\(found ? 1 : 0) superseded=\(superseded ? 1 : 0) waitedMs=\(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))", verbose: true)
        return result
    }

    /// Pure VOD eviction decision: the hard window
    /// `[target - backward, max(target + forward, highWater)]` is never
    /// evicted (correctness beats budget — it covers the playhead and the
    /// producer's bounded forward span); extras are retained
    /// nearest-to-target-first under the byte budget so each side of the
    /// resident span stays contiguous, and evicted farthest-first beyond it.
    static func vodEvictionVictims(
        indicesWithBytes: [(index: Int, bytes: Int)],
        targetIndex: Int,
        highWaterIndex: Int,
        forwardWindow: Int,
        backwardWindow: Int,
        budgetBytes: Int64
    ) -> [Int] {
        guard budgetBytes > 0 else { return [] }
        let lo = targetIndex - backwardWindow
        let hi = max(targetIndex + forwardWindow, highWaterIndex)
        var keptBytes: Int64 = 0
        var extras: [(index: Int, bytes: Int)] = []
        for entry in indicesWithBytes {
            if entry.index >= lo, entry.index <= hi {
                keptBytes += Int64(entry.bytes)
            } else {
                extras.append(entry)
            }
        }
        extras.sort { abs($0.index - targetIndex) < abs($1.index - targetIndex) }
        var victims: [Int] = []
        for entry in extras {
            if keptBytes + Int64(entry.bytes) <= budgetBytes {
                keptBytes += Int64(entry.bytes)
            } else {
                victims.append(entry.index)
            }
        }
        return victims
    }

    /// Must run under `lock`. Returns spill URLs to delete outside the lock.
    ///
    /// The inventory unions both residency states: a VOD append is disk-first
    /// but falls back to memory when the session directory is unwritable, and
    /// both copies count against the retention budget.
    private func vodPruneLocked() -> [URL] {
        var names = Set(segments.keys)
        names.formUnion(spilledSegments.keys)
        let inventory: [(index: Int, bytes: Int)] = names.compactMap { name in
            guard let index = Self.segmentIndex(fromName: name) else { return nil }
            let bytes = segments[name]?.data.count
                ?? spilledSegmentSizes[name]
                ?? 0
            return (index, bytes)
        }
        let victims = Self.vodEvictionVictims(
            indicesWithBytes: inventory,
            targetIndex: vodTargetIndex,
            highWaterIndex: vodHighWaterIndex,
            forwardWindow: vodForwardWindow,
            backwardWindow: vodBackwardWindow,
            budgetBytes: vodRetentionBudgetBytes
        )
        guard !victims.isEmpty else { return [] }
        var doomed: [URL] = []
        for index in victims {
            let name = String(format: "seg_%06d.m4s", index)
            if let segment = segments.removeValue(forKey: name) {
                memoryBytes -= segment.data.count
            }
            if let url = spilledSegments.removeValue(forKey: name) {
                tempSpillBytes -= Int64(spilledSegmentSizes.removeValue(forKey: name) ?? 0)
                doomed.append(url)
            }
            // Deliberately NOT `evictedResources`: a pruned VOD segment is
            // regenerable via a producer restart; `.gone` would 404 it for
            // the rest of the session.
        }
        // In-progress publications that left the consumer window belong to a
        // superseded producer (the user seeked away mid-anchor); dropping
        // them ends their streaming readers.
        for name in progressiveSegments.keys {
            guard let index = Self.segmentIndex(fromName: name) else { continue }
            if abs(index - vodTargetIndex) > vodForwardWindow + vodBackwardWindow {
                progressiveSegments.removeValue(forKey: name)
            }
        }
        tempSpillBytes = max(0, tempSpillBytes)
        return doomed
    }

    /// VOD writes are disk-first and bounded by the coupled segment-count
    /// window (`vodProducerMayAppend`), so an append is never refused here.
    /// Run retention pruning opportunistically and admit the append;
    /// correctness wins when the protected window temporarily exceeds its
    /// byte budget.
    func makeRoomForAppend(byteCount: Int) -> Bool {
        guard byteCount > 0 else { return true }
        lock.lock()
        let doomed = vodPruneLocked()
        lock.broadcast()
        lock.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    func retireSegments(names: [String]) -> [String] {
        guard !names.isEmpty else { return [] }
        var retired: [String] = []
        var spillURLsToDelete: [URL] = []

        lock.lock()
        for name in names {
            var didRetire = false

            if let segment = segments.removeValue(forKey: name) {
                memoryBytes -= segment.data.count
                didRetire = true
            }
            if let spillURL = spilledSegments.removeValue(forKey: name) {
                let size = spilledSegmentSizes.removeValue(forKey: name) ?? 0
                tempSpillBytes -= Int64(size)
                spillURLsToDelete.append(spillURL)
                didRetire = true
            }

            if didRetire {
                evictedResources.insert(name)
                retired.append(name)
            }
        }
        tempSpillBytes = max(0, tempSpillBytes)
        lock.broadcast()
        lock.unlock()

        for url in spillURLsToDelete {
            try? FileManager.default.removeItem(at: url)
        }
        if !retired.isEmpty {
            Self.logger.info("[CMP-HLS-STORE] generation=\(self.generation, privacy: .public) retired=\(retired.count, privacy: .public) tempSpillBytes=\(self.stats().tempSpillBytes, privacy: .public)")
        }
        return retired
    }

    func resource(path: String, waitForNearFuture: Bool = true) -> ResourceResult {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let started = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if waitForNearFuture,
           normalized.hasPrefix("seg_"),
           segments[normalized] == nil,
           progressiveSegments[normalized] == nil,
           spilledSegments[normalized] == nil,
           !evictedResources.contains(normalized) {
            waitCount += 1
            _ = lock.wait(until: Date().addingTimeInterval(1.0))
        }
        let result = resourceLocationLocked(path: normalized)
        lock.unlock()

        lock.lock()
        requestCount += 1
        switch result {
        case .found(let resource):
            bytesServed += Int64(resource.byteCount)
            if normalized.hasPrefix("seg_") {
                lastSegmentServeWall = CFAbsoluteTimeGetCurrent()
            }
        case .missing, .gone:
            break
        }
        lastRequestLatencyMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        lock.unlock()
        return result
    }

    private var lastSegmentServeWall: CFAbsoluteTime = 0

    /// Wall seconds since the last successful segment serve, or nil before
    /// any. A consumer actively pulling segments is filling its buffer, not
    /// wedged — the playhead watchdog holds recovery while this is fresh.
    func secondsSinceLastSegmentServe() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard lastSegmentServeWall > 0 else { return nil }
        return CFAbsoluteTimeGetCurrent() - lastSegmentServeWall
    }

    func stats() -> LoopbackSegmentStoreStats {
        lock.lock()
        let snapshot = LoopbackSegmentStoreStats(
            generation: generation,
            memoryBytes: Int64(memoryBytes),
            memoryBudgetBytes: Int64(memoryBudgetBytes),
            tempSpillBytes: tempSpillBytes,
            tempSpillBudgetBytes: spillPolicy.maxBytes,
            debugMirrorBytes: debugMirrorBytes,
            generatedMediaSeconds: generatedMediaSeconds,
            segmentCount: segments.count,
            spilledSegmentCount: spilledSegments.count,
            requestCount: requestCount,
            bytesServed: bytesServed,
            lastRequestLatencyMs: lastRequestLatencyMs,
            waitCount: waitCount
        )
        lock.unlock()
        return snapshot
    }

    private func replaceSpecialResource(name: String, old: inout Data?, new: Data) {
        lock.lock()
        if let old {
            memoryBytes -= old.count
        }
        old = new
        memoryBytes += new.count
        lock.broadcast()
        lock.unlock()
    }

    private func resourceLocationLocked(path: String) -> ResourceResult {
        switch path {
        case "init.mp4":
            return initSegment.map { .found(.memory(data: $0, mimeType: "video/mp4")) } ?? .missing
        case "playlist.m3u8":
            return mediaPlaylist.map { .found(.memory(data: $0, mimeType: "application/vnd.apple.mpegurl")) } ?? .missing
        case "master.m3u8":
            return masterPlaylist.map { .found(.memory(data: $0, mimeType: "application/vnd.apple.mpegurl")) } ?? .missing
        default:
            if let segment = segments[path] {
                return .found(.memory(data: segment.data, mimeType: mimeType(for: path)))
            }
            if let url = spilledSegments[path] {
                let byteCount = spilledSegmentSizes[path] ?? fileSize(at: url) ?? 0
                guard byteCount > 0 else { return .missing }
                return .found(.disk(url: url, byteCount: byteCount, mimeType: mimeType(for: path)))
            }
            if progressiveSegments[path] != nil {
                return .found(.progressive(name: path, mimeType: mimeType(for: path)))
            }
            return evictedResources.contains(path) ? .gone : .missing
        }
    }

    private func fileSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private func mirror(_ data: Data, name: String) {
        guard let debugDirectory else { return }
        let destination = debugDirectory.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            lock.lock()
            debugMirrorBytes += Int64(data.count)
            lock.unlock()
        } catch {
            Self.logger.info("[CMP-HLS-STORE] debug mirror failed name=\(name, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func mimeType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".m4s") || name.hasSuffix(".mp4") { return "video/mp4" }
        return "application/octet-stream"
    }
}
