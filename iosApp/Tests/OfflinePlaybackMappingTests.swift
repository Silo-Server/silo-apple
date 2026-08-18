import XCTest
import Foundation
@testable import Silo

/// Contract coverage for the offline manifest → player metadata mapping in
/// `OfflinePlaybackBuilder`.
///
/// The manifest's `index` is the ordinal within its own audio list, while
/// `AudioTrack.index` means the ffmpeg stream index — it becomes the
/// `ffIndex` the loopback muxer selects a source stream by. Forwarding one as
/// the other named the video stream, so the demuxer discarded the audio the
/// muxer then waited forever to receive, and playback died with a
/// `vodMoovBlocked` error that named nothing about audio. These lock the
/// mapping down, and decode through the same `.convertFromSnakeCase` strategy
/// the API client uses so the wire keys are covered too.
final class OfflinePlaybackMappingTests: XCTestCase {

    // MARK: - Factories

    private func manifest(
        audioTracksJSON: String? = nil,
        selectedAudioTrackIndex: Int? = nil,
        targetBitrateKbps: Int? = nil,
        fileSize: Int64? = 1_000_000_000,
        durationSeconds: Double? = 1358.176
    ) throws -> OfflineManifest {
        var fields = [
            "\"download_id\": \"d1\"",
            "\"content_id\": \"c1\"",
            "\"type\": \"episode\"",
            "\"title\": \"Test Episode\"",
            "\"quality\": \"original\"",
            "\"media_file_id\": 42",
            "\"container\": \"mkv\"",
            "\"codec_video\": \"hevc\"",
            "\"codec_audio\": \"eac3\""
        ]
        if let fileSize { fields.append("\"file_size\": \(fileSize)") }
        if let durationSeconds { fields.append("\"duration_seconds\": \(durationSeconds)") }
        if let audioTracksJSON { fields.append("\"audio_tracks\": \(audioTracksJSON)") }
        if let selectedAudioTrackIndex {
            fields.append("\"selected_audio_track_index\": \(selectedAudioTrackIndex)")
        }
        if let targetBitrateKbps {
            fields.append("\"target_bitrate_kbps\": \(targetBitrateKbps)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            OfflineManifest.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    private func prepared(
        _ manifest: OfflineManifest,
        videoTracks: [VideoTrack] = []
    ) -> PreparedPlayback {
        OfflinePlaybackBuilder.makePreparedPlayback(
            leafContentId: "leaf",
            manifest: manifest,
            mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"),
            videoTracks: videoTracks,
            subtitleURLs: [],
            resumePosition: nil
        )
    }

    /// A video track shaped the way `LocalMediaProbe` emits one: a bare DV
    /// profile number, and `color_transfer` in FFmpeg's spelling.
    private func probedVideoTrack(
        dolbyVisionProfile: Int?,
        colorTransfer: String = "smpte2084"
    ) -> VideoTrack {
        VideoTrack(
            index: 0,
            codec: "hevc",
            width: 3840,
            height: 2160,
            frameRate: "23.976",
            bitrate: nil,
            profile: nil,
            level: 153,
            bitDepth: 10,
            colorRange: "tv",
            colorTransfer: colorTransfer,
            videoRange: nil,
            dolbyVision: dolbyVisionProfile.map(String.init),
            title: nil,
            language: nil
        )
    }

    /// One 5.1 EAC-3 track, shaped exactly as the server writes it: `index` is
    /// the loop counter over the audio list, not the probed stream index.
    private let singleEAC3Track = """
    [{
      "index": 0,
      "title": "Surround 5.1",
      "language": "eng",
      "codec": "eac3",
      "layout": "5.1(side)",
      "channels": 6,
      "bitrate": 640000,
      "sample_rate": 48000,
      "default": true
    }]
    """

    // MARK: - Audio track identity

    func testManifestOrdinalIsNotForwardedAsAStreamIndex() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        // The manifest said `index: 0`. Forwarding it would claim the audio
        // lives on stream 0, which on any normal file is the video stream.
        XCTAssertNil(track.index)
    }

    func testAudioTrackDetailSurvivesTheWire() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        XCTAssertEqual(track.codec, "eac3")
        XCTAssertEqual(track.language, "eng")
        XCTAssertEqual(track.channels, 6)
        XCTAssertEqual(track.title, "Surround 5.1")
        // `layout` feeds the detail badge and the loopback's channel handling;
        // `sample_rate` only survives `.convertFromSnakeCase` if the coding key
        // is spelled in its converted camelCase form.
        XCTAssertEqual(track.channelLayout, "5.1(side)")
        XCTAssertEqual(track.bitrate, 640_000)
        XCTAssertEqual(track.sampleRate, 48_000)
        XCTAssertEqual(track.isDefault, true)
    }

    func testEmbeddedTitleIsNotFabricated() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        // The server collapsed title and embedded title into one field. Echoing
        // the same string back as both would corrupt the audio-pref signature,
        // which compares them separately.
        XCTAssertNil(track.embeddedTitle)
    }

    func testAbsentAudioTracksStayAbsent() throws {
        let version = prepared(try manifest()).selectedVersion

        // Manifests written before the client decoded these fields carry no
        // audio list at all; they must degrade to nil rather than an empty
        // array that would claim the file has no audio.
        XCTAssertNil(version.audioTracks)
    }

    // MARK: - Selected track

    func testSelectedAudioTrackIndexReachesTheSession() throws {
        let session = prepared(try manifest(
            audioTracksJSON: singleEAC3Track,
            selectedAudioTrackIndex: 0
        )).session

        // Ordinal into `version.audioTracks` — the same space the server's
        // `audio_track_index` uses.
        XCTAssertEqual(session.audioTrackIndex, 0)
    }

    // MARK: - Bitrate

    func testBitrateIsDerivedFromTheDeliveredFile() throws {
        let version = prepared(try manifest()).selectedVersion

        // 1_000_000_000 bytes * 8 / 1358.176s / 1000 ≈ 5890 kbps.
        XCTAssertEqual(version.bitrate, 5890)
    }

    func testBitrateFallsBackToTargetWhenDurationIsUnusable() throws {
        let version = prepared(try manifest(
            targetBitrateKbps: 4000,
            durationSeconds: 0
        )).selectedVersion

        XCTAssertEqual(version.bitrate, 4000)
    }

    func testUnusableDurationDoesNotTrapOnConversion() throws {
        // A sub-second duration divides into a value `Int(_:)` traps on.
        // Nothing to assert beyond "this returned at all", plus that it did
        // not invent a bitrate from the corrupt pair.
        let version = prepared(try manifest(durationSeconds: 0.000_001)).selectedVersion

        XCTAssertNil(version.bitrate)
    }

    func testBitrateIsAbsentWhenTheManifestCannotSupportIt() throws {
        let version = prepared(try manifest(fileSize: nil, durationSeconds: nil)).selectedVersion

        XCTAssertNil(version.bitrate)
    }

    // MARK: - Dolby Vision parity

    /// Route the offline playback through the real planner. The DV helpers are
    /// fileprivate to the planner, so asserting on the plan it produces both
    /// exercises them and pins the contract that actually matters.
    private func plan(
        dolbyVisionProfile: Int,
        colorTransfer: String = "smpte2084"
    ) throws -> PlaybackExecutionPlan {
        try plan(videoTracks: [probedVideoTrack(
            dolbyVisionProfile: dolbyVisionProfile,
            colorTransfer: colorTransfer
        )])
    }

    private func plan(videoTracks: [VideoTrack]) throws -> PlaybackExecutionPlan {
        let playback = prepared(
            try manifest(audioTracksJSON: singleEAC3Track, selectedAudioTrackIndex: 0),
            videoTracks: videoTracks
        )
        return ApplePlaybackRoutePlanner().makeExecutionPlan(
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
                preferredAudioTrackIndex: 0,
                selectedPrimarySubtitleTrackId: nil,
                selectedSecondarySubtitleTrackId: nil,
                dolbyVisionPolicy: .default
            )
        )
    }

    func testProbedDolbyVisionRoutesToTheDolbyVisionEngine() throws {
        for profile in [5, 7, 8] {
            let plan = try plan(dolbyVisionProfile: profile)

            // The end state asked for: a downloaded DV file reaches the
            // DV-capable engine with a resolved loopback session, exactly as
            // the same file does when streamed.
            XCTAssertEqual(plan.engine, .siloPlayerLoopback, "profile \(profile)")
            XCTAssertNotNil(plan.loopbackSession, "profile \(profile)")
            XCTAssertEqual(plan.sourceMetadata.dolbyVisionProfile, profile)
            XCTAssertTrue(
                plan.reason.contains("dolby_vision"),
                "profile \(profile) expected a Dolby Vision reason, got \(plan.reason)"
            )
        }
    }

    func testWithoutAProbedTrackDolbyVisionIsInvisible() throws {
        // The state this change exists to fix: the manifest describes no video
        // stream, so with nothing probed off the file a DV download planned as
        // plain HEVC and lost DV silently.
        let plan = try plan(videoTracks: [])

        XCTAssertNil(plan.sourceMetadata.dolbyVisionProfile)
        XCTAssertFalse(plan.reason.contains("dolby_vision"), plan.reason)
    }

    func testProbedTransferSplitsProfile8BaseLayers() throws {
        // 8.1 (PQ base) and 8.4 (HLG base) are only distinguishable by
        // color_transfer, which is exactly what a video track carries.
        let pq = try plan(dolbyVisionProfile: 8, colorTransfer: "smpte2084")
        let hlg = try plan(dolbyVisionProfile: 8, colorTransfer: "arib-std-b67")

        XCTAssertEqual(pq.loopbackSession?.manifestMetadata.videoRange, "PQ")
        XCTAssertEqual(hlg.loopbackSession?.manifestMetadata.videoRange, "HLG")
    }

    func testProbedColourRangeAndFrameRateReachThePlan() throws {
        let plan = try plan(dolbyVisionProfile: 8)

        XCTAssertEqual(plan.sourceMetadata.colorRange, "tv")
        XCTAssertEqual(plan.loopbackSession?.sourceVideoFrameRate, 23.976)
    }
}
