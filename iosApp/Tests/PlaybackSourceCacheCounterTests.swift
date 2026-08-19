import XCTest
@testable import Silo

/// The two source-cache counters must stay commensurable with
/// `originBytesTransferred`: bytes actually served out of the cache, and a
/// plain event count of origin waits. The old spelling accumulated an
/// *intended* chunk size per miss, which made every derived hit rate fiction.
/// (The reuse *quotient* is the composer's job and is pinned in
/// `PlaybackStatsComposerTests`.)
final class PlaybackSourceCacheCounterTests: XCTestCase {
    private func makeCache() -> PlaybackSourceCache {
        PlaybackSourceCache(maxBytes: 4 * 1024 * 1024, diskSpillEnabled: false)
    }

    func testReadCountsBytesActuallyServedAndCountsReuseAgain() {
        let cache = makeCache()
        cache.store(start: 0, data: Data(repeating: 0xAB, count: 1_000), totalLength: 1_000)

        XCTAssertEqual(cache.stats().bytesServedFromCache, 0)

        let first = cache.read(start: 0, maxLength: 400)
        XCTAssertEqual(first?.count, 400)
        XCTAssertEqual(cache.stats().bytesServedFromCache, 400)

        // Re-serving the same span (what a backward seek does) counts again —
        // that is the reuse the ratio is meant to surface.
        let second = cache.read(start: 0, maxLength: 400)
        XCTAssertEqual(second?.count, 400)
        XCTAssertEqual(cache.stats().bytesServedFromCache, 800)
    }

    func testRecordOriginWaitCountsEventsAndLeavesByteCountersAlone() {
        let cache = makeCache()
        cache.store(start: 0, data: Data(repeating: 0x01, count: 100), totalLength: 100)
        _ = cache.read(start: 0, maxLength: 100)
        cache.recordOriginTransfer(byteCount: 100)

        let before = cache.stats()
        cache.recordOriginWait()
        cache.recordOriginWait()
        let after = cache.stats()

        XCTAssertEqual(before.originWaitCount, 0)
        XCTAssertEqual(after.originWaitCount, 2)
        XCTAssertEqual(after.bytesServedFromCache, before.bytesServedFromCache)
        XCTAssertEqual(after.originBytesTransferred, before.originBytesTransferred)
    }
}
