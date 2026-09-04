//
//  TrailerFetchCoordinatorTests.swift
//  SiloTests
//
//  State-machine tests for `TrailerFetchCoordinator` driven entirely by
//  scripted closures (the `AIJobPollerTests` approach): no `SiloAPI`,
//  no network, no timers longer than a few milliseconds. Covers each of the
//  server's three outcomes, the "found" detection, exhaustion via the
//  settle counter, and `stop()` mid-poll.
//
//  Every wait is bounded, so a logic bug fails the assertion instead of
//  hanging the suite.
//

import XCTest
import Foundation
@testable import Silo

@MainActor
final class TrailerFetchCoordinatorTests: XCTestCase {

    // MARK: - Harness

    /// Records what the coordinator asked for and replies with a script.
    private final class Script {
        var requestCount = 0
        var detailFetchCount = 0
        var foundCallbackCount = 0
        /// The payloads handed to the found callback, so a test can assert
        /// the coordinator published what it observed rather than expecting
        /// the owner to re-fetch it.
        var foundDetails: [ItemDetail] = []
        var response = TrailerRefreshResponse(status: "queued", nextAllowedAt: nil)
        var requestError: Error?
        /// Held before the request answers, so a test can catch the
        /// coordinator in `.requesting`.
        var requestDelay: Duration?
        /// Consulted per detail fetch, by 0-based fetch index.
        var details: (Int) -> ItemDetail = { _ in trailerTestDetail() }
        var detailError: Error?
    }

    private struct ScriptedFailure: Error {}

    /// A coordinator wired to `script`, with a fast cadence so the poll loop
    /// completes in milliseconds rather than minutes.
    ///
    /// `minimumObservationSeconds` — the floor the settle counter may not
    /// conclude below in production — defaults to 0 here so the settle tests
    /// stay millisecond-fast. The floor's own behaviour is covered by the
    /// tests that pass it explicitly.
    private func makeCoordinator(
        _ script: Script,
        settledPollCount: Int = 3,
        windowSeconds: TimeInterval = 5,
        minimumObservationSeconds: TimeInterval = 0
    ) -> TrailerFetchCoordinator {
        TrailerFetchCoordinator(
            request: {
                script.requestCount += 1
                if let delay = script.requestDelay {
                    try await Task.sleep(for: delay)
                }
                if let error = script.requestError { throw error }
                return script.response
            },
            fetchDetail: {
                let index = script.detailFetchCount
                script.detailFetchCount += 1
                if let error = script.detailError { throw error }
                return script.details(index)
            },
            pollInterval: Duration.milliseconds(5),
            windowSeconds: windowSeconds,
            settledPollCount: settledPollCount,
            minimumObservationSeconds: minimumObservationSeconds
        )
    }

    /// Bounded spin until `condition` holds. Returns false on timeout rather
    /// than waiting forever, so a stuck state machine fails an assertion.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: - Queued → found

    func testQueuedThenFoundRunsTheFoundCallbackAndStops() async {
        let script = Script()
        script.response = TrailerRefreshResponse(status: "queued", nextAllowedAt: nil)
        // Nothing on the first two polls; trailers on the third.
        script.details = { index in
            index >= 2 ? trailerTestDetail(videoKeys: ["k1"]) : trailerTestDetail()
        }

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail()) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.requestCount, 1)
        XCTAssertEqual(script.foundCallbackCount, 1)
        // The message clears on success — the new rail is the feedback.
        XCTAssertNil(coordinator.statusMessage)

        // And the loop is genuinely finished: no further detail fetches.
        let settledFetches = script.detailFetchCount
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(script.detailFetchCount, settledFetches, "polling continued after .found")
    }

    func testTheFoundCallbackReceivesTheDetailTheTrailersWereObservedIn() async {
        // The owner applies this payload directly. Re-fetching instead would
        // let a transient failure leave the page on the old detail after the
        // run has already reported success and cleared its status.
        let script = Script()
        script.details = { index in
            index >= 1 ? trailerTestDetail(videoKeys: ["k1", "k2"]) : trailerTestDetail()
        }

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail()) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.foundDetails.count, 1)
        XCTAssertEqual(
            TrailerRail.supportedVideos(script.foundDetails.first?.videos).count,
            2,
            "the callback must receive the payload the trailers were seen in"
        )
    }

    func testANewLocalExtraCountsAsFoundEvenWithoutRemoteVideos() async {
        // A scanner-discovered extra that wasn't there when the user tapped
        // is a real result; one that was already there is not.
        let script = Script()
        script.details = { _ in trailerTestDetail(extraIds: ["extra:1", "extra:2"]) }

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail(extraIds: ["extra:1"]))

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
    }

    func testPreexistingExtrasAloneDoNotCountAsFound() async {
        let script = Script()
        script.details = { _ in trailerTestDetail(extraIds: ["extra:1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail(extraIds: ["extra:1"]))

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    // MARK: - Baseline-relative video detection

    func testPreexistingVideosAloneDoNotCountAsFound() async {
        // The regression this pins: an item that ALREADY has trailers used
        // to "find" them on the first poll tick (~3s), before the server
        // refresh could possibly have run — reporting success, skipping the
        // rest of the window, and spending the weekly slot for nothing.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k1", "k2"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["k1", "k2"]))

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    func testANewVideoOnTopOfANonEmptyBaselineCountsAsFound() async {
        let script = Script()
        script.details = { index in
            index >= 2
                ? trailerTestDetail(videoKeys: ["k1", "k2"])
                : trailerTestDetail(videoKeys: ["k1"])
        }

        let coordinator = makeCoordinator(script, settledPollCount: 100)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["k1"])) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.foundCallbackCount, 1)
    }

    func testUnplayableSitesDoNotCountAsFound() async {
        // The rails drop non-youtube videos, so a refresh that only returns
        // a Vimeo link changes nothing the user can see.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["v1"], videoSite: "vimeo") }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    func testGrowthIsMeasuredAgainstPlayableVideosOnly() async {
        // Baseline holds an unplayable video; a YouTube trailer arriving is
        // real growth even though the raw array only goes 1 → 2.
        let script = Script()
        script.details = { index in
            index >= 1
                ? trailerTestDetailMixed()
                : trailerTestDetail(videoKeys: ["v1"], videoSite: "vimeo")
        }

        let coordinator = makeCoordinator(script, settledPollCount: 100)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["v1"], videoSite: "vimeo"))

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
    }

    func testAReplacedTrailerCountsAsFoundAtAnUnchangedCount() async {
        // The refresh swapped a dead YouTube key for a working one: the array
        // stays 1 → 1, so a count comparison would call it "nothing", never
        // publish the payload, and end on "No trailers found" — with the
        // weekly slot already spent.
        let script = Script()
        script.details = { index in
            index >= 1 ? trailerTestDetail(videoKeys: ["fresh"]) : trailerTestDetail(videoKeys: ["stale"])
        }

        let coordinator = makeCoordinator(script, settledPollCount: 100)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["stale"])) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.foundCallbackCount, 1)
        XCTAssertEqual(
            TrailerRail.supportedVideos(script.foundDetails.first?.videos).first?.siteKey,
            "fresh"
        )
    }

    func testAReplacedExtraCountsAsFoundAtAnUnchangedCount() async {
        let script = Script()
        script.details = { index in
            index >= 1 ? trailerTestDetail(extraIds: ["extra:2"]) : trailerTestDetail(extraIds: ["extra:1"])
        }

        let coordinator = makeCoordinator(script, settledPollCount: 100)
        coordinator.start(baseline: trailerTestDetail(extraIds: ["extra:1"]))

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
    }

    func testAReorderedSetIsNotAFind() async {
        // Identity, not order: the server re-sorting the same two trailers
        // shows the user nothing new.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k2", "k1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["k1", "k2"]))

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    func testShrinkingToASubsetOfTheBaselineIsNotAFind() async {
        // A refresh that drops one of two known trailers left nothing new to
        // show, even though the payload changed.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["k1", "k2"]))

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    // MARK: - Platform trailer visibility

    func testRemoteOnlyGrowthIsNotAFindWhenRemoteCardsCannotBeShown() async {
        // tvOS without the YouTube app: the rail drops every remote card, so
        // reporting .found would clear the status over an unchanged rail.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 100)
        coordinator.start(
            baseline: trailerTestDetail(),
            remoteVideosDisplayable: false
        ) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .foundUnplayable }
        XCTAssertTrue(reached, "expected .foundUnplayable, got \(coordinator.phase)")
        XCTAssertEqual(script.foundCallbackCount, 0, "nothing renderable arrived")
        XCTAssertEqual(coordinator.statusMessage, "No playable trailers here")
        XCTAssertFalse(coordinator.isFetching)
    }

    func testNewExtrasStillCountWhenRemoteCardsCannotBeShown() async {
        // Local extras play natively on every platform, YouTube app or not.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k1"], extraIds: ["extra:1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 100)
        coordinator.start(
            baseline: trailerTestDetail(),
            remoteVideosDisplayable: false
        ) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.foundCallbackCount, 1)
    }

    func testHiddenRemoteVideosDoNotBlockAQuietExhaustion() async {
        // Nothing new at all, on a platform that hides remotes: still the
        // ordinary "No trailers found" ending, not the unplayable one.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(
            baseline: trailerTestDetail(videoKeys: ["k1"]),
            remoteVideosDisplayable: false
        )

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    // MARK: - Cooldown / disabled

    func testCooldownResolvesImmediatelyWithoutPolling() async {
        let next = Date.now.addingTimeInterval(3600)
        let script = Script()
        script.response = TrailerRefreshResponse(status: "cooldown", nextAllowedAt: next)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .cooldown(next) }
        XCTAssertTrue(reached, "expected .cooldown, got \(coordinator.phase)")
        XCTAssertEqual(script.detailFetchCount, 0, "cooldown must not poll")
        XCTAssertEqual(coordinator.statusMessage, "Trailers were checked recently")
        XCTAssertFalse(coordinator.isFetching)
    }

    func testCooldownWithoutATimestampStillResolves() async {
        let script = Script()
        script.response = TrailerRefreshResponse(status: "cooldown", nextAllowedAt: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .cooldown(nil) }
        XCTAssertTrue(reached, "expected .cooldown(nil), got \(coordinator.phase)")
    }

    func testDisabledResolvesImmediatelyWithoutPolling() async {
        let script = Script()
        script.response = TrailerRefreshResponse(status: "disabled", nextAllowedAt: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .disabled }
        XCTAssertTrue(reached, "expected .disabled, got \(coordinator.phase)")
        XCTAssertEqual(script.detailFetchCount, 0, "disabled must not poll")
        XCTAssertEqual(coordinator.statusMessage, "Trailers are disabled for this library")
    }

    func testUnknownStatusDoesNotPoll() async {
        let script = Script()
        script.response = TrailerRefreshResponse(status: "something_new", nextAllowedAt: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
        XCTAssertEqual(script.detailFetchCount, 0)
    }

    // MARK: - Request failure

    func testAThrownRequestIsReportedAsAFailureNotAsExhaustion() async {
        // The POST can time out *after* the server consumed the weekly slot
        // (15s idle timeout). Calling that "No trailers found" is a lie the
        // very next tap contradicts with "checked recently".
        let script = Script()
        script.requestError = ScriptedFailure()

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .requestFailed(rateLimited: false) }
        XCTAssertTrue(reached, "expected .requestFailed, got \(coordinator.phase)")
        XCTAssertEqual(script.detailFetchCount, 0)
        XCTAssertNotEqual(coordinator.statusMessage, "No trailers found")
        XCTAssertEqual(coordinator.statusMessage, "Couldn't reach the server — try again")
        XCTAssertFalse(coordinator.isFetching)
    }

    func testA429GetsItsOwnCopy() async {
        let script = Script()
        script.requestError = HTTPError.http(statusCode: 429, body: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .requestFailed(rateLimited: true) }
        XCTAssertTrue(reached, "expected rate-limited .requestFailed, got \(coordinator.phase)")
        XCTAssertEqual(coordinator.statusMessage, "Please wait a moment and try again")
    }

    func testANon429HTTPFailureUsesTheGenericCopy() async {
        let script = Script()
        script.requestError = HTTPError.http(statusCode: 503, body: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .requestFailed(rateLimited: false) }
        XCTAssertTrue(reached, "expected .requestFailed(false), got \(coordinator.phase)")
    }

    // MARK: - Exhaustion

    func testUnchangedDetailExhaustsViaTheSettleCounter() async {
        let script = Script()
        script.details = { _ in trailerTestDetail() }

        let coordinator = makeCoordinator(script, settledPollCount: 3)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
        // First poll seeds the signature, then 3 unchanged polls settle it.
        XCTAssertEqual(script.detailFetchCount, 4)
        XCTAssertEqual(coordinator.statusMessage, "No trailers found")
    }

    func testAChangingItemResetsTheSettleCounter() async {
        // The refresh is still landing writes (artwork, overview), so the
        // videos may yet follow — the counter must not settle early.
        let script = Script()
        script.details = { index in
            index >= 6
                ? trailerTestDetail(videoKeys: ["k1"])
                : trailerTestDetail(overview: "pass \(index)")
        }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertGreaterThanOrEqual(script.detailFetchCount, 7)
    }

    func testTransientFetchFailuresDoNotAdvanceTheSettleCounter() async {
        let script = Script()
        script.detailError = ScriptedFailure()

        // The window (1s at a 5ms cadence — room for ~200 polls) is what must
        // end this run. If failures advanced the counter it would stop after
        // 4 fetches instead.
        let coordinator = makeCoordinator(script, settledPollCount: 3, windowSeconds: 1)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
        XCTAssertGreaterThan(script.detailFetchCount, 4, "failures should keep polling until the window lapses")
    }

    func testTheSettleCounterCannotEndTheRunBeforeTheJobCouldHaveFinished() async {
        // There is no completion signal: five unchanged polls mean the
        // provider has been quiet, not that the queued refresh is done. Under
        // the minimum observation time an unchanged item must keep polling —
        // exiting there reports "No trailers found" over a slot that is
        // already spent, so the result can never be retrieved.
        let script = Script()
        script.details = { _ in trailerTestDetail() }

        // Settles immediately by count, but the floor holds the run open past
        // where the bare counter would have ended it.
        let coordinator = makeCoordinator(
            script,
            settledPollCount: 2,
            windowSeconds: 5,
            minimumObservationSeconds: 0.3
        )
        coordinator.start(baseline: trailerTestDetail())

        // 3 fetches is what the bare counter would have stopped at (seed + 2).
        let settleable = await waitUntil { script.detailFetchCount >= 3 }
        XCTAssertTrue(settleable)
        XCTAssertEqual(coordinator.phase, .polling, "settled out before the job could have finished")

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted after the floor, got \(coordinator.phase)")
        XCTAssertGreaterThan(
            script.detailFetchCount,
            3,
            "the floor should have bought more polls"
        )
    }

    func testALateResultIsStillFoundAfterTheSettleCounterWouldHaveGivenUp() async {
        // The case the floor exists for: a slow provider writes nothing for a
        // while, then lands the trailer. With the bare counter this reported
        // "No trailers found" ~18s in and the payload was never published.
        let script = Script()
        script.details = { index in
            index >= 12 ? trailerTestDetail(videoKeys: ["late"]) : trailerTestDetail()
        }

        let coordinator = makeCoordinator(
            script,
            settledPollCount: 2,
            windowSeconds: 5,
            minimumObservationSeconds: 0.5
        )
        coordinator.start(baseline: trailerTestDetail()) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let reached = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.foundCallbackCount, 1)
    }

    func testAnEarlyResultStillEndsTheRunImmediately() async {
        // The floor gates only the settle *exit*; it must never delay a
        // result. The common fast case is unchanged.
        let script = Script()
        script.details = { _ in trailerTestDetail(videoKeys: ["k1"]) }

        let coordinator = makeCoordinator(
            script,
            settledPollCount: 2,
            windowSeconds: 30,
            minimumObservationSeconds: 30
        )
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil(timeout: 2) { coordinator.phase == .found }
        XCTAssertTrue(reached, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.detailFetchCount, 1, "the first poll already had the answer")
    }

    func testTheFloorNeverOutlivesTheWindow() async {
        // A floor longer than the window must not wedge the run open: the
        // window is still the hard cap.
        let script = Script()
        script.details = { _ in trailerTestDetail() }

        let coordinator = makeCoordinator(
            script,
            settledPollCount: 2,
            windowSeconds: 0.3,
            minimumObservationSeconds: 60
        )
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil(timeout: 3) { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    func testTheShippedFloorSitsInsideTheShippedWindow() {
        // Both defaults are tied to the server's own 2-minute on-demand
        // refresh timeout; the floor has to leave polls on the table.
        XCTAssertLessThan(
            TrailerFetchCoordinator.defaultMinimumObservationSeconds,
            TrailerFetchCoordinator.defaultWindowSeconds
        )
        // And it must sit past where the bare settle counter would fire.
        let bareSettleSeconds =
            Double(TrailerFetchCoordinator.defaultSettledPollCount + 1)
            * (Double(TrailerFetchCoordinator.defaultPollInterval.components.seconds))
        XCTAssertGreaterThan(
            TrailerFetchCoordinator.defaultMinimumObservationSeconds,
            bareSettleSeconds
        )
    }

    func testWindowLapseEndsTheRun() async {
        let script = Script()
        script.details = { index in trailerTestDetail(overview: "pass \(index)") }

        // Every poll differs, so only the window can end this.
        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 0.2)
        coordinator.start(baseline: trailerTestDetail())

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
    }

    // MARK: - Cancellation

    func testStopMidPollHaltsPollingAndReturnsToIdle() async {
        // The retain-after-pop case: the poll task is not owned by SwiftUI's
        // `.task`, so leaving the page must stop it explicitly.
        let script = Script()
        script.details = { _ in trailerTestDetail(overview: "\(Date.now.timeIntervalSince1970)") }

        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 30)
        coordinator.start(baseline: trailerTestDetail()) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let polling = await waitUntil { script.detailFetchCount >= 2 }
        XCTAssertTrue(polling, "coordinator never started polling")
        XCTAssertEqual(coordinator.phase, .polling)

        coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)

        let afterStop = script.detailFetchCount
        try? await Task.sleep(for: .milliseconds(120))
        // At most the fetch already in flight when stop() landed may finish.
        XCTAssertLessThanOrEqual(
            script.detailFetchCount,
            afterStop + 1,
            "polling continued after stop()"
        )
        XCTAssertEqual(script.foundCallbackCount, 0)
    }

    func testStopOnAnIdleCoordinatorIsANoOp() {
        let coordinator = makeCoordinator(Script())
        coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// Was `testStopLeavesATerminalPhaseIntact`, which pinned the opposite.
    /// Its intent — "a terminal outcome must not be silently thrown away" —
    /// only holds *while the page is on screen*, where the pill's own 3s
    /// timer acknowledges it. Once the page goes away that timer dies with
    /// the view, so a surviving phase would replay its message for three
    /// seconds on a visit minutes later. Leaving the page now counts as
    /// having seen the outcome.
    func testStopAcknowledgesATerminalPhase() async {
        let script = Script()
        script.response = TrailerRefreshResponse(status: "disabled", nextAllowedAt: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())
        let reached = await waitUntil { coordinator.phase == .disabled }
        XCTAssertTrue(reached)

        coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle, "leaving the page acknowledges the outcome")
        XCTAssertNil(coordinator.statusMessage)
    }

    func testAnAcknowledgedTerminalIsNeverResurrectedByResume() async {
        let script = Script()
        script.response = TrailerRefreshResponse(status: "cooldown", nextAllowedAt: nil)

        let coordinator = makeCoordinator(script)
        coordinator.start(baseline: trailerTestDetail())
        let reached = await waitUntil { coordinator.phase == .cooldown(nil) }
        XCTAssertTrue(reached)

        coordinator.stop()
        coordinator.resumeIfInterrupted()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(script.detailFetchCount, 0, "a resolved run must not start polling")
    }

    // MARK: - Resume after interruption

    func testResumePicksUpAPollCancelledMidRunWithoutRePosting() async {
        // The mid-fetch playback case: the user plays the movie (or an
        // extra), `onDisappear` stops the poll, and coming back must resume
        // observing — but never re-POST, because the server already spent
        // the item's weekly slot on the first request.
        let script = Script()
        script.details = { index in
            index >= 4 ? trailerTestDetail(videoKeys: ["k1"]) : trailerTestDetail(overview: "p\(index)")
        }

        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 30)
        coordinator.start(baseline: trailerTestDetail()) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }

        let polling = await waitUntil { script.detailFetchCount >= 1 }
        XCTAssertTrue(polling, "coordinator never started polling")

        coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)

        coordinator.resumeIfInterrupted()
        XCTAssertEqual(coordinator.phase, .polling, "an interrupted poll must resume")

        let found = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(found, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.requestCount, 1, "resume must not re-POST the refresh")
        XCTAssertEqual(script.foundCallbackCount, 1)
    }

    func testResumePicksUpARunCancelledDuringTheRequestWithoutRePosting() async {
        // Leaving the page before the 202 lands: the server may already have
        // queued the work and spent the weekly slot, so the run must be
        // resumable — and resuming must poll rather than re-POST, or the
        // retry could only ever come back as "checked recently".
        let script = Script()
        script.requestDelay = .seconds(30)
        script.details = { index in
            index >= 2 ? trailerTestDetail(videoKeys: ["k1"]) : trailerTestDetail(overview: "p\(index)")
        }

        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 30)
        coordinator.start(baseline: trailerTestDetail()) { found in
            script.foundCallbackCount += 1
            script.foundDetails.append(found)
        }
        XCTAssertEqual(coordinator.phase, .requesting)
        let requested = await waitUntil { script.requestCount == 1 }
        XCTAssertTrue(requested, "the POST never went out")

        coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(script.detailFetchCount, 0, "the run never reached the poll loop")

        coordinator.resumeIfInterrupted()
        XCTAssertEqual(coordinator.phase, .polling, "an interrupted request must resume as a poll")

        let found = await waitUntil { coordinator.phase == .found }
        XCTAssertTrue(found, "expected .found, got \(coordinator.phase)")
        XCTAssertEqual(script.requestCount, 1, "resume must not re-POST the refresh")
        XCTAssertEqual(script.foundCallbackCount, 1)
    }

    func testAResumedRequestKeepsTheOriginalBaseline() async {
        // The baselines are captured before the POST goes out, so a run
        // interrupted during it resumes against the same starting point —
        // pre-existing trailers still must not read as a find.
        let script = Script()
        script.requestDelay = .seconds(30)
        script.details = { _ in trailerTestDetail(videoKeys: ["k1"]) }

        let coordinator = makeCoordinator(script, settledPollCount: 2)
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["k1"]))
        let requested = await waitUntil { script.requestCount == 1 }
        XCTAssertTrue(requested)

        coordinator.stop()
        coordinator.resumeIfInterrupted()

        let reached = await waitUntil { coordinator.phase == .exhausted }
        XCTAssertTrue(reached, "expected .exhausted, got \(coordinator.phase)")
        XCTAssertEqual(script.requestCount, 1)
    }

    func testResumeIsANoOpWhenNothingWasInterrupted() {
        let coordinator = makeCoordinator(Script())
        coordinator.resumeIfInterrupted()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testResumeIsANoOpWhileARunIsAlreadyGoing() async {
        let script = Script()
        script.details = { index in trailerTestDetail(overview: "p\(index)") }

        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 30)
        coordinator.start(baseline: trailerTestDetail())
        let polling = await waitUntil { coordinator.phase == .polling }
        XCTAssertTrue(polling)

        coordinator.resumeIfInterrupted()
        XCTAssertEqual(coordinator.phase, .polling)
        XCTAssertEqual(script.requestCount, 1)

        coordinator.stop()
    }

    func testAFreshStartSupersedesAnInterruptedPoll() async {
        // The user taps Find Trailers again rather than letting the page
        // resume: that re-POSTs, and the stale context must not survive to
        // be resumed on top of it later.
        let script = Script()
        script.details = { index in trailerTestDetail(overview: "p\(index)") }

        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 30)
        coordinator.start(baseline: trailerTestDetail())
        _ = await waitUntil { coordinator.phase == .polling }
        coordinator.stop()

        coordinator.start(baseline: trailerTestDetail())
        let polling = await waitUntil { coordinator.phase == .polling }
        XCTAssertTrue(polling)
        XCTAssertEqual(script.requestCount, 2, "an explicit retry re-POSTs")

        coordinator.stop()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testASecondStartWhileRunningIsIgnored() async {
        let script = Script()
        script.details = { _ in trailerTestDetail(overview: "\(Date.now.timeIntervalSince1970)") }

        let coordinator = makeCoordinator(script, settledPollCount: 100, windowSeconds: 30)
        coordinator.start(baseline: trailerTestDetail())
        coordinator.start(baseline: trailerTestDetail())

        let polling = await waitUntil { script.detailFetchCount >= 1 }
        XCTAssertTrue(polling)
        XCTAssertEqual(script.requestCount, 1, "a second start must not re-POST")

        coordinator.stop()
    }

    // MARK: - Display copy

    func testStatusMessageCoversEveryPhase() {
        let script = Script()
        let coordinator = makeCoordinator(script)

        XCTAssertNil(coordinator.statusMessage)
        XCTAssertFalse(coordinator.isFetching)

        script.response = TrailerRefreshResponse(status: "queued", nextAllowedAt: nil)
        coordinator.start(baseline: trailerTestDetail())
        XCTAssertEqual(coordinator.statusMessage, "Finding trailers…")
        XCTAssertTrue(coordinator.isFetching)
        coordinator.stop()
    }
}

/// Build an `ItemDetail` from JSON — it has no convenient memberwise call
/// site (dozens of fields), and decoding also exercises the real wire shape.
/// Free function so the scripted closures can call it without capturing the
/// test case.
private func trailerTestDetail(
    videoKeys: [String] = [],
    videoSite: String = "youtube",
    extraIds: [String] = [],
    overview: String = "base"
) -> ItemDetail {
    let videos = videoKeys
        .map { #"{"kind":"trailer","site":"\#(videoSite)","site_key":"\#($0)","is_official":true}"# }
        .joined(separator: ",")
    let extras = extraIds
        .map { #"{"content_id":"\#($0)","kind":"featurette"}"# }
        .joined(separator: ",")
    let json = """
    {
      "content_id": "movie:1",
      "type": "movie",
      "title": "Arrival",
      "overview": "\(overview)",
      "videos": [\(videos)],
      "extras": [\(extras)]
    }
    """
    return try! HTTPClient.makeJSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
}

/// One unplayable (vimeo) video plus one playable (youtube) one — the case
/// where the raw array count and the *renderable* count disagree.
private func trailerTestDetailMixed() -> ItemDetail {
    let json = """
    {
      "content_id": "movie:1",
      "type": "movie",
      "title": "Arrival",
      "overview": "base",
      "videos": [
        {"kind":"trailer","site":"vimeo","site_key":"v1","is_official":true},
        {"kind":"trailer","site":"youtube","site_key":"k1","is_official":true}
      ],
      "extras": []
    }
    """
    return try! HTTPClient.makeJSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
}
