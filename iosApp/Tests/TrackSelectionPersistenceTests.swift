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

        let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 2)

        XCTAssertEqual(request?.subtitleTrackIndex, 2)
        XCTAssertEqual(request?.subtitleLanguage, "en")
        XCTAssertEqual(request?.subtitleMode, SubtitleMode.always.rawValue)
        XCTAssertEqual(request?.externalSubtitlePath, "")
        XCTAssertEqual(request?.trackSignature?.source, "embedded")
        XCTAssertEqual(request?.trackSignature?.label, "English")
        XCTAssertEqual(request?.trackSignature?.hearingImpaired, true)
        XCTAssertNil(request?.showForcedSubtitles ?? nil, "a pick never pins the forced-subtitle setting")
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

        let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 5)

        XCTAssertEqual(request?.trackSignature?.source, "external")
        XCTAssertEqual(request?.externalSubtitlePath, "Movie.es.srt")
    }

    func testSubtitleRequestNegativeIndexMeansOff() {
        let version = decodedVersion("""
        { "file_id": 1, "subtitle_tracks": [ { "index": 0, "language": "en", "codec": "subrip" } ] }
        """)

        let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: -1)

        XCTAssertEqual(request?.subtitleTrackIndex, -1)
        XCTAssertEqual(request?.subtitleLanguage, "")
        XCTAssertEqual(request?.subtitleMode, SubtitleMode.off.rawValue)
        XCTAssertNil(request?.trackSignature ?? nil)
    }

    func testSubtitleRequestUnknownIndexReturnsNil() {
        let version = decodedVersion("""
        { "file_id": 1, "subtitle_tracks": [ { "index": 0, "language": "en", "codec": "subrip" } ] }
        """)

        XCTAssertNil(TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 3))
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

        let request = TrackSelectionPersistence.subtitleRequest(track: track)

        XCTAssertEqual(request.subtitleTrackIndex, 4)
        XCTAssertEqual(request.subtitleMode, SubtitleMode.always.rawValue)
        XCTAssertEqual(request.trackSignature?.forced, true)
        XCTAssertEqual(request.trackSignature?.label, "Signs & Songs")
    }

    // MARK: - Carrying an unsaved pick

    func testUnsavedPicksFoldIntoTheWatchDetail() {
        // The pick was made on another episode, whose Japanese track sat at
        // ordinal 1; on this file it is ordinal 0.
        let version = decodedVersion("""
        {
          "file_id": 9,
          "effective_audio_track_index": 1,
          "effective_audio_language": "en",
          "audio_tracks": [
            { "index": 1, "language": "jpn", "codec": "aac", "channels": 2 },
            { "index": 2, "language": "eng", "codec": "aac", "channels": 2 }
          ]
        }
        """)
        let detail = WatchDetail(
            contentId: "ep-2", type: "episode", title: "Two", year: nil, overview: nil,
            versions: [version], subtitles: nil, intro: nil, credits: nil, userData: nil,
            seriesId: "series-9", seriesTitle: nil, seasonNumber: 1, episodeNumber: 2,
            effectiveSubtitleLanguage: "en", effectiveSubtitleMode: "always",
            effectiveShowForcedSubtitles: false,
            effectiveSubtitleTrackSignature: SubtitleTrackSignature(
                source: "embedded", language: "en", codec: "subrip", label: nil, forced: false, hearingImpaired: false
            )
        )
        let settlement = TrackSelectionPersistence.Settlement(rereads: false, unsettled: [
            .audio: .audio(AudioPrefRequest(
                audioTrackIndex: 1, audioLanguage: "jpn",
                trackSignature: AudioTrackSignature(language: "jpn", codec: "aac", channels: 2)
            )),
            .subtitle: .subtitle(TrackSelectionPersistence.subtitleOffRequest()),
        ])

        let applied = settlement.applied(to: detail)

        XCTAssertEqual(applied.versions[0].effectiveAudioTrackIndex, 0)
        XCTAssertEqual(applied.versions[0].effectiveAudioLanguage, "jpn")
        XCTAssertEqual(applied.effectiveSubtitleMode, "off")
        XCTAssertNil(applied.effectiveSubtitleTrackSignature)
        XCTAssertEqual(applied.effectiveShowForcedSubtitles, false, "the forced setting is not the pick's to change")

        let auto = TrackSelectionPersistence.Settlement(rereads: false, unsettled: [.audio: .cleared])
        XCTAssertEqual(auto.applied(to: detail).versions[0].effectiveAudioTrackIndex, 1,
                       "only the server can resolve what Auto falls back to")
    }

    /// The folded detail feeds the start's subtitle intent. An unnamed,
    /// untagged pick cannot be identified there, and folding it as mode
    /// `always` started whichever track ranked first (English here).
    func testUnsavedSubtitlePickStartsThePickedTrackOrLeavesTheServerState() throws {
        let version = decodedVersion("""
        {
          "file_id": 1,
          "subtitle_tracks": [
            { "index": 2, "language": "en", "codec": "subrip" },
            { "index": 3, "codec": "subrip" },
            { "index": 4, "language": "es", "codec": "subrip" },
            { "index": 5, "codec": "ass", "title": "Signs & Songs" }
          ]
        }
        """)
        // The server still holds the series' earlier choice: subtitles off.
        var server = watchDetail(version: version, subtitleLanguage: "ja")
        server.effectiveSubtitleMode = "off"
        func startIndex(carrying request: SubtitlePrefRequest) -> Int? {
            let detail = TrackSelectionPersistence.Settlement(rereads: false, unsettled: [.subtitle: .subtitle(request)])
                .applied(to: server)
            return PlaybackSessionBridge.initialProtocolV3SubtitleIntent(
                version: detail.versions[0], explicitFFmpegIndex: nil, explicitCombinedIndex: nil,
                preferredLanguage: detail.effectiveSubtitleLanguage,
                mode: SubtitleMode(rawValue: detail.effectiveSubtitleMode ?? ""),
                showForced: false, trackSignature: detail.effectiveSubtitleTrackSignature,
                currentAudioLanguage: "ja"
            ).ffmpegStreamIndex
        }

        let untagged = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 3)
        XCTAssertNil(startIndex(carrying: try XCTUnwrap(untagged)),
                     "an unidentifiable pick leaves the server's Off instead of starting English")
        let spanish = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 4)
        XCTAssertEqual(startIndex(carrying: try XCTUnwrap(spanish)), 4)
        let titled = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 5)
        XCTAssertEqual(startIndex(carrying: try XCTUnwrap(titled)), 5,
                       "an untagged pick its title identifies is carried")
    }

    func testUndefinedLanguageInACarriedPickDoesNotPickAnotherUndefinedTrack() {
        let version = decodedVersion("""
        {
          "file_id": 6,
          "subtitle_tracks": [
            { "index": 2, "language": "und", "codec": "subrip", "title": "Full dialogue" },
            { "index": 3, "codec": "ass", "title": "Signs & Songs" }
          ]
        }
        """)
        let pick = SubtitlePrefRequest(
            subtitleLanguage: "und", subtitleTrackIndex: 3, externalSubtitlePath: "", subtitleMode: "always",
            trackSignature: SubtitleTrackSignature(source: "embedded", language: "und", codec: "ass", label: "Signs & Songs")
        )
        let detail = TrackSelectionPersistence.Settlement(rereads: false, unsettled: [.subtitle: .subtitle(pick)])
            .applied(to: watchDetail(version: version, subtitleLanguage: nil))

        let start = PlaybackSessionBridge.initialProtocolV3SubtitleIntent(
            version: version, explicitFFmpegIndex: nil, explicitCombinedIndex: nil,
            preferredLanguage: detail.effectiveSubtitleLanguage,
            mode: SubtitleMode(rawValue: detail.effectiveSubtitleMode ?? ""),
            showForced: false, trackSignature: detail.effectiveSubtitleTrackSignature,
            currentAudioLanguage: "ja"
        )
        XCTAssertEqual(start.ffmpegStreamIndex, 3, "the title finds the pick; `und` is no language to match on")
    }

    func testAudioPickPrefersItsOwnOrdinalThenTheMatchingDefaultFlag() throws {
        let version = decodedVersion("""
        {
          "file_id": 5,
          "audio_tracks": [
            { "index": 1, "language": "en", "codec": "ac3", "channels": 6, "default": false },
            { "index": 2, "language": "en", "codec": "ac3", "channels": 6, "default": true }
          ]
        }
        """)
        let picked = try XCTUnwrap(TrackSelectionPersistence.audioRequest(version: version, ordinal: 1))
        XCTAssertEqual(TrackSelectionPersistence.audioOrdinal(matching: picked, in: version), 1,
                       "the same file keeps the picked ordinal")

        // Another file of the series, where the picked ordinal holds nothing.
        let elsewhere = AudioPrefRequest(audioTrackIndex: 7, audioLanguage: "en", trackSignature: picked.trackSignature)
        XCTAssertEqual(TrackSelectionPersistence.audioOrdinal(matching: elsewhere, in: version), 1,
                       "the default flag breaks the tie between otherwise equal tracks")
    }

    func testUntaggedAudioPickMatchesOnlyAnUntaggedTrackWithItsDetails() {
        let version = decodedVersion("""
        {
          "file_id": 3,
          "effective_audio_track_index": 0,
          "effective_audio_language": "eng",
          "audio_tracks": [
            { "index": 1, "language": "eng", "codec": "ac3", "channels": 6 },
            { "index": 2, "codec": "aac", "channels": 2 },
            { "index": 3, "language": "und", "codec": "ac3", "channels": 6 }
          ]
        }
        """)
        func ordinal(_ signature: AudioTrackSignature?, index: Int = 0) -> Int? {
            TrackSelectionPersistence.audioOrdinal(
                matching: AudioPrefRequest(audioTrackIndex: index, audioLanguage: "", trackSignature: signature),
                in: version
            )
        }

        XCTAssertEqual(ordinal(AudioTrackSignature(codec: "ac3", channels: 6)), 2,
                       "the tagged English track with the same codec is not an untagged match")
        XCTAssertNil(ordinal(AudioTrackSignature(codec: "dts", channels: 6)),
                     "no matching untagged track leaves the server's audio")
        XCTAssertNil(ordinal(nil, index: 1), "the other file's ordinal is not trusted unchecked")

        let carried = TrackSelectionPersistence.Settlement(rereads: false, unsettled: [.audio: .audio(
            AudioPrefRequest(audioTrackIndex: 1, audioLanguage: "",
                             trackSignature: AudioTrackSignature(codec: "aac", channels: 2))
        )]).applied(to: watchDetail(version: version, subtitleLanguage: nil)).versions[0]
        XCTAssertEqual(carried.effectiveAudioTrackIndex, 1)
        XCTAssertNil(carried.effectiveAudioLanguage,
                     "the untagged track's language replaces English, so Auto subtitles don't judge by it")
    }

    func testAudioPickMatchesItsEmbeddedTitleAndEquivalentLanguageCodes() throws {
        let version = decodedVersion("""
        {
          "file_id": 4,
          "audio_tracks": [
            { "index": 1, "language": "en", "codec": "ac3", "channels": 6, "layout": "5.1", "embedded_title": "Commentary" },
            { "index": 2, "language": "en", "codec": "ac3", "channels": 6, "layout": "5.1", "embedded_title": "Main audio" },
            { "index": 3, "language": "jpn", "codec": "aac", "channels": 2 }
          ]
        }
        """)
        let main = try XCTUnwrap(TrackSelectionPersistence.audioRequest(version: version, ordinal: 1))
        XCTAssertEqual(TrackSelectionPersistence.audioOrdinal(matching: main, in: version), 1,
                       "a track that differs only in its embedded title is another pick")

        let japanese = AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "ja",
                                        trackSignature: AudioTrackSignature(language: "ja", codec: "aac", channels: 2))
        XCTAssertEqual(TrackSelectionPersistence.audioOrdinal(matching: japanese, in: version), 2,
                       "ja on one file is jpn on the next")
    }

    private func watchDetail(version: FileVersion, subtitleLanguage: String?) -> WatchDetail {
        WatchDetail(
            contentId: "ep-2", type: "episode", title: "Two", year: nil, overview: nil,
            versions: [version], subtitles: nil, intro: nil, credits: nil, userData: nil,
            seriesId: "series-9", seriesTitle: nil, seasonNumber: 1, episodeNumber: 2,
            effectiveSubtitleLanguage: subtitleLanguage, effectiveSubtitleMode: "auto",
            effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
        )
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
