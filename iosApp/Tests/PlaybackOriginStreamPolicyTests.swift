import XCTest

@testable import Silo

final class PlaybackOriginStreamPolicyTests: XCTestCase {
    private func snapshot(
        id: UUID = UUID(),
        start: Int64 = 0,
        cursor: Int64,
        order: UInt64,
        age: TimeInterval = .infinity
    ) -> PlaybackOriginStreamPolicy.StreamSnapshot {
        PlaybackOriginStreamPolicy.StreamSnapshot(
            id: id,
            startOffset: start,
            writeCursor: cursor,
            lastDemandOrder: order,
            secondsSinceTargeted: age
        )
    }

    func testDemandJustAheadOfCursorRidesThrough() {
        let id = UUID()
        let streams = [snapshot(id: id, cursor: 10_000_000, order: 1)]

        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 10_000_000, streams: streams),
            .rideThrough(id)
        )
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(
                demandOffset: 10_000_000 + PlaybackOriginStreamPolicy.rideThroughBytes,
                streams: streams
            ),
            .rideThrough(id)
        )
    }

    func testDemandBehindCursorNeverRidesThrough() {
        // Bytes behind a cursor will never arrive on that stream; a miss
        // there means the cache evicted them and a connection must move.
        let streams = [snapshot(cursor: 50_000_000, order: 1)]

        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 10_000_000, streams: streams),
            .spawn
        )
    }

    func testFarDemandSpawnsSecondStreamThenRetargetsLeastRecent() {
        let a = UUID()
        let b = UUID()
        let one = [snapshot(id: a, cursor: 1_000_000, order: 1)]
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 900_000_000, streams: one),
            .spawn
        )

        let two = [
            snapshot(id: a, cursor: 1_000_000, order: 1),
            snapshot(id: b, start: 900_000_000, cursor: 901_000_000, order: 2),
        ]
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 500_000_000, streams: two),
            .retarget(a)
        )
    }

    func testNoStreamsSpawns() {
        XCTAssertEqual(PlaybackOriginStreamPolicy.action(demandOffset: 0, streams: []), .spawn)
    }

    func testDemandWaitsWhenEveryStreamIsStillConnecting() {
        // Neither stream has delivered since its last (re)target and neither
        // has aged out: retargeting one would kill a connection before its
        // first byte — with three demand regions and two slots that cycle
        // livelocks. The demand must wait instead.
        let fresh = [
            snapshot(start: 0, cursor: 0, order: 1, age: 0),
            snapshot(start: 900_000_000, cursor: 900_000_000, order: 2, age: 0),
        ]
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 500_000_000, streams: fresh),
            .wait
        )
    }

    func testDeliveredStreamIsTheRetargetVictimOverAFresherOne() {
        // Only the stream that has delivered since its target is eligible,
        // even though the still-connecting one is less recently demanded.
        let connecting = UUID()
        let delivered = UUID()
        let streams = [
            snapshot(id: connecting, start: 0, cursor: 0, order: 1, age: 0),
            snapshot(id: delivered, start: 900_000_000, cursor: 901_000_000, order: 2, age: 0),
        ]
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 500_000_000, streams: streams),
            .retarget(delivered)
        )
    }

    func testGracePeriodMakesAWedgedStreamRetargetable() {
        // A connection that opens but never produces must not block
        // retargets forever; after the grace period it becomes a victim.
        let wedged = UUID()
        let streams = [
            snapshot(id: wedged, start: 0, cursor: 0, order: 1, age: PlaybackOriginStreamPolicy.retargetGraceSeconds),
            snapshot(start: 900_000_000, cursor: 900_000_000, order: 2, age: 0),
        ]
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.action(demandOffset: 500_000_000, streams: streams),
            .retarget(wedged)
        )
    }

    func testCoveringStreamPrefersNearestRegionStart() {
        let head = UUID()
        let tail = UUID()
        let streams = [
            snapshot(id: head, start: 0, cursor: 30_000_000, order: 1),
            snapshot(id: tail, start: 900_000_000, cursor: 910_000_000, order: 2),
        ]

        XCTAssertEqual(
            PlaybackOriginStreamPolicy.coveringStream(offset: 10_000_000, streams: streams),
            head
        )
        XCTAssertEqual(
            PlaybackOriginStreamPolicy.coveringStream(offset: 905_000_000, streams: streams),
            tail
        )
        XCTAssertNil(
            PlaybackOriginStreamPolicy.coveringStream(offset: 500_000_000, streams: streams)
        )
    }

    func testPrimaryStreamPausesOnlyOnGlobalBudget() {
        XCTAssertFalse(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 0,
                isMostRecentlyDemanded: true,
                globalBudgetAvailable: true
            )
        )
        XCTAssertTrue(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 499_000_000,
                isMostRecentlyDemanded: true,
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
                isMostRecentlyDemanded: true,
                globalBudgetAvailable: false
            )
        )
        XCTAssertFalse(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 500_000_000,
                demandMark: 502_000_000,
                isMostRecentlyDemanded: false,
                globalBudgetAvailable: false
            )
        )
    }

    func testSecondaryStreamPausesAtForwardCap() {
        XCTAssertFalse(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: 10_000_000,
                demandMark: 0,
                isMostRecentlyDemanded: false,
                globalBudgetAvailable: true
            )
        )
        XCTAssertTrue(
            PlaybackOriginStreamPolicy.shouldPause(
                writeCursor: PlaybackOriginStreamPolicy.secondaryForwardCapBytes,
                demandMark: 0,
                isMostRecentlyDemanded: false,
                globalBudgetAvailable: true
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
