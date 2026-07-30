import Foundation
import Network
import OSLog
import Security

struct PlaybackSourceProxyStats: Equatable {
    let cachedBytes: Int64
    let cacheBudgetBytes: Int64
    let highWaterBytes: Int64
    let lowWaterBytes: Int64
    let forwardCachedBytes: Int64
    let estimatedForwardCacheAheadSeconds: Double?
    let originBytesTransferred: Int64
    let currentOriginBitrateBps: Double?
    let cacheHitBytes: Int64
    let cacheMissBytes: Int64
    let activeOriginRequestCount: Int
    let diskSpillBytes: Int64
    let diskBudgetBytes: Int64
    let diskBytesWritten: Int64
    let resumeCapable: Bool
    let serverAdvertisesDirectStreamResume: Bool
}

enum PlaybackSourceInterruptionReason: Equatable {
    case serverUnavailable(statusCode: Int)
    case networkUnavailable
    /// The origin stopped producing bytes before the resolved end of the
    /// response (2026-06-28 stall report §4). `offset` is the first byte the
    /// proxy could not serve; `expectedEnd` is the last byte the response
    /// promised.
    case prematureEOF(offset: Int64, expectedEnd: Int64)
    /// A validator-protected range reopen returned a full response, proving
    /// the cached prefix belongs to a replaced source entity.
    case sourceEntityChanged
}

/// How a proxied GET response loop ended. Pure decision so tests can pin the
/// premature-EOF classification without a network stack: a short origin read
/// must be distinguishable from normal completion, consumer disconnect (a
/// send failure returns before classification), fetch errors (notified via
/// their own path), and teardown cancellation.
enum PlaybackSourceResponseEnd: Equatable {
    case complete
    case cancelled
    case fetchFailed
    case prematureEOF(offset: Int64, expectedEnd: Int64)

    static func classify(
        cursor: Int64,
        responseEnd: Int64?,
        totalLength: Int64?,
        wasCancelled: Bool,
        sawEmptyFetch: Bool,
        sawFetchError: Bool
    ) -> PlaybackSourceResponseEnd {
        if wasCancelled { return .cancelled }
        if sawFetchError { return .fetchFailed }
        // An exact range promising bytes past the real EOF (total unknown at
        // request time) must classify as complete, not premature EOF.
        let clampedEnd = responseEnd.map { end in totalLength.map { min(end, $0 - 1) } ?? end }
        guard sawEmptyFetch,
              let expectedEnd = clampedEnd ?? totalLength.map({ max(0, $0 - 1) }),
              cursor <= expectedEnd else {
            return .complete
        }
        return .prematureEOF(offset: cursor, expectedEnd: expectedEnd)
    }
}

final class PlaybackSourceCache {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackSourceCache"
    )

    static var defaultMemoryBudgetBytes: Int {
        isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 128 * 1024 * 1024
    }
    static var siloLoopbackMemoryBudgetBytes: Int {
        isConstrainedMemoryDevice ? 128 * 1024 * 1024 : 256 * 1024 * 1024
    }
    /// Session NAND-write budget multiplier over the disk retention budget.
    /// Spill writes the stream to flash once per watched-and-evicted byte, so
    /// an unbounded budget writes a 70 GB remux to NAND every viewing.
    /// Constrained devices (small-NAND Apple TVs) get half the allowance.
    static var diskWriteBudgetMultiplier: Int64 {
        isConstrainedMemoryDevice ? 1 : 2
    }
    /// When the retention budget holds less than this much content, the
    /// wear-per-benefit ratio is poor (a 2 GiB budget is ~4 min of a
    /// Blu-ray remux) — the write budget is halved for such sources.
    static let diskWriteBudgetBitrateGateSeconds: Double = 600
    /// Streaming appends grow a span in place until it reaches this size,
    /// then roll over to a new span so eviction stays reasonably granular.
    static let maxAppendSpanBytes = 16 * 1024 * 1024

    static var isConstrainedMemoryDevice: Bool {
        #if os(tvOS)
        return ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
        #else
        return false
        #endif
    }

    struct Snapshot: Equatable {
        let cachedBytes: Int64
        let cacheBudgetBytes: Int64
        let highWaterBytes: Int64
        let lowWaterBytes: Int64
        let forwardCachedBytes: Int64
        let estimatedForwardCacheAheadSeconds: Double?
        let originBytesTransferred: Int64
        let currentOriginBitrateBps: Double?
        let cacheHitBytes: Int64
        let cacheMissBytes: Int64
        let activeOriginRequestCount: Int
        let diskSpillBytes: Int64
        let diskBudgetBytes: Int64
        let diskBytesWritten: Int64
    }

    struct Gap {
        let start: Int64
        let end: Int64
    }

    private struct Span {
        var start: Int64
        var data: Data
        var createdAt = Date()
        var end: Int64 { start + Int64(data.count) - 1 }
        var range: ClosedRange<Int64> { start...end }
    }

    private struct Pin {
        let id: UUID
        let range: ClosedRange<Int64>
    }

    private struct DiskSpan {
        let start: Int64
        let length: Int
        let url: URL
        let createdAt: Date
        var end: Int64 { start + Int64(length) - 1 }
        var range: ClosedRange<Int64> { start...end }
    }

    let maxBytes: Int
    let highWaterBytes: Int
    let lowWaterBytes: Int
    private let lock = NSLock()
    private var spans: [Span] = []
    private var diskSpans: [DiskSpan] = []
    private var pins: [Pin] = []
    private var totalLength: Int64?
    private var cachedBytes: Int = 0
    private var originBytesTransferred: Int64 = 0
    private var cacheHitBytes: Int64 = 0
    private var cacheMissBytes: Int64 = 0
    private var activeOriginRequestCount = 0
    private var diskSpillBytes: Int64 = 0
    private var diskBytesWritten: Int64 = 0
    private var loggedWriteBudgetExhausted = false
    private var prefetchArmed = true
    private var recentTransfers: [(time: Date, bytes: Int)] = []
    private var lastReadEnd: Int64?
    /// Most recent read position (not a high-water mark). `lastReadEnd` is
    /// monotonic for forward-buffer accounting, so after a backward seek it
    /// stays pinned ahead of the bytes actually being served — disk eviction
    /// must anchor here instead, or it protects the wrong neighborhood.
    private var lastReadPosition: Int64?
    private var sourceBitrateBps: Double?
    private let diskSpillEnabled: Bool
    private let diskBudgetBytes: Int64
    private let diskDirectory: URL?

    /// The known total file length, once any origin response reported one.
    /// Used by the cache-handoff adoption check (a changed total under the
    /// same file id means the file was replaced and the cached bytes are
    /// stale).
    var knownTotalLength: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return totalLength
    }

    /// Effective disk-spill state after env overrides — the handoff adoption
    /// check compares it against what a freshly built cache would resolve.
    var diskSpillActive: Bool { diskSpillEnabled }

    /// Env vars remain as dev overrides in both directions; the shipped
    /// default comes from the caller (user "Seek Cache" setting, default on).
    /// Internal (not private) so handoff adoption can resolve the effective
    /// state a replacement cache would get.
    static func resolveDiskSpillEnabled(_ requested: Bool) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SILO_DISABLE_SOURCE_DISK_SPILL"] == "1" { return false }
        if env["SILO_ENABLE_SOURCE_DISK_SPILL"] == "1" { return true }
        return requested
    }

    init(
        maxBytes: Int = PlaybackSourceCache.defaultMemoryBudgetBytes,
        diskSpillEnabled: Bool = true,
        diskBudgetBytes: Int64? = nil
    ) {
        self.maxBytes = maxBytes
        self.highWaterBytes = maxBytes
        self.lowWaterBytes = max(0, maxBytes - 64 * 1024 * 1024)
        self.diskSpillEnabled = Self.resolveDiskSpillEnabled(diskSpillEnabled)
        self.diskBudgetBytes = diskBudgetBytes
            ?? PlaybackDiskBudget.retentionBudget(availableBytes: PlaybackDiskBudget.freeDiskSpaceBytes())
        _ = PlaybackDiskBudget.sweepOrphanedSpillDirectories
        if self.diskSpillEnabled {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("continuum-source-cache", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.diskDirectory = dir
        } else {
            self.diskDirectory = nil
        }
    }

    deinit {
        print("[CMP-LIFE] deinit PlaybackSourceCache")
        if let diskDirectory {
            try? FileManager.default.removeItem(at: diskDirectory)
        }
    }

    var maxCacheableBytes: Int { maxBytes }
    var downstreamHighWaterBytes: Int { highWaterBytes }
    var downstreamLowWaterBytes: Int { lowWaterBytes }
    var shouldPrefetch: Bool {
        var didRearm = false
        lock.lock()
        let cachedAhead = lastReadEnd == nil
            ? Int64(cachedBytes)
            : forwardCachedBytesLocked()
        if prefetchArmed, cachedAhead >= Int64(highWaterBytes) {
            prefetchArmed = false
        } else if !prefetchArmed, cachedAhead <= Int64(lowWaterBytes) {
            prefetchArmed = true
            didRearm = true
        }
        let value = prefetchArmed
        lock.unlock()
        if didRearm {
            Self.logger.info(
                "[CMP-SOURCE-CACHE] hysteresis re-arm cachedAheadBytes=\(cachedAhead, privacy: .public) lowWaterBytes=\(self.lowWaterBytes, privacy: .public)"
            )
        }
        return value
    }

    func forwardCachedByteCount() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return lastReadEnd == nil ? Int64(cachedBytes) : forwardCachedBytesLocked()
    }

    /// Bytes consumption must drain between the park (high water) and the
    /// prefetch re-arm (low water) — the interval a parked origin stream
    /// waits before demand resumes it.
    var hysteresisGapBytes: Int64 {
        Int64(highWaterBytes - lowWaterBytes)
    }

    func currentSourceBitrateBps() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return sourceBitrateBps
    }

    func setTotalLength(_ length: Int64?) {
        guard let length, length > 0 else { return }
        lock.lock()
        if totalLength == nil || length > totalLength! {
            totalLength = length
        }
        lock.unlock()
    }

    func setSourceBitrate(_ bps: Double?) {
        guard let bps, bps > 0 else { return }
        lock.lock()
        sourceBitrateBps = bps
        lock.unlock()
    }

    func pin(_ range: ClosedRange<Int64>) -> UUID {
        let id = UUID()
        lock.lock()
        pins.append(Pin(id: id, range: range))
        lock.unlock()
        return id
    }

    func unpin(_ id: UUID) {
        lock.lock()
        pins.removeAll { $0.id == id }
        evictIfNeededLocked()
        lock.unlock()
    }

    func read(start: Int64, maxLength: Int) -> Data? {
        guard maxLength > 0 else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        guard let span = spans.first(where: { $0.start <= start && $0.end >= start }) else {
            // mmap + .uncached keeps disk hits out of the heap footprint: the
            // kernel pages the span in and out under memory pressure; only
            // the requested slice below is copied. Spans are immutable after
            // their atomic write, so there is no torn-read window.
            if let diskSpan = diskSpans.first(where: { $0.start <= start && $0.end >= start }),
               let file = try? Data(contentsOf: diskSpan.url, options: [.alwaysMapped, .uncached]) {
                let offset = Int(start - diskSpan.start)
                let length = min(maxLength, file.count - offset)
                guard length > 0 else { return nil }
                let data = file.subdata(in: offset..<(offset + length))
                cacheHitBytes += Int64(data.count)
                lastReadEnd = max(lastReadEnd ?? 0, start + Int64(data.count) - 1)
                lastReadPosition = start + Int64(data.count) - 1
                return data
            }
            return nil
        }
        let offset = Int(start - span.start)
        let length = min(maxLength, span.data.count - offset)
        guard length > 0 else { return nil }
        let data = span.data.subdata(in: offset..<(offset + length))
        cacheHitBytes += Int64(data.count)
        lastReadEnd = max(lastReadEnd ?? 0, start + Int64(data.count) - 1)
        lastReadPosition = start + Int64(data.count) - 1
        return data
    }

    /// Whether the byte at `offset` is cached, without the read-head
    /// side effects of `read`.
    func contains(offset: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if spans.contains(where: { $0.start <= offset && $0.end >= offset }) { return true }
        return diskSpans.contains(where: { $0.start <= offset && $0.end >= offset })
    }

    func missingGap(start: Int64, desiredLength: Int, totalLimit: Int64?) -> Gap? {
        guard desiredLength > 0 else { return nil }
        let requestedEnd = min(
            start + Int64(desiredLength) - 1,
            (totalLimit ?? Int64.max) - 1
        )
        guard requestedEnd >= start else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var cursor = start
        for range in cachedRangesLocked() {
            if range.upperBound < cursor { continue }
            if range.lowerBound > cursor {
                return Gap(start: cursor, end: min(range.lowerBound - 1, requestedEnd))
            }
            cursor = max(cursor, range.upperBound + 1)
            if cursor > requestedEnd { return nil }
        }
        return Gap(start: cursor, end: requestedEnd)
    }

    func store(start: Int64, data: Data, totalLength: Int64?) {
        guard !data.isEmpty, start >= 0 else { return }
        lock.lock()
        if let totalLength, totalLength > 0 {
            self.totalLength = max(self.totalLength ?? 0, totalLength)
        }
        insertSpanLocked(Span(start: start, data: data))
        evictIfNeededLocked()
        lock.unlock()
    }

    func recordOriginTransfer(byteCount: Int) {
        let now = Date()
        lock.lock()
        originBytesTransferred += Int64(byteCount)
        recentTransfers.append((now, byteCount))
        recentTransfers.removeAll { now.timeIntervalSince($0.time) > 3 }
        lock.unlock()
    }

    func recordCacheMiss(byteCount: Int64) {
        guard byteCount > 0 else { return }
        lock.lock()
        cacheMissBytes += byteCount
        lock.unlock()
    }

    func beginOriginRequest() {
        lock.lock()
        activeOriginRequestCount += 1
        lock.unlock()
    }

    func endOriginRequest() {
        lock.lock()
        activeOriginRequestCount = max(0, activeOriginRequestCount - 1)
        lock.unlock()
    }

    func nextPrefetchStart(after suggestedStart: Int64?) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let base = suggestedStart ?? lastReadEnd.map { $0 + 1 } ?? 0
        if let totalLength, base >= totalLength { return nil }
        var cursor = max(0, base)
        for range in cachedRangesLocked() {
            if range.upperBound < cursor { continue }
            if range.lowerBound > cursor { break }
            cursor = max(cursor, range.upperBound + 1)
        }
        if let totalLength, cursor >= totalLength { return nil }
        return cursor
    }

    func stats() -> Snapshot {
        let now = Date()
        lock.lock()
        let transfers = recentTransfers.filter { now.timeIntervalSince($0.time) <= 3 }
        let bytes = transfers.reduce(0) { $0 + $1.bytes }
        let oldest = transfers.map(\.time).min()
        let bitrate: Double?
        if let oldest {
            let elapsed = max(0.25, now.timeIntervalSince(oldest))
            bitrate = Double(bytes * 8) / elapsed
        } else {
            bitrate = nil
        }
        let forward = forwardCachedBytesLocked()
        let sourceBitrate = sourceBitrateBps
        let ahead = sourceBitrate.flatMap { $0 > 0 ? Double(forward * 8) / $0 : nil }
        let snapshot = Snapshot(
            cachedBytes: Int64(cachedBytes),
            cacheBudgetBytes: Int64(maxBytes),
            highWaterBytes: Int64(highWaterBytes),
            lowWaterBytes: Int64(lowWaterBytes),
            forwardCachedBytes: forward,
            estimatedForwardCacheAheadSeconds: ahead,
            originBytesTransferred: originBytesTransferred,
            currentOriginBitrateBps: bitrate,
            cacheHitBytes: cacheHitBytes,
            cacheMissBytes: cacheMissBytes,
            activeOriginRequestCount: activeOriginRequestCount,
            diskSpillBytes: diskSpillBytes,
            diskBudgetBytes: diskSpillEnabled ? diskBudgetBytes : 0,
            diskBytesWritten: diskBytesWritten
        )
        lock.unlock()
        return snapshot
    }

    private func insertSpanLocked(_ incoming: Span) {
        // Fast path for streaming appends: the incoming bytes start exactly
        // where an existing span ends and overlap nothing else, so they can
        // be appended in place instead of paying the full-copy merge.
        if let idx = spans.firstIndex(where: { $0.end + 1 == incoming.start }),
           spans[idx].data.count + incoming.data.count <= Self.maxAppendSpanBytes,
           !spans.contains(where: { $0.start >= incoming.start && $0.start <= incoming.end }),
           !diskSpans.contains(where: { rangesOverlap($0.range, incoming.range) }) {
            spans[idx].data.append(incoming.data)
            // The span is hot — keep its eviction age current so a stream
            // that appended for 16 MiB isn't the next eviction victim.
            spans[idx].createdAt = Date()
            cachedBytes += incoming.data.count
            return
        }
        var start = incoming.start
        var data = incoming.data
        let incomingEnd = incoming.end
        var kept: [Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if span.end < start || span.start > incomingEnd {
                kept.append(span)
                continue
            }
            let mergedStart = min(start, span.start)
            let mergedEnd = max(start + Int64(data.count) - 1, span.end)
            var merged = Data(count: Int(mergedEnd - mergedStart + 1))
            merged.replaceSubrange(
                Int(span.start - mergedStart)..<Int(span.start - mergedStart) + span.data.count,
                with: span.data
            )
            merged.replaceSubrange(
                Int(start - mergedStart)..<Int(start - mergedStart) + data.count,
                with: data
            )
            start = mergedStart
            data = merged
            cachedBytes -= span.data.count
        }
        kept.append(Span(start: start, data: data))
        spans = kept.sorted(by: { $0.start < $1.start })
        cachedBytes += data.count
    }

    private func evictIfNeededLocked() {
        while cachedBytes > maxBytes {
            guard let candidate = spans
                .filter({ span in !pins.contains(where: { rangesOverlap($0.range, span.range) }) })
                .min(by: { $0.createdAt < $1.createdAt }) else {
                return
            }
            spillToDiskIfEnabledLocked(candidate)
            spans.removeAll { span in
                let matches = span.start == candidate.start && span.data.count == candidate.data.count
                if matches {
                    cachedBytes -= span.data.count
                }
                return matches
            }
        }
    }

    /// Session write budget: bounds total NAND writes (retention budget only
    /// bounds what is *stored*). Once spent, spill stops for the rest of the
    /// session — including the evict-to-make-room churn — so a long watch
    /// costs at most a few GiB of flash writes instead of the full stream.
    private func diskWriteBudgetLocked() -> Int64 {
        var budget = diskBudgetBytes * Self.diskWriteBudgetMultiplier
        if let bps = sourceBitrateBps, bps > 0,
           Double(diskBudgetBytes) / (bps / 8) < Self.diskWriteBudgetBitrateGateSeconds {
            budget /= 2
        }
        return budget
    }

    private func spillToDiskIfEnabledLocked(_ span: Span) {
        guard diskSpillEnabled, let diskDirectory else { return }
        guard diskBytesWritten + Int64(span.data.count) <= diskWriteBudgetLocked() else {
            if !loggedWriteBudgetExhausted {
                loggedWriteBudgetExhausted = true
                print("[CMP-SOURCE-CACHE] spill write-budget exhausted written=\(diskBytesWritten) retained=\(diskSpillBytes) budget=\(diskWriteBudgetLocked())")
            }
            return
        }
        makeRoomOnDiskLocked(for: Int64(span.data.count))
        guard diskSpillBytes + Int64(span.data.count) <= diskBudgetBytes else { return }
        let name = "\(span.start)-\(span.end).bin"
        let url = diskDirectory.appendingPathComponent(name)
        do {
            try span.data.write(to: url, options: .atomic)
            diskSpans.append(DiskSpan(start: span.start, length: span.data.count, url: url, createdAt: Date()))
            diskSpillBytes += Int64(span.data.count)
            diskBytesWritten += Int64(span.data.count)
        } catch {
            // Spill is opportunistic; active playback can always refetch.
        }
    }

    /// Frees disk retention for an incoming spill by deleting the spans
    /// farthest from the playhead first, so a seek-back target is the last
    /// thing evicted. POSIX keeps any concurrently mapped file valid after
    /// unlink, and the ledger mutation is under `lock`, so readers are safe.
    private func makeRoomOnDiskLocked(for incomingBytes: Int64) {
        let playhead = lastReadPosition ?? lastReadEnd ?? 0
        while diskSpillBytes + incomingBytes > diskBudgetBytes, !diskSpans.isEmpty {
            guard let victimIndex = diskSpans.indices.max(by: { a, b in
                distanceFromPlayhead(diskSpans[a], playhead: playhead)
                    < distanceFromPlayhead(diskSpans[b], playhead: playhead)
            }) else { return }
            let victim = diskSpans.remove(at: victimIndex)
            diskSpillBytes -= Int64(victim.length)
            try? FileManager.default.removeItem(at: victim.url)
        }
    }

    private func distanceFromPlayhead(_ span: DiskSpan, playhead: Int64) -> Int64 {
        if span.range.contains(playhead) { return 0 }
        return min(abs(span.start - playhead), abs(span.end - playhead))
    }

    private func forwardCachedBytesLocked() -> Int64 {
        guard let readEnd = lastReadEnd else { return 0 }
        var cursor = readEnd + 1
        var bytes: Int64 = 0
        for range in cachedRangesLocked() {
            if range.upperBound < cursor { continue }
            if range.lowerBound > cursor { break }
            let lower = max(cursor, range.lowerBound)
            bytes += range.upperBound - lower + 1
            cursor = range.upperBound + 1
        }
        return bytes
    }

    private func cachedRangesLocked() -> [ClosedRange<Int64>] {
        (spans.map(\.range) + diskSpans.map(\.range)).sorted { $0.lowerBound < $1.lowerBound }
    }

    private func rangesOverlap(_ a: ClosedRange<Int64>, _ b: ClosedRange<Int64>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }
}

private struct PlaybackSourceRangeRequest {
    enum Kind {
        case full
        case exact(ClosedRange<Int64>)
        case openEnded(start: Int64)
        case suffix(length: Int64)
    }

    let kind: Kind

    var start: Int64 {
        switch kind {
        case .full:
            return 0
        case .exact(let range):
            return range.lowerBound
        case .openEnded(let start):
            return start
        case .suffix:
            return 0
        }
    }

    var finiteEnd: Int64? {
        switch kind {
        case .full, .openEnded, .suffix:
            return nil
        case .exact(let range):
            return range.upperBound
        }
    }

    static func parse(_ raw: String?) -> PlaybackSourceRangeRequest {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.hasPrefix("bytes=") else {
            return PlaybackSourceRangeRequest(kind: .full)
        }
        let value = raw.dropFirst("bytes=".count)
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return PlaybackSourceRangeRequest(kind: .full) }
        if parts[0].isEmpty {
            let length = Int64(parts[1]) ?? 0
            return PlaybackSourceRangeRequest(kind: .suffix(length: max(0, length)))
        }
        guard let start = Int64(parts[0]), start >= 0 else {
            return PlaybackSourceRangeRequest(kind: .full)
        }
        if parts[1].isEmpty {
            return PlaybackSourceRangeRequest(kind: .openEnded(start: start))
        }
        guard let end = Int64(parts[1]), end >= start else {
            return PlaybackSourceRangeRequest(kind: .full)
        }
        return PlaybackSourceRangeRequest(kind: .exact(start...end))
    }
}

private final class PlaybackSourceResource {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackSourceResource"
    )

    enum WaitOutcome {
        case available
        case eof
        case failed
    }

    let token: String
    /// Origin endpoint for window/chunk fetches. Mutable for in-place session
    /// renewal (`retargetOrigin`): a renewed direct-play session serves the
    /// identical bytes under a new session URL, so the transport swaps
    /// endpoints while the cache, waiters, and local server stay put. Guarded
    /// by `stateLock`; every reader (stream/fetcher construction) already
    /// runs under it.
    private var originURL: URL
    private var originHeaders: [String: String]
    let cache: PlaybackSourceCache
    private let onPlaybackSessionMissing: (() -> Void)?
    private let onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)?
    /// Fired on outage entry (true) and recovery (false). Entry means the
    /// reconnect ladder gave up on a retryable cause and the blocked byte
    /// demands are parked; the transport keeps re-probing quietly while the
    /// player rides its buffered runway.
    private let onOriginOutageChanged: ((Bool) -> Void)?
    private let outageRideThroughEnabled: Bool
    private let resumeCapable: Bool
    private let serverAdvertisesDirectStreamResume: Bool
    private let originStreamClock: PlaybackOriginStreamClock
    private let stateLock = NSLock()
    private var cancelled = false
    /// A validator proved that the origin now refers to a different entity.
    /// Once set, this resource must neither fetch nor serve another byte from
    /// the cache while the view model tears down and replans playback.
    private var sourceEntityInvalidated = false
    /// Strong validator captured from the window's first accepted response.
    /// Resume-capable chunk requests use the same validator so random-access
    /// reads cannot race replacement detection and contaminate the cache.
    private var sourceEntityETag: String?
    /// Origin outage ride-through state (all under `stateLock`): parked
    /// demands stay registered in `dataWaiters`, `outageProbeTask` drives the
    /// slow re-probe cadence, and `sessionMissingObserved` widens parking to
    /// the session-missing 404 whose background renewal is in flight.
    private var originOutage = false
    private var outageProbeTask: Task<Void, Never>?
    private var sessionMissingObserved = false
    private var lastOutageFailureOffset: Int64 = 0
    private var discoveredTotalLength: Int64?
    /// A successful origin response has been seen (even if it carried no
    /// total), so total-length waiters need not block on the next one.
    private var sawOriginResponse = false
    /// The single streaming window connection (AetherEngine model): serves
    /// the sequential playback read, re-anchored only when the consumer
    /// itself moves. Random-access misses go to `chunkFetcher` instead.
    private var windowStream: PlaybackOriginStream?
    private var chunkFetcher: PlaybackOriginChunkFetcher?
    private var demandCounter: UInt64 = 0
    private var dataWaiters: [UUID: (offset: Int64, continuation: CheckedContinuation<WaitOutcome, Never>)] = [:]
    private var totalWaiters: [UUID: CheckedContinuation<Int64?, Never>] = [:]
    /// Detached serve tasks hold strong `self` for their whole body, so an
    /// await that outlives the session (a send parked on TCP backpressure,
    /// a fetch racing session invalidation) kept the resource — and its
    /// cache budget — alive forever. `stop()` cancels every tracked task;
    /// `send` cancels its connection on task cancellation so the parked
    /// completion fires. Guarded by `stateLock`.
    private var serveTasks: [UUID: Task<Void, Never>] = [:]
    private var completedServeTaskIDs: Set<UUID> = []
    /// Serve connections currently inside their response loop, keyed by the
    /// same id as `serveTasks`. Inserted before the task body can run so
    /// window-claim arbitration always sees a live claimant.
    private var activeServeIDs: Set<UUID> = []
    /// The serve connection that last re-anchored (or spawned) the streaming
    /// window. While it is alive, other serve connections' qualified misses
    /// are served by chunks instead of stealing the window
    /// (`PlaybackWindowClaimPolicy`) — the fix for the 2026-07 tvOS
    /// cancellation/range-request storm.
    private var windowOwnerServeID: UUID?

    init(
        originURL: URL,
        originHeaders: [String: String],
        cache: PlaybackSourceCache,
        onPlaybackSessionMissing: (() -> Void)?,
        onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)?,
        onOriginOutageChanged: ((Bool) -> Void)? = nil,
        outageRideThroughEnabled: Bool = PlaybackOriginOutagePolicy.rideThroughEnabled(),
        resumeCapable: Bool,
        serverAdvertisesDirectStreamResume: Bool,
        originStreamClock: PlaybackOriginStreamClock
    ) {
        self.token = Self.makeToken()
        self.originURL = originURL
        self.originHeaders = originHeaders
        self.cache = cache
        self.onPlaybackSessionMissing = onPlaybackSessionMissing
        self.onPlaybackSourceInterrupted = onPlaybackSourceInterrupted
        self.onOriginOutageChanged = onOriginOutageChanged
        self.outageRideThroughEnabled = outageRideThroughEnabled
        self.resumeCapable = resumeCapable
        self.serverAdvertisesDirectStreamResume = serverAdvertisesDirectStreamResume
        self.originStreamClock = originStreamClock
    }

    deinit {
        print("[CMP-LIFE] deinit PlaybackSourceResource")
        stop()
    }

    func stop() {
        stateLock.lock()
        cancelled = true
        originOutage = false
        let probeToCancel = outageProbeTask
        outageProbeTask = nil
        let windowToCancel = windowStream
        windowStream = nil
        let fetcherToCancel = chunkFetcher
        chunkFetcher = nil
        let dataResume = dataWaiters.values.map(\.continuation)
        dataWaiters.removeAll()
        let totalResume = Array(totalWaiters.values)
        totalWaiters.removeAll()
        let serving = serveTasks
        serveTasks.removeAll()
        completedServeTaskIDs.removeAll()
        stateLock.unlock()
        probeToCancel?.cancel()
        if let windowToCancel {
            windowToCancel.cancel()
            cache.endOriginRequest()
        }
        fetcherToCancel?.cancel()
        for continuation in totalResume {
            continuation.resume(returning: nil)
        }
        for continuation in dataResume {
            continuation.resume(returning: .failed)
        }
        for (_, serveTask) in serving {
            serveTask.cancel()
        }
    }

    /// Swap the origin endpoint in place (silent session renewal): the
    /// current window and chunk fetcher hold the dead session's URL and are
    /// cancelled; parked data waiters are re-driven so each re-misses and
    /// re-routes through the normal machinery (window claim or chunk)
    /// against the new origin. The cache, serve connections, and local URL
    /// are untouched — the renewed session must serve the identical bytes.
    func retargetOrigin(url: URL, headers: [String: String]) {
        var windowToCancel: PlaybackOriginStream?
        var fetcherToCancel: PlaybackOriginChunkFetcher?
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        originURL = url
        originHeaders = headers
        windowToCancel = windowStream
        windowStream = nil
        fetcherToCancel = chunkFetcher
        chunkFetcher = nil
        // A renewed session resolves any outage the dead session caused;
        // the redrive below re-routes every parked demand at the new origin.
        let outageCleared = originOutage
        originOutage = false
        sessionMissingObserved = false
        let probeToCancel = outageProbeTask
        outageProbeTask = nil
        stateLock.unlock()
        probeToCancel?.cancel()
        if let windowToCancel {
            windowToCancel.cancel()
            cache.endOriginRequest()
        }
        fetcherToCancel?.cancel()
        redriveAllDataWaiters()
        if outageCleared {
            onOriginOutageChanged?(false)
        }
        Self.logger.info("[CMP-SOURCE-CACHE] origin retargeted for renewed session")
    }

    /// Whether the transport is parked in an origin outage. Read by the
    /// writer's interrupt-callback deadline to allow a blocking source read
    /// to park instead of timing out at the normal read allowance.
    var isOriginOutageActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return originOutage
    }

    /// Re-probe the origin immediately (cancels the pending cadence probe).
    /// The view model nudges this when its server-health poll sees the
    /// server come back, so recovery isn't gated on the probe cadence.
    func reprobeOrigin() {
        var toStart: PlaybackOriginStream?
        var probeToCancel: Task<Void, Never>?
        stateLock.lock()
        guard !cancelled,
              !sourceEntityInvalidated,
              originOutage,
              windowStream == nil else {
            stateLock.unlock()
            return
        }
        probeToCancel = outageProbeTask
        outageProbeTask = nil
        demandCounter += 1
        let parkedDemand = dataWaiters.values.map(\.offset).min() ?? lastOutageFailureOffset
        let offset = cache.nextPrefetchStart(after: max(0, parkedDemand)) ?? max(0, parkedDemand)
        let stream = makeStream(startOffset: offset, order: demandCounter)
        windowStream = stream
        cache.beginOriginRequest()
        toStart = stream
        stateLock.unlock()
        probeToCancel?.cancel()
        Self.logger.info("[CMP-OUTAGE] origin re-probe at offset=\(offset, privacy: .public)")
        toStart?.start()
    }

    /// Enter (or stay in) outage ride-through after a parked give-up, and
    /// schedule the next cadence probe. Returns whether this call was the
    /// outage entry (the caller notifies outside the resource's lock).
    private func enterOutageAndScheduleProbe(failureOffset: Int64) -> Bool {
        var entered = false
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return false
        }
        entered = !originOutage
        originOutage = true
        lastOutageFailureOffset = failureOffset
        outageProbeTask?.cancel()
        outageProbeTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(PlaybackOriginOutagePolicy.probeDelaySeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.reprobeOrigin()
        }
        stateLock.unlock()
        return entered
    }

    /// A successful origin response ends the outage: resume every parked
    /// demand through the normal re-miss routing.
    private func clearOutageAfterOriginResponse() {
        stateLock.lock()
        guard originOutage, !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        originOutage = false
        sessionMissingObserved = false
        let probeToCancel = outageProbeTask
        outageProbeTask = nil
        stateLock.unlock()
        probeToCancel?.cancel()
        Self.logger.info("[CMP-OUTAGE] origin recovered; resuming parked demands")
        redriveAllDataWaiters()
        onOriginOutageChanged?(false)
    }

    private func noteSessionMissingObserved() {
        stateLock.lock()
        if !sourceEntityInvalidated {
            sessionMissingObserved = true
        }
        stateLock.unlock()
    }

    func stats() -> PlaybackSourceProxyStats {
        let snapshot = cache.stats()
        return PlaybackSourceProxyStats(
            cachedBytes: snapshot.cachedBytes,
            cacheBudgetBytes: snapshot.cacheBudgetBytes,
            highWaterBytes: snapshot.highWaterBytes,
            lowWaterBytes: snapshot.lowWaterBytes,
            forwardCachedBytes: snapshot.forwardCachedBytes,
            estimatedForwardCacheAheadSeconds: snapshot.estimatedForwardCacheAheadSeconds,
            originBytesTransferred: snapshot.originBytesTransferred,
            currentOriginBitrateBps: snapshot.currentOriginBitrateBps,
            cacheHitBytes: snapshot.cacheHitBytes,
            cacheMissBytes: snapshot.cacheMissBytes,
            activeOriginRequestCount: snapshot.activeOriginRequestCount,
            diskSpillBytes: snapshot.diskSpillBytes,
            diskBudgetBytes: snapshot.diskBudgetBytes,
            diskBytesWritten: snapshot.diskBytesWritten,
            resumeCapable: resumeCapable,
            serverAdvertisesDirectStreamResume: serverAdvertisesDirectStreamResume
        )
    }

    func originStreamDiagnostics() -> PlaybackOriginStream.DiagnosticsSnapshot? {
        stateLock.lock()
        let stream = windowStream
        stateLock.unlock()
        return stream?.diagnosticsSnapshot()
    }

    /// Births the streaming window at the initial playback offset. The
    /// window then belongs to the sequential consumer; probe misses never
    /// move it (they go to the chunk fetcher).
    func startPrefetch(at offset: Int64 = 0) {
        var toStart: PlaybackOriginStream?
        stateLock.lock()
        if !cancelled, !sourceEntityInvalidated, windowStream == nil {
            demandCounter += 1
            let stream = makeStream(startOffset: max(0, offset), order: demandCounter)
            windowStream = stream
            cache.beginOriginRequest()
            toStart = stream
        }
        stateLock.unlock()
        toStart?.start()
    }

    func setSourceBitrate(_ bps: Double?) {
        cache.setSourceBitrate(bps)
        Self.logger.info("[CMP-SOURCE-CACHE] source bitrate=\(bps ?? 0, privacy: .public)")
    }

    func handle(method: String, rangeHeader: String?, on connection: NWConnection) {
        stateLock.lock()
        let alreadyStopped = cancelled || sourceEntityInvalidated
        stateLock.unlock()
        guard !alreadyStopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        stateLock.lock()
        activeServeIDs.insert(id)
        stateLock.unlock()
        let task = Task.detached(priority: .userInitiated) { [weak self, weak connection] in
            if let self, let connection {
                if method == "HEAD" {
                    await self.respondHead(on: connection)
                } else {
                    await self.respondGet(rangeHeader: rangeHeader, on: connection, serveID: id)
                }
            }
            self?.serveTaskFinished(id)
        }
        registerServeTask(task, id: id)
    }

    /// The task starts running before registration can complete, so a
    /// fast finish parks its id in `completedServeTaskIDs` for the
    /// registration to reconcile.
    private func registerServeTask(_ task: Task<Void, Never>, id: UUID) {
        var cancelNow = false
        stateLock.lock()
        if completedServeTaskIDs.remove(id) != nil {
            // Finished before registration — nothing to track.
        } else if cancelled || sourceEntityInvalidated {
            cancelNow = true
        } else {
            serveTasks[id] = task
        }
        stateLock.unlock()
        if cancelNow {
            task.cancel()
        }
    }

    private func serveTaskFinished(_ id: UUID) {
        stateLock.lock()
        activeServeIDs.remove(id)
        if windowOwnerServeID == id {
            windowOwnerServeID = nil
        }
        if serveTasks.removeValue(forKey: id) == nil,
           !cancelled,
           !sourceEntityInvalidated {
            completedServeTaskIDs.insert(id)
        }
        stateLock.unlock()
    }

    private func respondHead(on connection: NWConnection) async {
        let total = await awaitTotalLength(hint: 0)
        var header = "HTTP/1.1 200 OK\r\n"
        if let total {
            header += "Content-Length: \(total)\r\n"
        }
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        _ = await send(Data(header.utf8), on: connection, close: true)
    }

    private func respondGet(
        rangeHeader: String?,
        on connection: NWConnection,
        serveID: UUID
    ) async {
        let request = PlaybackSourceRangeRequest.parse(rangeHeader)
        let total = await awaitTotalLength(hint: request.start)
        let resolved = resolveRequest(request, totalLength: total)
        var responseStatus = rangeHeader == nil ? 200 : 206
        let responseEnd = resolved.end
        if responseStatus == 206, total == nil, responseEnd == nil {
            if resolved.start == 0 {
                // No total and no finite end: nothing valid to put in a
                // Content-Range, but a head-anchored range can be answered
                // as a plain 200 (a server may always ignore Range).
                responseStatus = 200
            } else {
                // Mid-file open-ended range against an origin that never
                // reported a total: no valid 206 exists (Content-Range
                // requires a last-byte-pos). Fail honestly instead of
                // emitting a 206 the demuxer cannot size.
                print("[CMP-SRV] get exit reason=no_total_for_range start=\(resolved.start)")
                let refusal = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = await send(Data(refusal.utf8), on: connection, close: true)
                return
            }
        }

        var header = "HTTP/1.1 \(responseStatus) \(HTTPURLResponse.localizedString(forStatusCode: responseStatus))\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        if let total, responseStatus == 206 {
            let endLabel = responseEnd ?? (total - 1)
            header += "Content-Range: bytes \(resolved.start)-\(endLabel)/\(total)\r\n"
            header += "Content-Length: \(max(0, endLabel - resolved.start + 1))\r\n"
        } else if let responseEnd, responseStatus == 206 {
            // Total still unknown: an exact range can carry the RFC 9110
            // unknown-complete-length form so the response stays sizeable.
            header += "Content-Range: bytes \(resolved.start)-\(responseEnd)/*\r\n"
            header += "Content-Length: \(max(0, responseEnd - resolved.start + 1))\r\n"
        } else if let total, responseStatus == 200 {
            header += "Content-Length: \(max(0, total - resolved.start))\r\n"
        }
        header += "Connection: close\r\n\r\n"
        print("[CMP-SRV] get start=\(resolved.start) end=\(resolved.end.map(String.init) ?? "-")")
        guard await send(Data(header.utf8), on: connection, close: false) else {
            print("[CMP-SRV] get exit reason=header_send_failed")
            return
        }

        var cursor = resolved.start
        var sawEmptyFetch = false
        var sawFetchError = false
        while !Task.isCancelled {
            if let responseEnd, cursor > responseEnd { break }
            if let total, cursor >= total { break }
            let sendLength = responseEnd.map { Int(min(Int64(256 * 1024), $0 - cursor + 1)) } ?? 256 * 1024
            if let cached = cache.read(start: cursor, maxLength: max(1, sendLength)) {
                guard await send(cached, on: connection, close: false) else {
                    print("[CMP-SRV] get exit reason=send_failed cursor=\(cursor)")
                    return
                }
                cursor += Int64(cached.count)
                noteDemandHint(at: cursor)
                continue
            }
            cache.recordCacheMiss(byteCount: Int64(max(1, sendLength)))
            switch await awaitData(
                at: cursor,
                servedSequentialBytes: cursor - resolved.start,
                serveID: serveID
            ) {
            case .available:
                continue
            case .eof:
                sawEmptyFetch = true
            case .failed:
                sawFetchError = true
            }
            break
        }
        let knownTotal = currentTotalLength() ?? total
        let endCause = PlaybackSourceResponseEnd.classify(
            cursor: cursor,
            responseEnd: responseEnd,
            totalLength: knownTotal,
            wasCancelled: Task.isCancelled,
            sawEmptyFetch: sawEmptyFetch,
            sawFetchError: sawFetchError
        )
        if case let .prematureEOF(offset, expectedEnd) = endCause {
            let totalLabel = knownTotal.map(String.init) ?? "unknown"
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] premature eof offset=\(offset, privacy: .public) expectedEnd=\(expectedEnd, privacy: .public) total=\(totalLabel, privacy: .public)"
            )
            onPlaybackSourceInterrupted?(.prematureEOF(offset: offset, expectedEnd: expectedEnd))
        }
        noteDemandHint(at: cursor)
        print("[CMP-SRV] get exit reason=\(endCause) cursor=\(cursor)")
        _ = await send(nil, on: connection, close: true)
    }

    private func resolveRequest(
        _ request: PlaybackSourceRangeRequest,
        totalLength: Int64?
    ) -> (start: Int64, end: Int64?) {
        switch request.kind {
        case .full:
            return (0, totalLength.map { max(0, $0 - 1) })
        case .exact(let range):
            return (range.lowerBound, range.upperBound)
        case .openEnded(let start):
            return (start, totalLength.map { max(start, $0 - 1) })
        case .suffix(let length):
            guard let totalLength, length > 0 else { return (0, nil) }
            let start = max(0, totalLength - length)
            return (start, max(start, totalLength - 1))
        }
    }

    // MARK: - Origin stream orchestration

    private func currentTotalLength() -> Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return discoveredTotalLength
    }

    private func currentState() -> (
        cancelled: Bool,
        sourceEntityInvalidated: Bool,
        total: Int64?,
        sawResponse: Bool
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (
            cancelled: cancelled,
            sourceEntityInvalidated: sourceEntityInvalidated,
            total: discoveredTotalLength,
            sawResponse: sawOriginResponse
        )
    }

    /// Route a byte demand that MISSED the cache: ride the streaming window
    /// when the miss is just ahead of its cursor, re-anchor the window when
    /// the sequential consumer itself moved (a seek — the serving connection
    /// has already streamed enough to prove it is the playback reader), or
    /// fetch a discrete chunk for everything else so probes never disturb
    /// the warm window connection.
    private func routeMiss(
        for offset: Int64,
        servedSequentialBytes: Int64,
        serveID: UUID? = nil
    ) {
        var toStart: PlaybackOriginStream?
        var toNote: PlaybackOriginStream?
        var toRetarget: PlaybackOriginStream?
        var chunk = false
        var deferChunkUntilEntityKnown = false
        var order: UInt64 = 0
        var total: Int64?
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        total = discoveredTotalLength
        if let total, offset >= total {
            stateLock.unlock()
            return
        }
        demandCounter += 1
        order = demandCounter
        let cursor = windowStream?.snapshot().writeCursor
        switch PlaybackOriginRoutingPolicy.route(
            demandOffset: offset,
            windowCursor: cursor,
            servedSequentialBytes: servedSequentialBytes
        ) {
        case .rideWindow:
            toNote = windowStream
        case .claimWindow:
            let ownerIsAlive = windowOwnerServeID.map { activeServeIDs.contains($0) } ?? false
            switch PlaybackWindowClaimPolicy.arbitrate(
                claimant: serveID,
                owner: windowOwnerServeID,
                ownerIsAlive: ownerIsAlive
            ) {
            case .retarget:
                windowOwnerServeID = serveID
                if let window = windowStream {
                    toRetarget = window
                } else {
                    let stream = makeStream(startOffset: offset, order: order)
                    windowStream = stream
                    // Pair the gauge while still holding the lock: stop()
                    // snapshots the window and ends its request, so begin must
                    // not trail publication or a racing stop leaves the count
                    // stranded.
                    cache.beginOriginRequest()
                    toStart = stream
                }
            case .chunk:
                Self.logger.info(
                    "[CMP-SOURCE-CACHE] window claim contested offset=\(offset, privacy: .public) served=\(servedSequentialBytes, privacy: .public) routed=chunk"
                )
                chunk = true
                deferChunkUntilEntityKnown = resumeCapable && sourceEntityETag == nil
            }
        case .chunk:
            chunk = true
            // A resume-capable chunk must be bound to the streaming
            // window's representation. If a startup probe wins the race
            // with the window response, leave its registered data waiter
            // parked instead of spending the chunk's short retry budget on
            // requests that cannot yet carry If-Range. The first window
            // response with a strong validator re-drives all waiting
            // demands below.
            deferChunkUntilEntityKnown = resumeCapable && sourceEntityETag == nil
        }
        stateLock.unlock()
        toNote?.noteDemand(offset: offset, order: order)
        toStart?.start()
        if chunk && !deferChunkUntilEntityKnown {
            ensureChunkFetcher().ensureFetch(covering: offset, totalLength: total)
        }
        if let toRetarget {
            if toRetarget.retarget(to: offset, order: order) {
                // The window may have carried waiters for its old region;
                // nothing fills toward them anymore. Re-drive every waiter
                // so each re-misses and re-routes (to chunks) against the
                // new layout.
                redriveAllDataWaiters()
            } else {
                // The window finished or gave up between the snapshot and
                // the retarget; replace it with a fresh one.
                replaceDeadWindow(toRetarget, spawningAt: offset, order: order)
            }
        }
    }

    private func ensureChunkFetcher() -> PlaybackOriginChunkFetcher {
        stateLock.lock()
        if let chunkFetcher {
            stateLock.unlock()
            return chunkFetcher
        }
        let alreadyStopped = cancelled || sourceEntityInvalidated
        let fetcher = PlaybackOriginChunkFetcher(
            originURL: originURL,
            originHeaders: originHeaders,
            entityETagProvider: { [weak self] in
                self?.currentChunkEntityETag()
            },
            requiresEntityValidation: resumeCapable,
            callbacks: PlaybackOriginChunkFetcher.Callbacks(
                store: { [weak self] start, data, total, responseETag in
                    guard let self else { return .network }
                    return self.storeChunkOriginData(
                        start: start,
                        data: data,
                        total: total,
                        responseETag: responseETag
                    )
                },
                didStore: { [weak self] range in
                    self?.streamDidStore(range)
                },
                didReceiveResponse: { [weak self] total in
                    self?.streamReceivedResponse(total: total)
                },
                didDetectSessionMissing: { [weak self] in
                    self?.noteSessionMissingObserved()
                    self?.onPlaybackSessionMissing?()
                },
                didFail: { [weak self] range, cause, statusCode in
                    self?.chunkFailed(range: range, cause: cause, statusCode: statusCode)
                },
                beginRequest: { [weak self] in
                    self?.cache.beginOriginRequest()
                },
                endRequest: { [weak self] in
                    self?.cache.endOriginRequest()
                }
            )
        )
        if alreadyStopped {
            // A stop raced this creation; hand back a pre-cancelled fetcher
            // whose ensureFetch is a no-op instead of a zombie that stop()
            // can no longer reach.
            stateLock.unlock()
            fetcher.cancel()
            return fetcher
        }
        chunkFetcher = fetcher
        stateLock.unlock()
        return fetcher
    }

    private func currentChunkEntityETag() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resumeCapable ? sourceEntityETag : nil
    }

    /// A chunk and the window can complete on different URLSession queues.
    /// Bind the chunk to the window's established representation and store
    /// under one lock so neither can race replacement bytes into the cache.
    private func storeChunkOriginData(
        start: Int64,
        data: Data,
        total: Int64?,
        responseETag: String?
    ) -> PlaybackOriginReconnectPolicy.EndCause? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled, !sourceEntityInvalidated else {
            return .network
        }
        if resumeCapable {
            guard sawOriginResponse else {
                return .rangeIgnored
            }
            guard let sourceEntityETag, let responseETag else {
                return .rangeIgnored
            }
            guard responseETag == sourceEntityETag else {
                return .entityChanged
            }
        }
        cache.recordOriginTransfer(byteCount: data.count)
        cache.store(start: start, data: data, totalLength: total)
        return nil
    }

    private func redriveAllDataWaiters() {
        stateLock.lock()
        let resume = dataWaiters.values.map(\.continuation)
        dataWaiters.removeAll()
        stateLock.unlock()
        for continuation in resume {
            continuation.resume(returning: .available)
        }
    }

    private func replaceDeadWindow(
        _ dead: PlaybackOriginStream,
        spawningAt offset: Int64,
        order: UInt64
    ) {
        var toStart: PlaybackOriginStream?
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        if windowStream === dead {
            windowStream = nil
            cache.endOriginRequest()
        }
        if windowStream == nil {
            let stream = makeStream(startOffset: offset, order: order)
            windowStream = stream
            cache.beginOriginRequest()
            toStart = stream
        }
        stateLock.unlock()
        toStart?.start()
    }

    /// Record demand served from cache: refreshes the window's demand mark
    /// (which keeps it filling and unparks it when the budget frees) but
    /// never spawns or retargets — cached reads must not steer connections
    /// toward data we already have.
    private func noteDemandHint(at offset: Int64) {
        var toNote: PlaybackOriginStream?
        var toNudge: PlaybackOriginStream?
        var order: UInt64 = 0
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        demandCounter += 1
        order = demandCounter
        if let window = windowStream {
            let snapshot = window.snapshot()
            if offset >= snapshot.startOffset,
               offset <= snapshot.writeCursor + PlaybackOriginRoutingPolicy.rideThroughBytes {
                toNote = window
            } else {
                // The read is outside the window's region (e.g. the window
                // was re-anchored ahead by a seek while this consumer still
                // drains behind it). Its consumption still frees the global
                // budget, so a parked/detached window must re-check the
                // low-water re-arm here — a cache miss when playback is
                // already starved must not be the only wake-up.
                toNudge = window
            }
        }
        stateLock.unlock()
        toNote?.noteDemand(offset: offset, order: order)
        toNudge?.resumeFillingIfNeeded()
    }

    /// Suspend the serve loop until the byte at `offset` is cached, the file
    /// ends before it, or the responsible fetch gives up.
    /// `servedSequentialBytes` is how much this serve connection has already
    /// delivered sequentially — the signal that separates the playback
    /// reader (which may re-anchor the window) from short-lived probes.
    private func awaitData(
        at offset: Int64,
        servedSequentialBytes: Int64,
        serveID: UUID? = nil
    ) async -> WaitOutcome {
        let state = currentState()
        if state.cancelled || state.sourceEntityInvalidated { return .failed }
        if let total = state.total, offset >= total { return .eof }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitOutcome, Never>) in
                stateLock.lock()
                if cancelled || sourceEntityInvalidated {
                    stateLock.unlock()
                    continuation.resume(returning: .failed)
                    return
                }
                dataWaiters[id] = (offset, continuation)
                stateLock.unlock()
                // Route the demand only after the waiter is registered, so a
                // fetch give-up can never fire between routing and
                // registration and leave this waiter stranded.
                routeMiss(
                    for: offset,
                    servedSequentialBytes: servedSequentialBytes,
                    serveID: serveID
                )
                // The bytes may also have landed between the cache miss and
                // the registration above; re-check so the waiter can't sleep
                // through its own wake-up.
                if cache.contains(offset: offset) {
                    resumeDataWaiter(id: id, outcome: .available)
                } else if let total = currentTotalLength(), offset >= total {
                    resumeDataWaiter(id: id, outcome: .eof)
                }
            }
        } onCancel: {
            resumeDataWaiter(id: id, outcome: .failed)
        }
    }

    private func resumeDataWaiter(id: UUID, outcome: WaitOutcome) {
        stateLock.lock()
        let waiter = dataWaiters.removeValue(forKey: id)
        stateLock.unlock()
        waiter?.continuation.resume(returning: outcome)
    }

    /// Total length comes from the first successful origin response
    /// (Content-Range / Content-Length) — no dedicated probe round trip.
    private func awaitTotalLength(hint: Int64) async -> Int64? {
        let state = currentState()
        if let known = state.total { return known }
        if state.sawResponse || state.cancelled || state.sourceEntityInvalidated { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int64?, Never>) in
                stateLock.lock()
                if cancelled
                    || sourceEntityInvalidated
                    || sawOriginResponse
                    || discoveredTotalLength != nil {
                    let value = discoveredTotalLength
                    stateLock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                totalWaiters[id] = continuation
                stateLock.unlock()
                // Register first, then route: if the routed fetch gives up
                // instantly, its drain finds this waiter instead of missing
                // it (the drain resolves total waiters on any give-up).
                routeMiss(for: max(0, hint), servedSequentialBytes: 0)
            }
        } onCancel: {
            resumeTotalWaiter(id: id)
        }
    }

    private func resumeTotalWaiter(id: UUID) {
        stateLock.lock()
        let waiter = totalWaiters.removeValue(forKey: id)
        let value = discoveredTotalLength
        stateLock.unlock()
        waiter?.resume(returning: value)
    }

    /// Serialize cache writes with entity invalidation. A chunk completion can
    /// race the window's validator failure on a different URLSession queue;
    /// holding `stateLock` through the cache write guarantees that once the
    /// invalidation flag is visible, no replacement bytes can be appended.
    private func storeOriginData(start: Int64, data: Data, total: Int64?) {
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        cache.recordOriginTransfer(byteCount: data.count)
        cache.store(start: start, data: data, totalLength: total)
        stateLock.unlock()
    }

    private func makeStream(startOffset: Int64, order: UInt64) -> PlaybackOriginStream {
        PlaybackOriginStream(
            originURL: originURL,
            originHeaders: originHeaders,
            startOffset: startOffset,
            demandOrder: order,
            callbacks: PlaybackOriginStream.Callbacks(
                didStore: { [weak self] _, range in
                    self?.streamDidStore(range)
                },
                didReceiveResponse: { [weak self] _, total, entityETag in
                    self?.streamReceivedResponse(total: total, entityETag: entityETag)
                },
                didDetectSessionMissing: { [weak self] _ in
                    self?.noteSessionMissingObserved()
                    self?.onPlaybackSessionMissing?()
                },
                didFinish: { [weak self] stream in
                    self?.streamEnded(stream, gaveUpWith: nil, statusCode: nil)
                },
                didGiveUp: { [weak self] stream, cause, statusCode in
                    self?.streamEnded(stream, gaveUpWith: cause, statusCode: statusCode)
                },
                mayContinueFilling: { [weak self] stream, cursor, demandMark in
                    self?.mayContinueFilling(stream, cursor: cursor, demandMark: demandMark) ?? false
                },
                cachedAheadBytes: { [weak self] in
                    self?.cache.forwardCachedByteCount() ?? 0
                },
                nextMissingByte: { [weak self] cursor in
                    self?.cache.nextPrefetchStart(after: cursor)
                },
                store: { [weak self] start, data, total in
                    self?.storeOriginData(start: start, data: data, total: total)
                }
            ),
            resumeCapable: resumeCapable,
            initialEntityETag: resumeCapable ? sourceEntityETag : nil,
            initialResponseRequiresEntityValidation: resumeCapable && sawOriginResponse,
            clock: originStreamClock,
            detachGraceSecondsProvider: { [weak cache] in
                guard let cache else {
                    return PlaybackOriginStreamPolicy.detachAfterSeconds
                }
                return PlaybackOriginStreamPolicy.detachGraceSeconds(
                    hysteresisGapBytes: cache.hysteresisGapBytes,
                    sourceBitrateBps: cache.currentSourceBitrateBps()
                )
            }
        )
    }

    private func streamDidStore(_ range: ClosedRange<Int64>) {
        var resume: [CheckedContinuation<WaitOutcome, Never>] = []
        stateLock.lock()
        guard !sourceEntityInvalidated, !dataWaiters.isEmpty else {
            stateLock.unlock()
            return
        }
        let satisfied = dataWaiters.filter {
            $0.value.offset >= range.lowerBound && $0.value.offset <= range.upperBound
        }.map(\.key)
        for id in satisfied {
            if let waiter = dataWaiters.removeValue(forKey: id) {
                resume.append(waiter.continuation)
            }
        }
        stateLock.unlock()
        for continuation in resume {
            continuation.resume(returning: .available)
        }
    }

    private func streamReceivedResponse(total: Int64?, entityETag: String? = nil) {
        var resume: [CheckedContinuation<Int64?, Never>] = []
        var shouldRedriveDataWaiters = false
        stateLock.lock()
        guard !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        shouldRedriveDataWaiters = resumeCapable
            && sourceEntityETag == nil
            && entityETag != nil
        sawOriginResponse = true
        if sourceEntityETag == nil {
            sourceEntityETag = entityETag
        }
        if let total, total > 0 {
            discoveredTotalLength = max(discoveredTotalLength ?? 0, total)
        }
        let value = discoveredTotalLength
        resume = Array(totalWaiters.values)
        totalWaiters.removeAll()
        stateLock.unlock()
        cache.setTotalLength(value)
        for continuation in resume {
            continuation.resume(returning: value)
        }
        if shouldRedriveDataWaiters {
            redriveAllDataWaiters()
        }
        clearOutageAfterOriginResponse()
    }

    /// Entity identity is global to the resource, not to one transport. Either
    /// the streaming window or a random-access chunk can detect replacement;
    /// the first detector atomically closes every fetch/serve path and fails
    /// all waiters before escalating recovery.
    private func invalidateSourceEntity(statusCode: Int?, failureOffset: Int64) {
        var windowToCancel: PlaybackOriginStream?
        var fetcherToCancel: PlaybackOriginChunkFetcher?
        var probeToCancel: Task<Void, Never>?
        var serveTasksToCancel: [Task<Void, Never>] = []
        var dataResume: [CheckedContinuation<WaitOutcome, Never>] = []
        var totalResume: [CheckedContinuation<Int64?, Never>] = []
        var total: Int64?
        var outageWasActive = false

        stateLock.lock()
        guard !sourceEntityInvalidated else {
            stateLock.unlock()
            return
        }
        sourceEntityInvalidated = true
        outageWasActive = originOutage
        originOutage = false
        sessionMissingObserved = false
        probeToCancel = outageProbeTask
        outageProbeTask = nil
        windowToCancel = windowStream
        windowStream = nil
        fetcherToCancel = chunkFetcher
        chunkFetcher = nil
        serveTasksToCancel = Array(serveTasks.values)
        dataResume = dataWaiters.values.map(\.continuation)
        dataWaiters.removeAll()
        totalResume = Array(totalWaiters.values)
        totalWaiters.removeAll()
        total = discoveredTotalLength
        stateLock.unlock()

        probeToCancel?.cancel()
        if let windowToCancel {
            windowToCancel.cancel()
            cache.endOriginRequest()
        }
        fetcherToCancel?.cancel()
        for task in serveTasksToCancel {
            task.cancel()
        }
        for continuation in totalResume {
            continuation.resume(returning: total)
        }
        for continuation in dataResume {
            continuation.resume(returning: .failed)
        }
        if outageWasActive {
            onOriginOutageChanged?(false)
        }
        escalateInterruption(
            cause: .entityChanged,
            statusCode: statusCode,
            failureOffset: failureOffset
        )
    }

    /// The window stream ended. A clean finish (EOF, or everything to EOF
    /// already cached) re-drives waiters — data may satisfy them or their
    /// re-miss routes to a chunk. A give-up fails the waiters the window was
    /// responsible for (those an in-flight chunk will not deliver) and
    /// surfaces the interruption exactly once.
    private func streamEnded(
        _ stream: PlaybackOriginStream,
        gaveUpWith cause: PlaybackOriginReconnectPolicy.EndCause?,
        statusCode: Int?
    ) {
        if cause == .entityChanged {
            invalidateSourceEntity(
                statusCode: statusCode,
                failureOffset: stream.snapshot().writeCursor
            )
            return
        }
        var redrive: [CheckedContinuation<WaitOutcome, Never>] = []
        var failed: [CheckedContinuation<WaitOutcome, Never>] = []
        var totalResume: [CheckedContinuation<Int64?, Never>] = []
        var park = false
        stateLock.lock()
        if let cause {
            park = PlaybackOriginOutagePolicy.shouldPark(
                cause: cause,
                sessionMissingObserved: sessionMissingObserved,
                rideThroughEnabled: outageRideThroughEnabled
            )
        }
        let wasTracked = windowStream === stream
        if wasTracked {
            windowStream = nil
        }
        // Safe lock nesting: the fetcher never calls back into the resource
        // while holding its own lock, so stateLock → fetcher.lock is the
        // only order that ever occurs.
        let fetcher = chunkFetcher
        for (id, waiter) in dataWaiters {
            if cause == nil || fetcher?.coversInFlight(offset: waiter.offset) == true {
                redrive.append(waiter.continuation)
                dataWaiters.removeValue(forKey: id)
            } else if park {
                // Outage ride-through: the demand stays registered and parked;
                // outage recovery (probe success, retarget, or stop) resumes it.
            } else {
                failed.append(waiter.continuation)
                dataWaiters.removeValue(forKey: id)
            }
        }
        if cause != nil {
            totalResume = Array(totalWaiters.values)
            totalWaiters.removeAll()
        }
        let total = discoveredTotalLength
        stateLock.unlock()
        if wasTracked {
            cache.endOriginRequest()
        }
        for continuation in totalResume {
            continuation.resume(returning: total)
        }
        for continuation in redrive {
            continuation.resume(returning: .available)
        }
        for continuation in failed {
            continuation.resume(returning: .failed)
        }
        guard let cause else { return }
        if park {
            let entered = enterOutageAndScheduleProbe(failureOffset: stream.snapshot().writeCursor)
            Self.logger.warning(
                "[CMP-OUTAGE] window gave up cause=\(String(describing: cause), privacy: .public) status=\(statusCode ?? 0, privacy: .public); parked entry=\(entered, privacy: .public)"
            )
            if entered {
                onOriginOutageChanged?(true)
            }
            return
        }
        // Surface the interruption only when the give-up actually failed a
        // foreground waiter. The window dying while playback rides the
        // forward cache must stay silent — the next cache miss routes to a
        // chunk (or re-claims a fresh window), and if that also gives up its
        // waiter fails and escalates.
        guard !failed.isEmpty else {
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] window origin stream gave up cause=\(String(describing: cause), privacy: .public) status=\(statusCode ?? 0, privacy: .public); no foreground waiter affected"
            )
            return
        }
        escalateInterruption(cause: cause, statusCode: statusCode, failureOffset: stream.snapshot().writeCursor)
    }

    /// A chunk fetch failed terminally: fail the waiters inside its range
    /// (nothing else will deliver those bytes), resolve total waiters, and
    /// surface the interruption when a foreground waiter was affected.
    private func chunkFailed(
        range: Range<Int64>,
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?
    ) {
        if cause == .entityChanged {
            invalidateSourceEntity(
                statusCode: statusCode,
                failureOffset: range.lowerBound
            )
            return
        }
        var failed: [CheckedContinuation<WaitOutcome, Never>] = []
        var totalResume: [CheckedContinuation<Int64?, Never>] = []
        stateLock.lock()
        let park = PlaybackOriginOutagePolicy.shouldPark(
            cause: cause,
            sessionMissingObserved: sessionMissingObserved,
            rideThroughEnabled: outageRideThroughEnabled
        )
        if !park {
            for (id, waiter) in dataWaiters where range.contains(waiter.offset) {
                failed.append(waiter.continuation)
                dataWaiters.removeValue(forKey: id)
            }
        }
        totalResume = Array(totalWaiters.values)
        totalWaiters.removeAll()
        let total = discoveredTotalLength
        stateLock.unlock()
        for continuation in totalResume {
            continuation.resume(returning: total)
        }
        for continuation in failed {
            continuation.resume(returning: .failed)
        }
        if park {
            let entered = enterOutageAndScheduleProbe(failureOffset: range.lowerBound)
            Self.logger.warning(
                "[CMP-OUTAGE] chunk gave up cause=\(String(describing: cause), privacy: .public) status=\(statusCode ?? 0, privacy: .public); parked entry=\(entered, privacy: .public)"
            )
            if entered {
                onOriginOutageChanged?(true)
            }
            return
        }
        guard !failed.isEmpty else {
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] chunk gave up cause=\(String(describing: cause), privacy: .public) status=\(statusCode ?? 0, privacy: .public); no foreground waiter affected"
            )
            return
        }
        escalateInterruption(cause: cause, statusCode: statusCode, failureOffset: range.lowerBound)
    }

    private func escalateInterruption(
        cause: PlaybackOriginReconnectPolicy.EndCause,
        statusCode: Int?,
        failureOffset: Int64
    ) {
        let total = currentTotalLength()
        let reason: PlaybackSourceInterruptionReason?
        switch cause {
        case .network, .stalled:
            reason = .networkUnavailable
        case .httpOutage(let code):
            reason = .serverUnavailable(statusCode: code)
        case .prematureEOF:
            if let total {
                reason = .prematureEOF(offset: failureOffset, expectedEnd: total - 1)
            } else {
                reason = nil
            }
        case .entityChanged:
            reason = .sourceEntityChanged
        case .httpFatal, .rangeIgnored:
            reason = nil
        }
        if let reason {
            Self.logger.warning(
                "[CMP-SOURCE-CACHE] origin interruption reason=\(String(describing: reason), privacy: .public) status=\(statusCode ?? 0, privacy: .public)"
            )
            onPlaybackSourceInterrupted?(reason)
        }
    }

    private func mayContinueFilling(
        _ stream: PlaybackOriginStream,
        cursor: Int64,
        demandMark: Int64
    ) -> Bool {
        stateLock.lock()
        guard !cancelled, !sourceEntityInvalidated else {
            stateLock.unlock()
            return false
        }
        stateLock.unlock()
        return !PlaybackOriginStreamPolicy.shouldPause(
            writeCursor: cursor,
            demandMark: demandMark,
            globalBudgetAvailable: cache.shouldPrefetch
        )
    }

    /// Cancellation-aware: a send parked on TCP backpressure (peer holds
    /// the socket but stops reading) withholds `contentProcessed`
    /// indefinitely; cancelling the serve task cancels the connection,
    /// which forces the pending completion to fire so the await resumes.
    private func send(_ data: Data?, on connection: NWConnection, close: Bool) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                connection.send(content: data, isComplete: close, completion: .contentProcessed { error in
                    let success = error == nil
                    if !success {
                        connection.cancel()
                    }
                    if close {
                        connection.cancel()
                    }
                    continuation.resume(returning: success)
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

final class PlaybackSourceProxy {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackSourceProxy"
    )

    private let resource: PlaybackSourceResource
    private let queue = DispatchQueue(label: "com.continuum.playback.sourceproxy", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    private var stopped = true

    init(
        originURL: URL,
        originHeaders: [String: String],
        cache: PlaybackSourceCache = PlaybackSourceCache(),
        onPlaybackSessionMissing: (() -> Void)? = nil,
        onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)? = nil,
        onOriginOutageChanged: ((Bool) -> Void)? = nil,
        outageRideThroughEnabled: Bool = PlaybackOriginOutagePolicy.rideThroughEnabled(),
        resumeCapable: Bool = false,
        serverAdvertisesDirectStreamResume: Bool = false,
        originStreamClock: PlaybackOriginStreamClock = SystemPlaybackOriginStreamClock()
    ) {
        self.resource = PlaybackSourceResource(
            originURL: originURL,
            originHeaders: originHeaders,
            cache: cache,
            onPlaybackSessionMissing: onPlaybackSessionMissing,
            onPlaybackSourceInterrupted: onPlaybackSourceInterrupted,
            onOriginOutageChanged: onOriginOutageChanged,
            outageRideThroughEnabled: outageRideThroughEnabled,
            resumeCapable: resumeCapable,
            serverAdvertisesDirectStreamResume: serverAdvertisesDirectStreamResume,
            originStreamClock: originStreamClock
        )
    }

    var localURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/source/\(resource.token)")
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        setStopped(false)
        self.listener = listener

        let port: UInt16
        do {
            port = try await withCheckedThrowingContinuation { continuation in
                let outcomeLock = NSLock()
                var completed = false
                let complete: (Result<UInt16, Error>) -> Void = { result in
                    outcomeLock.lock()
                    guard !completed else {
                        outcomeLock.unlock()
                        return
                    }
                    completed = true
                    outcomeLock.unlock()
                    continuation.resume(with: result)
                }

                queue.asyncAfter(deadline: .now() + 2) {
                    complete(.failure(URLError(.timedOut)))
                }

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            self.port = port.rawValue
                            complete(.success(port.rawValue))
                        }
                    case .failed(let error):
                        complete(.failure(error))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            self.listener = nil
            setStopped(true)
            throw error
        }

        guard !isStopped else {
            listener.cancel()
            throw URLError(.cancelled)
        }
        Self.logger.info("[CMP-SOURCE-CACHE] proxy listening on 127.0.0.1:\(port, privacy: .public)")
    }

    deinit {
        print("[CMP-LIFE] deinit PlaybackSourceProxy")
        stop()
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = connections
        connections.removeAll()
        lock.unlock()
        print("[CMP-LIFE] PlaybackSourceProxy.stop openConnections=\(open.count)")
        resource.stop()
        listener?.cancel()
        listener = nil
        for (_, connection) in open {
            connection.cancel()
        }
    }

    func stats() -> PlaybackSourceProxyStats {
        resource.stats()
    }

    func originStreamDiagnostics() -> PlaybackOriginStream.DiagnosticsSnapshot? {
        resource.originStreamDiagnostics()
    }

    func startPrefetch(at offset: Int64 = 0) {
        resource.startPrefetch(at: offset)
    }

    /// Swap the origin endpoint in place after a silent session renewal.
    /// See `PlaybackSourceResource.retargetOrigin`.
    func retargetOrigin(url: URL, headers: [String: String]) {
        resource.retargetOrigin(url: url, headers: headers)
    }

    /// The cache, exposed for handoff across proxy generations: holding it
    /// past `stop()` keeps its spans (memory and disk) alive so a
    /// same-file replacement proxy can adopt them instead of re-downloading.
    /// Dropping the last reference cleans the disk directory via deinit.
    var handoffCache: PlaybackSourceCache { resource.cache }

    /// Whether the transport is parked in an origin outage. See
    /// `PlaybackSourceResource.isOriginOutageActive`.
    var isOriginOutageActive: Bool { resource.isOriginOutageActive }

    /// Re-probe the origin immediately (view-model nudge when the server
    /// health poll sees the server return).
    func reprobeOrigin() {
        resource.reprobeOrigin()
    }

    func setSourceBitrate(_ bps: Double?) {
        resource.setSourceBitrate(bps)
    }

    private var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    private func setStopped(_ value: Bool) {
        lock.lock()
        stopped = value
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        guard !stopped else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[id] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.drop(id: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func drop(id: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()
    }

    private func receive(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let raw = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                self.handleRequest(raw, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            if buffer.count > 32 * 1024 {
                self.respondError(413, "Payload Too Large", on: connection)
                return
            }
            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func handleRequest(_ raw: String, on connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else {
            respondError(400, "Bad Request", on: connection)
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else {
            respondError(400, "Bad Request", on: connection)
            return
        }
        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            respondError(405, "Method Not Allowed", on: connection)
            return
        }
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        guard path == "/source/\(resource.token)" else {
            respondError(404, "Not Found", on: connection)
            return
        }
        let headers = parseHeaders(lines.dropFirst())
        resource.handle(method: method, rangeHeader: headers["range"], on: connection)
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private func respondError(_ code: Int, _ reason: String, on connection: NWConnection) {
        let body = Data(reason.utf8)
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
