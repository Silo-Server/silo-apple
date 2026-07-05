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
    static let sourcePrefetchChunkBytes = 2 * 1024 * 1024
    static let highBitrateSourcePrefetchChunkBytes = 8 * 1024 * 1024
    static let ultraBitrateSourcePrefetchChunkBytes = 16 * 1024 * 1024
    static let sourceDiskSpillBudgetBytes = 512 * 1024 * 1024

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

private struct PlaybackSourceHTTPStatusError: Error, CustomStringConvertible {
    let statusCode: Int
    let body: String?

    var description: String {
        if let body, !body.isEmpty {
            return "origin HTTP \(statusCode): \(body)"
        }
        return "origin HTTP \(statusCode)"
    }
}

private enum PlaybackSourceFetchError: Error, CustomStringConvertible {
    case http(PlaybackSourceHTTPStatusError)
    case network(Error)

    var description: String {
        switch self {
        case .http(let error):
            return error.description
        case .network(let error):
            return String(describing: error)
        }
    }
}

private final class PlaybackSourceResource {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackSourceResource"
    )

    let token: String
    let originURL: URL
    let originHeaders: [String: String]
    let cache: PlaybackSourceCache
    private let onPlaybackSessionMissing: (() -> Void)?
    private let onPlaybackSourceInterrupted: ((PlaybackSourceInterruptionReason) -> Void)?
    private var chunkBytes: Int
    private let session: URLSession
    private let chunkLock = NSLock()
    private let prefetchLock = NSLock()
    private var prefetchTask: Task<Void, Never>?
    private var prefetchTaskID: UUID?
    private var prefetchStartOffset: Int64?
    private var pendingPrefetchStartOffset: Int64?
    private var cancelled = false
    private var discoveredTotalLength: Int64?
    /// Detached serve tasks hold strong `self` for their whole body, so an
    /// await that outlives the session (a send parked on TCP backpressure,
    /// a fetch racing session invalidation) kept the resource — and its
    /// cache budget — alive forever. `stop()` cancels every tracked task;
    /// `send` cancels its connection on task cancellation so the parked
    /// completion fires. Guarded by `prefetchLock`.
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
        self.chunkBytes = PlaybackSourceCache.sourcePrefetchChunkBytes
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    deinit {
        print("[CMP-LIFE] deinit PlaybackSourceResource")
        stop()
    }

    func stop() {
        prefetchLock.lock()
        cancelled = true
        let task = prefetchTask
        prefetchTask = nil
        prefetchTaskID = nil
        prefetchStartOffset = nil
        pendingPrefetchStartOffset = nil
        let serving = serveTasks
        serveTasks.removeAll()
        completedServeTaskIDs.removeAll()
        prefetchLock.unlock()
        task?.cancel()
        for (_, serveTask) in serving {
            serveTask.cancel()
        }
        session.invalidateAndCancel()
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
        schedulePrefetch(after: max(0, offset))
    }

    func setSourceBitrate(_ bps: Double?) {
        cache.setSourceBitrate(bps)
        let chunk: Int
        if let bps, bps >= 200_000_000 {
            chunk = PlaybackSourceCache.ultraBitrateSourcePrefetchChunkBytes
        } else if let bps, bps >= 80_000_000 {
            chunk = PlaybackSourceCache.highBitrateSourcePrefetchChunkBytes
        } else {
            chunk = PlaybackSourceCache.sourcePrefetchChunkBytes
        }
        chunkLock.lock()
        chunkBytes = chunk
        chunkLock.unlock()
        Self.logger.info("[CMP-SOURCE-CACHE] source bitrate=\(bps ?? 0, privacy: .public) chunkBytes=\(chunk, privacy: .public)")
    }

    func handle(method: String, rangeHeader: String?, on connection: NWConnection) {
        prefetchLock.lock()
        let alreadyStopped = cancelled
        prefetchLock.unlock()
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
        prefetchLock.lock()
        if completedServeTaskIDs.remove(id) != nil {
            // Finished before registration — nothing to track.
        } else if cancelled {
            cancelNow = true
        } else {
            serveTasks[id] = task
        }
        prefetchLock.unlock()
        if cancelNow {
            task.cancel()
        }
    }

    private func serveTaskFinished(_ id: UUID) {
        prefetchLock.lock()
        if serveTasks.removeValue(forKey: id) == nil, !cancelled {
            completedServeTaskIDs.insert(id)
        }
        prefetchLock.unlock()
    }

    private func isCancelledFlag() -> Bool {
        prefetchLock.lock()
        let value = cancelled
        prefetchLock.unlock()
        return value
    }

    private func respondHead(on connection: NWConnection) async {
        let total = await discoverTotalLength()
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
        let total = await discoverTotalLength()
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
                schedulePrefetch(after: cursor)
                continue
            }
            let chunkBytes = currentChunkBytes()
            let fetchLength = responseEnd.map { Int(min(Int64(chunkBytes), max(1, $0 - cursor + 1))) } ?? chunkBytes
            cache.recordCacheMiss(byteCount: Int64(fetchLength))
            do {
                let fetched = try await fetchRange(start: cursor, length: fetchLength)
                guard !fetched.data.isEmpty else {
                    sawEmptyFetch = true
                    break
                }
                cache.store(start: fetched.start, data: fetched.data, totalLength: fetched.totalLength)
                if let totalLength = fetched.totalLength {
                    discoveredTotalLength = totalLength
                    cache.setTotalLength(totalLength)
                }
            } catch {
                sawFetchError = true
                if !Self.isCancellationError(error) {
                    Self.logger.info("[CMP-SOURCE-CACHE] foreground range fetch failed start=\(cursor, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    notifyForegroundInterruptionIfNeeded(error: error, offset: cursor)
                }
                break
            }
        }
        let endCause = PlaybackSourceResponseEnd.classify(
            cursor: cursor,
            responseEnd: responseEnd,
            totalLength: discoveredTotalLength ?? total,
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
        schedulePrefetch(after: cursor)
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

    private func schedulePrefetch(after offset: Int64) {
        prefetchLock.lock()
        guard !cancelled else {
            prefetchLock.unlock()
            return
        }
        if let prefetchTask, !prefetchTask.isCancelled {
            if let prefetchStartOffset,
               !PlaybackSourcePrefetchPolicy.shouldRetargetPrefetch(
                    activeStart: prefetchStartOffset,
                    requestedStart: offset,
                    chunkBytes: currentChunkBytes()
               ) {
                prefetchLock.unlock()
                return
            }
            pendingPrefetchStartOffset = offset
            prefetchLock.unlock()
            return
        }
        let taskID = UUID()
        prefetchTaskID = taskID
        prefetchStartOffset = offset
        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            await self?.prefetchLoop(start: offset, taskID: taskID)
        }
        prefetchLock.unlock()
    }

    private func prefetchLoop(start: Int64, taskID: UUID) async {
        var cursor: Int64? = start
        while !Task.isCancelled, cache.shouldPrefetch {
            guard let fetchStart = cache.nextPrefetchStart(after: cursor) else { break }
            do {
                let fetched = try await fetchRange(start: fetchStart, length: currentChunkBytes())
                guard !fetched.data.isEmpty else { break }
                cache.store(start: fetched.start, data: fetched.data, totalLength: fetched.totalLength)
                cursor = fetched.start + Int64(fetched.data.count)
                if let totalLength = fetched.totalLength {
                    discoveredTotalLength = totalLength
                    cache.setTotalLength(totalLength)
                    if cursor! >= totalLength { break }
                }
            } catch {
                if !Self.isCancellationError(error) {
                    Self.logger.info("[CMP-SOURCE-CACHE] prefetch failed start=\(fetchStart, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
                break
            }
        }
        clearPrefetchTask(taskID: taskID)
    }

    private func clearPrefetchTask(taskID: UUID) {
        let pending: Int64?
        prefetchLock.lock()
        if prefetchTaskID == taskID {
            prefetchTask = nil
            prefetchTaskID = nil
            prefetchStartOffset = nil
            pending = pendingPrefetchStartOffset
            pendingPrefetchStartOffset = nil
        } else {
            pending = nil
        }
        prefetchLock.unlock()
        if let pending {
            schedulePrefetch(after: pending)
        }
    }

    private func currentChunkBytes() -> Int {
        chunkLock.lock()
        let value = chunkBytes
        chunkLock.unlock()
        return value
    }

    private func discoverTotalLength() async -> Int64? {
        if let discoveredTotalLength { return discoveredTotalLength }
        do {
            let fetched = try await fetchRange(start: 0, length: 1)
            cache.store(start: fetched.start, data: fetched.data, totalLength: fetched.totalLength)
            discoveredTotalLength = fetched.totalLength
            cache.setTotalLength(fetched.totalLength)
            return fetched.totalLength
        } catch {
            return nil
        }
    }

    private func fetchRange(start: Int64, length: Int) async throws -> (start: Int64, data: Data, totalLength: Int64?) {
        // Never create a task on a session that may already be invalidated
        // — the async wrapper's continuation can otherwise hang forever.
        try Task.checkCancellation()
        guard !isCancelledFlag() else { throw CancellationError() }
        let upper = max(start, start + Int64(max(1, length)) - 1)
        var request = URLRequest(url: originURL)
        request.httpMethod = "GET"
        for (key, value) in originHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(start)-\(upper)", forHTTPHeaderField: "Range")
        cache.beginOriginRequest()
        defer { cache.endOriginRequest() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlaybackSourceFetchError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            if Self.isPlaybackSessionMissing(statusCode: http.statusCode, body: body) {
                onPlaybackSessionMissing?()
            }
            throw PlaybackSourceFetchError.http(PlaybackSourceHTTPStatusError(statusCode: http.statusCode, body: body))
        }
        let total = Self.totalLength(from: http, fallbackDataLength: data.count)
        cache.recordOriginTransfer(byteCount: data.count)
        return (start, data, total)
    }

    private static func isPlaybackSessionMissing(statusCode: Int, body: String?) -> Bool {
        guard statusCode == 404 else { return false }
        let text = body ?? ""
        return text.contains("playback_session_not_found")
            || text.contains("Playback session not found")
    }

    private func notifyForegroundInterruptionIfNeeded(error: Error, offset: Int64) {
        guard let reason = Self.interruptionReason(for: error) else { return }
        Self.logger.warning(
            "[CMP-SOURCE-CACHE] foreground source interruption offset=\(offset, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
        )
        onPlaybackSourceInterrupted?(reason)
    }

    private static func interruptionReason(for error: Error) -> PlaybackSourceInterruptionReason? {
        if case let PlaybackSourceFetchError.http(httpError) = error {
            guard [502, 503, 504].contains(httpError.statusCode) else { return nil }
            return .serverUnavailable(statusCode: httpError.statusCode)
        }
        if case let PlaybackSourceFetchError.network(underlying) = error,
           !isCancellationError(underlying) {
            return .networkUnavailable
        }
        if !isCancellationError(error),
           (error as NSError).domain == NSURLErrorDomain {
            return .networkUnavailable
        }
        return nil
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

    private static func totalLength(from response: HTTPURLResponse, fallbackDataLength: Int) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/") {
            let suffix = contentRange[contentRange.index(after: slash)...]
            if suffix != "*", let total = Int64(suffix) {
                return total
            }
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           let value = Int64(length),
           response.statusCode == 200 {
            return value
        }
        return fallbackDataLength > 0 ? nil : 0
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case let PlaybackSourceFetchError.network(underlying) = error {
            return isCancellationError(underlying)
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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
