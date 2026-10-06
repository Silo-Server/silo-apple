import Foundation
import XCTest
@testable import Silo

/// Server subtitle sync on the player: the status line, when a timing change
/// makes the player fetch a track's cues again, the sync card, the realtime
/// events, and refreshing saved offline subtitles.
@MainActor
final class SubtitleSyncTests: XCTestCase {
    private static let sidecarKey = "external-" + String(repeating: "ab", count: 32)
    private static let createdAt = "2026-01-02T03:04:05.678Z"

    nonisolated private static func job(
        _ id: String = "1",
        status: String,
        subtitleId: String? = nil,
        result: SubtitleTiming? = nil,
        phase: String? = nil,
        progress: Double? = nil,
        failure: String? = nil,
        createdAt: String = createdAt
    ) -> SubtitleSyncJob {
        SubtitleSyncJob(id: id, subtitleId: subtitleId, status: status, trigger: "manual", confidence: nil,
                        result: result, createdAt: createdAt, finishedAt: nil,
                        phase: phase, progress: progress, failure: failure)
    }

    nonisolated private static func subtitle(
        _ id: String = "7",
        timing: SubtitleTiming = .identity,
        status: String? = nil,
        result: SubtitleTiming? = nil
    ) -> DownloadedSubtitle {
        DownloadedSubtitle(
            id: id, mediaFileId: 42, language: "en", timing: timing,
            sync: status.map {
                SubtitleSyncJob(id: "1", subtitleId: id, status: $0, trigger: "auto", confidence: nil,
                                result: result, createdAt: createdAt, finishedAt: nil)
            }
        )
    }

    nonisolated private static func sidecar(
        timing: SubtitleTiming = .identity,
        sync: SubtitleSyncJob? = nil,
        language: String = "en"
    ) -> SubtitleSyncState {
        SubtitleSyncState(key: sidecarKey, mediaFileId: "42", source: "external", storedSubtitleId: nil,
                          language: language, format: "srt", label: "Night Train (2024).en.srt",
                          timing: timing, sync: sync)
    }

    // MARK: Status line

    func testStatusLineMatchesTheWebPlayer() {
        let shifted = SubtitleTiming(offsetMs: -3200, scale: 1)
        let label = SubtitleSyncLabel.status(for:)
        XCTAssertNil(label(Self.subtitle()))
        XCTAssertEqual(label(Self.subtitle(status: "running")), "Syncing…")
        XCTAssertEqual(label(Self.subtitle(timing: shifted, status: "synced", result: shifted)), "Synced \u{2212}3.2 s")
        XCTAssertEqual(label(Self.subtitle(status: "synced", result: shifted)), "Original timing")
        XCTAssertEqual(label(Self.subtitle(status: "already_synced")), "Already in sync")
        XCTAssertEqual(label(Self.subtitle(status: "no_match")), "Doesn't match this video")
        XCTAssertEqual(label(Self.subtitle(status: "failed")), "Sync failed")
        XCTAssertEqual(label(Self.subtitle(timing: SubtitleTiming(offsetMs: 1400, scale: 1))), "Timing adjusted +1.4 s")

        let pal = SubtitleTiming(offsetMs: 1400, scale: 25 / 23.976)
        XCTAssertEqual(label(Self.subtitle(timing: pal, status: "synced", result: pal)), "Synced +1.4 s · 25→23.976 fps")
        let drift = SubtitleTiming(offsetMs: -23700, scale: 1.0008)
        XCTAssertEqual(label(Self.subtitle(timing: drift, status: "synced", result: drift)), "Synced \u{2212}23.7 s · ×1.0008 speed")
        XCTAssertEqual(SubtitleSyncLabel.scale(25 / 23.976), "25→23.976 fps")
    }

    func testRunningJobReportsItsProgressAndPhase() {
        let running = Self.job(status: "running", phase: "analyzing", progress: 0.4)
        XCTAssertEqual(SubtitleSyncLabel.status(timing: .identity, sync: running), "Syncing… 40%")
        XCTAssertEqual(SubtitleSyncLabel.percent(running), 40)
        XCTAssertEqual(SubtitleSyncLabel.phase(running), "Listening to the audio…")
        XCTAssertEqual(SubtitleSyncLabel.phase(Self.job(status: "running", phase: "matching")), "Matching lines to speech…")
        XCTAssertEqual(SubtitleSyncLabel.phase(Self.job(status: "pending", phase: "queued")), "Waiting to start…")
        XCTAssertEqual(SubtitleSyncLabel.percent(Self.job(status: "running", progress: 1.7)), 100)
        XCTAssertNil(SubtitleSyncLabel.percent(Self.job(status: "synced")))
        XCTAssertNil(SubtitleSyncLabel.phase(Self.job(status: "failed")))
    }

    func testFinishedJobsExplainTheirResult() {
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        let result = SubtitleSyncLabel.result(timing:sync:)
        XCTAssertEqual(result(shifted, Self.job(status: "synced", result: shifted))?.text,
                       "Synced to the audio: \u{2212}3.0 s")
        XCTAssertNil(result(.identity, Self.job(status: "synced", result: shifted)), "a reset synced result says nothing")
        XCTAssertEqual(result(.identity, Self.job(status: "already_synced")), .init(text: "Already matches the audio."))
        XCTAssertEqual(result(.identity, Self.job(status: "no_match"))?.isWarning, true)
        XCTAssertEqual(result(.identity, Self.job(status: "failed", failure: "unavailable")),
                       .init(text: "The server is busy. Try again in a few minutes.", isWarning: true))
        XCTAssertEqual(SubtitleSyncLabel.failure("no_audio"), "This video has no audio Silo can read.")
        XCTAssertEqual(SubtitleSyncLabel.failure("subtitle_changed"), "The subtitle changed while it was syncing. Try again.")
        XCTAssertEqual(SubtitleSyncLabel.failure(nil), "Sync failed. Try again.")
        XCTAssertEqual(SubtitleSyncLabel.actionNote(isExternal: true),
                       "Matches the timing to the audio for everyone. The file itself isn't changed.")
    }

    // MARK: Model

    private final class Calls {
        var status = #"{"revision":"r","state":"available","allowed":true,"auto_sync":true,"external":true}"#
        var lists = 0
        var list: [SubtitleSyncState] = []
        var reads: [SubtitleSyncState] = []
        var resetResult: Result<SubtitleSyncState, Error> = .success(SubtitleSyncTests.sidecar())
        var syncJob = SubtitleSyncTests.job("2", status: "pending", phase: "queued")
        var syncError: Error?
        var readError: Error?
        /// Runs while a listing is on the wire, before it answers.
        var beforeListReturns: (() async -> Void)?
        /// Runs while a read is on the wire, before it answers.
        var beforeReadReturns: (() async -> Void)?
        /// Runs while a timing reset is on the wire, before it answers.
        var beforeResetReturns: (() async -> Void)?
    }

    private func model(_ calls: Calls, list: [SubtitleSyncState]) -> SubtitleSyncModel {
        calls.list = list
        let endpoints = SubtitleSyncEndpoints(
            list: { _ in
                calls.lists += 1
                let list = calls.list
                if let hook = calls.beforeListReturns { await hook() }
                return list
            },
            read: { _, _ in
                if let error = calls.readError { throw error }
                let state = calls.reads.removeFirst()
                if let hook = calls.beforeReadReturns { await hook() }
                return state
            },
            start: { _, _ in
                if let error = calls.syncError { throw error }
                return calls.syncJob
            },
            resetTiming: { _, _ in
                if let hook = calls.beforeResetReturns { await hook() }
                return try calls.resetResult.get()
            }
        )
        let model = SubtitleSyncModel(service: SubtitleSyncService(
            status: { try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSyncStatus.self, from: Data(calls.status.utf8)) },
            endpoints: { _ in endpoints }
        ))
        model.bind(mediaFileId: 42)
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Another file may be on another server, so binding it asks the server
    /// again what it supports instead of reusing the first answer.
    func testBindingAnotherFileProbesTheServerAgain() async {
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        await model.reload()
        XCTAssertTrue(model.isExternalSyncAvailable)

        calls.status = #"{"revision":"r","state":"disabled","allowed":true,"auto_sync":true,"external":true}"#
        model.bind(mediaFileId: 43)
        XCTAssertFalse(model.isSyncAvailable, "nothing is offered before the new server answers")
        await model.reload()
        XCTAssertFalse(model.isSyncAvailable)
        XCTAssertFalse(model.isExternalSyncAvailable)
        XCTAssertNil(model.entry(for: Self.sidecarKey))
    }

    /// A timing change the model reads (a reset, a finished poll) fetches
    /// the cues once; reading the same timing again does not.
    func testObservedTimingChangeRefetchesOnce() async {
        let shifted = SubtitleTiming(offsetMs: -3200, scale: 1)
        let calls = Calls()
        let model = model(calls, list: [Self.subtitle(timing: shifted, status: "synced", result: shifted).syncState])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }

        await model.reload()
        XCTAssertTrue(model.isSyncAvailable)
        XCTAssertEqual(model.entry(for: "stored-7")?.statusLabel, "Synced \u{2212}3.2 s")
        XCTAssertEqual(refetched, [], "the first read only records the timing")

        calls.resetResult = .success(Self.subtitle().syncState)
        await model.resetTiming(key: "stored-7")
        XCTAssertEqual(refetched, ["stored-7"])
        XCTAssertEqual(model.entry(for: "stored-7")?.canReset, false)

        calls.list = [Self.subtitle().syncState]
        await model.reload()
        XCTAssertEqual(refetched, ["stored-7"], "an unchanged timing is not fetched again")
    }

    /// The realtime event refetches right away; the read it triggers sees
    /// the new timing and must not ask a second time.
    func testRealtimeChangeRefetchesOnceWithItsFollowUpRead() async throws {
        let shifted = SubtitleTiming(offsetMs: -3200, scale: 1)
        let calls = Calls()
        calls.reads = [Self.subtitle(timing: shifted, status: "synced", result: shifted).syncState]
        let model = model(calls, list: [Self.subtitle().syncState])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }
        await model.reload()

        model.timingChanged(key: "stored-7")
        XCTAssertEqual(refetched, ["stored-7"])
        try await waitUntil { model.entry(for: "stored-7")?.state.timing == shifted }
        XCTAssertEqual(model.entry(for: "stored-7")?.state.timing, shifted)
        XCTAssertEqual(refetched, ["stored-7"])
    }

    /// A sync update carrying the applied timing fetches the cues; the
    /// `subtitle_timing_changed` that follows it does not fetch them again.
    func testSyncUpdateThenTimingChangeRefetchesOnce() async throws {
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        let calls = Calls()
        calls.reads = [Self.sidecar(timing: shifted, sync: Self.job("2", status: "synced", result: shifted))]
        let model = model(calls, list: [Self.sidecar()])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }
        await model.reload()

        model.syncUpdated(try Self.syncUpdate(status: "synced", offset: -3010))
        XCTAssertEqual(refetched, [Self.sidecarKey])
        XCTAssertEqual(model.statusLabel(for: Self.sidecarKey), "Synced \u{2212}3.0 s")

        model.timingChanged(key: Self.sidecarKey)
        try await waitUntil { calls.reads.isEmpty }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(refetched, [Self.sidecarKey])
    }

    /// Two separate timing changes in quick succession fetch the cues twice:
    /// only a change whose timing a sync update already reported is coalesced.
    func testBackToBackTimingChangesEachRefetch() async throws {
        let calls = Calls()
        calls.reads = [Self.sidecar(), Self.sidecar()]
        let model = model(calls, list: [Self.sidecar()])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }
        await model.reload()
        model.timingChanged(key: Self.sidecarKey)
        model.timingChanged(key: Self.sidecarKey)
        XCTAssertEqual(refetched, [Self.sidecarKey, Self.sidecarKey])
    }

    func testSyncUpdateShowsProgressAndUnknownKeysReloadEverything() async throws {
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        await model.reload()
        XCTAssertEqual(calls.lists, 1)

        model.syncUpdated(try Self.syncUpdate(status: "running", offset: 0, phase: "analyzing", progress: 0.15))
        XCTAssertEqual(model.statusLabel(for: Self.sidecarKey), "Syncing… 15%")
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.isInProgress, true)

        model.syncUpdated(try Self.syncUpdate(key: "stored-9", status: "running", offset: 0))
        try await waitUntil { calls.lists == 2 }
        XCTAssertEqual(calls.lists, 2)
    }

    /// A realtime update after a reset is newer than the reset's answer:
    /// the answer is dropped and the subtitle read again.
    func testResetAnswerOlderThanARealtimeUpdateIsDropped() async throws {
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        let other = SubtitleTiming(offsetMs: 500, scale: 1)
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar(timing: shifted)])
        model.onTimingChanged = { _ in }
        await model.reload()
        let update = try Self.syncUpdate(jobId: "9", status: "synced", offset: 500)
        calls.reads = [Self.sidecar(timing: other)]
        calls.resetResult = .success(Self.sidecar())
        // Another viewer's change lands while the reset is on the wire.
        calls.beforeResetReturns = { await MainActor.run { model.syncUpdated(update) } }
        await model.resetTiming(key: Self.sidecarKey)
        try await waitUntil { calls.reads.isEmpty }
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.state.timing, other)
    }

    func testRefusedSyncExplainsItself() async {
        let calls = Calls()
        calls.syncError = APIv2Error.httpStatus(403)
        let model = model(calls, list: [Self.sidecar()])
        await model.reload()
        await model.requestSync(key: Self.sidecarKey)
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.isForbidden, true)
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.isBusy, false)
        XCTAssertEqual(model.forbiddenMessage, "This server doesn't allow changing subtitle timing.")

        calls.syncError = APIv2Error.httpStatus(422)
        await model.requestSync(key: Self.sidecarKey)
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.isUnsupported, true)
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.error, "This format can't be synced.")
    }

    /// A server that predates sync keys refuses everyone but the subtitle's
    /// owner and admins; the explanation says so.
    func testStoredOnlyServerExplainsItsOwnerRule() async {
        let calls = Calls()
        calls.status = #"{"revision":"r","state":"available","allowed":true,"auto_sync":true}"#
        calls.syncError = APIv2Error.httpStatus(403)
        let model = model(calls, list: [Self.subtitle().syncState])
        await model.reload()
        await model.requestSync(key: "stored-7")
        XCTAssertEqual(model.forbiddenMessage,
                       "Only the person who added this subtitle or an admin can change its timing.")
        XCTAssertFalse(model.isExternalSyncAvailable)
    }

    func testUnavailableSyncHidesEverything() async {
        let calls = Calls()
        calls.status = #"{"revision":"r","state":"disabled","allowed":true,"auto_sync":true,"external":true}"#
        let shifted = SubtitleTiming(offsetMs: 900, scale: 1)
        let model = model(calls, list: [Self.sidecar(timing: shifted)])
        await model.reload()
        XCTAssertFalse(model.isSyncAvailable)
        XCTAssertEqual(calls.lists, 0, "nothing is read for a server that cannot sync")
        XCTAssertNil(model.statusLabel(for: Self.sidecarKey))
    }

    func testSidecarsNeedTheExternalCapability() async {
        let calls = Calls()
        calls.status = #"{"revision":"r","state":"available","allowed":true,"auto_sync":true,"external":false}"#
        let model = model(calls, list: [Self.sidecar(), Self.subtitle().syncState])
        await model.reload()
        let sidecar = try? XCTUnwrap(model.entry(for: Self.sidecarKey))
        let stored = try? XCTUnwrap(model.entry(for: "stored-7"))
        XCTAssertEqual(sidecar.map(model.canSync), false)
        XCTAssertEqual(stored.map(model.canSync), true)
    }

    func testAnotherFileDropsEverything() async {
        let model = model(Calls(), list: [Self.sidecar()])
        await model.reload()
        XCTAssertNotNil(model.entry(for: Self.sidecarKey))
        model.bind(mediaFileId: 43)
        XCTAssertNil(model.entry(for: Self.sidecarKey))
        XCTAssertNil(model.notice)
    }

    /// The viewer's own sync on the track on screen: progress, then
    /// "Applying new timing…" until the reloaded cues finish loading, then
    /// the result.
    func testOwnSyncOnScreenReportsProgressThenTheAppliedResult() async throws {
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        model.onTimingChanged = { _ in }
        await model.reload()
        model.setActiveTrack(key: Self.sidecarKey)

        await model.requestSync(key: Self.sidecarKey)
        XCTAssertEqual(model.notice?.tone, .progress)
        XCTAssertEqual(model.notice?.title, "Syncing English subtitles")
        XCTAssertEqual(model.notice?.detail, "Waiting to start…")
        XCTAssertEqual(model.notice?.percent, 0)

        model.syncUpdated(try Self.syncUpdate(jobId: "2", status: "running", offset: 0, phase: "analyzing", progress: 0.3))
        XCTAssertEqual(model.notice?.percent, 30)
        XCTAssertEqual(model.notice?.detail, "Listening to the audio…")

        model.syncUpdated(try Self.syncUpdate(jobId: "2", status: "synced", offset: -3010))
        XCTAssertEqual(model.notice?.title, "Applying new timing…")
        model.setActiveTrackLoading(true)
        XCTAssertEqual(model.notice?.title, "Applying new timing…")
        model.setActiveTrackLoading(false)
        XCTAssertEqual(model.notice, SubtitleSyncNotice(id: "2", tone: .success, title: "Subtitles synced",
                                                        detail: "\u{2212}3.0 s"))
    }

    /// The automatic sync of a subtitle the viewer just downloaded is
    /// reported like one they asked for.
    func testDownloadedSubtitleAutoSyncIsReported() async throws {
        let calls = Calls()
        let model = model(calls, list: [])
        await model.reload()
        model.remember(DownloadedSubtitle(id: "9", mediaFileId: 42, language: "fr",
            sync: Self.job("4", status: "pending", subtitleId: "9", phase: "queued")))
        XCTAssertEqual(model.notice?.title, "Syncing French subtitles")
        model.syncUpdated(try Self.syncUpdate(key: "stored-9", jobId: "4", status: "no_match", offset: 0))
        XCTAssertEqual(model.notice?.tone, .warning)
        XCTAssertEqual(model.notice?.title, "French subtitles don't match the audio")
    }

    /// A listing sent before the job's outcome arrived over realtime
    /// describes it as still running; it must not bring the progress back
    /// or fetch the cues again.
    func testReadSentBeforeARealtimeUpdateIsDropped() async throws {
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }
        await model.reload()
        model.setActiveTrack(key: Self.sidecarKey)
        await model.requestSync(key: Self.sidecarKey)

        calls.list = [Self.sidecar(sync: Self.job("2", status: "running", phase: "analyzing", progress: 0.95))]
        let outcome = try Self.syncUpdate(status: "synced", offset: -3010)
        calls.beforeListReturns = { await MainActor.run { model.syncUpdated(outcome) } }
        await model.reload()

        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.job?.status, "synced")
        XCTAssertEqual(refetched, [Self.sidecarKey], "the stale listing fetched the cues again")
        XCTAssertEqual(model.notice?.title, "Applying new timing…")
    }

    /// A realtime update for a subtitle the listing on the wire does not know
    /// yet asks for another listing; it runs once the first one answers,
    /// which dropped that subtitle as superseded.
    func testUpdateDuringAListingGetsItsOwnListing() async throws {
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        let update = try Self.syncUpdate(status: "running", offset: 0, phase: "analyzing", progress: 0.3)
        calls.beforeListReturns = {
            calls.beforeListReturns = nil
            await MainActor.run { model.syncUpdated(update) }
            // Let the reload the update asked for find this one in flight.
            try? await Task.sleep(for: .milliseconds(50))
        }
        await model.reload()
        try await waitUntil { model.entry(for: Self.sidecarKey) != nil }
        XCTAssertEqual(calls.lists, 2)
        XCTAssertNotNil(model.entry(for: Self.sidecarKey))
    }

    /// A second timing change during a read reads the subtitle again once
    /// the first read answers, which it drops as stale.
    func testChangeDuringAReadGetsItsOwnRead() async throws {
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        model.onTimingChanged = { _ in }
        await model.reload()
        calls.reads = [Self.sidecar(), Self.sidecar(timing: shifted, sync: Self.job("3", status: "synced", result: shifted))]
        calls.beforeReadReturns = {
            calls.beforeReadReturns = nil
            await MainActor.run { model.timingChanged(key: Self.sidecarKey) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        model.timingChanged(key: Self.sidecarKey)
        try await waitUntil { model.entry(for: Self.sidecarKey)?.state.timing == shifted }
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.state.timing, shifted)
        XCTAssertTrue(calls.reads.isEmpty)
    }

    /// A poll that finds the subtitle gone stops, and the progress card of a
    /// job nobody can follow any more leaves; a failed read keeps polling.
    func testLostSubtitleEndsItsProgressCard() async throws {
        XCTAssertTrue(SubtitleSyncModel.stopsPolling(APIv2Error.httpStatus(404)))
        XCTAssertTrue(SubtitleSyncModel.stopsPolling(APIv2Error.httpStatus(403)))
        XCTAssertFalse(SubtitleSyncModel.stopsPolling(APIv2Error.httpStatus(503)))
        XCTAssertFalse(SubtitleSyncModel.stopsPolling(URLError(.timedOut)))

        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        model.onTimingChanged = { _ in }
        await model.reload()
        await model.requestSync(key: Self.sidecarKey)
        XCTAssertEqual(model.notice?.tone, .progress)

        calls.readError = APIv2Error.httpStatus(404)
        model.timingChanged(key: Self.sidecarKey)
        try await waitUntil { model.notice == nil }
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.entry(for: Self.sidecarKey)?.pollExpired, true)
    }

    // MARK: Feedback

    func testFeedbackNeverReopensAJobItAnnounced() {
        var feedback = SubtitleSyncFeedback()
        feedback.step(.init(watched: Self.watched("running", progress: 0.5)))
        feedback.step(.init(watched: Self.watched("no_match")))
        feedback.step(.init(watched: Self.watched("running", progress: 0.95)))
        XCTAssertEqual(feedback.notice?.tone, .warning, "a stale running read replaced the outcome")
    }

    private static func watched(_ status: String, key: String = sidecarKey, jobId: String = "2",
                                timing: SubtitleTiming = .identity, revision: Int = 0,
                                failure: String? = nil, progress: Double? = nil) -> SubtitleSyncFeedback.Watched {
        SubtitleSyncFeedback.Watched(key: key, name: "English",
            job: job(jobId, status: status, progress: progress, failure: failure), timing: timing, revision: revision)
    }

    func testFeedbackAnnouncesOutcomesOfJobsOffScreen() {
        var feedback = SubtitleSyncFeedback()
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        feedback.step(.init(watched: Self.watched("running", progress: 0.6)))
        XCTAssertEqual(feedback.notice?.percent, 60)
        feedback.step(.init(watched: Self.watched("synced", timing: shifted, revision: 1)))
        XCTAssertEqual(feedback.notice, SubtitleSyncNotice(id: "2", tone: .success, title: "English subtitles synced",
                                                           detail: "\u{2212}3.0 s"))
        XCTAssertNil(feedback.applying, "a track not on screen has nothing to apply")

        var others = SubtitleSyncFeedback()
        others.step(.init(watched: Self.watched("already_synced", jobId: "3")))
        XCTAssertEqual(others.notice?.title, "English subtitles already match the audio")
        XCTAssertEqual(others.notice?.tone, .info)
        others.step(.init(watched: Self.watched("failed", jobId: "4", failure: "unavailable")))
        XCTAssertEqual(others.notice, SubtitleSyncNotice(id: "4", tone: .warning, title: "Couldn't sync English subtitles",
                                                         detail: "The server is busy. Try again in a few minutes."))
        others.step(.init(watched: Self.watched("no_match", jobId: "5")))
        XCTAssertEqual(others.notice?.detail, "They're probably for another release. The timing wasn't changed.")
    }

    /// A load that began before the timing changed shows the old cues; only
    /// a load that finishes after the new cue revision counts as applied.
    func testFeedbackWaitsForTheReloadedCues() {
        var feedback = SubtitleSyncFeedback()
        let key = Self.sidecarKey
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        let synced = Self.job("2", status: "synced", result: shifted)
        feedback.step(.init(watched: Self.watched("running"), activeKey: key, activeRevision: 0,
                            activeJob: Self.job("2", status: "running"), activeWatchedJobId: "2",
                            isActiveTrackLoading: true))
        // The synced job bumps the revision while the old load is still finishing.
        feedback.step(.init(watched: Self.watched("synced", timing: shifted, revision: 1), activeKey: key,
                            activeRevision: 1, activeJob: synced, activeWatchedJobId: "2", isActiveTrackLoading: true))
        XCTAssertEqual(feedback.notice?.title, "Applying new timing…")
        feedback.step(.init(watched: Self.watched("synced", timing: shifted, revision: 1), activeKey: key,
                            activeRevision: 1, activeJob: synced, activeWatchedJobId: "2", isActiveTrackLoading: false))
        XCTAssertEqual(feedback.notice?.title, "Subtitles synced",
                       "the load that ended belongs to revision 1, after the job started at 0")
    }

    func testFeedbackFinishesApplyingWhenTheViewerSwitchesTracks() {
        var feedback = SubtitleSyncFeedback()
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        feedback.step(.init(watched: Self.watched("running"), activeKey: Self.sidecarKey))
        feedback.step(.init(watched: Self.watched("synced", timing: shifted, revision: 1), activeKey: Self.sidecarKey,
                            activeRevision: 1))
        XCTAssertNotNil(feedback.applying)
        feedback.step(.init(watched: Self.watched("synced", timing: shifted, revision: 1), activeKey: "stored-7"))
        XCTAssertNil(feedback.applying)
        XCTAssertEqual(feedback.notice?.title, "Subtitles synced")
    }

    /// Someone else's timing change to the track on screen shows a short
    /// note once its new cues load; the viewer's own sync does not.
    func testFeedbackNotesForeignTimingChangesOnce() {
        var feedback = SubtitleSyncFeedback()
        let key = Self.sidecarKey
        let manual = Self.job("8", status: "synced")
        feedback.step(.init(activeKey: key, activeRevision: 0, activeJob: manual, isActiveKnown: true))
        feedback.step(.init(activeKey: key, activeRevision: 1, activeJob: manual, isActiveKnown: true))
        XCTAssertNil(feedback.notice, "nothing shows before the new cues load")
        feedback.step(.init(activeKey: key, activeRevision: 1, activeJob: manual, isActiveKnown: true,
                            isActiveTrackLoading: true))
        feedback.step(.init(activeKey: key, activeRevision: 1, activeJob: manual, isActiveKnown: true,
                            isActiveTrackLoading: false))
        XCTAssertEqual(feedback.notice?.title, "Subtitle timing updated")
        XCTAssertEqual(feedback.notice?.tone, .info)

        var own = SubtitleSyncFeedback()
        let running = Self.job("2", status: "running")
        own.step(.init(watched: Self.watched("running"), activeKey: key, activeJob: running, activeWatchedJobId: "2"))
        own.step(.init(watched: Self.watched("synced", revision: 1), activeKey: key, activeRevision: 1,
                       activeJob: Self.job("2", status: "synced"), activeWatchedJobId: "2"))
        own.step(.init(watched: Self.watched("synced", revision: 1), activeKey: key, activeRevision: 1,
                       activeJob: Self.job("2", status: "synced"), activeWatchedJobId: "2", isActiveTrackLoading: true))
        own.step(.init(watched: Self.watched("synced", revision: 1), activeKey: key, activeRevision: 1,
                       activeJob: Self.job("2", status: "synced"), activeWatchedJobId: "2", isActiveTrackLoading: false))
        XCTAssertEqual(own.notice?.title, "Subtitles synced")
    }

    /// An automatic sync the server ran when the track was first played goes
    /// unnoticed; a later manual change by someone else is still announced.
    func testAutomaticSyncOfTheTrackOnScreenIsQuiet() {
        let key = Self.sidecarKey
        let shifted = SubtitleTiming(offsetMs: -3010, scale: 1)
        var auto = Self.job("7", status: "synced", result: shifted)
        auto = SubtitleSyncJob(id: auto.id, subtitleId: nil, status: "synced", trigger: "auto", confidence: 1,
                               result: shifted, createdAt: Self.createdAt, finishedAt: Self.createdAt)
        var feedback = SubtitleSyncFeedback()
        feedback.step(.init(activeKey: key, activeRevision: 0))
        // The cues reload before the track's state has been read: nothing yet.
        feedback.step(.init(activeKey: key, activeRevision: 1))
        feedback.step(.init(activeKey: key, activeRevision: 1, isActiveTrackLoading: true))
        feedback.step(.init(activeKey: key, activeRevision: 1))
        XCTAssertNil(feedback.notice, "nothing is said while the change's source is unknown")
        // The read shows an automatic sync whose result is applied: still nothing.
        feedback.step(.init(activeKey: key, activeRevision: 1, activeJob: auto, activeTiming: shifted, isActiveKnown: true))
        XCTAssertNil(feedback.notice, "an automatic sync's swap is not announced")

        // Someone resets it by hand afterwards: the timing no longer equals
        // the automatic result, so the change is announced.
        let known = SubtitleSyncFeedback.Input(activeKey: key, activeRevision: 2, activeJob: auto,
                                               activeTiming: .identity, isActiveKnown: true)
        feedback.step(known)
        var loading = known
        loading.isActiveTrackLoading = true
        feedback.step(loading)
        feedback.step(known)
        XCTAssertEqual(feedback.notice?.title, "Subtitle timing updated")
    }

    /// An automatic job the viewer did not start shows no progress card,
    /// through the model.
    func testUnwatchedAutomaticJobShowsNoCard() async throws {
        let calls = Calls()
        let model = model(calls, list: [Self.sidecar()])
        model.onTimingChanged = { _ in }
        await model.reload()
        model.setActiveTrack(key: Self.sidecarKey)
        model.syncUpdated(try Self.syncUpdate(jobId: "7", status: "running", offset: 0, progress: 0.4))
        XCTAssertNil(model.notice)
    }

    // MARK: Cue hold

    func testCueHoldLastsUntilTheReloadFinishes() {
        let hold = SubtitleCueHold()
        hold.begin(.primary, trackID: 4)
        XCTAssertTrue(hold.holds(.primary, trackID: 4))
        hold.loadingChanged(false, for: .primary)
        XCTAssertTrue(hold.isHolding(.primary), "a load that never started cannot end the hold")
        hold.loadingChanged(true, for: .primary)
        hold.loadingChanged(false, for: .primary)
        XCTAssertFalse(hold.isHolding(.primary))

        hold.begin(.primary, trackID: 4, alreadyLoading: true)
        hold.loadingChanged(false, for: .primary)
        XCTAssertFalse(hold.isHolding(.primary), "the reload continued a load already running")

        hold.begin(.primary, trackID: 4)
        hold.release(.primary)
        XCTAssertFalse(hold.isHolding(.primary))
    }

    func testCueHoldCoversOnlyTheReloadedStreamAndTrack() {
        let hold = SubtitleCueHold()
        hold.begin(.primary, trackID: 4)
        XCTAssertFalse(hold.holds(.primary, trackID: 2), "another primary track's empty cues pass through")
        XCTAssertFalse(hold.holds(.secondary, trackID: nil), "the secondary stream is not held")

        hold.begin(.secondary)
        hold.loadingChanged(true, for: .secondary)
        hold.loadingChanged(false, for: .secondary)
        XCTAssertFalse(hold.isHolding(.secondary))
        XCTAssertTrue(hold.holds(.primary, trackID: 4), "the secondary load does not end the primary hold")

        hold.begin(.secondary)
        hold.release(.primary)
        XCTAssertTrue(hold.holds(.secondary, trackID: nil))
        hold.releaseAll()
        XCTAssertFalse(hold.isHolding(.secondary))
    }

    // MARK: Wire

    /// A well-formed `subtitle_sync_updated` payload tree, for tests that
    /// alter one field of it.
    private static func syncUpdatePayload(status: String) throws -> PlaybackRealtimePayload {
        let object: [String: Any] = ["type": "event", "session_id": "s1", "name": "subtitle_sync_updated",
            "payload": ["session_id": "s1", "file_id": 42, "sync_key": sidecarKey,
                        "timing": ["offset_ms": 0, "scale": 1],
                        "job": ["id": "2", "status": status, "trigger": "manual", "confidence": NSNull(),
                                "created_at": createdAt, "finished_at": NSNull()]]]
        return try JSONDecoder().decode(PlaybackRealtimeEventEnvelope.self,
                                        from: JSONSerialization.data(withJSONObject: object)).payload
    }

    private static func syncUpdate(key: String = sidecarKey, jobId: String = "2", status: String, offset: Int,
                                   phase: String? = nil, progress: Double? = nil) throws -> PlaybackRealtimeSubtitleSyncUpdatedPayload {
        var job: [String: Any] = ["id": jobId, "status": status, "trigger": "manual", "confidence": NSNull(),
                                  "created_at": createdAt, "finished_at": NSNull()]
        if let phase { job["phase"] = phase }
        if let progress { job["progress"] = progress }
        if status == "synced" { job["result"] = ["offset_ms": offset, "scale": 1] }
        let object: [String: Any] = ["type": "event", "session_id": "s1", "name": "subtitle_sync_updated",
            "payload": ["session_id": "s1", "file_id": 42, "sync_key": key,
                        "timing": ["offset_ms": offset, "scale": 1], "job": job]]
        let envelope = try JSONDecoder().decode(PlaybackRealtimeEventEnvelope.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(envelope.name, .subtitleSyncUpdated)
        return try XCTUnwrap(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: envelope.payload))
    }

    func testSyncUpdatedEventCarriesTheJobAndTiming() throws {
        let update = try Self.syncUpdate(status: "running", offset: 0, phase: "matching", progress: 0.75)
        XCTAssertEqual(update.fileId, 42)
        XCTAssertEqual(update.syncKey, Self.sidecarKey)
        XCTAssertNil(update.subtitleId)
        XCTAssertEqual(update.timing, .identity)
        XCTAssertEqual(update.job.phase, "matching")
        XCTAssertEqual(update.job.progress, 0.75)
        XCTAssertNil(update.job.confidence)

        let synced = try Self.syncUpdate(status: "synced", offset: -3010)
        XCTAssertEqual(synced.timing, SubtitleTiming(offsetMs: -3010, scale: 1))
        XCTAssertEqual(synced.job.result, synced.timing)

        XCTAssertNil(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: [
            "file_id": .number(42), "sync_key": .string(Self.sidecarKey),
            "timing": .object(["offset_ms": .number(0), "scale": .number(1)]),
        ]), "an update without its job is ignored")

        var outOfRange = try Self.syncUpdatePayload(status: "running")
        outOfRange["timing"] = .object(["offset_ms": .number(1e300), "scale": .number(1)])
        XCTAssertNil(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: outOfRange),
                     "an offset no Int can hold is rejected, not trapped on")
        outOfRange["timing"] = .object(["offset_ms": .number(12.5), "scale": .number(1)])
        XCTAssertNil(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: outOfRange))
        outOfRange["timing"] = .object(["offset_ms": .number(-9_223_372_036_854_775_808), "scale": .number(1)])
        XCTAssertNil(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: outOfRange), "outside ±600000 ms")
        outOfRange["timing"] = .object(["offset_ms": .number(0), "scale": .number(1e300)])
        XCTAssertNil(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: outOfRange), "outside 0.9...1.1")
        var hugeFile = try Self.syncUpdatePayload(status: "running")
        hugeFile["file_id"] = .number(1e300)
        XCTAssertNil(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: hugeFile), "a file id no Int can hold")
        hugeFile = try Self.syncUpdatePayload(status: "running")
        hugeFile["subtitle_id"] = .number(-1e300)
        XCTAssertNil(try XCTUnwrap(PlaybackRealtimeSubtitleSyncUpdatedPayload(payload: hugeFile)).subtitleId)
        let fractional: PlaybackRealtimePayload = ["n": .number(42.9)]
        XCTAssertEqual(fractional.int(forKeys: "n"), 42, "still truncates")
        // Values from elsewhere still format without trapping.
        XCTAssertEqual(SubtitleSyncLabel.offset(Int.min).first, "\u{2212}")
        XCTAssertNotNil(SubtitleSyncLabel.scale(1e300))
    }

    func testTimingChangedEventNamesTheTrackBySyncKey() throws {
        let data = Data(#"{"type":"event","session_id":"s1","name":"subtitle_timing_changed","payload":{"session_id":"s1","file_id":42,"subtitle_id":9}}"#.utf8)
        let envelope = try JSONDecoder().decode(PlaybackRealtimeEventEnvelope.self, from: data)
        XCTAssertEqual(envelope.name, .subtitleTimingChanged)
        let payload = try XCTUnwrap(PlaybackRealtimeSubtitleTimingChangedPayload(payload: envelope.payload))
        XCTAssertEqual(payload.fileId, 42)
        XCTAssertEqual(payload.subtitleId, "9")
        XCTAssertEqual(payload.syncKey, "stored-9", "a server without sync keys names a stored subtitle")
        XCTAssertNil(PlaybackRealtimeSubtitleEvent(name: envelope.name, payload: envelope.payload))
        XCTAssertNil(PlaybackRealtimeSubtitleTimingChangedPayload(payload: ["file_id": .number(42)]))

        let sidecar = try XCTUnwrap(PlaybackRealtimeSubtitleTimingChangedPayload(payload: [
            "file_id": .number(42), "sync_key": .string(Self.sidecarKey),
        ]))
        XCTAssertEqual(sidecar.syncKey, Self.sidecarKey)
        XCTAssertNil(sidecar.subtitleId)
    }

    func testInventoryTrackCarriesItsSyncKey() throws {
        let item = try HTTPClient.makeJSONDecoder().decode(PlaybackV3SubtitleInventoryItem.self, from: Data(
            #"{"track_id":"t1","combined_index":0,"source":"external","codec":"subrip","language":"en","forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar","url":"/x","sync_key":"\#(Self.sidecarKey)"}"#.utf8))
        XCTAssertEqual(item.syncKey, Self.sidecarKey)
        let embedded = try HTTPClient.makeJSONDecoder().decode(PlaybackV3SubtitleInventoryItem.self, from: Data(
            #"{"track_id":"t2","combined_index":1,"source":"embedded","forced":false,"default":false,"hearing_impaired":false,"delivery":"burn_in_only"}"#.utf8))
        XCTAssertNil(embedded.syncKey)
    }

    func testStoredSubtitleIdComesFromTheDownloadedPin() {
        XCTAssertEqual(PlayerViewModel.storedSubtitleId(
            fromURL: "/api/v2/stream/s1/subtitles/3.vtt?file_id=42&downloaded_subtitle_id=9"), "9")
        XCTAssertNil(PlayerViewModel.storedSubtitleId(fromURL: "/api/v2/stream/s1/subtitles/0.vtt?file_id=42"))
        XCTAssertNil(PlayerViewModel.storedSubtitleId(fromURL: "/x?downloaded_subtitle_id=09"))
        XCTAssertNil(PlayerViewModel.storedSubtitleId(fromURL: "/x?downloaded_subtitle_id=9a"))
    }

    // MARK: Offline

    func testOnlyStoredSubtitleReferencesAreRevalidated() {
        XCTAssertTrue(DownloadManager.isStoredSubtitleReference("/api/v2/downloads/d1/subtitles/downloaded:9"))
        XCTAssertTrue(DownloadManager.isStoredSubtitleReference("/api/v2/downloads/d1/subtitles/downloaded%3A9"))
        XCTAssertFalse(DownloadManager.isStoredSubtitleReference("/api/v2/downloads/d1/subtitles/external:0"))
        XCTAssertFalse(DownloadManager.isStoredSubtitleReference("/api/v2/downloads/d1/subtitles/2"))
    }

    /// A saved subtitle is fetched again when the refreshed manifest names
    /// another revision; without revisions (an older server) only stored
    /// subtitles are asked about.
    func testSavedSubtitlesRefreshWhenTheirManifestRevisionChanges() {
        let external = "/api/v2/downloads/d1/subtitles/external:0"
        let stored = "/api/v2/downloads/d1/subtitles/downloaded:9"
        var record = DownloadRecord(
            id: "d1", contentId: "c1", episodeId: nil, batchId: nil, mediaFileId: "42", format: "original",
            serverStatus: "ready", localStatus: .completed, fileSize: 1_000, bytesDownloaded: 1_000,
            mediaFilename: nil, manifestFilename: nil, posterFilename: nil, backdropFilename: nil,
            logoFilename: nil, subtitleFilenames: [external: "sub_0.srt", stored: "sub_1.srt"],
            title: "Night Train", subtitle: nil, type: "movie", seriesId: nil, seriesTitle: nil,
            posterThumbhash: nil, container: nil, stableIdentity: nil, registeredAt: Date(), downloadedAt: nil,
            lastError: nil, retryCount: 0, taskIdentifier: nil
        )
        record.setSubtitleRevision("r1", for: external)

        func subtitle(_ url: String, _ revision: String?) -> OfflineSubtitle {
            OfflineSubtitle(language: "en", title: nil, format: "srt", forced: false, hearingImpaired: false,
                            external: url == external, fetchUrl: url, fileSize: nil, revision: revision)
        }
        let needs = DownloadManager.savedSubtitleNeedsRefresh
        XCTAssertFalse(needs(subtitle(external, "r1"), record))
        XCTAssertTrue(needs(subtitle(external, "r2"), record))
        XCTAssertTrue(needs(subtitle(stored, "s1"), record), "a revision never saved is fetched once")
        XCTAssertFalse(needs(subtitle(external, nil), record), "an older server's external subtitles never change")
        XCTAssertTrue(needs(subtitle(stored, nil), record), "an older server's stored subtitles revalidate by ETag")
        XCTAssertFalse(needs(subtitle("/api/v2/downloads/d1/subtitles/external:5", "r9"), record),
                       "a subtitle that was never saved is not fetched here")

        record.setSubtitleRevision("s1", for: stored)
        XCTAssertFalse(needs(subtitle(stored, "s1"), record))
    }

    func testManifestSubtitleRevisionDecodesAndStaysOptional() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let withRevision = try decoder.decode(OfflineSubtitle.self, from: Data(
            #"{"language":"en","format":"srt","external":true,"fetch_url":"/api/v2/downloads/d1/subtitles/external:0","file_size":10,"revision":"abc"}"#.utf8))
        XCTAssertEqual(withRevision.revision, "abc")
        let without = try decoder.decode(OfflineSubtitle.self, from: Data(
            #"{"language":"en","format":"srt","fetch_url":"/api/v2/downloads/d1/subtitles/downloaded:9"}"#.utf8))
        XCTAssertNil(without.revision)
    }
}
