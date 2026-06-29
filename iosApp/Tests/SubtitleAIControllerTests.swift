//
//  SubtitleAIControllerTests.swift
//  SiloTests
//
//  Controller-level tests for the poller-vs-websocket completion race — the
//  highest-risk untested seam in the AI subtitle pipeline (M4 FIX 10). The
//  websocket `completed` path and the poller-authority terminal path BOTH route
//  through `completePersistedHandoff`, guarded by the `handoffJobId` latch, so
//  the persisted track must register EXACTLY once regardless of which driver
//  wins — and in every ordering the live coordinator must close its synthetic
//  track and reach `.completed` (so a dropped socket never strands the viewer
//  in `.streaming` with an orphaned live row).
//
//  Driven headless: a REAL `LiveSubtitleCoordinator` over fake controls/sink,
//  a stubbed handoff-listing fetch, and the controller's test seams that seed
//  `activeJob` without the network. No HTTP, no libass, no player.
//

import XCTest
import Foundation
@testable import Silo

@MainActor
final class SubtitleAIControllerTests: XCTestCase {

    // MARK: - Fakes (mirror LiveSubtitleCoordinatorTests' seams)

    private final class FakeControls: LivePlaybackControls {
        var isPlaying: Bool
        init(isPlaying: Bool) { self.isPlaying = isPlaying }
        func pause() { isPlaying = false }
        func play() { isPlaying = true }
    }

    private final class FakeSink: LiveSubtitleSink {
        private(set) var registerCount = 0
        private(set) var closeCount = 0
        private(set) var lastRegisteredId: Int?
        private(set) var closedKeys: [String] = []

        func installLiveTrack(trackKey: String, label: String?, language: String?) {}
        func feedCue(_ cue: PlaybackRealtimeSubtitleCue) {}
        func selectLive(trackKey: String) {}
        func closeLiveTrack(trackKey: String) { closeCount += 1; closedKeys.append(trackKey) }
        func restorePriorSelection(_ selection: Int64?) {}
        func registerPersisted(subtitleId: Int) { registerCount += 1; lastRegisteredId = subtitleId }
        func showPreparingNotice() {}
        func showFailureNotice(_ message: String) {}
    }

    /// Clock whose scheduled action is fired (or cancelled) on demand.
    private final class ManualClock: LiveSubtitleClock {
        final class Handle: LiveSubtitleCancellable {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        private(set) var lastAction: (@MainActor () -> Void)?
        func scheduleSafetyResume(
            after seconds: TimeInterval,
            _ action: @escaping @MainActor () -> Void
        ) -> LiveSubtitleCancellable {
            lastAction = action
            return Handle()
        }
    }

    // MARK: - Builders

    /// One harness: a real coordinator + controller wired to fakes. The
    /// controller's `registerAndSelectDescriptor` increments `registerSelectCount`
    /// (this is what the SHARED latched handoff invokes exactly once); the
    /// coordinator's own `registerPersisted` is recorded separately on the sink.
    private struct Harness {
        let controller: SubtitleAIController
        let coordinator: LiveSubtitleCoordinator
        let sink: FakeSink
        let controls: FakeControls
        let registerSelectCount: () -> Int
    }

    private func makeHarness(
        mediaFileId: Int = 1,
        downloaded: [DownloadedSubtitle],
        isPlaying: Bool = true
    ) -> Harness {
        let controls = FakeControls(isPlaying: isPlaying)
        let sink = FakeSink()
        let coordinator = LiveSubtitleCoordinator(
            controls: controls,
            sink: sink,
            clock: ManualClock(),
            selectionSnapshot: { nil }
        )

        var registerSelectCount = 0
        let controller = SubtitleAIController(
            mediaFileId: { mediaFileId },
            currentTime: { 0 },
            sessionId: { "sess-1" },
            realtimeUnavailable: { false },
            liveCoordinator: coordinator,
            handoffContext: {
                SubtitleAIController.HandoffContext(
                    sessionId: "sess-1",
                    baseTrackCount: 3,
                    resolveURL: { path in URL(string: "https://host\(path)") }
                )
            },
            registerAndSelectDescriptor: { _ in registerSelectCount += 1 },
            downloadedSubtitlesFetch: { _ in downloaded }
        )
        return Harness(
            controller: controller,
            coordinator: coordinator,
            sink: sink,
            controls: controls,
            registerSelectCount: { registerSelectCount }
        )
    }

    /// A persisted downloaded subtitle whose `id` matches a job's
    /// `result_subtitle_id` so the handoff can synthesize a descriptor.
    private func persisted(id: Int) -> DownloadedSubtitle {
        DownloadedSubtitle(id: id, mediaFileId: 1, provider: "p", language: "es", format: "subrip", releaseName: "r")
    }

    private func runningJob(id: String, resultSubtitleId: Int? = nil) -> SubtitleJob {
        aiJob(id: id, status: "running", resultSubtitleId: resultSubtitleId)
    }
    private func completedJob(id: String, resultSubtitleId: Int) -> SubtitleJob {
        aiJob(id: id, status: "completed", resultSubtitleId: resultSubtitleId)
    }

    private func started(_ trackKey: String) -> PlaybackRealtimeSubtitleEvent {
        .started(.init(fileId: 1, jobId: nil, trackKey: trackKey, language: "es", label: "Spanish", totalCues: 10))
    }
    private func cues(_ trackKey: String) -> PlaybackRealtimeSubtitleEvent {
        .cues(.init(trackKey: trackKey, cues: [PlaybackRealtimeSubtitleCue(start: 10, end: 12, text: "hi")], done: 1, total: 10))
    }
    private func completedEvent(_ trackKey: String, subtitleId: Int) -> PlaybackRealtimeSubtitleEvent {
        .completed(.init(trackKey: trackKey, subtitleId: subtitleId, language: "es", label: "Spanish"))
    }

    /// Pump the main run loop so the handoff's detached `Task` (the listing
    /// fetch → register) runs to completion before assertions.
    private func drainMainQueue() async {
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: - (a) websocket-completed-then-poller

    func testWebsocketCompletesThenPollerRegistersExactlyOnce() async {
        let h = makeHarness(downloaded: [persisted(id: 555)])
        let job = runningJob(id: "42", resultSubtitleId: nil)
        h.controller.seedAcceptedJobForTesting(job)

        // Live job starts + streams a cue (coordinator → .streaming).
        h.controller.handle(started("ai-42"))
        h.controller.handle(cues("ai-42"))
        XCTAssertEqual(h.coordinator.phase, .streaming)

        // Websocket wins: the coordinator's `completed` drives its own teardown,
        // and the sink-adapter callback (simulated here) routes the persisted id
        // through the controller's shared latched handoff.
        h.controller.handle(completedEvent("ai-42", subtitleId: 555))
        h.controller.completeLivePersistedHandoff(subtitleId: 555)
        await drainMainQueue()

        // Poller arrives second with the same completion.
        h.controller.deliverPollerTerminalForTesting(completedJob(id: "42", resultSubtitleId: 555))
        await drainMainQueue()

        XCTAssertEqual(h.registerSelectCount(), 1, "persisted track registered exactly once")
        XCTAssertEqual(h.coordinator.phase, .completed, "coordinator completed")
        XCTAssertEqual(h.controller.phase, .completed, "controller completed")
    }

    // MARK: - (b) poller-completed-then-websocket

    func testPollerCompletesThenWebsocketRegistersExactlyOnce() async {
        let h = makeHarness(downloaded: [persisted(id: 777)])
        h.controller.seedAcceptedJobForTesting(runningJob(id: "9"))
        h.controller.handle(started("ai-9"))
        h.controller.handle(cues("ai-9"))
        XCTAssertEqual(h.coordinator.phase, .streaming)

        // Poller wins.
        h.controller.deliverPollerTerminalForTesting(completedJob(id: "9", resultSubtitleId: 777))
        await drainMainQueue()

        XCTAssertEqual(h.registerSelectCount(), 1)
        XCTAssertEqual(h.coordinator.phase, .completed, "poller authority closed the live track")
        XCTAssertEqual(h.sink.closeCount, 1, "live track closed exactly once")

        // Websocket arrives second — must NOT double-register.
        h.controller.handle(completedEvent("ai-9", subtitleId: 777))
        h.controller.completeLivePersistedHandoff(subtitleId: 777)
        await drainMainQueue()

        XCTAssertEqual(h.registerSelectCount(), 1, "still registered exactly once after late websocket")
        XCTAssertEqual(h.coordinator.phase, .completed)
    }

    // MARK: - (c) poller-wins-after-socket-drop (FIX 2)

    func testPollerWinsAfterSocketDropClosesCoordinator() async {
        let h = makeHarness(downloaded: [persisted(id: 321)])
        h.controller.seedAcceptedJobForTesting(runningJob(id: "5"))

        // Live presentation is up and streaming when the socket silently drops.
        h.controller.handle(started("ai-5"))
        h.controller.handle(cues("ai-5"))
        XCTAssertEqual(h.coordinator.phase, .streaming)

        // The `completed` websocket frame is LOST (socket drop, no replay). Only
        // the poller reaches completion.
        h.controller.deliverPollerTerminalForTesting(completedJob(id: "5", resultSubtitleId: 321))
        await drainMainQueue()

        // FIX 2: the persisted track registers once AND the coordinator closes
        // the orphaned live track + reaches `.completed` (not stuck `.streaming`).
        XCTAssertEqual(h.registerSelectCount(), 1, "registered exactly once")
        XCTAssertEqual(h.coordinator.phase, .completed, "coordinator must not strand in .streaming")
        XCTAssertEqual(h.sink.closeCount, 1, "synthetic live track closed")
        XCTAssertTrue(h.sink.closedKeys.contains("ai-5"))
    }
}

// MARK: - Local job builder (no network)

/// Build a `SubtitleJob` from the REAL integer wire shape (`id` is a JSON
/// number), decoded exactly as `HTTPClient` would.
private func aiJob(id: String, status: String, resultSubtitleId: Int?) -> SubtitleJob {
    let resultField = resultSubtitleId.map { "\"result_subtitle_id\": \($0)," } ?? ""
    let json = """
    {
      "id": \(id),
      "media_file_id": 1,
      "kind": "translate",
      "source_index": 0,
      \(resultField)
      "status": "\(status)",
      "progress": \(status == "completed" ? 1 : 0)
    }
    """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try! d.decode(SubtitleJob.self, from: Data(json.utf8))
}
