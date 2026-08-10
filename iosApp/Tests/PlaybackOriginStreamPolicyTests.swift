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

final class PlaybackWindowClaimPolicyTests: XCTestCase {

    private let owner = UUID()
    private let rival = UUID()

    func testUnownedWindowGrantsAnyClaim() {
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: rival,
                owner: nil,
                ownerIsAlive: false,
                demandOffset: 10,
                windowCursor: 20
            ),
            .retarget
        )
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: nil,
                owner: nil,
                ownerIsAlive: false,
                demandOffset: 10,
                windowCursor: 20
            ),
            .retarget
        )
    }

    func testOwnerMayAdvanceItsOwnWindow() {
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: owner,
                owner: owner,
                ownerIsAlive: true,
                demandOffset: 100,
                windowCursor: 20
            ),
            .retarget
        )
    }

    func testOwnerUsesChunkForNearbyBehindWindowMiss() {
        // Origin bytes can land between the response's cache check and its
        // window claim. Re-anchoring for this tiny behind-cursor race caused
        // the production 1-2 second cancellation loop.
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: owner,
                owner: owner,
                ownerIsAlive: true,
                demandOffset: 10,
                windowCursor: 50
            ),
            .chunk(.sameOwnerBehindWindow)
        )
    }

    func testOwnerReanchorsWhenFarBehindProductiveWindow() {
        // A sequential reader can lag after finite-cache eviction. Discrete
        // fallback is deliberately bounded to one chunk so that reader can
        // reclaim the streaming connection instead of becoming RTT-bound.
        let cursor = PlaybackWindowClaimPolicy.sameOwnerChunkBehindBytes + 100
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: owner,
                owner: owner,
                ownerIsAlive: true,
                demandOffset: 0,
                windowCursor: cursor
            ),
            .retarget
        )
    }

    func testRivalCannotStealLiveOwnersWindow() {
        // The 2026-07 tvOS storm: two full-rate readers alternately
        // retargeting the window, cancelling each other's origin connection
        // every 1-2s. The rival must be served by a chunk instead.
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: rival,
                owner: owner,
                ownerIsAlive: true,
                demandOffset: 100,
                windowCursor: 20
            ),
            .chunk(.liveOwnerConflict)
        )
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: nil,
                owner: owner,
                ownerIsAlive: true,
                demandOffset: 100,
                windowCursor: 20
            ),
            .chunk(.liveOwnerConflict)
        )
    }

    func testDeadOwnerFreesTheWindow() {
        // A seek closes the old serve connection and opens a new one; the
        // new consumer must be able to re-anchor immediately.
        XCTAssertEqual(
            PlaybackWindowClaimPolicy.arbitrate(
                claimant: rival,
                owner: owner,
                ownerIsAlive: false,
                demandOffset: 10,
                windowCursor: 50
            ),
            .retarget
        )
    }

    func testRepeatedBehindMissesDoNotRetargetTheLiveOwner() {
        // Model the live simulator trace: the origin advances productively
        // while a cache-check/storage race leaves the same response only
        // kilobytes behind it. Those nearby misses must never cancel the
        // warm request.
        var windowCursor: Int64 = 64 * 1024 * 1024
        var retargetCount = 0
        var chunkCount = 0
        let deliveredPerInterval: [Int64] = [
            23_709_456,
            16_391_800,
            14_292_744,
        ]

        for cycle in 0..<48 {
            let delivered = deliveredPerInterval[cycle % deliveredPerInterval.count]
            windowCursor += delivered
            let demandOffset = windowCursor - 64 * 1024
            let verdict = PlaybackWindowClaimPolicy.arbitrate(
                claimant: owner,
                owner: owner,
                ownerIsAlive: true,
                demandOffset: demandOffset,
                windowCursor: windowCursor
            )
            switch verdict {
            case .retarget:
                retargetCount += 1
                windowCursor = demandOffset
            case .chunk(let reason):
                XCTAssertEqual(reason, .sameOwnerBehindWindow)
                chunkCount += 1
            }
        }

        XCTAssertEqual(retargetCount, 0)
        XCTAssertEqual(chunkCount, 48)
    }
}

final class PlaybackOriginDetachGraceTests: XCTestCase {

    func testUnknownBitrateFallsBackToFixedGrace() {
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.detachGraceSeconds(
                hysteresisGapBytes: 64 * 1024 * 1024,
                sourceBitrateBps: nil
            ),
            PlaybackOriginStreamPolicy.detachAfterSeconds
        )
    }

    func testFastSourceKeepsFloorGrace() {
        // 80 Mbps drains 64 MiB in ~6.7s; grace stays at the floor.
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.detachGraceSeconds(
                hysteresisGapBytes: 64 * 1024 * 1024,
                sourceBitrateBps: 80_000_000
            ),
            PlaybackOriginStreamPolicy.detachAfterSeconds
        )
    }

    func testMastersBitrateOutlivesTheDrain() {
        // The regression file: 19.4 Mbps drains the 64 MiB gap in ~27.7s,
        // past the fixed 25s grace. The adaptive grace must cover the drain
        // plus margin so demand resumes the parked task instead of paying a
        // detach + reconnect every cycle.
        let drain = Double(64 * 1024 * 1024) * 8.0 / 19_400_000
        let grace = PlaybackOriginStreamPolicy.detachGraceSeconds(
            hysteresisGapBytes: 64 * 1024 * 1024,
            sourceBitrateBps: 19_400_000
        )
        XCTAssertGreaterThan(grace, drain)
        XCTAssertLessThanOrEqual(grace, PlaybackOriginStreamPolicy.detachGraceCeilingSeconds)
    }

    func testSlowPlaybackRateStretchesTheGrace() {
        // At 0.75x the 19.4 Mbps title drains 64 MiB in ~36.9s, past the
        // 1x grace — the rate must scale the drain estimate.
        let gap: Int64 = 64 * 1024 * 1024
        let slowDrain = Double(gap) * 8.0 / (19_400_000 * 0.75)
        let grace = PlaybackOriginStreamPolicy.detachGraceSeconds(
            hysteresisGapBytes: gap,
            sourceBitrateBps: 19_400_000,
            playbackRate: 0.75
        )
        XCTAssertGreaterThan(grace, slowDrain)
        XCTAssertLessThanOrEqual(grace, PlaybackOriginStreamPolicy.detachGraceCeilingSeconds)
        // Zero/negative rates (paused, backends reporting 0) fall back to 1x
        // instead of producing an infinite drain.
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.detachGraceSeconds(
                hysteresisGapBytes: gap,
                sourceBitrateBps: 19_400_000,
                playbackRate: 0
            ),
            PlaybackOriginStreamPolicy.detachGraceSeconds(
                hysteresisGapBytes: gap,
                sourceBitrateBps: 19_400_000
            )
        )
    }

    func testVerySlowSourceClampsToProxySafeCeiling() {
        // 4 Mbps would drain 64 MiB in ~134s; the grace must still close
        // the connection before reverse-proxy client-send timeouts reap it.
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.detachGraceSeconds(
                hysteresisGapBytes: 64 * 1024 * 1024,
                sourceBitrateBps: 4_000_000
            ),
            PlaybackOriginStreamPolicy.detachGraceCeilingSeconds
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
    func testPrefetchHysteresisRearmsOnlyAtLowWater() throws {
        let cache = PlaybackSourceCache(maxBytes: 1_024, diskSpillEnabled: false)
        cache.store(start: 0, data: Data(count: 1_024), totalLength: nil)

        XCTAssertFalse(cache.shouldPrefetch)
        XCTAssertEqual(try XCTUnwrap(cache.read(start: 0, maxLength: 1)).count, 1)
        XCTAssertFalse(cache.shouldPrefetch, "a one-byte dip below high water must stay disarmed")
        XCTAssertFalse(cache.shouldPrefetch, "repeated gate reads near high water must remain sticky")

        XCTAssertEqual(try XCTUnwrap(cache.read(start: 1, maxLength: 1_023)).count, 1_023)
        XCTAssertTrue(cache.shouldPrefetch, "draining to low water must re-arm prefetch")
        XCTAssertTrue(cache.shouldPrefetch)
    }

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
