import XCTest
@testable import Silo

/// Pins the contract behind the `client_audio_track_selection_v1` feature the
/// `original_http` capability advertises: a plan whose selected audio track is
/// not the container default must not execute on native-direct AVPlayer
/// (which cannot apply a catalog audio index) — it goes to the loopback,
/// whose writer maps exactly the selected track. The container-default case
/// keeps native-direct.
final class ApplePlaybackAudioSelectionRouteTests: XCTestCase {

    private static let streamURL = URL(string: "https://example.invalid/stream")!

    private func makeSession(audioTrackIndex: Int?) -> PlaybackSessionResponse {
        PlaybackSessionResponse(
            sessionId: "audio-route-session",
            userId: nil,
            profileId: nil,
            mediaFileId: 1,
            playMethod: "direct",
            position: 0,
            isPaused: false,
            streamUrl: Self.streamURL.absoluteString,
            audioTrackIndex: audioTrackIndex,
            durationSeconds: 120,
            subtitleUrls: nil,
            playbackInfo: nil
        )
    }

    private func makeAudioTrack(index: Int, language: String, isDefault: Bool) -> AudioTrack {
        AudioTrack(
            index: index,
            codec: "aac",
            channels: 2,
            channelLayout: "stereo",
            bitrate: 128_000,
            sampleRate: 48_000,
            language: language,
            title: nil,
            embeddedTitle: nil,
            isDefault: isDefault
        )
    }

    private func makeVersion(audioTracks: [AudioTrack]) -> FileVersion {
        FileVersion(
            fileId: 1,
            fileName: "audio-route.mp4",
            resolution: "1080p",
            codecVideo: "h264",
            codecAudio: "aac",
            hdr: false,
            container: "mp4",
            fileSize: 1_000_000,
            duration: 120,
            bitrate: 8_000,
            videoTracks: nil,
            audioTracks: audioTracks,
            subtitleTracks: nil,
            chapters: nil,
            effectiveAudioTrackIndex: 0
        )
    }

    private func plan(version: FileVersion, session: PlaybackSessionResponse) -> PlaybackExecutionPlan {
        makeTestExecutionPlan(
            session: session,
            version: version,
            streamRequest: StreamRequest(
                url: Self.streamURL,
                headers: [:],
                serverUrl: "https://example.invalid"
            )
        )
    }

    private var twoTrackVersion: FileVersion {
        makeVersion(audioTracks: [
            makeAudioTrack(index: 1, language: "zh", isDefault: true),
            makeAudioTrack(index: 2, language: "en", isDefault: false),
        ])
    }

    func testContainerDefaultAudioKeepsNativeDirect() {
        let result = plan(version: twoTrackVersion, session: makeSession(audioTrackIndex: 0))
        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
        XCTAssertFalse(result.decisionTrace.contains("audio_selection_non_default"))
    }

    func testNonDefaultAudioSelectionRoutesToLoopback() {
        let result = plan(version: twoTrackVersion, session: makeSession(audioTrackIndex: 1))
        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertTrue(result.decisionTrace.contains("audio_selection_non_default"))
        // The loopback spec must carry the selected (non-default) track.
        XCTAssertEqual(result.loopbackSession?.selectedAudio.trackIndex, 1)
    }

    func testNoServerSelectionKeepsNativeDirect() {
        let result = plan(version: twoTrackVersion, session: makeSession(audioTrackIndex: nil))
        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
    }

    func testSingleTrackNeverBlocks() {
        let single = makeVersion(audioTracks: [makeAudioTrack(index: 1, language: "en", isDefault: false)])
        let result = plan(version: single, session: makeSession(audioTrackIndex: 0))
        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
    }

    func testOriginalHTTPAdvertisesClientAudioTrackSelection() {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let original = snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        XCTAssertTrue(original?.features.contains("client_audio_track_selection_v1") == true)
        let progressive = snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.progressive]
        XCTAssertEqual(progressive?.supportedOnDevice, false)
        XCTAssertNotNil(progressive?.failureReason)
    }
}
