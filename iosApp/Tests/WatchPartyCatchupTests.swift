import Foundation
import XCTest
@testable import Silo

/// Mirrors the web client's `roomSyncCatchup.test.ts`, so native and browser
/// members converge on the room the same way.
final class WatchPartyCatchupTests: XCTestCase {
    // Small, exact offsets keep interval arithmetic free of rounding.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testNudgeStartsPastTheDeadbandAndRunsToTheSettlePoint() {
        // Playback inside the deadband stays at 1x.
        XCTAssertEqual(WatchPartyCorrection.nudge(drift: 0.35, currentRate: 1), 1)
        XCTAssertEqual(WatchPartyCorrection.nudge(drift: -0.35, currentRate: 1), 1)
        // Past it, a member behind the room speeds up and one ahead slows down.
        XCTAssertGreaterThan(WatchPartyCorrection.nudge(drift: 0.6, currentRate: 1), 1)
        XCTAssertLessThan(WatchPartyCorrection.nudge(drift: -0.6, currentRate: 1), 1)
        // A nudge in progress keeps going inside the deadband until it settles,
        // so playback hovering at the deadband does not flip between rates.
        XCTAssertGreaterThan(WatchPartyCorrection.nudge(drift: 0.3, currentRate: 1.01), 1)
        XCTAssertEqual(WatchPartyCorrection.nudge(drift: 0.08, currentRate: 1.01), 1)
        XCTAssertEqual(WatchPartyCorrection.nudge(drift: .nan, currentRate: 1.02), 1)
    }

    func testNudgeRatesStayBetweenOneAndFourPercent() {
        for step in -120...120 {
            let drift = Double(step) / 20
            guard abs(drift) > WatchPartyCorrection.deadband else { continue }
            let delta = abs(WatchPartyCorrection.nudge(drift: drift, currentRate: 1) - 1)
            XCTAssertLessThanOrEqual(delta, WatchPartyCorrection.maxRateDelta + 1e-9, "drift \(drift)")
            XCTAssertGreaterThanOrEqual(delta, WatchPartyCorrection.minRateDelta - 1e-9, "drift \(drift)")
        }
        XCTAssertEqual(WatchPartyCorrection.rate(for: 0.5), 1.02, accuracy: 1e-9)
        XCTAssertEqual(WatchPartyCorrection.rate(for: -0.5), 0.98, accuracy: 1e-9)
        XCTAssertEqual(WatchPartyCorrection.rate(for: 1), 1.04, accuracy: 1e-9)
        XCTAssertEqual(WatchPartyCorrection.rate(for: 30), 1.04, accuracy: 1e-9)
        XCTAssertEqual(WatchPartyCorrection.rate(for: 0.15), 1.01, accuracy: 1e-9)
    }

    func testAStoppedMemberSeeksOnlyWhenTheMoveIsCheapOrTheDriftLarge() {
        XCTAssertFalse(WatchPartyCorrection.seeksWhileStopped(drift: 0.9, reachableInPlace: true))
        XCTAssertTrue(WatchPartyCorrection.seeksWhileStopped(drift: -1.5, reachableInPlace: true))
        XCTAssertFalse(WatchPartyCorrection.seeksWhileStopped(drift: 4.9, reachableInPlace: false))
        XCTAssertTrue(WatchPartyCorrection.seeksWhileStopped(drift: 5.1, reachableInPlace: false))
        XCTAssertFalse(WatchPartyCorrection.seeksWhileStopped(drift: .infinity, reachableInPlace: true))
    }

    func testRoomPositionAdvancesFromTheCommandsExecuteTimeOnlyWhilePlaying() {
        func command(_ state: WatchPartyPlaybackState) -> WatchPartyTransportCommand {
            WatchPartyTransportCommand(commandId: "c", selectionRevision: 1, action: .play, positionSeconds: 100,
                                       executeAt: at(10), issuedAt: at(9.5), playbackState: state)
        }
        XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(.playing), serverNow: at(9)), 100)
        XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(.playing), serverNow: at(12.5)), 102.5)
        XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(.paused), serverNow: at(12.5)), 100)
        XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(.waiting), serverNow: at(12.5)), 100)
    }

    func testClockUsesTheFastestRecentRoundTrip() {
        var clock = WatchPartyClock()
        XCTAssertEqual(clock.offset, 0)
        // Server 10s ahead, 0.2s round trip split evenly.
        clock.record(clientSent: at(0), serverReceived: at(10.1), serverSent: at(10.1), clientReceived: at(0.2))
        XCTAssertEqual(clock.offset, 10, accuracy: 1e-9)
        // A slow, lopsided round trip would read 10.5; the fast sample stands.
        clock.record(clientSent: at(1), serverReceived: at(12.1), serverSent: at(12.1), clientReceived: at(2.2))
        XCTAssertEqual(clock.offset, 10, accuracy: 1e-9)
        // Impossible and stale-looking samples are dropped.
        clock.record(clientSent: at(3), serverReceived: at(13), serverSent: at(13.5), clientReceived: at(3.2))
        clock.record(clientSent: at(4), serverReceived: at(14), serverSent: at(14), clientReceived: at(10))
        XCTAssertEqual(clock.samples.count, 2)
        // The fast sample ages out after enough newer ones (0.5s, reading 10.5).
        for i in 0..<WatchPartyClock.sampleLimit {
            let sent = at(20 + Double(i))
            clock.record(clientSent: sent, serverReceived: sent.addingTimeInterval(10.75),
                         serverSent: sent.addingTimeInterval(10.75), clientReceived: sent.addingTimeInterval(0.5))
        }
        XCTAssertEqual(clock.samples.count, WatchPartyClock.sampleLimit)
        XCTAssertEqual(clock.offset, 10.5, accuracy: 1e-9)
        // On equal round trips the newer sample wins.
        clock.record(clientSent: at(40), serverReceived: at(50.6), serverSent: at(50.6), clientReceived: at(40.5))
        XCTAssertEqual(clock.offset, 10.35, accuracy: 1e-9)
    }

    func testDriftLoopFollowsTheAdvancingRoomPosition() {
        let reference = WatchPartyTransportCommand(commandId: "c", selectionRevision: 1, action: .play, positionSeconds: 100,
                                                    executeAt: at(10), issuedAt: at(9.5), playbackState: .playing)
        var room = WatchPartyRoom(roomId: "room")
        room.phase = .playing
        room.playbackState = .playing
        room.isPaused = false
        room.selectionRevision = 1
        func step(_ serverNow: Double, local: Double, room: WatchPartyRoom, playing: Bool = true,
                  since: TimeInterval = 5, reference: WatchPartyTransportCommand? = reference) -> WatchPartyCommandState.LoopStep {
            WatchPartyCommandState.loopStep(reference: reference, room: room, memberPlaying: playing,
                                            sourceTime: local, serverNow: at(serverNow), sinceCompleted: since)
        }
        // The target is the room's position now, not the command's fixed position.
        XCTAssertEqual(step(13, local: 102.5, room: room), .nudge(0.5))
        XCTAssertEqual(step(40, local: 129.5, room: room), .nudge(0.5))
        XCTAssertEqual(step(40, local: 130.25, room: room), .nudge(-0.25))
        // Just after a command it waits; when the room or member stops it resets.
        XCTAssertEqual(step(13, local: 102.5, room: room, since: 0.5), .wait)
        XCTAssertEqual(step(13, local: 102.5, room: room, playing: false), .reset)
        var paused = room
        paused.playbackState = .paused
        paused.isPaused = true
        XCTAssertEqual(step(13, local: 102.5, room: paused), .reset)
        var newSelection = room
        newSelection.selectionRevision = 2
        XCTAssertEqual(step(13, local: 102.5, room: newSelection), .reset)
        XCTAssertEqual(step(13, local: 102.5, room: room, reference: nil), .reset)
        // A held clock gets no rate write until it moves again.
        XCTAssertEqual(WatchPartyCommandState.loopStep(reference: reference, room: room, memberPlaying: true,
                                                       sourceTime: 102.5, serverNow: at(13), sinceCompleted: 5,
                                                       playheadAdvancing: false), .wait)
    }

    func testCommandPositionStepFollowsTheSharedRules() {
        func command(_ action: WatchPartyTransportAction, _ state: WatchPartyPlaybackState) -> WatchPartyTransportCommand {
            WatchPartyTransportCommand(commandId: "c", selectionRevision: 1, action: action, positionSeconds: 100,
                                       executeAt: at(10), issuedAt: at(9.5), playbackState: state)
        }
        typealias Step = WatchPartyCommandState.PositionStep
        func step(_ action: WatchPartyTransportAction, _ state: WatchPartyPlaybackState, playing: Bool,
                  drift: Double, reachable: Bool, host: Bool = false) -> Step {
            WatchPartyCommandState.positionStep(command(action, state), memberPlaying: playing, drift: drift,
                                                reachableInPlace: reachable,
                                                seekBand: WatchPartyCorrection.seekBand(isHost: host))
        }
        // A room seek always lands exactly, however small the drift.
        XCTAssertEqual(step(.seek, .waiting, playing: true, drift: 0.1, reachable: true), Step.roomSeek)
        // A playing member in a playing room converges; it never realigns.
        XCTAssertEqual(step(.play, .playing, playing: true, drift: 3, reachable: true), Step.correct)
        // A stopped member moves only for a cheap move or a large gap.
        XCTAssertEqual(step(.play, .playing, playing: false, drift: 3, reachable: false), Step.none)
        XCTAssertEqual(step(.play, .playing, playing: false, drift: 3, reachable: true), Step.realign)
        XCTAssertEqual(step(.pause, .paused, playing: true, drift: 0.8, reachable: true), Step.none)
        XCTAssertEqual(step(.pause, .paused, playing: true, drift: -6, reachable: false), Step.realign)
        // A stopped host moves from 2 seconds off even when the move rebuilds
        // the stream, where a guest waits for the nudge.
        XCTAssertEqual(step(.play, .playing, playing: false, drift: 3, reachable: false, host: true), Step.realign)
        XCTAssertEqual(step(.pause, .paused, playing: false, drift: -2.5, reachable: false, host: true), Step.realign)
        XCTAssertEqual(step(.pause, .paused, playing: false, drift: 1.5, reachable: false, host: true), Step.none)
    }

    func testAHostRunningARoomCommandSeeksFromTwoSecondsAndAGuestFromFive() {
        // A released server re-anchors the room to a host report more than
        // 2 seconds off, so a lagging host must not rely on the nudge.
        let host = WatchPartyCorrection.seekBand(isHost: true)
        let guest = WatchPartyCorrection.seekBand(isHost: false)
        XCTAssertEqual(host, 2)
        XCTAssertEqual(guest, WatchPartyCorrection.hardSeek)
        for drift in [2.1, -2.1, 4.9, -4.9] {
            XCTAssertTrue(WatchPartyCorrection.seeks(drift: drift, band: host), "host drift \(drift)")
            XCTAssertFalse(WatchPartyCorrection.seeks(drift: drift, band: guest), "guest drift \(drift)")
        }
        XCTAssertFalse(WatchPartyCorrection.seeks(drift: 1.9, band: host))
        XCTAssertTrue(WatchPartyCorrection.seeks(drift: 5.1, band: guest))
    }

    func testClockDropsSamplesFromBeforeTheDeviceClockStepped() {
        var clock = WatchPartyClock()
        clock.record(clientSent: at(0), serverReceived: at(10.1), serverSent: at(10.1), clientReceived: at(0.2))
        // The device clock jumps 3s ahead; the old fast sample can no longer be right.
        XCTAssertTrue(clock.record(clientSent: at(23), serverReceived: at(20.2), serverSent: at(20.2), clientReceived: at(23.4)))
        XCTAssertEqual(clock.samples.count, 1)
        XCTAssertEqual(clock.offset, -3, accuracy: 1e-9)
        // A LAN round trip that rounds below zero is a zero round trip, not a rejection.
        XCTAssertTrue(clock.record(clientSent: at(30), serverReceived: at(27.0005), serverSent: at(27.0015), clientReceived: at(30.0005)))
    }

    func testAStaleLoadStopsCountingAsInFlight() {
        var budget = WatchPartyReloadBudget()
        XCTAssertFalse(budget.inFlight(at: at(0)))
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        XCTAssertTrue(budget.inFlight(at: at(WatchPartyReloadBudget.staleAfter - 1)))
        XCTAssertFalse(budget.inFlight(at: at(WatchPartyReloadBudget.staleAfter)))
        // A load whose seek completed counts as landed even far past its aim.
        var completed = WatchPartyReloadBudget()
        _ = completed.begin(roomPosition: 100, at: at(0), duration: 0)
        completed.noteLoading()
        XCTAssertFalse(completed.landed(at: 104))
        completed.noteSeekCompleted()
        XCTAssertTrue(completed.landed(at: 104))
        XCTAssertFalse(completed.landed(at: 99))
        // A refused reanchor leaves the old stream playing; it did not move.
        XCTAssertTrue(WatchPartyReloadBudget.moved(from: 90, to: 104, toward: 100))
        XCTAssertTrue(WatchPartyReloadBudget.moved(from: 120, to: 101, toward: 100))
        XCTAssertFalse(WatchPartyReloadBudget.moved(from: 120, to: 120.5, toward: 100))
        XCTAssertFalse(WatchPartyReloadBudget.moved(from: 90, to: 90.4, toward: 100))
        // A refused forward load whose old stream kept playing for 4s only
        // played toward the aim; it did not move there.
        XCTAssertFalse(WatchPartyReloadBudget.moved(from: 90, played: 4, to: 94, toward: 100))
        XCTAssertTrue(WatchPartyReloadBudget.moved(from: 90, played: 4, to: 100.5, toward: 100))
        // Expiring it lets the next load start at once, as a stale load always could.
        budget.expire(at: at(WatchPartyReloadBudget.staleAfter))
        XCTAssertNil(budget.target)
        XCTAssertTrue(budget.allowed(at: at(WatchPartyReloadBudget.staleAfter)))
    }

    func testOnlyTheRoomSeekToTheHeldRequestReleasesIt() {
        // Skips to 110, 120 and 130: the room's seeks for the first two land
        // while 130 is still held, so the next skip builds on 130.
        var held: WatchPartyHeldSeek? = WatchPartyHeldSeek(target: 130, origin: 23)
        XCTAssertEqual(WatchPartyHeldSeek.roomSeek(to: 110, held: &held, from: 130).shown, 130)
        XCTAssertEqual(WatchPartyHeldSeek.roomSeek(to: 120, held: &held, from: 130).shown, 130)
        XCTAssertEqual(held, WatchPartyHeldSeek(target: 130, origin: 120))
        XCTAssertEqual(WatchPartyHeldSeek.roomSeek(to: 130, held: &held, from: 130).shown, 130)
        XCTAssertNil(held)
        // The server folds a repeat seek within a second into its waiting seek.
        XCTAssertTrue(WatchPartyHeldSeek(target: 130.6, origin: 23).isAnswered(byRoomSeekTo: 130))
        XCTAssertFalse(WatchPartyHeldSeek(target: 131.5, origin: 23).isAnswered(byRoomSeekTo: 130))
        // Without a request the room's seek is shown as it runs.
        var none: WatchPartyHeldSeek?
        let unheld = WatchPartyHeldSeek.roomSeek(to: 110, held: &none, from: 40)
        XCTAssertEqual(unheld.shown, 110)
        XCTAssertEqual(unheld.origin, 40)
    }

    func testANewerCommandReleasesAHeldRequestOnlyAfterItsRoomSeekArrived() {
        var held = WatchPartyHeldSeek(target: 130, origin: 23)
        // A command the room sent before its seek, such as a correction.
        XCTAssertFalse(held.isReleased(byCommandSeekingTo: nil))
        XCTAssertFalse(held.isReleased(byCommandSeekingTo: 110))
        held.seekArrived = true
        // The seek itself runs and answers the request.
        XCTAssertFalse(held.isReleased(byCommandSeekingTo: 130.5))
        // Any other command replaced that seek before it ran.
        XCTAssertTrue(held.isReleased(byCommandSeekingTo: nil))
        XCTAssertTrue(held.isReleased(byCommandSeekingTo: 110))
    }

    func testTheRoomSeekThatAnswersAHeldRequestStillRejectsTicksFromTheOldStream() {
        // The host asked for 120 while playing at 23, and the timeline shows
        // 120 already. The room's seek rebuilds the stream, whose first ticks
        // still come from the old position; they must not move the timeline back.
        var held: WatchPartyHeldSeek? = WatchPartyHeldSeek(target: 120, origin: 23)
        let answer = WatchPartyHeldSeek.roomSeek(to: 120, held: &held, from: 120)
        XCTAssertNil(held)
        XCTAssertEqual(answer.origin, 23)
        XCTAssertTrue(PlayerViewModel.isStaleSeekTick(23.5, origin: answer.origin, target: answer.shown))
        XCTAssertFalse(PlayerViewModel.isStaleSeekTick(120.2, origin: answer.origin, target: answer.shown))
        // In a burst, the stale ticks come from where the earlier room seek
        // sent the engine.
        var burst: WatchPartyHeldSeek? = WatchPartyHeldSeek(target: 130, origin: 23)
        _ = WatchPartyHeldSeek.roomSeek(to: 110, held: &burst, from: 130)
        let last = WatchPartyHeldSeek.roomSeek(to: 130, held: &burst, from: 130)
        XCTAssertTrue(PlayerViewModel.isStaleSeekTick(110.4, origin: last.origin, target: last.shown))
        XCTAssertFalse(PlayerViewModel.isStaleSeekTick(129.8, origin: last.origin, target: last.shown))
    }

    func testOnlyATargetReachableInPlaceCountsAsBuffered() {
        // Server HLS reports no forward buffer. A target outside the seek
        // window rebuilds the stream, so it goes through the load budget.
        XCTAssertFalse(WatchPartyCorrection.targetBuffered(105, local: 100, locallySeekable: false, forwardBuffer: nil))
        XCTAssertFalse(WatchPartyCorrection.targetBuffered(105, local: 100, locallySeekable: false, forwardBuffer: 30))
        XCTAssertFalse(WatchPartyCorrection.targetBuffered(95, local: 100, locallySeekable: false, forwardBuffer: 30))
        XCTAssertTrue(WatchPartyCorrection.targetBuffered(105, local: 100, locallySeekable: true, forwardBuffer: nil))
        XCTAssertTrue(WatchPartyCorrection.targetBuffered(105, local: 100, locallySeekable: true, forwardBuffer: 5))
        XCTAssertFalse(WatchPartyCorrection.targetBuffered(105, local: 100, locallySeekable: true, forwardBuffer: 4))
        XCTAssertTrue(WatchPartyCorrection.targetBuffered(95, local: 100, locallySeekable: true, forwardBuffer: 0))
    }

    func testOneLoadAtATimeAimsTheNextAheadByTheMeasuredLoadTime() {
        var budget = WatchPartyReloadBudget()
        XCTAssertTrue(budget.allowed(at: at(0)))
        XCTAssertEqual(budget.begin(roomPosition: 100, at: at(0), duration: 0), 100)
        XCTAssertFalse(budget.allowed(at: at(5)))

        // Until the load's seek is taken, even the target belongs to the
        // stream being replaced.
        XCTAssertFalse(budget.landed(at: 100))
        budget.noteLoading()
        XCTAssertFalse(budget.landed(at: 95))
        XCTAssertTrue(budget.landed(at: 100))
        budget.land(at: at(6))
        XCTAssertEqual(budget.lead, 6)
        XCTAssertFalse(budget.allowed(at: at(6 + WatchPartyReloadBudget.minInterval - 0.001)))
        XCTAssertTrue(budget.allowed(at: at(6 + WatchPartyReloadBudget.minInterval)))
        XCTAssertEqual(budget.begin(roomPosition: 200, at: at(20), duration: 0), 206)
    }

    func testEveryLoadHasItsOwnGeneration() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        let first = budget.generation
        budget.abandon(at: at(1))
        _ = budget.begin(roomPosition: 100, at: at(40), duration: 0)
        let second = budget.generation
        XCTAssertNotEqual(second, first)
        // Converging does not end a load in flight.
        budget.settle()
        XCTAssertEqual(budget.generation, second)
        budget.noteLoading()
        budget.land(at: at(42))
        XCTAssertNotEqual(budget.generation, second)
    }

    func testLeadNeverAimsPastTheEndOfTheMedia() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.noteLoading()
        budget.land(at: at(8))
        XCTAssertEqual(budget.lead, 8)
        XCTAssertEqual(budget.begin(roomPosition: 5_995, at: at(60), duration: 6_000), 6_000)
        XCTAssertEqual(budget.begin(roomPosition: 5_000, at: at(120), duration: 6_000), 5_008)
        // A room already past the reported end keeps its own position.
        XCTAssertEqual(budget.begin(roomPosition: 6_010, at: at(180), duration: 6_000), 6_010)
    }

    func testABackwardLoadDoesNotSettleOnTheStreamItReplaces() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.noteLoading()
        XCTAssertFalse(budget.landed(at: 105))
        XCTAssertTrue(budget.landed(at: 100.3))
    }

    func testLoadsBackOffUntilTheViewerConverges() {
        var budget = WatchPartyReloadBudget()
        var now = at(0)
        var intervals: [TimeInterval] = []
        for _ in 0..<5 {
            _ = budget.begin(roomPosition: 100, at: now, duration: 0)
            budget.land(at: now)
            intervals.append(budget.nextAllowedAt.timeIntervalSince(now))
            now = budget.nextAllowedAt
        }
        XCTAssertEqual(intervals, [10, 20, 40, 60, 60])

        budget.settle()
        XCTAssertTrue(budget.allowed(at: now))
        _ = budget.begin(roomPosition: 100, at: now, duration: 0)
        budget.land(at: now)
        XCTAssertEqual(budget.nextAllowedAt.timeIntervalSince(now), WatchPartyReloadBudget.minInterval)
    }

    func testASupersededLoadIsRetiredInsteadOfBlockingUntilStale() {
        var budget = WatchPartyReloadBudget()
        budget.retire(at: at(0))
        XCTAssertTrue(budget.allowed(at: at(0)), "Retiring with no load in flight changes nothing")

        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.noteLoading()
        let generation = budget.generation
        budget.retire(at: at(2))
        XCTAssertNil(budget.target)
        XCTAssertNotEqual(budget.generation, generation, "A late completion of the retired load cannot act")
        XCTAssertFalse(budget.landed(at: 100))
        XCTAssertFalse(budget.allowed(at: at(2 + WatchPartyReloadBudget.minInterval - 0.001)))
        XCTAssertTrue(budget.allowed(at: at(2 + WatchPartyReloadBudget.minInterval)),
            "The next load waits the backoff, not the 30-second stale window")
    }

    func testLeadIsBoundedAndAnUnlandedLoadStopsBlocking() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.land(at: at(60))
        XCTAssertEqual(budget.lead, WatchPartyReloadBudget.maxLead)

        _ = budget.begin(roomPosition: 100, at: at(100), duration: 0)
        XCTAssertFalse(budget.allowed(at: at(100 + WatchPartyReloadBudget.staleAfter - 0.001)))
        XCTAssertTrue(budget.allowed(at: at(100 + WatchPartyReloadBudget.staleAfter)))

        budget.abandon(at: at(200))
        XCTAssertNil(budget.target)
        XCTAssertFalse(budget.allowed(at: at(200)))
    }
}
