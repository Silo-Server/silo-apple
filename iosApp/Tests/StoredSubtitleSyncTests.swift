import Foundation
import XCTest
@testable import Silo

/// Server subtitle sync on the player: the status line, when a timing change
/// makes the player fetch a track's cues again, and the realtime event.
@MainActor
final class StoredSubtitleSyncTests: XCTestCase {
    nonisolated private static func subtitle(
        _ id: String = "7",
        timing: SubtitleTiming = .identity,
        status: String? = nil,
        result: SubtitleTiming? = nil
    ) -> DownloadedSubtitle {
        DownloadedSubtitle(
            id: id, mediaFileId: 42, timing: timing,
            sync: status.map {
                SubtitleSyncJob(id: "1", subtitleId: id, status: $0, trigger: "auto", confidence: nil,
                                result: result, createdAt: "2026-01-02T03:04:05.678Z", finishedAt: nil)
            }
        )
    }

    // MARK: Status line

    func testStatusLineMatchesTheWebPlayer() {
        let shifted = SubtitleTiming(offsetMs: -3200, scale: 1)
        let label = StoredSubtitleSyncLabel.status(for:)
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
        XCTAssertEqual(StoredSubtitleSyncLabel.scale(25 / 23.976), "25→23.976 fps")
    }

    // MARK: Model

    private final class Calls {
        var list: [DownloadedSubtitle] = []
        var reads: [DownloadedSubtitle] = []
        var resetResult: Result<DownloadedSubtitle, Error> = .success(StoredSubtitleSyncTests.subtitle())
        var syncError: Error?
    }

    private func model(_ calls: Calls, list: [DownloadedSubtitle]) -> StoredSubtitleSyncModel {
        calls.list = list
        let model = StoredSubtitleSyncModel(service: StoredSubtitleSyncService(
            status: { try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSyncStatus.self,
                from: Data(#"{"revision":"r","state":"available","allowed":true,"auto_sync":true}"#.utf8)) },
            list: { _ in calls.list },
            read: { _, _ in calls.reads.removeFirst() },
            requestSync: { _ in
                if let error = calls.syncError { throw error }
                return SubtitleSyncJob(id: "2", subtitleId: "7", status: "pending", trigger: "manual",
                                       confidence: nil, result: nil, createdAt: "2026-01-02T03:04:05.678Z", finishedAt: nil)
            },
            resetTiming: { _, _ in try calls.resetResult.get() }
        ))
        model.bind(mediaFileId: 42)
        return model
    }

    /// A timing change the model reads (a reset, a finished poll) fetches
    /// the cues once; reading the same timing again does not.
    func testObservedTimingChangeRefetchesOnce() async {
        let shifted = SubtitleTiming(offsetMs: -3200, scale: 1)
        let calls = Calls()
        let model = model(calls, list: [Self.subtitle(timing: shifted, status: "synced", result: shifted)])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }

        await model.reload()
        XCTAssertTrue(model.isSyncAvailable)
        XCTAssertEqual(model.entry(for: "7")?.statusLabel, "Synced \u{2212}3.2 s")
        XCTAssertEqual(refetched, [], "the first read only records the timing")

        await model.resetTiming(id: "7")
        XCTAssertEqual(refetched, ["7"])
        XCTAssertEqual(model.entry(for: "7")?.canReset, false)

        calls.list = [Self.subtitle()]
        await model.reload()
        XCTAssertEqual(refetched, ["7"], "an unchanged timing is not fetched again")
    }

    /// The realtime event refetches right away; the read it triggers sees
    /// the new timing and must not ask a second time.
    func testRealtimeChangeRefetchesOnceWithItsFollowUpRead() async throws {
        let shifted = SubtitleTiming(offsetMs: -3200, scale: 1)
        let calls = Calls()
        calls.reads = [Self.subtitle(timing: shifted, status: "synced", result: shifted)]
        let model = model(calls, list: [Self.subtitle()])
        var refetched: [String] = []
        model.onTimingChanged = { refetched.append($0) }
        await model.reload()

        model.timingChanged(id: "7")
        XCTAssertEqual(refetched, ["7"])
        for _ in 0..<50 where model.entry(for: "7")?.subtitle.timing != shifted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.entry(for: "7")?.subtitle.timing, shifted)
        XCTAssertEqual(refetched, ["7"])
    }

    func testRefusedSyncExplainsWhoMayRetime() async {
        let calls = Calls()
        calls.syncError = APIv2Error.httpStatus(403)
        let model = model(calls, list: [Self.subtitle()])
        await model.reload()
        await model.requestSync(id: "7")
        XCTAssertEqual(model.entry(for: "7")?.isForbidden, true)
        XCTAssertEqual(model.entry(for: "7")?.isBusy, false)

        calls.syncError = APIv2Error.httpStatus(422)
        await model.requestSync(id: "7")
        XCTAssertEqual(model.entry(for: "7")?.isUnsupported, true)
        XCTAssertEqual(model.entry(for: "7")?.error, "This format can't be synced.")
    }

    func testAnotherFileDropsEverything() async {
        let model = model(Calls(), list: [Self.subtitle()])
        await model.reload()
        XCTAssertNotNil(model.entry(for: "7"))
        model.bind(mediaFileId: 43)
        XCTAssertNil(model.entry(for: "7"))
    }

    // MARK: Wire

    func testTimingChangedEventNamesTheStoredSubtitle() throws {
        let data = Data(#"{"type":"event","session_id":"s1","name":"subtitle_timing_changed","payload":{"session_id":"s1","file_id":42,"subtitle_id":9}}"#.utf8)
        let envelope = try JSONDecoder().decode(PlaybackRealtimeEventEnvelope.self, from: data)
        XCTAssertEqual(envelope.name, .subtitleTimingChanged)
        let payload = try XCTUnwrap(PlaybackRealtimeSubtitleTimingChangedPayload(payload: envelope.payload))
        XCTAssertEqual(payload.fileId, 42)
        XCTAssertEqual(payload.subtitleId, "9")
        XCTAssertNil(PlaybackRealtimeSubtitleEvent(name: envelope.name, payload: envelope.payload))
        XCTAssertNil(PlaybackRealtimeSubtitleTimingChangedPayload(payload: ["file_id": .number(42)]))
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
}
