import XCTest

@testable import Silo

final class PlaybackOriginRoutingPolicyTests: XCTestCase {
    private let claim = PlaybackOriginRoutingPolicy.windowClaimBytes
    private let ride = PlaybackOriginRoutingPolicy.rideThroughBytes

    func testMissJustAheadOfWindowCursorRides() {
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 10_000_000,
                windowCursor: 10_000_000,
                servedSequentialBytes: 0
            ),
            .rideWindow
        )
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 10_000_000 + ride,
                windowCursor: 10_000_000,
                servedSequentialBytes: 0
            ),
            .rideWindow
        )
    }

    func testProbeMissesFetchChunksAndNeverMoveTheWindow() {
        // Head, tail-cues, and mid-file probe reads consume almost nothing
        // before missing; regardless of where they land relative to the
        // window they must go to the chunk path.
        for offset: Int64 in [0, 5_976, 3_126_797_895, 6_177_217_657] {
            XCTAssertEqual(
                PlaybackOriginRoutingPolicy.route(
                    demandOffset: offset,
                    windowCursor: 30_000_000,
                    servedSequentialBytes: 100_000
                ),
                .chunk,
                "offset=\(offset)"
            )
        }
    }

    func testMissBehindWindowCursorIsAChunkNotARetarget() {
        // Bytes behind the cursor will never arrive on the window; the
        // cache evicted them. Refetch discretely — moving the window
        // backward would abandon its forward runway.
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 10_000_000,
                windowCursor: 50_000_000,
                servedSequentialBytes: 0
            ),
            .chunk
        )
    }

    func testSequentialConsumerClaimsTheWindowOnASeek() {
        // A connection that has already streamed windowClaimBytes is the
        // playback reader; its far miss is a seek and re-anchors the window.
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 900_000_000,
                windowCursor: 30_000_000,
                servedSequentialBytes: claim
            ),
            .claimWindow
        )
        // Just below the claim threshold it is still treated as a probe.
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 900_000_000,
                windowCursor: 30_000_000,
                servedSequentialBytes: claim - 1
            ),
            .chunk
        )
    }

    func testNoWindowRoutesByClaimThreshold() {
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 500_000_000,
                windowCursor: nil,
                servedSequentialBytes: claim
            ),
            .claimWindow
        )
        XCTAssertEqual(
            PlaybackOriginRoutingPolicy.route(
                demandOffset: 500_000_000,
                windowCursor: nil,
                servedSequentialBytes: 0
            ),
            .chunk
        )
    }

    func testRoutingConstantsArePinned() {
        XCTAssertEqual(PlaybackOriginRoutingPolicy.chunkBytes, 4 * 1024 * 1024)
        XCTAssertEqual(PlaybackOriginRoutingPolicy.windowClaimBytes, 8 * 1024 * 1024)
        XCTAssertEqual(PlaybackOriginRoutingPolicy.rideThroughBytes, 8 * 1024 * 1024)
    }

    func testInteractiveChunkAttemptUsesShortIndependentTimeout() {
        let configuration = PlaybackOriginChunkFetcher.makeSessionConfiguration()
        XCTAssertEqual(
            configuration.timeoutIntervalForRequest,
            PlaybackOriginChunkFetcher.interactiveRequestTimeoutSeconds
        )
        XCTAssertEqual(PlaybackOriginChunkFetcher.interactiveRequestTimeoutSeconds, 4.0)
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(
                cause: .network,
                unproductiveStreak: 0,
                everProductive: false
            ),
            .retry(afterSeconds: 0.5),
            "a short interactive attempt must still flow into the longer reconnect/outage policy"
        )
    }
}

final class PlaybackOriginStreamPolicyTests: XCTestCase {

    func testWindowPausesOnlyOnGlobalBudget() {
        XCTAssertFalse(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 0,
                globalBudgetAvailable: true
            )
        )
        XCTAssertTrue(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 499_000_000,
                globalBudgetAvailable: false
            )
        )
    }

    func testBlockedDemandAtCursorOverridesBudgetPark() {
        // A demand at or ahead of the cursor is blocked on bytes only this
        // connection will deliver; a full readahead budget must not park it
        // (the budget frees through reads, and the read is what's blocked).
        XCTAssertFalse(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 500_000_000,
                globalBudgetAvailable: false
            )
        )
        XCTAssertFalse(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 502_000_000,
                globalBudgetAvailable: false
            )
        )
    }
}

final class PlaybackOriginReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(PlaybackOriginReconnectPolicy.backoffSeconds(streak: 0), 0.5)
        XCTAssertEqual(PlaybackOriginReconnectPolicy.backoffSeconds(streak: 1), 1.0)
        XCTAssertEqual(PlaybackOriginReconnectPolicy.backoffSeconds(streak: 2), 2.0)
        XCTAssertEqual(PlaybackOriginReconnectPolicy.backoffSeconds(streak: 10), 8.0)
    }

    func testProductiveConnectionsExtendNetworkRetries() {
        // A link that has delivered real bytes gets 8 attempts before the
        // player is torn down; one that never produced anything gets 4.
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .network, unproductiveStreak: 7, everProductive: true),
            .retry(afterSeconds: 8.0)
        )
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .network, unproductiveStreak: 8, everProductive: true),
            .giveUp
        )
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .network, unproductiveStreak: 4, everProductive: false),
            .giveUp
        )
    }

    func testHttpOutageRetriesBeforeGivingUp() {
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .httpOutage(503), unproductiveStreak: 0, everProductive: false),
            .retry(afterSeconds: 0.5)
        )
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .httpOutage(503), unproductiveStreak: 4, everProductive: true),
            .giveUp
        )
    }

    func testFatalCausesGetSingleRetry() {
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .httpFatal(500), unproductiveStreak: 0, everProductive: true),
            .retry(afterSeconds: 0.5)
        )
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .httpFatal(500), unproductiveStreak: 1, everProductive: true),
            .giveUp
        )
        XCTAssertEqual(
            PlaybackOriginReconnectPolicy.decide(cause: .rangeIgnored, unproductiveStreak: 1, everProductive: true),
            .giveUp
        )
    }

    func testContentRangeParsing() {
        XCTAssertEqual(PlaybackOriginStream.totalLength(fromContentRange: "bytes 100-499/12345"), 12_345)
        XCTAssertNil(PlaybackOriginStream.totalLength(fromContentRange: "bytes 100-499/*"))
        XCTAssertNil(PlaybackOriginStream.totalLength(fromContentRange: nil))
        XCTAssertEqual(PlaybackOriginStream.rangeStart(fromContentRange: "bytes 100-499/12345"), 100)
        XCTAssertNil(PlaybackOriginStream.rangeStart(fromContentRange: "garbage"))
    }
}

final class PlaybackSourceCacheStreamingAppendTests: XCTestCase {
    func testAdjacentStoresGrowOneSpanAndReadAcrossBoundary() {
        let cache = PlaybackSourceCache(maxBytes: 8 * 1024 * 1024)
        cache.store(start: 0, data: Data(repeating: 1, count: 1024), totalLength: nil)
        cache.store(start: 1024, data: Data(repeating: 2, count: 1024), totalLength: nil)

        let across = cache.read(start: 512, maxLength: 1024)
        XCTAssertEqual(across?.count, 1024)
        XCTAssertEqual(across?.first, 1)
        XCTAssertEqual(across?.last, 2)
    }

    func testNonAdjacentStoresStaySeparate() {
        let cache = PlaybackSourceCache(maxBytes: 8 * 1024 * 1024)
        cache.store(start: 0, data: Data(repeating: 1, count: 1024), totalLength: nil)
        cache.store(start: 4096, data: Data(repeating: 2, count: 1024), totalLength: nil)

        XCTAssertNil(cache.read(start: 2048, maxLength: 16))
        XCTAssertTrue(cache.contains(offset: 0))
        XCTAssertTrue(cache.contains(offset: 4096))
        XCTAssertFalse(cache.contains(offset: 2048))
        // A read at the first span still stops at its end.
        XCTAssertEqual(cache.read(start: 1000, maxLength: 4096)?.count, 24)
    }

    func testOverlappingStoreStillMerges() {
        let cache = PlaybackSourceCache(maxBytes: 8 * 1024 * 1024)
        cache.store(start: 0, data: Data(repeating: 1, count: 1024), totalLength: nil)
        cache.store(start: 512, data: Data(repeating: 2, count: 1024), totalLength: nil)

        let merged = cache.read(start: 0, maxLength: 1536)
        XCTAssertEqual(merged?.count, 1536)
        XCTAssertEqual(merged?[0], 1)
        XCTAssertEqual(merged?[600], 2)
        XCTAssertEqual(merged?[1535], 2)
    }
}
