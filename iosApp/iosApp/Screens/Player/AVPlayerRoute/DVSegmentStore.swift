import Foundation
import OSLog

struct DVSegmentStoreStats: Equatable {
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

final class DVSegmentStore {
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
        /// A `seg_*` resource that has not been produced yet and has not
        /// been evicted — it will plausibly exist shortly. The server
        /// answers 503 + Retry-After so AVPlayer retries; a 404 on a VOD
        /// asset is treated as terminal `loadFailed`.
        case pending
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
        category: "DVSegmentStore"
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
        let evicted = evictIfNeededLocked()
        lock.broadcast()
        lock.unlock()
        mirror(data, name: name)
        return SegmentAppendResult(evictedSegmentNames: evicted)
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
            // Short grace so a segment that is mid-write when requested is
            // served without a retry round trip. Kept short because this
            // wait holds up the server's serial connection queue; anything
            // slower falls through to `.pending` and the client retries.
            waitCount += 1
            _ = lock.wait(until: Date().addingTimeInterval(0.25))
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
            // An un-produced (not evicted) segment name is upcoming, not
            // absent — distinguish it so the server can answer retriable.
            result = normalized.hasPrefix("seg_") ? .pending : .missing
        case .gone:
            result = .gone
        }

        lock.lock()
        requestCount += 1
        switch result {
        case .found(let resource):
            bytesServed += Int64(resource.byteCount)
        case .pending, .missing, .gone:
            break
        }
        lastRequestLatencyMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        lock.unlock()
        return result
    }

    func stats() -> DVSegmentStoreStats {
        lock.lock()
        let snapshot = DVSegmentStoreStats(
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
