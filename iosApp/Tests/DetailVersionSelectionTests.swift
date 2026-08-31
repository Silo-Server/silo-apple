import XCTest
import Foundation
@testable import Silo

final class DetailVersionSelectionTests: XCTestCase {

    func testDeviceSettingsDoNotForwardServerSubtitleSeedAsManualChoice() {
        XCTAssertNil(DetailPlaybackFormatting.launchPreferredSubtitleIndex(
            version: nil,
            signature: nil,
            mode: SubtitleMode.off.rawValue,
            usesDeviceSettings: true
        ))
        XCTAssertEqual(DetailPlaybackFormatting.launchPreferredSubtitleIndex(
            version: nil,
            signature: nil,
            mode: SubtitleMode.off.rawValue,
            usesDeviceSettings: false
        ), -1)
    }

    func testAutoDisplayPrefersBestVersionOverFirstReturnedVersion() {
        let versions = [
            version(fileId: 10, resolution: "1080p"),
            version(fileId: 20, resolution: "4K")
        ]

        let selected = DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: nil,
            lastFileId: nil
        )

        XCTAssertTrue(
            selected?.fileId == 20,
            "Auto should display the best version playback will choose; got \(selected?.fileId.description ?? "nil")"
        )
    }

    func testVersionSelectorUsesRichPrePlaySummary() {
        let version = decodedVersions("""
        [
          {
            "file_id": 1,
            "resolution": "2160p",
            "codec_video": "hevc",
            "codec_audio": "truehd",
            "hdr": true
          }
        ]
        """)[0]

        XCTAssertEqual(
            DetailPlaybackFormatting.versionShortLabel(version),
            "2160p · HEVC · HDR · TrueHD"
        )
    }

    func testVersionSelectorUsesDVForDolbyVisionMetadata() {
        let version = decodedVersions("""
        [
          {
            "file_id": 1,
            "resolution": "2160p",
            "codec_video": "hevc",
            "codec_audio": "eac3",
            "hdr": true,
            "video_tracks": [
              { "dolby_vision": "Profile 8.1", "color_range": "tv" }
            ]
          }
        ]
        """)[0]

        XCTAssertEqual(
            DetailPlaybackFormatting.versionShortLabel(version),
            "2160p · HEVC · DV · EAC3"
        )
        XCTAssertEqual(
            DetailPlaybackFormatting.versionCompactLabel(version),
            "2160p · DV"
        )
        XCTAssertEqual(
            DetailPlaybackFormatting.versionPrimaryText(version),
            "2160p · HEVC · DV · EAC3"
        )
        XCTAssertEqual(version.videoTracks?.first?.colorRange, "tv")
    }

    func testSourceColorRangeIsNotAppliedToTranscodedOutput() {
        XCTAssertTrue(PlaybackDeliveryStrategy.direct.preservesSourceVideoMetadata)
        XCTAssertTrue(PlaybackDeliveryStrategy.remux.preservesSourceVideoMetadata)
        XCTAssertFalse(PlaybackDeliveryStrategy.transcode.preservesSourceVideoMetadata)
    }

    private func decodedVersions(_ json: String) -> [FileVersion] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data(json.utf8))
    }

    func testEditionsGroupVersionsByEditionLabel() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "edition_raw": "Director's Cut", "edition_key": "directors_cut", "resolution": "4K" },
          { "file_id": 2, "edition_raw": "Director's Cut", "edition_key": "directors_cut", "resolution": "1080p" },
          { "file_id": 3, "resolution": "1080p" }
        ]
        """)

        let editions = PlaybackEditions.editions(from: versions)

        XCTAssertTrue(editions.count == 2, "Expected 2 editions; got \(editions.count)")
        XCTAssertTrue(editions[0].label == "Director's Cut", "First edition label wrong: \(editions[0].label)")
        XCTAssertTrue(editions[0].versions.count == 2, "Director's Cut should hold 2 versions")
        XCTAssertTrue(editions[1].label == "Standard", "Untitled edition should be labeled Standard; got \(editions[1].label)")
    }

    func testFileVersionDecodesServerEditionFields() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 10,
            "edition_raw": "Final Cut",
            "edition_key": "final_cut",
            "edition": "Legacy Cut",
            "resolution": "4K"
          }
        ]
        """)

        let version = versions[0]

        XCTAssertTrue(version.editionRaw == "Final Cut")
        XCTAssertTrue(version.editionKey == "final_cut")
        XCTAssertTrue(version.edition == "Legacy Cut")
        XCTAssertTrue(version.editionDisplayLabel == "Final Cut")
    }

    func testLegacyEditionFallbackStillGroups() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "edition": "Theatrical", "resolution": "1080p" },
          { "file_id": 2, "edition": "Theatrical", "resolution": "720p" }
        ]
        """)

        let editions = PlaybackEditions.editions(from: versions)

        XCTAssertTrue(editions.count == 1, "Legacy edition field should still group versions")
        XCTAssertTrue(editions[0].label == "Theatrical")
        XCTAssertTrue(editions[0].versions.map(\.fileId) == [1, 2])
    }

    func testEditionForFileIdFindsOwningEdition() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "edition": "Theatrical", "resolution": "1080p" },
          { "file_id": 2, "edition": "Extended", "resolution": "1080p" }
        ]
        """)

        let edition = PlaybackEditions.edition(forFileId: 2, in: versions)

        XCTAssertTrue(edition?.label == "Extended", "fileId 2 should resolve to Extended; got \(edition?.label ?? "nil")")
    }

    func testSelectorValuesShowForSingleChoicesButOnlyEnableForMultipleChoices() {
        let singleChoiceVersion = decodedVersions("""
        [
          {
            "file_id": 1,
            "resolution": "4K",
            "audio_tracks": [
              { "codec": "aac", "language": "eng" }
            ],
            "subtitle_tracks": [
              { "index": 2, "codec": "srt", "language": "eng" }
            ]
          }
        ]
        """)[0]

        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableVersionSelector(
            versions: [singleChoiceVersion],
            currentVersion: singleChoiceVersion
        ))
        XCTAssertTrue(DetailPlaybackFormatting.shouldShowAudioValue(version: singleChoiceVersion))
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableAudioSelector(version: singleChoiceVersion))
        XCTAssertTrue(DetailPlaybackFormatting.shouldShowSubtitleValue(version: singleChoiceVersion))
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: singleChoiceVersion))
        XCTAssertTrue(
            DetailPlaybackFormatting.subtitleValueLabel(
                version: singleChoiceVersion,
                selectedSubtitleTrackIndex: nil
            ) == "English · SRT"
        )

        let multipleChoiceVersion = decodedVersions("""
        [
          {
            "file_id": 2,
            "resolution": "4K",
            "audio_tracks": [
              { "codec": "aac", "language": "eng" },
              { "codec": "ac3", "language": "spa" }
            ],
            "subtitle_tracks": [
              { "index": 2, "codec": "srt", "language": "eng" },
              { "index": 3, "codec": "srt", "language": "spa" }
            ]
          }
        ]
        """)[0]

        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableAudioSelector(version: multipleChoiceVersion))
        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: multipleChoiceVersion))
    }

    func testVersionSelectorScopesChoicesToCurrentEdition() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "edition_raw": "Theatrical", "edition_key": "theatrical", "resolution": "4K" },
          { "file_id": 2, "edition_raw": "Extended", "edition_key": "extended", "resolution": "4K" },
          { "file_id": 3, "edition_raw": "Extended", "edition_key": "extended", "resolution": "1080p" }
        ]
        """)

        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableVersionSelector(
            versions: versions,
            currentVersion: versions[0]
        ))
        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableVersionSelector(
            versions: versions,
            currentVersion: versions[1]
        ))
        XCTAssertTrue(
            DetailPlaybackFormatting.versionSelectorVersions(
                versions: versions,
                currentVersion: versions[1]
            ).map(\.fileId) == [2, 3]
        )
    }

    func testAudioOptionsUseOrdinalIndexes() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 1,
            "audio_tracks": [
              { "codec": "aac", "language": "eng", "default": true },
              { "codec": "truehd", "language": "jpn", "layout": "7.1" }
            ]
          }
        ]
        """)

        let options = DetailPlaybackFormatting.audioOptions(
            version: versions[0],
            selectedAudioTrackIndex: 1
        )

        XCTAssertTrue(options.count == 2)
        XCTAssertTrue(options[0].ordinal == 0)
        XCTAssertTrue(options[1].ordinal == 1)
        XCTAssertTrue(options[1].isSelected)
    }

    func testEffectiveAudioLabelPrefersServerEffectiveTrack() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 1,
            "effective_audio_track_index": 1,
            "audio_tracks": [
              { "codec": "aac", "language": "eng", "default": true },
              { "codec": "truehd", "language": "jpn", "layout": "7.1" }
            ]
          }
        ]
        """)

        let version = versions[0]
        let effectiveLabel = DetailPlaybackFormatting.audioValueLabel(
            version: version,
            selectedAudioTrackIndex: nil
        )
        let selectedLabel = DetailPlaybackFormatting.audioValueLabel(
            version: version,
            selectedAudioTrackIndex: 0
        )
        let annotatedAutoLabel = DetailPlaybackFormatting.audioValueLabel(
            version: version,
            selectedAudioTrackIndex: nil,
            annotateAuto: true
        )

        XCTAssertTrue(version.effectiveAudioTrackIndex == 1)
        XCTAssertTrue(effectiveLabel == "Japanese · TrueHD · 7.1", "Expected effective track label; got \(effectiveLabel)")
        XCTAssertTrue(selectedLabel == "English · AAC", "Selected ordinal should override effective track; got \(selectedLabel)")
        XCTAssertEqual(annotatedAutoLabel, "Auto: Japanese · TrueHD · 7.1")

        let defaultFallback = decodedVersions("""
        [
          {
            "file_id": 2,
            "audio_tracks": [
              { "codec": "aac", "language": "eng" },
              { "codec": "ac3", "language": "spa", "default": true }
            ]
          }
        ]
        """)[0]
        let defaultLabel = DetailPlaybackFormatting.audioValueLabel(
            version: defaultFallback,
            selectedAudioTrackIndex: nil
        )
        XCTAssertTrue(defaultLabel == "Spanish · AC3", "Expected default track label; got \(defaultLabel)")

        let firstFallback = decodedVersions("""
        [
          {
            "file_id": 3,
            "audio_tracks": [
              { "codec": "aac", "language": "eng" },
              { "codec": "ac3", "language": "spa" }
            ]
          }
        ]
        """)[0]
        let firstLabel = DetailPlaybackFormatting.audioValueLabel(
            version: firstFallback,
            selectedAudioTrackIndex: nil
        )
        XCTAssertTrue(firstLabel == "English · AAC", "Expected first track fallback; got \(firstLabel)")
    }

    func testAudioLabelsSimplifyTechnicalTitles() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 1,
            "effective_audio_track_index": 0,
            "audio_tracks": [
              {
                "title": "atsc a/52b (ac-3, e-ac-3)",
                "codec": "eac3",
                "channels": 6,
                "language": "eng",
                "default": true
              }
            ]
          }
        ]
        """)

        let label = DetailPlaybackFormatting.audioValueLabel(
            version: versions[0],
            selectedAudioTrackIndex: nil
        )
        let options = DetailPlaybackFormatting.audioOptions(
            version: versions[0],
            selectedAudioTrackIndex: nil
        )

        XCTAssertTrue(label == "English · EAC3 · 5.1", "Expected simplified audio label; got \(label)")
        XCTAssertTrue(options[0].title == "English")
        XCTAssertTrue(options[0].detail == "EAC3 · 5.1 · Default · Preferred")
    }

    func testSubtitleNilIndexDoesNotCollideWithOff() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 1,
            "subtitle_tracks": [
              {
                "codec": "srt",
                "language": "eng",
                "file_name": "/subs/English.srt",
                "external": true
              }
            ]
          }
        ]
        """)

        // The external subtitle's path must actually decode (it feeds the
        // track id); under `.convertFromSnakeCase` the wire key `file_name`
        // becomes `fileName`, which the CodingKey now matches. Without this the
        // id collapses to "-1|" and collides with any other external sub.
        XCTAssertTrue(
            versions[0].subtitleTracks?.first?.externalPath == "/subs/English.srt",
            "external subtitle file_name should decode into externalPath"
        )
        XCTAssertTrue(
            versions[0].subtitleTracks?.first?.id == "-1|/subs/English.srt",
            "external subtitle id should incorporate the decoded path so it stays unique"
        )

        let options = DetailPlaybackFormatting.subtitleOptions(
            version: versions[0],
            selectedSubtitleTrackIndex: -1,
            preferredLanguage: nil
        )

        XCTAssertTrue(options.count == 1)
        XCTAssertTrue(options[0].selectionIndex == nil)
        XCTAssertTrue(options[0].title == "English")
        XCTAssertTrue(options[0].detail == "SRT · External · Available in player")
        XCTAssertFalse(options[0].isSelectable)
        XCTAssertFalse(options[0].isSelected)
        XCTAssertTrue(
            DetailPlaybackFormatting.subtitleValueLabel(
                version: versions[0],
                selectedSubtitleTrackIndex: -1
            ) == "Off"
        )
    }

    func testSubtitleLabelsIncludeTypeAndLanguage() {
        let versions = decodedVersions("""
        [
          {
            "file_id": 1,
            "subtitle_tracks": [
              {
                "index": 2,
                "title": "sdh",
                "codec": "subrip",
                "language": "eng",
                "default": true
              },
              {
                "index": 3,
                "codec": "srt",
                "language": "jpn"
              }
            ]
          }
        ]
        """)

        let options = DetailPlaybackFormatting.subtitleOptions(
            version: versions[0],
            selectedSubtitleTrackIndex: 2,
            preferredLanguage: nil
        )
        let selectedLabel = DetailPlaybackFormatting.subtitleValueLabel(
            version: versions[0],
            selectedSubtitleTrackIndex: 2
        )

        XCTAssertTrue(options.count == 2)
        XCTAssertTrue(options[0].title == "English", "Expected language-first subtitle label; got \(options[0].title)")
        XCTAssertTrue(options[0].detail == "SRT · SDH · Default", "Expected subtitle type detail; got \(options[0].detail)")
        XCTAssertTrue(options[1].title == "Japanese", "Expected language-first subtitle label; got \(options[1].title)")
        XCTAssertTrue(options[1].detail == "SRT", "Expected subtitle format detail; got \(options[1].detail)")
        XCTAssertTrue(selectedLabel == "English (SDH) · SRT", "Expected selected subtitle label; got \(selectedLabel)")
    }

    func testSubtitleLabelsDoNotDuplicateTitleBasedMarkers() {
        let version = decodedVersions("""
        [
          {
            "file_id": 1,
            "subtitle_tracks": [
              {
                "index": 2,
                "title": "Signs and Songs Forced",
                "codec": "srt",
                "language": "eng",
                "forced": false
              },
              {
                "index": 3,
                "title": "Director's Commentary (Hearing Impaired)",
                "codec": "srt"
              }
            ]
          }
        ]
        """)[0]

        let options = DetailPlaybackFormatting.subtitleOptions(
            version: version,
            selectedSubtitleTrackIndex: 2,
            preferredLanguage: nil
        )

        XCTAssertTrue(options[0].detail == "Signs and Songs Forced · SRT · Forced")
        XCTAssertTrue(
            DetailPlaybackFormatting.subtitleValueLabel(
                version: version,
                selectedSubtitleTrackIndex: 3
            ) == "Director's Commentary (Hearing Impaired) · SRT",
            "The hearing-impaired marker is already present in the detail title and should not be repeated"
        )
    }

    func testUntaggedEditionDisplaysStandard() {
        let versions = decodedVersions("""
        [
          { "file_id": 1, "resolution": "1080p" }
        ]
        """)

        let editions = PlaybackEditions.editions(from: versions)

        XCTAssertTrue(versions[0].editionDisplayLabel == "Standard")
        XCTAssertTrue(editions.count == 1)
        XCTAssertTrue(editions[0].label == "Standard")
    }

    private func version(fileId: Int, resolution: String?) -> FileVersion {
        FileVersion(
            fileId: fileId,
            fileName: nil,
            resolution: resolution,
            codecVideo: "hevc",
            codecAudio: nil,
            hdr: nil,
            container: nil,
            fileSize: nil,
            duration: nil,
            bitrate: nil,
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil,
            intro: nil,
            credits: nil
        )
    }

    func testFileVersionDecodesIntroAndCreditsMarkers() {
        let json = """
        {
          "file_id": 42,
          "file_name": "Episode.mkv",
          "intro": { "start": 12.5, "end": 74.25 },
          "credits": { "start": 1440.0, "end": 1500.0 }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let version = try! decoder.decode(FileVersion.self, from: Data(json.utf8))

        XCTAssertTrue(version.fileId == 42)
        XCTAssertTrue(version.intro?.start == 12.5)
        XCTAssertTrue(version.intro?.end == 74.25)
        XCTAssertTrue(version.credits?.start == 1440.0)
        XCTAssertTrue(version.credits?.end == 1500.0)
    }

    func testAudiobookDetailAndPresentationFieldsDecode() {
        let json = """
        {
          "content_id": "book-1",
          "type": "audiobook",
          "title": "The Test Book",
          "user_data": {
            "played": false,
            "position_seconds": 95,
            "duration_seconds": 1800
          },
          "audiobook": {
            "authors": [{ "name": "Ada Writer" }],
            "narrators": [{ "name": "Nia Voice" }],
            "publisher": "Silo Press",
            "total_duration_seconds": 1800
          },
          "versions": [
            {
              "file_id": 7,
              "file_name": "Part 1.m4b",
              "codec_audio": "aac",
              "container": "m4b",
              "duration": 900,
              "presentation_kind": "audiobook_part",
              "presentation_group_key": "book-1",
              "presentation_part_index": 1,
              "presentation_part_total": 2
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let detail = try! decoder.decode(ItemDetail.self, from: Data(json.utf8))

        XCTAssertTrue(detail.type == "audiobook")
        XCTAssertTrue(detail.audiobook?.authors.first?.name == "Ada Writer")
        XCTAssertTrue(detail.audiobook?.narrators.first?.name == "Nia Voice")
        XCTAssertTrue(detail.audiobook?.publisher == "Silo Press")
        XCTAssertTrue(detail.audiobook?.totalDurationSeconds == 1800)
        XCTAssertTrue(detail.versions?.first?.presentationKind == "audiobook_part")
        XCTAssertTrue(detail.versions?.first?.presentationGroupKey == "book-1")
        XCTAssertTrue(detail.versions?.first?.presentationPartIndex == 1)
        XCTAssertTrue(detail.versions?.first?.presentationPartTotal == 2)
    }

    func testAudiobookMediaTypeNormalization() {
        XCTAssertTrue(SiloMediaType.isAudiobook("audiobook"))
        XCTAssertTrue(SiloMediaType.isAudiobook("audiobooks"))
        XCTAssertTrue(SiloMediaType.isAudiobook("book"))
        XCTAssertTrue(SiloMediaType.isAudiobook("books"))
        XCTAssertFalse(SiloMediaType.isAudiobook("movies"))

        let library = Library(
            id: 10,
            name: "Audiobooks",
            type: "audiobooks",
            sortOrder: nil,
            posterUrl: nil
        )
        XCTAssertTrue(library.isAudiobookLibrary)
    }

    func testLibrariesResponseDecodesBareArray() {
        let json = """
        [
          { "id": 1, "name": "Movies", "type": "movies" },
          { "id": 10, "name": "Audiobooks", "type": "audiobooks" }
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try! decoder.decode(LibrariesResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.libraries.count == 2)
        XCTAssertTrue(response.libraries[1].isAudiobookLibrary)
    }

    func testAudioPlaybackTimelineMapsGlobalAndLocalTime() {
        let tracks = [
            AudioPlaybackTrack(
                index: 0,
                fileId: 7,
                fileName: nil,
                version: version(fileId: 7, resolution: nil),
                durationSeconds: 120,
                startOffsetSeconds: 0
            ),
            AudioPlaybackTrack(
                index: 1,
                fileId: 8,
                fileName: nil,
                version: version(fileId: 8, resolution: nil),
                durationSeconds: 180,
                startOffsetSeconds: 120
            ),
        ]

        XCTAssertTrue(AudioPlaybackTimeline.trackIndex(at: -10, tracks: tracks) == 0)
        XCTAssertTrue(AudioPlaybackTimeline.trackIndex(at: 119.9, tracks: tracks) == 0)
        XCTAssertTrue(AudioPlaybackTimeline.trackIndex(at: 120, tracks: tracks) == 1)
        XCTAssertTrue(AudioPlaybackTimeline.trackIndex(at: 500, tracks: tracks) == 1)

        let second = tracks[1]
        XCTAssertTrue(AudioPlaybackTimeline.localTime(for: 135, in: second) == 15)
        XCTAssertTrue(AudioPlaybackTimeline.localTime(for: 999, in: second) == 180)
        XCTAssertTrue(AudioPlaybackTimeline.globalTime(for: 45, in: second) == 165)
        XCTAssertTrue(AudioPlaybackTimeline.globalTime(for: -1, in: second) == 120)
    }

    func testRealtimeMarkersUpdatedEventDecodesPayload() {
        let json = """
        {
          "type": "event",
          "session_id": "session-1",
          "name": "markers_updated",
          "payload": {
            "session_id": "session-1",
            "file_id": 42,
            "intro": { "start": 12.0, "end": 75.0 },
            "credits": null
          }
        }
        """

        guard case .event(let event)? = parsePlaybackRealtimeInboundMessage(Data(json.utf8)) else {
            XCTFail("Expected markers_updated event")
            return
        }

        XCTAssertTrue(event.sessionId == "session-1")
        XCTAssertTrue(event.name == .markersUpdated)

        guard let payload = PlaybackRealtimeMarkersUpdatedPayload(payload: event.payload) else {
            XCTFail("Expected markers_updated payload")
            return
        }
        XCTAssertTrue(payload.sessionId == "session-1")
        XCTAssertTrue(payload.fileId == 42)
        XCTAssertTrue(payload.intro?.start == 12.0)
        XCTAssertTrue(payload.intro?.end == 75.0)
        XCTAssertTrue(payload.credits == nil)
        XCTAssertTrue(payload.introUpdate == .set(TimeRange(start: 12.0, end: 75.0)))
        XCTAssertTrue(payload.creditsUpdate == .clear)

        let missingMarkersPayload = PlaybackRealtimeMarkersUpdatedPayload(
            payload: ["file_id": .number(42)]
        )
        XCTAssertTrue(missingMarkersPayload?.introUpdate == .unchanged)
        XCTAssertTrue(missingMarkersPayload?.creditsUpdate == .unchanged)
    }
}
