import Foundation
import XCTest
@testable import Silo

/// Stage-0 characterization: offline manifest → executable plan for the two
/// download shapes `OfflinePlaybackMappingTests` does not cover.
///
/// That file pins the audio-identity fix and the Dolby Vision parity path.
/// What is still unpinned is (a) what a *multi*-audio download does with its
/// selection when it reaches the shared planner, and (b) that a download's
/// subtitles arrive as sidecars only — the manifest describes no embedded
/// tracks at all, so the bitmap-subtitle route gate that fires for the same
/// file streamed cannot fire offline.
final class OfflinePlaybackMappingMatrixTests: XCTestCase {

    // MARK: - Factories

    private func manifest(
        audioTracksJSON: String? = nil,
        selectedAudioTrackIndex: Int? = nil,
        container: String = "mkv",
        codecVideo: String = "hevc",
        codecAudio: String = "eac3"
    ) throws -> OfflineManifest {
        var fields = [
            "\"download_id\": \"d1\"",
            "\"content_id\": \"c1\"",
            "\"type\": \"movie\"",
            "\"title\": \"Test Movie\"",
            "\"quality\": \"original\"",
            "\"media_file_id\": 42",
            "\"container\": \"\(container)\"",
            "\"codec_video\": \"\(codecVideo)\"",
            "\"codec_audio\": \"\(codecAudio)\"",
            "\"file_size\": 1000000000",
            "\"duration_seconds\": 1358.176"
        ]
        if let audioTracksJSON { fields.append("\"audio_tracks\": \(audioTracksJSON)") }
        if let selectedAudioTrackIndex {
            fields.append("\"selected_audio_track_index\": \(selectedAudioTrackIndex)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            OfflineManifest.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    /// Three tracks as the server writes them: `index` is the ordinal within
    /// this list, never a stream index.
    private let threeAudioTracks = """
    [
      {
        "index": 0, "title": "English 5.1", "language": "eng", "codec": "eac3",
        "layout": "5.1(side)", "channels": 6, "bitrate": 640000,
        "sample_rate": 48000, "default": true
      },
      {
        "index": 1, "title": "English Commentary", "language": "eng", "codec": "aac",
        "layout": "stereo", "channels": 2, "bitrate": 192000,
        "sample_rate": 48000, "default": false
      },
      {
        "index": 2, "title": "Japanese Atmos", "language": "jpn", "codec": "truehd",
        "layout": "7.1", "channels": 8, "bitrate": 4000000,
        "sample_rate": 48000, "default": false
      }
    ]
    """

    private func prepared(
        _ manifest: OfflineManifest,
        subtitleURLs: [SubtitleUrl] = []
    ) -> PreparedPlayback {
        OfflinePlaybackBuilder.makePreparedPlayback(
            leafContentId: "leaf",
            manifest: manifest,
            mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"),
            videoTracks: [],
            subtitleURLs: subtitleURLs,
            resumePosition: nil
        )
    }

    private func plan(
        _ playback: PreparedPlayback,
        preferredAudioTrackIndex: Int?
    ) -> PlaybackExecutionPlan {
        ApplePlaybackRoutePlanner().makeExecutionPlan(
            input: ApplePlaybackPlannerInput(
                session: playback.session,
                selectedVersion: playback.selectedVersion,
                streamRequest: StreamRequest(
                    url: URL(fileURLWithPath: "/tmp/media.mkv"),
                    headers: [:],
                    serverUrl: ""
                ),
                routeRequirements: .baseline,
                selectedAudioTrackId: nil,
                pendingAudioFfIndex: nil,
                preferredAudioTrackIndex: preferredAudioTrackIndex,
                selectedPrimarySubtitleTrackId: nil,
                selectedSecondarySubtitleTrackId: nil,
                dolbyVisionPolicy: .default
            )
        )
    }

    // MARK: - Multi-audio downloads

    func testEveryManifestAudioTrackSurvivesWithoutAStreamIndex() throws {
        let version = prepared(
            try manifest(audioTracksJSON: threeAudioTracks, selectedAudioTrackIndex: 0)
        ).selectedVersion
        let tracks = try XCTUnwrap(version.audioTracks)

        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.map(\.codec), ["eac3", "aac", "truehd"])
        XCTAssertEqual(tracks.map(\.channels), [6, 2, 8])
        XCTAssertEqual(tracks.map(\.language), ["eng", "eng", "jpn"])
        // Ordinal-only identity: not one of the three claims a stream index.
        XCTAssertEqual(tracks.compactMap(\.index), [])
    }

    func testSelectedOrdinalDrivesTheMuxedTrackNotTheFirstOne() throws {
        let playback = prepared(
            try manifest(audioTracksJSON: threeAudioTracks, selectedAudioTrackIndex: 2)
        )
        XCTAssertEqual(playback.session.audioTrackIndex, 2)

        let result = plan(playback, preferredAudioTrackIndex: 2)
        let selected = try XCTUnwrap(result.loopbackSession?.selectedAudio)

        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(selected.trackIndex, 2)
        XCTAssertEqual(selected.sourceCodec, "truehd")
        XCTAssertEqual(selected.sourceChannelCount, 8)
        // TrueHD cannot be carried in fMP4, so the loopback normalizes it —
        // never a passthrough copy, never a lossy re-encode.
        XCTAssertEqual(selected.outputMode, .requireFLAC)
    }

    func testCommentaryTrackSelectionCopiesRatherThanNormalizes() throws {
        let playback = prepared(
            try manifest(audioTracksJSON: threeAudioTracks, selectedAudioTrackIndex: 1)
        )
        let result = plan(playback, preferredAudioTrackIndex: 1)
        let selected = try XCTUnwrap(result.loopbackSession?.selectedAudio)

        XCTAssertEqual(selected.trackIndex, 1)
        XCTAssertEqual(selected.sourceCodec, "aac")
        XCTAssertEqual(selected.outputMode, .copy)
    }

    func testAllThreeTracksArePublishedToThePlayerNotJustTheSelectedOne() throws {
        let playback = prepared(
            try manifest(audioTracksJSON: threeAudioTracks, selectedAudioTrackIndex: 1)
        )
        let result = plan(playback, preferredAudioTrackIndex: 1)
        let available = try XCTUnwrap(result.loopbackSession?.availableAudioTracks)

        XCTAssertEqual(available.count, 3)
        XCTAssertEqual(available.filter(\.isSelected).count, 1)
        XCTAssertEqual(available.first(where: \.isSelected)?.codec, "aac")
    }

    // MARK: - Subtitles on a download

    /// A download's subtitles are fetched as sidecar files; the manifest
    /// carries no embedded subtitle inventory. So the version the planner sees
    /// has `subtitleTracks == nil` — the offline route can never be gated on a
    /// bitmap subtitle the way the streamed route is.
    func testDownloadedSubtitlesArriveAsSidecarsAndNeverGateTheRoute() throws {
        let pgsSidecar = SubtitleUrl(
            index: 0,
            language: "eng",
            codec: "hdmv_pgs_subtitle",
            label: "English (PGS)",
            source: "downloaded",
            forced: false,
            default: false,
            hearingImpaired: false,
            fontBundleUrl: nil,
            url: "file:///tmp/subs/0.sup"
        )
        let playback = prepared(
            try manifest(audioTracksJSON: threeAudioTracks, selectedAudioTrackIndex: 0),
            subtitleURLs: [pgsSidecar]
        )

        XCTAssertNil(playback.selectedVersion.subtitleTracks)
        XCTAssertEqual(playback.session.subtitleUrls?.count, 1)
        XCTAssertEqual(playback.session.subtitleUrls?.first?.codec, "hdmv_pgs_subtitle")
        XCTAssertEqual(playback.session.subtitleUrls?.first?.index, 0)

        // Same file, same PGS track: streamed it produces a
        // `silo_bitmap_subtitles_*` trace token; offline the planner never
        // sees a subtitle at all.
        let result = plan(playback, preferredAudioTrackIndex: 0)
        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertFalse(
            result.decisionTrace.contains { $0.hasPrefix("silo_bitmap_subtitles") },
            result.decisionTrace.joined(separator: ",")
        )
        XCTAssertEqual(result.parityBlockers, [])
    }

    func testAnEmptySidecarListStaysNilRatherThanAnEmptyArray() throws {
        let playback = prepared(try manifest(audioTracksJSON: threeAudioTracks))
        XCTAssertNil(playback.session.subtitleUrls)
    }

    // MARK: - Offline transport shape

    /// The synthetic session is always `direct` and always carries the
    /// `file://` URL, which is what keeps the source proxy out of the offline
    /// path entirely.
    func testOfflineSessionIsADirectFileURLSession() throws {
        let playback = prepared(try manifest(audioTracksJSON: threeAudioTracks))

        XCTAssertEqual(playback.session.playMethod, "direct")
        XCTAssertEqual(playback.session.sessionId, "offline-d1")
        XCTAssertTrue(playback.session.streamUrl.hasPrefix("file://"))

        let result = plan(playback, preferredAudioTrackIndex: 0)
        XCTAssertEqual(result.delivery, .direct)
        XCTAssertEqual(result.loopbackSession?.sourceURL.isFileURL, true)
    }
}
