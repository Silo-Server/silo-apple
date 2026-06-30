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
        // The M5 seamless-swap variant: in production the VM performs the close
        // after the persisted selection lands; headless, we count it the same
        // (the coordinator has finished with the synthetic track either way).
        func closeLiveTrackAfterPersistedSelected(trackKey: String) {
            closeCount += 1; closedKeys.append(trackKey)
        }
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
        /// OWNED handoffs (auto-select): the shared latched handoff for a job
        /// this client started.
        let registerSelectCount: () -> Int
        /// REGISTER-ONLY handoffs (no auto-select): the `subtitle_ready`
        /// broadcast path for a track finished elsewhere. The descriptor carries
        /// the synthesized combined `index`, not the DB id, so we record that.
        let registerOnlyCount: () -> Int
        /// The combined `index` of the last register-only (`ready`) handoff.
        let lastRegisterOnlyIndex: () -> Int?
        let waitForRegisterSelectCount: (Int) async -> Void
        let waitForRegisterOnlyCount: (Int) async -> Void
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

        let counters = HandoffCounters()
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
            registerAndSelectDescriptor: { _ in counters.recordSelect() },
            registerDescriptorWithoutSelecting: { descriptor in
                counters.recordOnly(index: descriptor.index)
            },
            downloadedSubtitlesFetch: { _ in downloaded }
        )
        return Harness(
            controller: controller,
            coordinator: coordinator,
            sink: sink,
            controls: controls,
            registerSelectCount: { counters.selectCount },
            registerOnlyCount: { counters.onlyCount },
            lastRegisterOnlyIndex: { counters.lastOnlyIndex },
            waitForRegisterSelectCount: { count in await counters.waitForSelectCount(count) },
            waitForRegisterOnlyCount: { count in await counters.waitForOnlyCount(count) }
        )
    }

    /// Reference box so the controller's `@MainActor` register closures can
    /// mutate shared counters the test reads back (a `var` captured by an
    /// `@escaping @MainActor` closure isn't shareable across the boundary).
    @MainActor
    private final class HandoffCounters {
        private struct Waiter {
            let target: Int
            let continuation: CheckedContinuation<Void, Never>
        }

        var selectCount = 0
        var onlyCount = 0
        var lastOnlyIndex: Int?
        private var selectWaiters: [Waiter] = []
        private var onlyWaiters: [Waiter] = []

        func recordSelect() {
            selectCount += 1
            resumeSatisfiedWaiters(&selectWaiters, currentCount: selectCount)
        }

        func recordOnly(index: Int) {
            onlyCount += 1
            lastOnlyIndex = index
            resumeSatisfiedWaiters(&onlyWaiters, currentCount: onlyCount)
        }

        func waitForSelectCount(_ target: Int) async {
            guard selectCount < target else { return }
            await withCheckedContinuation { continuation in
                selectWaiters.append(Waiter(target: target, continuation: continuation))
            }
        }

        func waitForOnlyCount(_ target: Int) async {
            guard onlyCount < target else { return }
            await withCheckedContinuation { continuation in
                onlyWaiters.append(Waiter(target: target, continuation: continuation))
            }
        }

        private func resumeSatisfiedWaiters(
            _ waiters: inout [Waiter],
            currentCount: Int
        ) {
            var remaining: [Waiter] = []
            for waiter in waiters {
                if currentCount >= waiter.target {
                    waiter.continuation.resume()
                } else {
                    remaining.append(waiter)
                }
            }
            waiters = remaining
        }
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
    private func readyEvent(fileId: Int = 1, subtitleId: Int) -> PlaybackRealtimeSubtitleEvent {
        .ready(.init(fileId: fileId, subtitleId: subtitleId, language: "es", label: "Spanish"))
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
        await h.waitForRegisterSelectCount(1)

        // Poller arrives second with the same completion.
        h.controller.deliverPollerTerminalForTesting(completedJob(id: "42", resultSubtitleId: 555))

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
        await h.waitForRegisterSelectCount(1)

        XCTAssertEqual(h.registerSelectCount(), 1)
        XCTAssertEqual(h.coordinator.phase, .completed, "poller authority closed the live track")
        XCTAssertEqual(h.sink.closeCount, 1, "live track closed exactly once")

        // Websocket arrives second — must NOT double-register.
        h.controller.handle(completedEvent("ai-9", subtitleId: 777))
        h.controller.completeLivePersistedHandoff(subtitleId: 777)

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
        await h.waitForRegisterSelectCount(1)

        // FIX 2: the persisted track registers once AND the coordinator closes
        // the orphaned live track + reaches `.completed` (not stuck `.streaming`).
        XCTAssertEqual(h.registerSelectCount(), 1, "registered exactly once")
        XCTAssertEqual(h.coordinator.phase, .completed, "coordinator must not strand in .streaming")
        XCTAssertEqual(h.sink.closeCount, 1, "synthetic live track closed")
        XCTAssertTrue(h.sink.closedKeys.contains("ai-5"))
    }

    // MARK: - (c2) ready-broadcast dedup against the owned WS completion (M5 FIX 1)

    /// The server broadcasts `subtitle_ready` for a file to ALL its sessions —
    /// INCLUDING the session that just completed the job. When the websocket
    /// `completed` path registers the persisted track it does NOT write
    /// `activeJob.resultSubtitleId` (the poller does, ~1.5s later), so the
    /// back-to-back `subtitle_ready` for the SAME id would slip past the
    /// `activeJob.resultSubtitleId` guard and trigger a redundant second
    /// downloaded-subtitles fetch + register. The controller records the owned
    /// handoff's subtitle id at registration time and short-circuits `ready` on
    /// it, so the self-handoff broadcast is a no-op.
    func testReadyMatchingJustWebsocketCompletedJobDoesNotReregister() async {
        let h = makeHarness(downloaded: [persisted(id: 555)])
        // Accepted running job with NO result id yet — exactly the state the
        // websocket `completed` path runs in (poller hasn't snapshotted it).
        h.controller.seedAcceptedJobForTesting(runningJob(id: "42", resultSubtitleId: nil))
        h.controller.handle(started("ai-42"))
        h.controller.handle(cues("ai-42"))
        XCTAssertEqual(h.coordinator.phase, .streaming)

        // Websocket completes: registers the owned persisted track exactly once
        // and records its id as the owned handoff.
        h.controller.handle(completedEvent("ai-42", subtitleId: 555))
        h.controller.completeLivePersistedHandoff(subtitleId: 555)
        await h.waitForRegisterSelectCount(1)
        XCTAssertEqual(h.registerSelectCount(), 1, "owned WS completion registered once")

        // The server's `subtitle_ready` for that SAME id arrives right after. It
        // must be recognized as this client's own just-completed handoff and
        // skipped — NOT a second register on either path.
        h.controller.handle(readyEvent(subtitleId: 555))
        XCTAssertEqual(
            h.registerSelectCount(), 1,
            "ready for the just-WS-completed id must not trigger a second owned register"
        )
        XCTAssertEqual(
            h.registerOnlyCount(), 0,
            "ready for the just-WS-completed id must not take the register-only path either"
        )
    }

    /// A `subtitle_ready` for a DIFFERENT subtitle id (a translation finished
    /// elsewhere / on another device) is NOT the owned handoff, so it still
    /// registers — register-only (no auto-select). Guards against the dedup
    /// over-matching and swallowing legitimate broadcasts.
    func testReadyForDifferentIdStillRegisters() async {
        let h = makeHarness(downloaded: [persisted(id: 555), persisted(id: 900)])
        h.controller.seedAcceptedJobForTesting(runningJob(id: "42", resultSubtitleId: nil))
        h.controller.handle(started("ai-42"))
        h.controller.handle(cues("ai-42"))
        h.controller.handle(completedEvent("ai-42", subtitleId: 555))
        h.controller.completeLivePersistedHandoff(subtitleId: 555)
        await h.waitForRegisterSelectCount(1)
        XCTAssertEqual(h.registerSelectCount(), 1)

        // A different file-scoped subtitle becomes ready → register-only.
        h.controller.handle(readyEvent(subtitleId: 900))
        await h.waitForRegisterOnlyCount(1)
        XCTAssertEqual(h.registerSelectCount(), 1, "owned auto-select count unchanged")
        XCTAssertEqual(h.registerOnlyCount(), 1, "different ready id registered once (register-only)")
        // baseTrackCount (3) + position of id 900 in the listing (1) == combined index 4.
        XCTAssertEqual(h.lastRegisterOnlyIndex(), 4)
    }

    // MARK: - (d) early-frame buffering (M5)

    /// `started` + `cues` race ahead of the 202 (so `activeJob` isn't set yet):
    /// they must be buffered during the in-flight submit window, then replayed
    /// in order once the accepted job lands — so the coordinator engages the
    /// live cue experience (preparing → streaming) even on a fast LAN where the
    /// websocket beats the HTTP response.
    func testEarlyFramesBeforeAcceptAreBufferedThenReplayed() async {
        let h = makeHarness(downloaded: [persisted(id: 99)])

        // Submit is in flight; the 202 hasn't returned the job id yet.
        h.controller.beginSubmitWindowForTesting()

        // Early frames arrive over the websocket BEFORE `activeJob` is known.
        h.controller.handle(started("ai-77"))
        h.controller.handle(cues("ai-77"))

        // They are buffered (not dropped) and the coordinator hasn't engaged yet.
        XCTAssertEqual(h.controller.bufferedEarlyFrameCountForTesting, 2, "early frames buffered")
        XCTAssertEqual(h.coordinator.phase, .idle, "coordinator idle until the job lands")

        // The 202 lands: the buffered frames replay through the coordinator.
        h.controller.seedAcceptedJobForTesting(runningJob(id: "77"))

        XCTAssertEqual(h.controller.bufferedEarlyFrameCountForTesting, 0, "buffer drained after replay")
        XCTAssertEqual(h.coordinator.phase, .streaming, "replayed started+cues drove preparing→streaming")
        XCTAssertEqual(h.controls.isPlaying, true, "resumed on the replayed first cue batch")
    }

    /// Buffered frames whose `track_key` doesn't match the landed job are
    /// discarded (a stale racing job), and the matching ones still replay.
    func testEarlyFramesForOtherTrackKeyDiscardedOnAccept() async {
        let h = makeHarness(downloaded: [persisted(id: 1)])
        h.controller.beginSubmitWindowForTesting()

        // A frame for a different (stale) job key, plus the real one.
        h.controller.handle(started("ai-OTHER"))
        h.controller.handle(started("ai-3"))
        XCTAssertEqual(h.controller.bufferedEarlyFrameCountForTesting, 2)

        h.controller.seedAcceptedJobForTesting(runningJob(id: "3"))

        // Only `ai-3` replayed → coordinator installed exactly that track.
        XCTAssertEqual(h.controller.bufferedEarlyFrameCountForTesting, 0)
        XCTAssertEqual(h.coordinator.phase, .preparing, "matching started replayed (no cues yet)")
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
