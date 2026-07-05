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

    struct SegmentAppendResult {
        let evictedSegmentNames: [String]
    }

    private struct Segment {
        let name: String
        let data: Data
        let duration: Double
        let createdAt: Date
        var pinned: Int = 0
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "LoopbackSegmentStore"
    )
    /// Warm-tail floor: the evictor keeps up to this many recent segments
    /// resident even when over the memory budget, so AVPlayer re-fetches of
    /// just-served media come from RAM instead of spill. Count-only it is
    /// blind to segment size — at ~30 MB Blu-ray-remux segments, 8 resident
    /// segments are ~240 MiB against a 96 MiB constrained budget (measured
    /// on a 3 GB Apple TV: store steady at 210–239 MiB). The floor is
    /// therefore byte-capped by `evictionFloorReachedLocked`.
    private static let minimumSegmentsToKeep = 8
    /// Segments the evictor must never go below regardless of bytes: the
    /// currently-serving segment plus its successor.
    private static let minimumSegmentsToKeepHard = 2

    /// Shared floor predicate for the evictor and the append-admission
    /// simulation (`appendWouldFitLocked`) — the two must agree or relief
    /// can satisfy a looser criterion than the gate it unblocks. The warm
    /// count floor only holds while the resident bytes stay within 1.5× the
    /// memory budget; past that, eviction continues down to the hard
    /// minimum. Small segments never feel the byte clause (the budget
    /// check terminates eviction first); large segments stop overriding
    /// the budget by 2.5×.
    private static func evictionFloorReached(
        segmentCount: Int,
        residentBytes: Int,
        memoryBudgetBytes: Int
    ) -> Bool {
        if segmentCount <= minimumSegmentsToKeepHard { return true }
        guard segmentCount <= minimumSegmentsToKeep else { return false }
        return residentBytes <= memoryBudgetBytes + memoryBudgetBytes / 2
    }

    let generation: UInt64
    private let memoryBudgetBytes: Int
    private let debugDirectory: URL?
    private let lock = NSCondition()
    private var initSegment: Data?
    private var mediaPlaylist: Data?
    private var masterPlaylist: Data?
    private var segments: [String: Segment] = [:]
    /// Anchor segments the producer is still writing, published fragment by
    /// fragment so the server can stream them before the cut completes
    /// (seek-latency: AVPlayer only needs the first ~2 s of a 10 s anchor
    /// segment to render). NOT counted against `memoryBytes` — the bytes
    /// transiently duplicate the writer's own pending buffer, bounded by
    /// one segment. Replaced wholesale by `beginProgressiveSegment` (a
    /// restarted producer re-publishing the same name must not append to a
    /// dead predecessor's prefix) and cleared when the complete segment
    /// arrives via `append` or the name leaves the VOD window.
    private var progressiveSegments: [String: Data] = [:]
    private var spillingSegments: [String: Segment] = [:]
    private var spilledSegments: [String: URL] = [:]
    private var spilledSegmentSizes: [String: Int] = [:]
    private var segmentOrder: [String] = []
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

    private enum ResourceLocation {
        case memory(data: Data, mimeType: String)
        case disk(url: URL, byteCount: Int, mimeType: String)
        case progressive(name: String, mimeType: String)
        case missing
        case gone
    }

    init(
        generation: UInt64,
        memoryBudgetBytes: Int = 128 * 1024 * 1024,
        spillPolicy: SpillPolicy = .disabled(reason: "default"),
        debugDirectory: URL? = nil
    ) {
        self.generation = generation
        self.memoryBudgetBytes = memoryBudgetBytes
        self.debugDirectory = debugDirectory
        self.spillPolicy = spillPolicy
        if spillPolicy.isEnabled {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("continuum-dv-hls", isDirectory: true)
                .appendingPathComponent("\(generation)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.spillDirectory = dir
        } else {
            self.spillDirectory = nil
        }
        if let debugDirectory {
            try? FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        }
        Self.logger.info("[CMP-HLS-STORE] generation=\(self.generation, privacy: .public) spillPolicy=\(spillPolicy.isEnabled ? "enabled" : "memory", privacy: .public) reason=\(spillPolicy.reason, privacy: .public) maxBytes=\(spillPolicy.maxBytes, privacy: .public)")
    }

    deinit {
        print("[CMP-LIFE] deinit LoopbackSegmentStore")
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

    func putSegment(name: String, data: Data, duration: Double) -> SegmentAppendResult {
        lock.lock()
        if let old = segments[name] {
            memoryBytes -= old.data.count
        } else {
            segmentOrder.append(name)
        }
        segments[name] = Segment(name: name, data: data, duration: duration, createdAt: Date())
        memoryBytes += data.count
        generatedMediaSeconds += duration
        evictedResources.remove(name)
        // The complete segment supersedes any in-progress publication;
        // streaming readers finish from the stored data.
        progressiveSegments.removeValue(forKey: name)
        var vodDoomedURLs: [URL] = []
        if vodRetentionBudgetBytes > 0 {
            if let index = Self.segmentIndex(fromName: name) {
                vodHighWaterIndex = max(vodHighWaterIndex, index)
            }
            vodDoomedURLs = vodPruneLocked()
        }
        let evicted = evictIfNeededLocked()
        lock.broadcast()
        lock.unlock()
        for url in vodDoomedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        mirror(data, name: name)
        return SegmentAppendResult(evictedSegmentNames: evicted)
    }

    // MARK: - VOD retention (loopback-primary plan, 1e)

    private var vodRetentionBudgetBytes: Int64 = 0
    private var vodForwardWindow = 10
    private var vodBackwardWindow = 20
    /// Byte cap on produce-ahead past the consumer target. The segment-count
    /// window alone is blind to segment size: at ~30 MB Blu-ray-remux
    /// segments, `target + 10` authorizes ~300 MB of produced-ahead media,
    /// which the producer races through at wire speed (measured ~300 Mbps /
    /// 460 MiB in 14 s on a 3 GB Apple TV — jetsam). The byte gate parks the
    /// producer once forward bytes (memory + spill) reach the budget, so
    /// produce-ahead scales down as bitrate scales up. Low-bitrate sources
    /// never hit it; the count window stays their binding constraint.
    private var vodForwardByteBudget: Int64 = 192 << 20
    /// Forward segments always allowed past the target regardless of bytes,
    /// so a pathological byte state (e.g. stale forward segments retained
    /// across a backward seek exhausting the budget) can never starve the
    /// consumer of its next segments.
    private static let vodForwardMinSegments = 3
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
    /// as "retention not configured" — pruning silently never runs and the
    /// spill gate eventually deadlocks the producer (living-room
    /// spill-exhaustion freeze). Configuring retention must always retain
    /// *some* positive budget; small explicit budgets stay honored as-is
    /// (aggressive eviction is a valid mode — tests use it).
    static let vodRetentionBudgetFloorBytes: Int64 = 256 << 20

    func configureVODRetention(
        budgetBytes: Int64,
        forwardWindow: Int = 10,
        backwardWindow: Int = 20,
        forwardByteBudget: Int64 = 192 << 20
    ) {
        lock.lock()
        vodRetentionBudgetBytes = budgetBytes > 0
            ? budgetBytes
            : Self.vodRetentionBudgetFloorBytes
        vodForwardWindow = max(1, forwardWindow)
        vodBackwardWindow = max(0, backwardWindow)
        vodForwardByteBudget = max(1 << 20, forwardByteBudget)
        lock.unlock()
    }

    /// Consumer fetch high-water: every segment GET declares its index. The
    /// hard retention window follows the newest target (a backward scrub is
    /// a valid non-monotonic move) and pruning re-runs around it.
    func declareVODTarget(_ index: Int) {
        lock.lock()
        guard vodRetentionBudgetBytes > 0 else {
            lock.unlock()
            return
        }
        vodTargetIndex = index
        vodTargetDeclarationCount += 1
        let doomed = vodPruneLocked()
        lock.broadcast()
        lock.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Producer window backpressure: appends past `target + forwardWindow`
    /// wait, so the producer paces on consumption instead of racing to EOF.
    /// The byte budget bounds backward history; this bounds the forward span
    /// (and by construction it also parks the producer when the playhead
    /// wedges, replacing the EVENT generated-ahead throttle).
    func vodProducerMayAppend(segmentIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard vodRetentionBudgetBytes > 0 else { return true }
        guard segmentIndex <= vodTargetIndex + vodForwardWindow else { return false }
        // Byte-aware clamp on top of the count window (see
        // `vodForwardByteBudget`). The min-segments floor guarantees the
        // consumer's next segments are always producible.
        if segmentIndex <= vodTargetIndex + Self.vodForwardMinSegments { return true }
        return vodForwardBytesLocked() < vodForwardByteBudget
    }

    /// Bytes of produced segments ahead of the consumer target, across
    /// memory-resident, in-flight-spill, and spilled storage. Counting the
    /// spilled bytes too is deliberate: the gate exists to bound the
    /// producer's read race (network + transient mux/spill allocations),
    /// not just resident store bytes — a spill-exempt gate would let the
    /// count window keep authorizing wire-speed reads straight to disk.
    private func vodForwardBytesLocked() -> Int64 {
        var total: Int64 = 0
        for (name, segment) in segments {
            if let index = Self.segmentIndex(fromName: name), index > vodTargetIndex {
                total += Int64(segment.data.count)
            }
        }
        for (name, segment) in spillingSegments {
            if let index = Self.segmentIndex(fromName: name), index > vodTargetIndex {
                total += Int64(segment.data.count)
            }
        }
        for (name, size) in spilledSegmentSizes {
            if let index = Self.segmentIndex(fromName: name), index > vodTargetIndex {
                total += Int64(size)
            }
        }
        return total
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
        deadline: Date
    ) -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let segment = segments[name] ?? spillingSegments[name] {
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
        print("[CMP-HLS-STORE] waitForSegment enter name=\(normalized) evicted=\(evictedResources.contains(normalized) ? 1 : 0) present=\(segments[normalized] != nil ? 1 : 0)")
        while segments[normalized] == nil,
              progressiveSegments[normalized] == nil,
              spillingSegments[normalized] == nil,
              spilledSegments[normalized] == nil,
              Date() < deadline {
            // Checked before every wait (including the first); a second
            // consecutive out-of-band observation exits the wait.
            if let index = waitedIndex,
               vodRetentionBudgetBytes > 0,
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
        print("[CMP-HLS-STORE] waitForSegment exit name=\(normalized) found=\(found ? 1 : 0) superseded=\(superseded ? 1 : 0) waitedMs=\(Int((CFAbsoluteTimeGetCurrent() - started) * 1000))")
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
    /// The inventory unions all three residency states rather than reading
    /// `segmentOrder`: the memory-eviction loop removes a name from
    /// `segmentOrder` when it spills it to disk, so an order-based
    /// inventory is blind to every spilled segment — retention then never
    /// evicts a spilled byte and the spill gate eventually deadlocks the
    /// producer (living-room spill-exhaustion freeze).
    private func vodPruneLocked() -> [URL] {
        var names = Set(segments.keys)
        names.formUnion(spillingSegments.keys)
        names.formUnion(spilledSegments.keys)
        let inventory: [(index: Int, bytes: Int)] = names.compactMap { name in
            guard let index = Self.segmentIndex(fromName: name) else { return nil }
            let bytes = segments[name]?.data.count
                ?? spillingSegments[name]?.data.count
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
            if let segment = segments[name], segment.pinned > 0 { continue }
            if let segment = segments.removeValue(forKey: name) {
                memoryBytes -= segment.data.count
            }
            if let segment = spillingSegments.removeValue(forKey: name) {
                tempSpillBytes -= Int64(segment.data.count)
            }
            if let url = spilledSegments.removeValue(forKey: name) {
                tempSpillBytes -= Int64(spilledSegmentSizes.removeValue(forKey: name) ?? 0)
                doomed.append(url)
            }
            segmentOrder.removeAll { $0 == name }
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

    /// Emergency relief for the writer's append gate: runs the normal
    /// target-anchored prune, then — if the projected append still exceeds
    /// the spill budget — force-evicts segments farthest from the current
    /// VOD target until the append fits, sparing only the immediate
    /// `[target − backward, target + forward]` neighborhood (unlike the
    /// prune's hard window this ignores the produced high-water: anything
    /// outside the playhead's neighborhood is regenerable via a producer
    /// restart, and a wedged producer is strictly worse). Fit is judged by
    /// the writer's own append criterion (`appendWouldFitLocked`) — spill
    /// bytes plus the projected spill demand of the append — and the return
    /// value reports whether that gate would now pass.
    func makeRoomForAppend(byteCount: Int) -> Bool {
        guard byteCount > 0 else { return true }
        lock.lock()
        guard spillPolicy.isEnabled, vodRetentionBudgetBytes > 0 else {
            lock.unlock()
            return true
        }
        var doomed = vodPruneLocked()
        var forceEvicted = 0
        if !appendWouldFitLocked(byteCount: byteCount) {
            let lo = vodTargetIndex - vodBackwardWindow
            let hi = vodTargetIndex + vodForwardWindow
            // Only segments that actually occupy spill budget qualify —
            // evicting memory-resident segments frees no spill bytes and
            // would just destroy good cache. (Not `segmentOrder`: spilled
            // names have already left it — see vodPruneLocked.)
            var spillNames = Set(spilledSegments.keys)
            spillNames.formUnion(spillingSegments.keys)
            var candidates: [(index: Int, name: String)] = spillNames.compactMap { name in
                guard let index = Self.segmentIndex(fromName: name),
                      index < lo || index > hi else { return nil }
                return (index, name)
            }
            candidates.sort { abs($0.index - vodTargetIndex) > abs($1.index - vodTargetIndex) }
            for candidate in candidates {
                if appendWouldFitLocked(byteCount: byteCount) { break }
                let name = candidate.name
                if let segment = spillingSegments.removeValue(forKey: name) {
                    tempSpillBytes -= Int64(segment.data.count)
                }
                if let url = spilledSegments.removeValue(forKey: name) {
                    tempSpillBytes -= Int64(spilledSegmentSizes.removeValue(forKey: name) ?? 0)
                    doomed.append(url)
                }
                segmentOrder.removeAll { $0 == name }
                forceEvicted += 1
                // Same as vodPruneLocked: regenerable, so not `.gone`.
            }
            tempSpillBytes = max(0, tempSpillBytes)
        }
        let fits = appendWouldFitLocked(byteCount: byteCount)
        lock.broadcast()
        lock.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
        if forceEvicted > 0 {
            Self.logger.info("[CMP-HLS-STORE] generation=\(self.generation, privacy: .public) force-evicted=\(forceEvicted, privacy: .public) for append tempSpillBytes=\(self.stats().tempSpillBytes, privacy: .public)")
        }
        return fits
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
            if let segment = spillingSegments.removeValue(forKey: name) {
                tempSpillBytes -= Int64(segment.data.count)
                didRetire = true
            }
            if let spillURL = spilledSegments.removeValue(forKey: name) {
                let size = spilledSegmentSizes.removeValue(forKey: name) ?? 0
                tempSpillBytes -= Int64(size)
                spillURLsToDelete.append(spillURL)
                didRetire = true
            }

            if didRetire {
                segmentOrder.removeAll { $0 == name }
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

    func canAppendSegment(byteCount: Int) -> Bool {
        guard byteCount > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        return appendWouldFitLocked(byteCount: byteCount)
    }

    /// Must run under `lock`. The writer's append criterion: the append is
    /// acceptable when it fits in memory outright, or when the spill budget
    /// can absorb every memory-resident segment the evictor would spill to
    /// bring the append back under the memory budget (honoring pins and the
    /// minimum-resident floor). Shared by the gate (`canAppendSegment`) and
    /// the relief path (`makeRoomForAppend`) so relief can never satisfy a
    /// looser criterion than the gate it exists to unblock.
    private func appendWouldFitLocked(byteCount: Int) -> Bool {
        guard spillPolicy.isEnabled else { return true }
        guard memoryBytes + byteCount > memoryBudgetBytes else { return true }

        var projectedMemoryBytes = memoryBytes + byteCount
        var projectedSpillBytes = tempSpillBytes
        var projectedSegmentCount = segmentOrder.count + 1

        for name in segmentOrder {
            guard projectedMemoryBytes > memoryBudgetBytes,
                  !Self.evictionFloorReached(
                      segmentCount: projectedSegmentCount,
                      residentBytes: projectedMemoryBytes,
                      memoryBudgetBytes: memoryBudgetBytes
                  ) else {
                break
            }
            guard let segment = segments[name],
                  segment.pinned == 0 else {
                break
            }
            projectedMemoryBytes -= segment.data.count
            projectedSpillBytes += Int64(segment.data.count)
            projectedSegmentCount -= 1
        }

        return projectedSpillBytes <= spillPolicy.maxBytes
    }

    func resource(path: String, waitForNearFuture: Bool = true) -> ResourceResult {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let started = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if waitForNearFuture,
           normalized.hasPrefix("seg_"),
           segments[normalized] == nil,
           progressiveSegments[normalized] == nil,
           spillingSegments[normalized] == nil,
           spilledSegments[normalized] == nil,
           !evictedResources.contains(normalized) {
            waitCount += 1
            _ = lock.wait(until: Date().addingTimeInterval(1.0))
        }
        let location = resourceLocationLocked(path: normalized)
        lock.unlock()

        let result: ResourceResult
        switch location {
        case .memory(let data, let mimeType):
            result = .found(.memory(data: data, mimeType: mimeType))
        case .disk(let url, let byteCount, let mimeType):
            result = .found(.disk(url: url, byteCount: byteCount, mimeType: mimeType))
        case .progressive(let name, let mimeType):
            result = .found(.progressive(name: name, mimeType: mimeType))
        case .missing:
            result = .missing
        case .gone:
            result = .gone
        }

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

    /// Test seam: runs between a spill's disk write and the store re-locking
    /// to finalize it — the window where a concurrent prune (running on a
    /// server request thread via `declareVODTarget`) can claim the in-flight
    /// segment. Nil outside tests.
    var spillWriteInterludeForTesting: (() -> Void)?

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

    private func resourceLocationLocked(path: String) -> ResourceLocation {
        switch path {
        case "init.mp4":
            return initSegment.map { .memory(data: $0, mimeType: "video/mp4") } ?? .missing
        case "playlist.m3u8":
            return mediaPlaylist.map { .memory(data: $0, mimeType: "application/vnd.apple.mpegurl") } ?? .missing
        case "master.m3u8":
            return masterPlaylist.map { .memory(data: $0, mimeType: "application/vnd.apple.mpegurl") } ?? .missing
        default:
            if let segment = segments[path] {
                return .memory(data: segment.data, mimeType: mimeType(for: path))
            }
            if let segment = spillingSegments[path] {
                return .memory(data: segment.data, mimeType: mimeType(for: path))
            }
            if let url = spilledSegments[path] {
                let byteCount = spilledSegmentSizes[path] ?? fileSize(at: url) ?? 0
                guard byteCount > 0 else { return .missing }
                return .disk(url: url, byteCount: byteCount, mimeType: mimeType(for: path))
            }
            if progressiveSegments[path] != nil {
                return .progressive(name: path, mimeType: mimeType(for: path))
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

    private func evictIfNeededLocked() -> [String] {
        var evicted: [String] = []
        while memoryBytes > memoryBudgetBytes,
              !Self.evictionFloorReached(
                  segmentCount: segmentOrder.count,
                  residentBytes: memoryBytes,
                  memoryBudgetBytes: memoryBudgetBytes
              ) {
            guard let candidate = segmentOrder.first,
                  let segment = segments[candidate],
                  segment.pinned == 0 else {
                break
            }
            segmentOrder.removeFirst()
            segments.removeValue(forKey: candidate)
            memoryBytes -= segment.data.count
            guard let spillURL = reserveSpillLocked(segment) else {
                evictedResources.insert(candidate)
                evicted.append(candidate)
                continue
            }

            lock.unlock()
            let spilled = spillSegmentToDisk(segment, to: spillURL)
            spillWriteInterludeForTesting?()
            lock.lock()
            finishSpillLocked(segment, url: spillURL, spilled: spilled, evicted: &evicted)
            lock.broadcast()
        }
        if !evicted.isEmpty {
            Self.logger.info("[CMP-HLS-STORE] generation=\(self.generation, privacy: .public) evicted=\(evicted.count, privacy: .public) memoryBytes=\(self.memoryBytes, privacy: .public)")
        }
        return evicted
    }

    private func reserveSpillLocked(_ segment: Segment) -> URL? {
        guard let spillDirectory else { return nil }
        guard tempSpillBytes + Int64(segment.data.count) <= spillPolicy.maxBytes else {
            Self.logger.info("[CMP-HLS-STORE] generation=\(self.generation, privacy: .public) temp spill budget exceeded name=\(segment.name, privacy: .public) bytes=\(segment.data.count, privacy: .public) maxBytes=\(self.spillPolicy.maxBytes, privacy: .public)")
            return nil
        }
        spillingSegments[segment.name] = segment
        tempSpillBytes += Int64(segment.data.count)
        return spillDirectory.appendingPathComponent(segment.name)
    }

    private func spillSegmentToDisk(_ segment: Segment, to url: URL) -> Bool {
        do {
            try segment.data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func finishSpillLocked(
        _ segment: Segment,
        url: URL,
        spilled: Bool,
        evicted: inout [String]
    ) {
        let wasSpilling = spillingSegments.removeValue(forKey: segment.name) != nil
        guard wasSpilling else {
            // Someone claimed the in-flight spill while the lock was down
            // for the disk write: retirement, the VOD prune, or the
            // force-evict relief. All of them already released the reserved
            // spill bytes, so registering the segment now would resurrect
            // an eviction victim whose size no longer counts against the
            // budget (and whose later removal would deduct it a second
            // time). Drop the orphaned file instead.
            if spilled {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        if evictedResources.contains(segment.name) {
            tempSpillBytes -= Int64(segment.data.count)
            tempSpillBytes = max(0, tempSpillBytes)
            if spilled {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        if spilled {
            spilledSegments[segment.name] = url
            spilledSegmentSizes[segment.name] = segment.data.count
            return
        }
        tempSpillBytes -= Int64(segment.data.count)
        tempSpillBytes = max(0, tempSpillBytes)
        evictedResources.insert(segment.name)
        evicted.append(segment.name)
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
