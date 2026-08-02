//
//  TrailerFetchCoordinatorTests.swift
//  SiloTests
//
//  State-machine tests for `TrailerFetchCoordinator` driven entirely by
//  scripted closures (the `AIJobPollerTests` approach): no `ContinuumAPI`,
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
        var response = TrailerRefreshResponse(status: "queued", nextAllowedAt: nil)
        var requestError: Error?
        /// Consulted per detail fetch, by 0-based fetch index.
        var details: (Int) -> ItemDetail = { _ in trailerTestDetail() }
        var detailError: Error?
    }

    private struct ScriptedFailure: Error {}

    /// A coordinator wired to `script`, with a fast cadence so the poll loop
    /// completes in milliseconds rather than minutes.
    private func makeCoordinator(
        _ script: Script,
        settledPollCount: Int = 3,
        windowSeconds: TimeInterval = 5
    ) -> TrailerFetchCoordinator {
        TrailerFetchCoordinator(
            request: {
                script.requestCount += 1
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
            settledPollCount: settledPollCount
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
        coordinator.start(baseline: trailerTestDetail()) {
            script.foundCallbackCount += 1
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
        coordinator.start(baseline: trailerTestDetail(videoKeys: ["k1"])) {
            script.foundCallbackCount += 1
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
        coordinator.start(baseline: trailerTestDetail()) {
            script.foundCallbackCount += 1
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
        coordinator.start(baseline: trailerTestDetail()) {
            script.foundCallbackCount += 1
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
