import XCTest
import Foundation
@testable import Silo

/// The pref-request builders feed the server's per-series audio /
/// subtitle preference endpoints; a wrong index space or a signature
/// field mismatch silently breaks track stickiness, so the wire shapes
/// are pinned here.
final class TrackSelectionPersistenceTests: XCTestCase {

    // MARK: - Pref key

    func testPrefKeyPrefersSeriesIdOverContentId() {
        XCTAssertEqual(
            TrackSelectionPersistence.prefKey(seriesId: "series-9", contentId: "ep-1"),
            "series-9"
        )
        XCTAssertEqual(
            TrackSelectionPersistence.prefKey(seriesId: nil, contentId: "movie-7"),
            "movie-7"
        )
        XCTAssertEqual(
            TrackSelectionPersistence.prefKey(seriesId: "", contentId: "movie-7"),
            "movie-7"
        )
        XCTAssertNil(TrackSelectionPersistence.prefKey(seriesId: nil, contentId: nil))
        XCTAssertNil(TrackSelectionPersistence.prefKey(seriesId: "", contentId: ""))
    }

    // MARK: - Audio requests

    func testAudioRequestBuildsSignatureFromServerMetadata() {
        let version = decodedVersion("""
        {
          "file_id": 1,
          "audio_tracks": [
            { "language": "en", "codec": "aac", "channels": 2, "layout": "stereo", "default": true },
            {
              "language": "ja",
              "title": "Japanese 5.1",
              "embedded_title": "JPN Surround",
              "codec": "eac3",
              "channels": 6,
              "layout": "5.1",
              "default": false
            }
          ]
        }
        """)

        let request = TrackSelectionPersistence.audioRequest(version: version, ordinal: 1)

        XCTAssertEqual(request?.audioTrackIndex, 1)
        XCTAssertEqual(request?.audioLanguage, "ja")
        XCTAssertEqual(request?.trackSignature?.language, "ja")
        XCTAssertEqual(request?.trackSignature?.title, "Japanese 5.1")
        XCTAssertEqual(request?.trackSignature?.embeddedTitle, "JPN Surround")
        XCTAssertEqual(request?.trackSignature?.codec, "eac3")
        XCTAssertEqual(request?.trackSignature?.layout, "5.1")
        XCTAssertEqual(request?.trackSignature?.channels, 6)
        XCTAssertEqual(request?.trackSignature?.isDefault, false)
    }

    func testAudioRequestRejectsOutOfRangeOrdinal() {
        let version = decodedVersion("""
        { "file_id": 1, "audio_tracks": [ { "language": "en", "codec": "aac" } ] }
        """)

        XCTAssertNil(TrackSelectionPersistence.audioRequest(version: version, ordinal: 1))
        XCTAssertNil(TrackSelectionPersistence.audioRequest(version: version, ordinal: -1))
    }

    func testAudioRequestFromPlayerTrackFallsBackToTrackFields() {
        let track = playerTrack(
            kind: .audio,
            title: "Commentary",
            lang: "en",
            codec: "ac3",
            channels: 2
        )

        let request = TrackSelectionPersistence.audioRequest(track: track, ordinal: nil)

        XCTAssertEqual(request.audioTrackIndex, -1, "Unknown ordinal must persist as 'no index' so the server matches by signature/language")
        XCTAssertEqual(request.audioLanguage, "en")
        XCTAssertEqual(request.trackSignature?.codec, "ac3")
        XCTAssertEqual(request.trackSignature?.channels, 2)
    }

    // MARK: - Subtitle requests

    func testSubtitleRequestForEmbeddedTrack() {
        let version = decodedVersion("""
        {
          "file_id": 1,
          "subtitle_tracks": [
            { "index": 2, "language": "en", "codec": "subrip", "title": "English", "forced": false, "hearing_impaired": true }
          ]
        }
        """)

        let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 2, showForced: true)

        XCTAssertEqual(request?.subtitleTrackIndex, 2)
        XCTAssertEqual(request?.subtitleLanguage, "en")
        XCTAssertEqual(request?.subtitleMode, SubtitleMode.always.rawValue)
        XCTAssertEqual(request?.externalSubtitlePath, "")
        XCTAssertEqual(request?.trackSignature?.source, "embedded")
        XCTAssertEqual(request?.trackSignature?.label, "English")
        XCTAssertEqual(request?.trackSignature?.hearingImpaired, true)
        XCTAssertEqual(request?.showForcedSubtitles, true)
    }

    func testSubtitleRequestForExternalTrackCarriesPath() {
        let version = decodedVersion("""
        {
          "file_id": 1,
          "subtitle_tracks": [
            { "index": 5, "language": "es", "codec": "subrip", "external": true, "file_name": "Movie.es.srt" }
          ]
        }
        """)

        let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 5, showForced: nil)

        XCTAssertEqual(request?.trackSignature?.source, "external")
        XCTAssertEqual(request?.externalSubtitlePath, "Movie.es.srt")
    }

    func testSubtitleRequestNegativeIndexMeansOff() {
        let version = decodedVersion("""
        { "file_id": 1, "subtitle_tracks": [ { "index": 0, "language": "en", "codec": "subrip" } ] }
        """)

        let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: -1, showForced: false)

        XCTAssertEqual(request?.subtitleTrackIndex, -1)
        XCTAssertEqual(request?.subtitleLanguage, "")
        XCTAssertEqual(request?.subtitleMode, SubtitleMode.off.rawValue)
        XCTAssertNil(request?.trackSignature ?? nil)
    }

    func testSubtitleRequestUnknownIndexReturnsNil() {
        let version = decodedVersion("""
        { "file_id": 1, "subtitle_tracks": [ { "index": 0, "language": "en", "codec": "subrip" } ] }
        """)

        XCTAssertNil(TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 3, showForced: nil))
    }

    func testSubtitleRequestFromPlayerTrackUsesFfIndexAndFlags() {
        let track = playerTrack(
            kind: .sub,
            title: "Signs & Songs",
            lang: "en",
            codec: "ass",
            isForced: true,
            ffIndex: 4
        )

        let request = TrackSelectionPersistence.subtitleRequest(track: track, showForced: nil)

        XCTAssertEqual(request.subtitleTrackIndex, 4)
        XCTAssertEqual(request.subtitleMode, SubtitleMode.always.rawValue)
        XCTAssertEqual(request.trackSignature?.forced, true)
        XCTAssertEqual(request.trackSignature?.label, "Signs & Songs")
    }

    // MARK: - Helpers

    private func decodedVersion(_ json: String) -> FileVersion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(FileVersion.self, from: Data(json.utf8))
    }

    private func playerTrack(
        kind: PlayerTrack.Kind,
        title: String?,
        lang: String?,
        codec: String?,
        channels: Int? = nil,
        isForced: Bool = false,
        ffIndex: Int? = nil
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: 1,
            kind: kind,
            title: title,
            lang: lang,
            codec: codec,
            audioChannelCount: channels,
            bitrate: nil,
            isDefault: false,
            isForced: isForced,
            isHearingImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: ffIndex,
            srcId: nil
        )
    }
}
