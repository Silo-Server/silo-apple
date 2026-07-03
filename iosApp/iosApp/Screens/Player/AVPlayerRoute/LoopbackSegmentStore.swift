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

        var mimeType: String {
            switch self {
            case .memory(_, let mimeType), .disk(_, _, let mimeType):
                return mimeType
            }
        }

        var byteCount: Int {
            switch self {
            case .memory(let data, _):
                return data.count
            case .disk(_, let byteCount, _):
                return byteCount
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
    private static let minimumSegmentsToKeep = 8

    let generation: UInt64
    private let memoryBudgetBytes: Int
    private let debugDirectory: URL?
    private let lock = NSCondition()
    private var initSegment: Data?
    private var mediaPlaylist: Data?
    private var masterPlaylist: Data?
    private var segments: [String: Segment] = [:]
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
    private var vodTargetIndex = 0
    private var vodHighWaterIndex = -1
    /// Counts `declareVODTarget` calls so waiters can tell "a real consumer
    /// target exists" apart from the fresh-store default of index 0.
    private var vodTargetDeclarationCount: UInt64 = 0

    static func segmentIndex(fromName name: String) -> Int? {
        guard name.hasPrefix("seg_"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }

    func configureVODRetention(
        budgetBytes: Int64,
        forwardWindow: Int = 10,
        backwardWindow: Int = 20
    ) {
        lock.lock()
        vodRetentionBudgetBytes = max(0, budgetBytes)
        vodForwardWindow = max(1, forwardWindow)
        vodBackwardWindow = max(0, backwardWindow)
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
        return segmentIndex <= vodTargetIndex + vodForwardWindow
    }

    /// Bounded wait used by the server's miss resolver while a producer
    /// restart fills the requested segment.
    ///
    /// Supersede early-exit: the wait survives only while the newest declared
    /// consumer target T keeps the waited segment N inside the producer band
    /// `[T - forwardWindow, T + forwardWindow]`. Outside that band the wait
    /// is provably moot — above it every producer parks at
    /// `T + forwardWindow` (`vodProducerMayAppend`) and can never fill N;
    /// below it producers only march forward, and anything that could
    /// regenerate N would first re-declare a target near N. Inside the band
    /// the wait stays alive: the miss's own restart seeds `declareVODTarget`
    /// at (or near) N, and a covering producer's march delivers it.
    /// `declareVODTarget` already broadcasts on the condition, so a
    /// superseding scrub wakes the waiter immediately instead of letting an
    /// abandoned fetch ride the full deadline.
    func waitForSegment(named name: String, deadline: Date) -> ResourceResult {
        let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let waitedIndex = Self.segmentIndex(fromName: normalized)
        let started = CFAbsoluteTimeGetCurrent()
        var superseded = false
        lock.lock()
        print("[CMP-HLS-STORE] waitForSegment enter name=\(normalized) evicted=\(evictedResources.contains(normalized) ? 1 : 0) present=\(segments[normalized] != nil ? 1 : 0)")
        while segments[normalized] == nil,
              spillingSegments[normalized] == nil,
              spilledSegments[normalized] == nil,
              Date() < deadline {
            // Checked before every wait (including the first) so a target
            // that was already stale at entry exits immediately.
            if let index = waitedIndex,
               vodRetentionBudgetBytes > 0,
               vodTargetDeclarationCount > 0,
               abs(index - vodTargetIndex) > vodForwardWindow {
                superseded = true
                break
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
    private func vodPruneLocked() -> [URL] {
        let inventory: [(index: Int, bytes: Int)] = segmentOrder.compactMap { name in
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
        tempSpillBytes = max(0, tempSpillBytes)
        return doomed
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
        guard spillPolicy.isEnabled else { return true }
        guard memoryBytes + byteCount > memoryBudgetBytes else { return true }

        var projectedMemoryBytes = memoryBytes + byteCount
        var projectedSpillBytes = tempSpillBytes
        var projectedSegmentCount = segmentOrder.count + 1

        for name in segmentOrder {
            guard projectedMemoryBytes > memoryBudgetBytes,
                  projectedSegmentCount > Self.minimumSegmentsToKeep else {
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

        guard projectedSpillBytes <= spillPolicy.maxBytes else { return false }
        return true
    }

    func resource(path: String, waitForNearFuture: Bool = true) -> ResourceResult {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let started = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if waitForNearFuture,
           normalized.hasPrefix("seg_"),
           segments[normalized] == nil,
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
        while memoryBytes > memoryBudgetBytes, segmentOrder.count > Self.minimumSegmentsToKeep {
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
        if evictedResources.contains(segment.name) {
            if wasSpilling {
                tempSpillBytes -= Int64(segment.data.count)
                tempSpillBytes = max(0, tempSpillBytes)
            }
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
