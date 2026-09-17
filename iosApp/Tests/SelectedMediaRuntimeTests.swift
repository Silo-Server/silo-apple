import Foundation
import XCTest
@testable import Silo

final class SelectedMediaRuntimeTests: XCTestCase {
    func testSelectedSinglePartVersionOverridesEditorialRuntimeImmediately() throws {
        let detail = try decodedDetail()
        let versions = try XCTUnwrap(detail.versions)

        XCTAssertEqual(SelectedMediaRuntime.minutes(detail: detail, selectedVersion: versions[0]), 229)
        XCTAssertEqual(SelectedMediaRuntime.minutes(detail: detail, selectedVersion: versions[1]), 251)
    }

    func testMultipartVariantUsesCombinedDuration() throws {
        let detail = try decodedDetail(playbackVariants: """
        [{
          "variant_id":"multipart","part_count":2,"total_duration":6600,
          "parts":[
            {"part_index":0,"versions":[{"file_id":1,"duration":3600}]},
            {"part_index":1,"versions":[{"file_id":3,"duration":3000}]}
          ]
        }]
        """)

        XCTAssertEqual(
            SelectedMediaRuntime.minutes(detail: detail, selectedVersion: detail.versions?.first),
            110
        )
    }

    func testSinglePartVariantRetainsSelectedFileDuration() throws {
        let detail = try decodedDetail(playbackVariants: """
        [{
          "variant_id":"single","part_count":1,"total_duration":99999,
          "parts":[{"part_index":0,"versions":[{"file_id":2,"duration":15060}]}]
        }]
        """)

        XCTAssertEqual(
            SelectedMediaRuntime.minutes(detail: detail, selectedVersion: detail.versions?.last),
            251
        )
    }

    func testMissingAndUnusableFileDurationFallsBackToEditorialRuntime() throws {
        let detail = try decodedDetail()
        XCTAssertEqual(SelectedMediaRuntime.minutes(detail: detail, selectedVersion: nil), 229)

        for duration in [0.0, -1.0, .nan, .infinity, .greatestFiniteMagnitude] {
            let invalid = version(fileId: 9, duration: duration)
            XCTAssertEqual(SelectedMediaRuntime.minutes(detail: detail, selectedVersion: invalid), 229)
        }
    }

    func testMissingPlaybackVariantsRemainsBackwardCompatible() throws {
        let detail = try decodedDetail(playbackVariants: nil)
        XCTAssertEqual(
            SelectedMediaRuntime.minutes(detail: detail, selectedVersion: detail.versions?.last),
            251
        )
    }

#if !os(tvOS)
    func testIOSRuntimeAndQualityMetadataFollowOnlySelectedVersion() throws {
        let detail = try decodedDetail()
        let versions = try XCTUnwrap(detail.versions)

        XCTAssertEqual(
            PhoneHeroMetadata.movieFactsLine(from: detail, version: versions[0]),
            [.text("3h 49m"), .chip("HD")]
        )
        XCTAssertEqual(
            PhoneHeroMetadata.movieFactsLine(from: detail, version: versions[1]),
            [.text("4h 11m"), .chip("4K"), .chip("DOLBY VISION"), .chip("7.1"), .chip("CC")]
        )
        XCTAssertEqual(DetailPlaybackFormatting.versionShortLabel(versions[0]), "1080p · H.264 · AAC")
        XCTAssertEqual(DetailPlaybackFormatting.versionShortLabel(versions[1]), "2160p · HEVC · DV · TrueHD")
        XCTAssertEqual(
            DetailPlaybackFormatting.audioValueLabel(
                version: versions[1],
                selectedAudioTrackIndex: nil,
                annotateAuto: true
            ),
            "Auto: English · TrueHD · 7.1"
        )
        XCTAssertEqual(
            DetailPlaybackFormatting.subtitleValueLabel(
                version: versions[1],
                selectedSubtitleTrackIndex: nil
            ),
            "English · SRT"
        )
    }
#else
    func testTVOSRuntimeMetadataFollowsOnlySelectedVersion() throws {
        let detail = try decodedDetail()
        let versions = try XCTUnwrap(detail.versions)

        XCTAssertEqual(TVHeroMetadata.movieFactsLine(from: detail, version: versions[0]), [.text("3h 49m")])
        XCTAssertEqual(TVHeroMetadata.movieFactsLine(from: detail, version: versions[1]), [.text("4h 11m")])
        XCTAssertEqual(DetailPlaybackFormatting.versionShortLabel(versions[0]), "1080p · H.264 · AAC")
        XCTAssertEqual(DetailPlaybackFormatting.versionShortLabel(versions[1]), "2160p · HEVC · DV · TrueHD")
        XCTAssertEqual(
            TVPlaybackSelectionSummary.make(
                currentVersion: versions[1],
                selectedVersionFileId: versions[1].fileId,
                selectedAudioTrackIndex: nil,
                selectedSubtitleTrackIndex: 0,
                subtitleMode: nil,
                subtitleSignature: nil,
                preferredSubtitleLanguage: nil,
                showForcedSubtitles: false
            ),
            TVPlaybackSelectionSummary(
                version: "2160p · DV",
                audio: "Auto · English · TrueHD · 7.1",
                subtitles: "English · SRT"
            )
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let episode = try decoder.decode(
            EpisodeListItem.self,
            from: Data(#"{"content_id":"episode","season_number":1,"episode_number":1,"runtime":48}"#.utf8)
        )
        XCTAssertEqual(
            TVHeroMetadata.seriesEpisodeFactsLine(
                episode: episode,
                playbackDetail: detail,
                selectedVersion: versions[1]
            ),
            [.text("4h 11m")]
        )
    }
#endif

    private func decodedDetail(playbackVariants: String? = "[]") throws -> ItemDetail {
        let variantsField = playbackVariants.map { ",\"playback_variants\":\($0)" } ?? ""
        let json = """
        {
          "content_id":"movie","type":"movie","title":"Once Upon a Time in America","runtime":229,
          "versions":[
            {
              "file_id":1,"duration":13740,"resolution":"1080p","codec_video":"h264","codec_audio":"aac",
              "audio_tracks":[{"codec":"aac","language":"eng","channels":2,"default":true}]
            },
            {
              "file_id":2,"duration":15060,"resolution":"2160p","codec_video":"hevc","codec_audio":"truehd","hdr":true,
              "video_tracks":[{"codec":"hevc","dolby_vision":"Profile 8","hdr":true}],
              "audio_tracks":[{"codec":"truehd","language":"eng","channel_layout":"7.1","channels":8,"default":true}],
              "subtitle_tracks":[{"index":0,"codec":"srt","language":"eng"}]
            }
          ]\(variantsField)
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }

    private func version(fileId: Int, duration: Double) -> FileVersion {
        FileVersion(
            fileId: fileId,
            fileName: nil,
            resolution: nil,
            codecVideo: nil,
            codecAudio: nil,
            hdr: nil,
            container: nil,
            fileSize: nil,
            duration: duration,
            bitrate: nil,
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil
        )
    }
}
