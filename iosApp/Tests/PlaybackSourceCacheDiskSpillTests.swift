import XCTest
@testable import Silo

final class PlaybackSourceCacheDiskSpillTests: XCTestCase {
    private let spanBytes = 1024

    private func makeCache(
        maxBytes: Int = 4 * 1024,
        diskBudgetBytes: Int64 = 16 * 1024
    ) -> PlaybackSourceCache {
        PlaybackSourceCache(
            maxBytes: maxBytes,
            diskSpillEnabled: true,
            diskBudgetBytes: diskBudgetBytes
        )
    }

    private func fill(_ cache: PlaybackSourceCache, spans: Int, startingAt base: Int64 = 0) {
        for i in 0..<spans {
            cache.store(
                start: base + Int64(i * spanBytes),
                data: Data(repeating: UInt8(truncatingIfNeeded: i + 1), count: spanBytes),
                totalLength: nil
            )
        }
    }

    func testEvictedSpanIsServedFromDisk() {
        let cache = makeCache()
        // Distinct non-adjacent spans so the append fast path can't merge
        // them; overflow the 4 KiB memory budget to force eviction + spill.
        for i in 0..<8 {
            cache.store(
                start: Int64(i * spanBytes * 2),
                data: Data(repeating: UInt8(i + 1), count: spanBytes),
                totalLength: nil
            )
        }
        let stats = cache.stats()
        XCTAssertGreaterThan(stats.diskSpillBytes, 0, "eviction should spill to disk")
        XCTAssertEqual(stats.diskBytesWritten, stats.diskSpillBytes)
        // The oldest span (start 0) was evicted from memory; bytes must
        // round-trip identically from the disk span.
        let read = cache.read(start: 0, maxLength: spanBytes)
        XCTAssertEqual(read, Data(repeating: 1, count: spanBytes))
    }

    func testDiskSpillDisabledWritesNothing() {
        let cache = PlaybackSourceCache(
            maxBytes: 4 * 1024,
            diskSpillEnabled: false,
            diskBudgetBytes: 16 * 1024
        )
        for i in 0..<8 {
            cache.store(
                start: Int64(i * spanBytes * 2),
                data: Data(repeating: UInt8(i + 1), count: spanBytes),
                totalLength: nil
            )
        }
        let stats = cache.stats()
        XCTAssertEqual(stats.diskSpillBytes, 0)
        XCTAssertEqual(stats.diskBytesWritten, 0)
        XCTAssertEqual(stats.diskBudgetBytes, 0)
        XCTAssertNil(cache.read(start: 0, maxLength: spanBytes), "evicted span must be gone without spill")
    }

    func testDiskEvictionPrefersSpansFarthestFromPlayhead() {
        // Disk budget of 4 spans; spill 4, then anchor the playhead near the
        // start and force one more spill — the victim must be the farthest
        // span, not the seek-back neighborhood.
        let cache = makeCache(maxBytes: 2 * spanBytes, diskBudgetBytes: Int64(4 * spanBytes))
        for i in 0..<6 {
            cache.store(
                start: Int64(i * spanBytes * 2),
                data: Data(repeating: UInt8(i + 1), count: spanBytes),
                totalLength: nil
            )
        }
        // Playhead near start: reading span 0 (from disk) sets lastReadEnd.
        XCTAssertNotNil(cache.read(start: 0, maxLength: spanBytes))
        // Force another spill over the full disk budget.
        cache.store(
            start: Int64(6 * spanBytes * 2),
            data: Data(repeating: 7, count: spanBytes),
            totalLength: nil
        )
        cache.store(
            start: Int64(7 * spanBytes * 2),
            data: Data(repeating: 8, count: spanBytes),
            totalLength: nil
        )
        // Span 0 is at the playhead — it must survive disk eviction.
        XCTAssertEqual(cache.read(start: 0, maxLength: spanBytes), Data(repeating: 1, count: spanBytes))
        XCTAssertLessThanOrEqual(cache.stats().diskSpillBytes, Int64(4 * spanBytes))
    }

    func testBackwardSeekMovesDiskEvictionAnchor() {
        // lastReadEnd is a monotonic high-water mark; disk eviction must
        // anchor on the *recent* read position or a backward seek's
        // neighborhood gets evicted while stale forward spans survive.
        let cache = makeCache(maxBytes: 2 * spanBytes, diskBudgetBytes: Int64(4 * spanBytes))
        for i in 0..<6 {
            cache.store(
                start: Int64(i * spanBytes * 2),
                data: Data(repeating: UInt8(i + 1), count: spanBytes),
                totalLength: nil
            )
        }
        // Play far forward (pins the high-water mark high)...
        XCTAssertNotNil(cache.read(start: Int64(5 * spanBytes * 2), maxLength: spanBytes))
        // ...then seek back to the start.
        XCTAssertNotNil(cache.read(start: 0, maxLength: spanBytes))
        // Force disk eviction with two more spills.
        for i in 6..<8 {
            cache.store(
                start: Int64(i * spanBytes * 2),
                data: Data(repeating: UInt8(i + 1), count: spanBytes),
                totalLength: nil
            )
        }
        // The seek-back neighborhood must survive despite the stale
        // high-water mark sitting far ahead.
        XCTAssertEqual(cache.read(start: 0, maxLength: spanBytes), Data(repeating: 1, count: spanBytes))
    }

    func testWriteBudgetStopsSpillAndChurn() {
        // Write budget = multiplier × diskBudget. Give a tiny disk budget so
        // the write budget is exhausted quickly, then verify writes stop.
        let diskBudget = Int64(2 * spanBytes)
        let writeBudget = diskBudget * PlaybackSourceCache.diskWriteBudgetMultiplier
        let cache = makeCache(maxBytes: 2 * spanBytes, diskBudgetBytes: diskBudget)
        for i in 0..<32 {
            cache.store(
                start: Int64(i * spanBytes * 2),
                data: Data(repeating: UInt8(truncatingIfNeeded: i + 1), count: spanBytes),
                totalLength: nil
            )
        }
        let stats = cache.stats()
        XCTAssertLessThanOrEqual(stats.diskBytesWritten, writeBudget, "session writes must respect the wear budget")
        XCTAssertLessThanOrEqual(stats.diskSpillBytes, diskBudget)
    }

    func testRetentionBudgetClampParity() {
        // The source-cache budget must match the segment store's policy.
        let cap: Int64 = 2 << 30
        let floor: Int64 = 512 << 20
        XCTAssertEqual(PlaybackDiskBudget.retentionBudget(availableBytes: nil), cap)
        XCTAssertEqual(PlaybackDiskBudget.retentionBudget(availableBytes: 0), cap)
        XCTAssertEqual(PlaybackDiskBudget.retentionBudget(availableBytes: -1), cap)
        XCTAssertEqual(PlaybackDiskBudget.retentionBudget(availableBytes: 100 << 20), floor)
        XCTAssertEqual(PlaybackDiskBudget.retentionBudget(availableBytes: 4 << 30), 1 << 30)
        XCTAssertEqual(PlaybackDiskBudget.retentionBudget(availableBytes: 100 << 30), cap)
        XCTAssertEqual(
            AVPlayerBackend.vodRetentionBudget(availableBytes: 4 << 30),
            PlaybackDiskBudget.retentionBudget(availableBytes: 4 << 30)
        )
    }
}
