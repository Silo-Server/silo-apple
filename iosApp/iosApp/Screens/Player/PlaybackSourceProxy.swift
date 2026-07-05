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
}

enum PlaybackSourceInterruptionReason: Equatable {
    case serverUnavailable(statusCode: Int)
    case networkUnavailable
    /// The origin stopped producing bytes before the resolved end of the
    /// response (2026-06-28 stall report §4). `offset` is the first byte the
    /// proxy could not serve; `expectedEnd` is the last byte the response
    /// promised.
    case prematureEOF(offset: Int64, expectedEnd: Int64)
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
        guard sawEmptyFetch,
              let expectedEnd = responseEnd ?? totalLength.map({ max(0, $0 - 1) }),
              cursor <= expectedEnd else {
            return .complete
        }
        return .prematureEOF(offset: cursor, expectedEnd: expectedEnd)
    }
}

final class PlaybackSourceCache {
    static var defaultMemoryBudgetBytes: Int {
        isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 128 * 1024 * 1024
    }
    static var siloLoopbackMemoryBudgetBytes: Int {
        isConstrainedMemoryDevice ? 128 * 1024 * 1024 : 256 * 1024 * 1024
    }
    static let sourceDiskSpillBudgetBytes = 512 * 1024 * 1024
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
    private var recentTransfers: [(time: Date, bytes: Int)] = []
    private var lastReadEnd: Int64?
    private var sourceBitrateBps: Double?
    private let diskSpillEnabled: Bool
    private let diskDirectory: URL?

    init(maxBytes: Int = PlaybackSourceCache.defaultMemoryBudgetBytes) {
        self.maxBytes = maxBytes
        self.highWaterBytes = maxBytes
        self.lowWaterBytes = max(0, maxBytes - 64 * 1024 * 1024)
        self.diskSpillEnabled = ProcessInfo.processInfo.environment["SILO_ENABLE_SOURCE_DISK_SPILL"] == "1"
        if diskSpillEnabled {
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
        lock.lock()
        let value: Bool
        if lastReadEnd == nil {
            value = cachedBytes < highWaterBytes
        } else {
            value = forwardCachedBytesLocked() < highWaterBytes
        }
        lock.unlock()
        return value
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
            if let diskSpan = diskSpans.first(where: { $0.start <= start && $0.end >= start }),
               let file = try? Data(contentsOf: diskSpan.url) {
                let offset = Int(start - diskSpan.start)
                let length = min(maxLength, file.count - offset)
                guard length > 0 else { return nil }
                let data = file.subdata(in: offset..<(offset + length))
                cacheHitBytes += Int64(data.count)
                lastReadEnd = max(lastReadEnd ?? 0, start + Int64(data.count) - 1)
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
            diskSpillBytes: diskSpillBytes
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

    private func spillToDiskIfEnabledLocked(_ span: Span) {
        guard diskSpillEnabled,
              let diskDirectory,
              diskSpillBytes + Int64(span.data.count) <= Int64(Self.sourceDiskSpillBudgetBytes) else {
            return
        }
        let name = "\(span.start)-\(span.end).bin"
        let url = diskDirectory.appendingPathComponent(name)
        do {
            try span.data.write(to: url, options: .atomic)
            diskSpans.append(DiskSpan(start: span.start, length: span.data.count, url: url, createdAt: Date()))
            diskSpillBytes += Int64(span.data.count)
        } catch {
            // Spill is opportunistic; active playback can always refetch.
        }
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
    let originURL: URL
    let originHeaders: [String: String]
    let cache: PlaybackSourceCache
    private let onPlaybackSessionMissing: (() -> Void)?
    private let onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)?
    private let stateLock = NSLock()
    private var cancelled = false
    private var discoveredTotalLength: Int64?
    /// A successful origin response has been seen (even if it carried no
    /// total), so total-length waiters need not block on the next one.
    private var sawOriginResponse = false
    private var streams: [PlaybackOriginStream] = []
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

    init(
        originURL: URL,
        originHeaders: [String: String],
        cache: PlaybackSourceCache,
        onPlaybackSessionMissing: (() -> Void)?,
        onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)?
    ) {
        self.token = Self.makeToken()
        self.originURL = originURL
        self.originHeaders = originHeaders
        self.cache = cache
        self.onPlaybackSessionMissing = onPlaybackSessionMissing
        self.onPlaybackSourceInterrupted = onPlaybackSourceInterrupted
    }

    deinit {
        print("[CMP-LIFE] deinit PlaybackSourceResource")
        stop()
    }

    func stop() {
        stateLock.lock()
        cancelled = true
        let streamsToCancel = streams
        streams.removeAll()
        let dataResume = dataWaiters.values.map(\.continuation)
        dataWaiters.removeAll()
        let totalResume = Array(totalWaiters.values)
        totalWaiters.removeAll()
        let serving = serveTasks
        serveTasks.removeAll()
        completedServeTaskIDs.removeAll()
        stateLock.unlock()
        for stream in streamsToCancel {
            stream.cancel()
            cache.endOriginRequest()
        }
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
            diskSpillBytes: snapshot.diskSpillBytes
        )
    }

    func startPrefetch(at offset: Int64 = 0) {
        ensureStream(for: max(0, offset))
    }

    func setSourceBitrate(_ bps: Double?) {
        cache.setSourceBitrate(bps)
        Self.logger.info("[CMP-SOURCE-CACHE] source bitrate=\(bps ?? 0, privacy: .public)")
    }

    func handle(method: String, rangeHeader: String?, on connection: NWConnection) {
        stateLock.lock()
        let alreadyStopped = cancelled
        stateLock.unlock()
        guard !alreadyStopped else {
            connection.cancel()
            return
        }
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self, weak connection] in
            if let self, let connection {
                if method == "HEAD" {
                    await self.respondHead(on: connection)
                } else {
                    await self.respondGet(rangeHeader: rangeHeader, on: connection)
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
        } else if cancelled {
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
        if serveTasks.removeValue(forKey: id) == nil, !cancelled {
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

    private func respondGet(rangeHeader: String?, on connection: NWConnection) async {
        let request = PlaybackSourceRangeRequest.parse(rangeHeader)
        let total = await awaitTotalLength(hint: request.start)
        let resolved = resolveRequest(request, totalLength: total)
        let responseStatus = rangeHeader == nil ? 200 : 206
        let responseEnd = resolved.end

        var header = "HTTP/1.1 \(responseStatus) \(HTTPURLResponse.localizedString(forStatusCode: responseStatus))\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        if let total, responseStatus == 206 {
            let endLabel = responseEnd ?? (total - 1)
            header += "Content-Range: bytes \(resolved.start)-\(endLabel)/\(total)\r\n"
            header += "Content-Length: \(max(0, endLabel - resolved.start + 1))\r\n"
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
            switch await awaitData(at: cursor) {
            case .available:
                continue
            case .eof:
                sawEmptyFetch = true
            case .failed:
                sawFetchError = true
            }
            break
        }
        // An exact range promising bytes past the real EOF (total unknown at
        // request time) must classify as complete, not premature EOF.
        let knownTotal = currentTotalLength() ?? total
        let endCause = PlaybackSourceResponseEnd.classify(
            cursor: cursor,
            responseEnd: responseEnd.map { end in knownTotal.map { min(end, $0 - 1) } ?? end },
            totalLength: knownTotal,
            wasCancelled: Task.isCancelled,
            sawEmptyFetch: sawEmptyFetch,
            sawFetchError: sawFetchError
        )
        if case let .prematureEOF(offset, expectedEnd) = endCause {
            let totalLabel = (discoveredTotalLength ?? total).map(String.init) ?? "unknown"
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

    private func currentState() -> (cancelled: Bool, total: Int64?, sawResponse: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (cancelled, discoveredTotalLength, sawOriginResponse)
    }

    /// Route a byte demand that MISSED the cache onto a stream: ride an
    /// existing one, spawn a second, or retarget the least-recently-demanded.
    private func ensureStream(for offset: Int64) {
        var toStart: PlaybackOriginStream?
        var toNote: PlaybackOriginStream?
        var toRetarget: PlaybackOriginStream?
        var order: UInt64 = 0
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        if let total = discoveredTotalLength, offset >= total {
            stateLock.unlock()
            return
        }
        demandCounter += 1
        order = demandCounter
        let live = streams
        let snapshots = live.map { $0.snapshot() }
        switch PlaybackOriginStreamPolicy.action(demandOffset: offset, streams: snapshots) {
        case .rideThrough(let id):
            toNote = live.first(where: { $0.id == id })
        case .spawn:
            let stream = makeStream(startOffset: offset, order: order)
            streams.append(stream)
            toStart = stream
        case .retarget(let id):
            toRetarget = live.first(where: { $0.id == id })
        }
        stateLock.unlock()
        toNote?.noteDemand(offset: offset, order: order)
        if let toStart {
            cache.beginOriginRequest()
            toStart.start()
        }
        if let toRetarget {
            if toRetarget.retarget(to: offset, order: order) {
                // The victim may have carried waiters for its old region;
                // nothing fills toward them anymore. Re-drive every waiter
                // so each re-misses and re-routes against the new layout.
                redriveAllDataWaiters()
            } else {
                // The victim finished or gave up between the snapshot and
                // the retarget; replace it with a fresh stream.
                replaceDeadStream(toRetarget, spawningAt: offset, order: order)
            }
        }
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

    private func replaceDeadStream(
        _ dead: PlaybackOriginStream,
        spawningAt offset: Int64,
        order: UInt64
    ) {
        var toStart: PlaybackOriginStream?
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        if streams.contains(where: { $0 === dead }) {
            streams.removeAll { $0 === dead }
            cache.endOriginRequest()
        }
        if streams.count < PlaybackOriginStreamPolicy.maxStreams {
            let stream = makeStream(startOffset: offset, order: order)
            streams.append(stream)
            toStart = stream
        }
        stateLock.unlock()
        if let toStart {
            cache.beginOriginRequest()
            toStart.start()
        } else {
            ensureStream(for: offset)
        }
    }

    /// Record demand served from cache: refreshes the covering stream's
    /// demand mark (which keeps it "primary" and unparks it when the budget
    /// frees) but never spawns or retargets — cached reads must not steer
    /// connections toward data we already have.
    private func noteDemandHint(at offset: Int64) {
        var toNote: PlaybackOriginStream?
        var order: UInt64 = 0
        stateLock.lock()
        guard !cancelled else {
            stateLock.unlock()
            return
        }
        demandCounter += 1
        order = demandCounter
        let snapshots = streams.map { $0.snapshot() }
        if let covering = PlaybackOriginStreamPolicy.coveringStream(offset: offset, streams: snapshots) {
            toNote = streams.first(where: { $0.id == covering })
        }
        stateLock.unlock()
        toNote?.noteDemand(offset: offset, order: order)
    }

    /// Suspend the serve loop until the byte at `offset` is cached, the file
    /// ends before it, or the responsible stream gives up.
    private func awaitData(at offset: Int64) async -> WaitOutcome {
        let state = currentState()
        if state.cancelled { return .failed }
        if let total = state.total, offset >= total { return .eof }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitOutcome, Never>) in
                stateLock.lock()
                if cancelled {
                    stateLock.unlock()
                    continuation.resume(returning: .failed)
                    return
                }
                dataWaiters[id] = (offset, continuation)
                stateLock.unlock()
                // Route the demand only after the waiter is registered, so a
                // stream give-up can never drain the pool between routing
                // and registration and leave this waiter stranded.
                ensureStream(for: offset)
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
        if state.sawResponse || state.cancelled { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int64?, Never>) in
                stateLock.lock()
                if cancelled || sawOriginResponse || discoveredTotalLength != nil {
                    let value = discoveredTotalLength
                    stateLock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                totalWaiters[id] = continuation
                stateLock.unlock()
                // Register first, then route: if the routed stream gives up
                // instantly, its drain finds this waiter instead of missing
                // it (the drain resolves total waiters on any give-up).
                ensureStream(for: max(0, hint))
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
                didReceiveResponse: { [weak self] _, total in
                    self?.streamReceivedResponse(total: total)
                },
                didDetectSessionMissing: { [weak self] _ in
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
                store: { [weak self] start, data, total in
                    guard let self else { return }
                    self.cache.recordOriginTransfer(byteCount: data.count)
                    self.cache.store(start: start, data: data, totalLength: total)
                }
            )
        )
    }

    private func streamDidStore(_ range: ClosedRange<Int64>) {
        var resume: [CheckedContinuation<WaitOutcome, Never>] = []
        stateLock.lock()
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

    private func streamReceivedResponse(total: Int64?) {
        var resume: [CheckedContinuation<Int64?, Never>] = []
        stateLock.lock()
        sawOriginResponse = true
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
    }

    /// A stream left the pool. Finished streams re-drive their waiters
    /// (data may satisfy them or a new stream will be ensured); a give-up
    /// fails them and surfaces the interruption exactly once.
    private func streamEnded(
        _ stream: PlaybackOriginStream,
        gaveUpWith cause: PlaybackOriginReconnectPolicy.EndCause?,
        statusCode: Int?
    ) {
        var redrive: [CheckedContinuation<WaitOutcome, Never>] = []
        var failed: [CheckedContinuation<WaitOutcome, Never>] = []
        var totalResume: [CheckedContinuation<Int64?, Never>] = []
        stateLock.lock()
        let wasTracked = streams.contains(where: { $0 === stream })
        streams.removeAll { $0 === stream }
        let survivors = streams.map { $0.snapshot() }
        for (id, waiter) in dataWaiters {
            // Waiters a surviving stream still covers re-drive and re-ride
            // it; only waiters this stream was responsible for fail. A
            // clean finish re-drives everyone.
            if cause == nil
                || PlaybackOriginStreamPolicy.coveringStream(offset: waiter.offset, streams: survivors) != nil {
                redrive.append(waiter.continuation)
            } else {
                failed.append(waiter.continuation)
            }
            dataWaiters.removeValue(forKey: id)
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
        let reason: PlaybackSourceInterruptionReason?
        switch cause {
        case .network, .stalled:
            reason = .networkUnavailable
        case .httpOutage(let code):
            reason = .serverUnavailable(statusCode: code)
        case .prematureEOF:
            if let total {
                reason = .prematureEOF(offset: stream.snapshot().writeCursor, expectedEnd: total - 1)
            } else {
                reason = nil
            }
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
        guard !cancelled else {
            stateLock.unlock()
            return false
        }
        let maxOrder = streams.map { $0.currentDemandOrder }.max() ?? 0
        let isMostRecent = stream.currentDemandOrder >= maxOrder
        stateLock.unlock()
        return !PlaybackOriginStreamPolicy.shouldPause(
            writeCursor: cursor,
            demandMark: demandMark,
            isMostRecentlyDemanded: isMostRecent,
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
        onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)? = nil
    ) {
        self.resource = PlaybackSourceResource(
            originURL: originURL,
            originHeaders: originHeaders,
            cache: cache,
            onPlaybackSessionMissing: onPlaybackSessionMissing,
            onPlaybackSourceInterrupted: onPlaybackSourceInterrupted
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

    func startPrefetch(at offset: Int64 = 0) {
        resource.startPrefetch(at: offset)
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
