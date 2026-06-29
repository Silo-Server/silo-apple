//
//  LiveSubtitleCoordinatorTests.swift
//  SiloTests
//
//  State-machine tests for `LiveSubtitleCoordinator` driven entirely through
//  fake `LivePlaybackControls` + `LiveSubtitleSink` seams and a manually-fired
//  clock. No libass, no websocket, no player.
//
//  Transitions under test (spec Data flow (e)):
//    started        → snapshot selection, pause if playing, install + select
//                     the live track, show "Preparing…", arm the 30s timer.
//    first cues     → feed cues, cancel the timer, resume (playhead-first).
//    safety timeout → resume + fail out + restore selection.
//    completed      → register the persisted track, close the live track.
//    failed         → close the live track, restore the prior selection,
//                     resume if we paused.
//

import XCTest
import Foundation
@testable import Silo

@MainActor
final class LiveSubtitleCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    /// Records control calls and lets a test script `isPlaying`.
    private final class FakeControls: LivePlaybackControls {
        var isPlaying: Bool
        private(set) var pauseCount = 0
        private(set) var playCount = 0
        private(set) var seeks: [Double] = []
        var time: Double = 100

        init(isPlaying: Bool) { self.isPlaying = isPlaying }

        func pause() { pauseCount += 1; isPlaying = false }
        func play() { playCount += 1; isPlaying = true }
        func seek(to seconds: Double) { seeks.append(seconds) }
        func currentTime() -> Double { time }
    }

    /// Records every sink interaction so tests can assert ordering + payloads.
    private final class FakeSink: LiveSubtitleSink {
        enum Call: Equatable {
            case install(trackKey: String, label: String?, language: String?)
            case feed(start: Double, end: Double, text: String)
            case selectLive(trackKey: String)
            case close(trackKey: String)
            case restore(Int64?)
            case registerPersisted(Int)
            case showPreparing
            case showFailure(String)
        }
        private(set) var calls: [Call] = []

        func installLiveTrack(trackKey: String, label: String?, language: String?) {
            calls.append(.install(trackKey: trackKey, label: label, language: language))
        }
        func feedCue(_ cue: PlaybackRealtimeSubtitleCue) {
            calls.append(.feed(start: cue.start, end: cue.end, text: cue.text))
        }
        func selectLive(trackKey: String) { calls.append(.selectLive(trackKey: trackKey)) }
        func closeLiveTrack(trackKey: String) { calls.append(.close(trackKey: trackKey)) }
        func restorePriorSelection(_ selection: Int64?) { calls.append(.restore(selection)) }
        func registerPersisted(subtitleId: Int) { calls.append(.registerPersisted(subtitleId)) }
        func showPreparingNotice() { calls.append(.showPreparing) }
        func showFailureNotice(_ message: String) { calls.append(.showFailure(message)) }

        var feedCount: Int { calls.filter { if case .feed = $0 { return true }; return false }.count }
        func contains(_ call: Call) -> Bool { calls.contains(call) }
    }

    /// Clock that hands the scheduled action back to the test to fire (or not)
    /// on demand, and records cancellation.
    private final class ManualClock: LiveSubtitleClock {
        final class Handle: LiveSubtitleCancellable {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        private(set) var lastHandle: Handle?
        private(set) var lastAction: (@MainActor () -> Void)?
        private(set) var lastInterval: TimeInterval?
        private(set) var scheduleCount = 0

        func scheduleSafetyResume(
            after seconds: TimeInterval,
            _ action: @escaping @MainActor () -> Void
        ) -> LiveSubtitleCancellable {
            scheduleCount += 1
            lastInterval = seconds
            lastAction = action
            let handle = Handle()
            lastHandle = handle
            return handle
        }

        /// Fire the most recently scheduled safety action (simulates timeout).
        func fireSafety() { lastAction?() }
    }

    // MARK: - Builders

    private func makeCoordinator(
        isPlaying: Bool,
        priorSelection: Int64?
    ) -> (LiveSubtitleCoordinator, FakeControls, FakeSink, ManualClock) {
        let controls = FakeControls(isPlaying: isPlaying)
        let sink = FakeSink()
        let clock = ManualClock()
        let coordinator = LiveSubtitleCoordinator(controls: controls, sink: sink, clock: clock)
        coordinator.selectionSnapshotProvider = { priorSelection }
        return (coordinator, controls, sink, clock)
    }

    private func started(_ trackKey: String) -> PlaybackRealtimeSubtitleEvent {
        .started(.init(fileId: 1, jobId: nil, trackKey: trackKey, language: "es", label: "Spanish", totalCues: 10))
    }
    private func cues(_ trackKey: String, _ cues: [(Double, Double, String)], done: Bool = false) -> PlaybackRealtimeSubtitleEvent {
        .cues(.init(trackKey: trackKey, cues: cues.map { PlaybackRealtimeSubtitleCue(start: $0.0, end: $0.1, text: $0.2) }, done: done, total: nil))
    }
    private func completed(_ trackKey: String, subtitleId: Int?) -> PlaybackRealtimeSubtitleEvent {
        .completed(.init(trackKey: trackKey, subtitleId: subtitleId, language: "es", label: "Spanish"))
    }
    private func failed(_ trackKey: String, _ message: String?) -> PlaybackRealtimeSubtitleEvent {
        .failed(.init(trackKey: trackKey, message: message))
    }

    // MARK: - started

    func testStartedPausesInstallsSelectsAndArmsTimer() {
        let (coordinator, controls, sink, clock) = makeCoordinator(isPlaying: true, priorSelection: 0x4000_0001)
        coordinator.handle(started("ai-7"))

        XCTAssertEqual(coordinator.phase, .preparing)
        XCTAssertEqual(controls.pauseCount, 1, "should pause when playing")
        XCTAssertEqual(controls.playCount, 0, "must not resume before first cue")
        XCTAssertTrue(sink.contains(.install(trackKey: "ai-7", label: "Spanish", language: "es")))
        XCTAssertTrue(sink.contains(.selectLive(trackKey: "ai-7")))
        XCTAssertTrue(sink.contains(.showPreparing))
        XCTAssertEqual(clock.scheduleCount, 1, "safety timer armed")
        XCTAssertEqual(clock.lastInterval, LiveSubtitleCoordinator.safetyResumeSeconds)
    }

    func testStartedWhenPausedDoesNotPauseAndWillNotResume() {
        let (coordinator, controls, sink, _) = makeCoordinator(isPlaying: false, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        XCTAssertEqual(controls.pauseCount, 0, "already paused — nothing to pause")

        // First cues must NOT resume a player the user had paused.
        coordinator.handle(cues("ai-7", [(10, 12, "hi")]))
        XCTAssertEqual(controls.playCount, 0, "must not resume a user-paused player")
        XCTAssertEqual(coordinator.phase, .streaming)
        XCTAssertEqual(sink.feedCount, 1)
    }

    // MARK: - first cues → resume + timer cancel

    func testFirstCuesResumesAndCancelsTimer() {
        let (coordinator, controls, sink, clock) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        let armedHandle = clock.lastHandle

        coordinator.handle(cues("ai-7", [(10, 12, "one"), (12, 14, "two")]))

        XCTAssertEqual(coordinator.phase, .streaming)
        XCTAssertEqual(controls.playCount, 1, "resume on first cues")
        XCTAssertEqual(sink.feedCount, 2)
        XCTAssertEqual(armedHandle?.cancelled, true, "safety timer cancelled on first cues")
    }

    func testEmptyFirstBatchDoesNotResume() {
        let (coordinator, controls, sink, clock) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))

        // A `done`-heartbeat with no cues must not trip the resume; the timer
        // stays armed so a job that never streams a cue still recovers.
        coordinator.handle(cues("ai-7", [], done: true))
        XCTAssertEqual(controls.playCount, 0)
        XCTAssertEqual(coordinator.phase, .preparing)
        XCTAssertEqual(clock.lastHandle?.cancelled, false)

        // Real cues then resume.
        coordinator.handle(cues("ai-7", [(10, 12, "real")]))
        XCTAssertEqual(controls.playCount, 1)
        XCTAssertEqual(coordinator.phase, .streaming)
    }

    func testSecondCueBatchDoesNotResumeAgain() {
        let (coordinator, controls, _, _) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        coordinator.handle(cues("ai-7", [(10, 12, "a")]))
        coordinator.handle(cues("ai-7", [(14, 16, "b")]))
        XCTAssertEqual(controls.playCount, 1, "resume exactly once")
    }

    // MARK: - safety timeout

    func testSafetyTimeoutResumesAndRestores() {
        let (coordinator, controls, sink, clock) = makeCoordinator(isPlaying: true, priorSelection: 0x4000_0002)
        coordinator.handle(started("ai-7"))

        // No cues arrive; fire the safety timer.
        clock.fireSafety()

        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertEqual(controls.playCount, 1, "resume on timeout")
        XCTAssertTrue(sink.contains(.close(trackKey: "ai-7")))
        XCTAssertTrue(sink.contains(.restore(0x4000_0002)))
        XCTAssertTrue(sink.calls.contains { if case .showFailure = $0 { return true }; return false })
    }

    func testSafetyTimeoutDoesNotFireAfterFirstCues() {
        let (coordinator, controls, _, clock) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        coordinator.handle(cues("ai-7", [(10, 12, "a")]))    // cancels + resumes
        XCTAssertEqual(controls.playCount, 1)

        // Even if a stale timer action fires, it must no-op (phase is .streaming).
        clock.fireSafety()
        XCTAssertEqual(coordinator.phase, .streaming)
        XCTAssertEqual(controls.playCount, 1, "no double resume from a stale timer")
    }

    // MARK: - completed → register + close (no restore)

    func testCompletedRegistersPersistedAndClosesLiveTrack() {
        let (coordinator, _, sink, _) = makeCoordinator(isPlaying: true, priorSelection: 0x4000_0003)
        coordinator.handle(started("ai-7"))
        coordinator.handle(cues("ai-7", [(10, 12, "a")]))
        coordinator.handle(completed("ai-7", subtitleId: 555))

        XCTAssertEqual(coordinator.phase, .completed)
        XCTAssertTrue(sink.contains(.registerPersisted(555)))
        XCTAssertTrue(sink.contains(.close(trackKey: "ai-7")))
        // On success we swap to the persisted track — we do NOT restore the
        // pre-job selection.
        XCTAssertFalse(sink.calls.contains { if case .restore = $0 { return true }; return false })
    }

    func testCompletedBeforeAnyCueStillResumes() {
        let (coordinator, controls, sink, _) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        // Instant completion (short clip) — never streamed a cue.
        coordinator.handle(completed("ai-7", subtitleId: 9))
        XCTAssertEqual(controls.playCount, 1, "completion must un-pause even with no cues")
        XCTAssertTrue(sink.contains(.registerPersisted(9)))
        XCTAssertEqual(coordinator.phase, .completed)
    }

    // MARK: - failed → restore + resume

    func testFailedClosesRestoresAndResumes() {
        let (coordinator, controls, sink, _) = makeCoordinator(isPlaying: true, priorSelection: 0x4000_0004)
        coordinator.handle(started("ai-7"))
        coordinator.handle(failed("ai-7", "model error"))

        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertEqual(controls.playCount, 1, "resume on failure")
        XCTAssertTrue(sink.contains(.close(trackKey: "ai-7")))
        XCTAssertTrue(sink.contains(.restore(0x4000_0004)))
        XCTAssertTrue(sink.contains(.showFailure("model error")))
    }

    // MARK: - stale track_key guard

    func testCuesForStaleTrackKeyIgnored() {
        let (coordinator, controls, sink, _) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        let feedsAfterStart = sink.feedCount

        // A batch for a DIFFERENT job must be ignored.
        coordinator.handle(cues("ai-OTHER", [(1, 2, "stale")]))
        XCTAssertEqual(sink.feedCount, feedsAfterStart, "stale track_key cues must not feed")
        XCTAssertEqual(controls.playCount, 0, "stale cues must not resume")
        XCTAssertEqual(coordinator.phase, .preparing)
    }

    func testCompletedForStaleTrackKeyIgnored() {
        let (coordinator, _, sink, _) = makeCoordinator(isPlaying: true, priorSelection: nil)
        coordinator.handle(started("ai-7"))
        coordinator.handle(cues("ai-7", [(10, 12, "a")]))
        coordinator.handle(completed("ai-OTHER", subtitleId: 1))
        XCTAssertFalse(sink.contains(.registerPersisted(1)), "stale completion must not register")
        XCTAssertEqual(coordinator.phase, .streaming, "stale completion must not advance phase")
    }

    func testEventsAfterTeardownIgnored() {
        let (coordinator, controls, sink, _) = makeCoordinator(isPlaying: true, priorSelection: 0x4000_0005)
        coordinator.handle(started("ai-7"))
        coordinator.teardown()
        XCTAssertEqual(coordinator.phase, .idle)
        let callsAfterTeardown = sink.calls.count

        // Late frames for the torn-down job must be dropped.
        coordinator.handle(cues("ai-7", [(1, 2, "late")]))
        coordinator.handle(completed("ai-7", subtitleId: 1))
        XCTAssertEqual(sink.calls.count, callsAfterTeardown, "no sink calls after teardown")
        XCTAssertEqual(controls.playCount, 0)
    }

    // MARK: - superseding started

    func testNewStartedSupersedesPreviousLiveJob() {
        let (coordinator, _, sink, _) = makeCoordinator(isPlaying: true, priorSelection: 0x4000_0006)
        coordinator.handle(started("ai-1"))
        coordinator.handle(started("ai-2"))

        // The first track is torn down before the second installs.
        XCTAssertTrue(sink.contains(.close(trackKey: "ai-1")))
        XCTAssertTrue(sink.contains(.install(trackKey: "ai-2", label: "Spanish", language: "es")))
        XCTAssertTrue(sink.contains(.selectLive(trackKey: "ai-2")))
        XCTAssertEqual(coordinator.phase, .preparing)

        // Now the new job drives normally.
        coordinator.handle(cues("ai-2", [(10, 12, "x")]))
        XCTAssertEqual(coordinator.phase, .streaming)
    }
}
