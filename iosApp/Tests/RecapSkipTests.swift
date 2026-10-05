import XCTest
@testable import Silo

/// Recap markers reach the player from watch detail, `markers_updated` and a
/// download's manifest, and drive the same pill as the intro under
/// `playback.auto_skip_recap`.
@MainActor
final class RecapSkipTests: XCTestCase {
    private let recap = TimeRange(start: 0, end: 45)

    // MARK: - Marker sources

    func testWatchDetailCarriesRecapForTheItemAndEachVersion() throws {
        let json = """
        {
          "content_id": "episode:1",
          "type": "episode",
          "title": "Pilot",
          "subtitles": [],
          "recap": {"start_seconds": 0, "end_seconds": 45},
          "versions": [{
            "file_id": "42",
            "resolution": "1080p",
            "codec_video": "h264",
            "codec_audio": "aac",
            "hdr": false,
            "container": "mkv",
            "file_size": 1000,
            "duration_seconds": 2400,
            "bitrate": 8000000,
            "recap": {"start_seconds": 2, "end_seconds": 50}
          }]
        }
        """
        let wire = try HTTPClient.makeJSONDecoder().decode(
            APIv2CatalogRead.WatchDetail.self, from: Data(json.utf8)
        )
        let detail = try WatchDetail(v2: wire)

        XCTAssertEqual(detail.recap, recap)
        XCTAssertEqual(detail.versions.first?.recap, TimeRange(start: 2, end: 50))
    }

    func testMarkersUpdatedSetsClearsAndLeavesRecap() {
        let set = PlaybackRealtimeMarkersUpdatedPayload(payload: [
            "file_id": .number(42),
            "recap": .object(["start": .number(0), "end": .number(45)]),
        ])
        XCTAssertEqual(set?.recapUpdate, .set(recap))
        XCTAssertEqual(set?.recap, recap)

        let cleared = PlaybackRealtimeMarkersUpdatedPayload(payload: [
            "file_id": .number(42),
            "recap": .null,
        ])
        XCTAssertEqual(cleared?.recapUpdate, .clear)

        let untouched = PlaybackRealtimeMarkersUpdatedPayload(payload: ["file_id": .number(42)])
        XCTAssertEqual(untouched?.recapUpdate, .unchanged)
    }

    func testDownloadedEpisodeKeepsItsRecap() throws {
        let json = """
        {
          "download_id": "d1",
          "content_id": "c1",
          "type": "episode",
          "title": "Pilot",
          "quality": "original",
          "media_file_id": "42",
          "container": "mkv",
          "codec_video": "hevc",
          "codec_audio": "eac3",
          "recap": {"start": 0, "end": 45}
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(OfflineManifest.self, from: Data(json.utf8))
        let prepared = OfflinePlaybackBuilder.makePreparedPlayback(
            leafContentId: "leaf",
            manifest: manifest,
            mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"),
            subtitleURLs: [],
            resumePosition: nil
        )

        XCTAssertEqual(prepared.selectedVersion.recap, recap)
        XCTAssertEqual(prepared.watchDetail.recap, recap)
    }

    // MARK: - Skip decisions

    func testAutoSkipRecapSkipsAndOtherwiseOffers() {
        XCTAssertEqual(PlayerViewModel.recapSkipMode(autoSkip: true), .always)
        XCTAssertEqual(PlayerViewModel.recapSkipMode(autoSkip: false), .ask)
    }

    func testWatchPartyNeverSkipsOnItsOwn() {
        XCTAssertEqual(
            PlayerViewModel.markerSkipMode(.always, isWatchParty: false, canRequestSeek: false),
            .always
        )
        XCTAssertEqual(
            PlayerViewModel.markerSkipMode(.always, isWatchParty: true, canRequestSeek: true),
            .ask
        )
        XCTAssertEqual(
            PlayerViewModel.markerSkipMode(.ask, isWatchParty: true, canRequestSeek: false),
            .never
        )
    }

    func testAutoSkippedRecapJumpsToItsEndAndOffersWatchRecap() {
        let prompt = IntroSkipPrompt(marker: .recap, clock: ManualIntroSkipClock())
        let target = prompt.update(inputs(position: 3, mode: .always))

        XCTAssertEqual(target, 45)
        XCTAssertEqual(prompt.pill?.actionTitle, "Watch Recap")
        XCTAssertEqual(prompt.pill?.caption, "Recap skipped")
        XCTAssertEqual(prompt.pill?.accessibilityLabel, "Recap skipped. Watch Recap")
        XCTAssertEqual(prompt.select(), 0)
    }

    func testRecapOfferSaysSkipRecapAndSeeksPastIt() {
        let prompt = IntroSkipPrompt(marker: .recap, clock: ManualIntroSkipClock())
        XCTAssertNil(prompt.update(inputs(position: 3, mode: .ask)))

        XCTAssertEqual(prompt.pill?.actionTitle, "Skip Recap")
        XCTAssertNil(prompt.pill?.caption)
        XCTAssertEqual(prompt.select(), 45)
        XCTAssertNil(prompt.update(inputs(position: 10, mode: .ask)), "a decided recap is not offered again")
        XCTAssertNil(prompt.pill)
    }

    func testIntroLabelsAreUnchanged() {
        let prompt = IntroSkipPrompt(clock: ManualIntroSkipClock())
        prompt.update(inputs(position: 3, mode: .ask))
        XCTAssertEqual(prompt.pill?.actionTitle, "Skip Intro")
        XCTAssertEqual(prompt.pill?.accessibilityLabel, "Skip Intro")
    }

    private func inputs(position: Double, mode: IntroSkipMode) -> IntroSkipPrompt.Inputs {
        .init(position: position, range: recap, key: "episode:1:42:0.0:45.0", mode: mode, activity: .playing)
    }
}
