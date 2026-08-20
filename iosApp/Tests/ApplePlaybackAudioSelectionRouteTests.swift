import XCTest
@testable import Silo

/// Pins the contract behind the `client_audio_track_selection_v1` feature the
/// `original_http` capability advertises: a plan whose selected audio track is
/// not the container default must not execute on native-direct AVPlayer
/// (which cannot apply a catalog audio index) — it goes to the loopback,
/// whose writer maps exactly the selected track. The container-default case
/// keeps native-direct.
final class ApplePlaybackAudioSelectionRouteTests: XCTestCase {

    private func plan(version: FileVersion, session: PlaybackSessionResponse) -> PlaybackExecutionPlan {
        makeTestExecutionPlan(
            session: session,
            version: version,
            streamRequest: StreamRequest(
                url: testStreamURL,
                headers: [:],
                serverUrl: "https://example.invalid"
            )
        )
    }

    private var twoTrackVersion: FileVersion {
        mp4Version(audioTracks: [
            makeTestAudioTrack(index: 1, codec: "aac", language: "zh", isDefault: true),
            makeTestAudioTrack(index: 2, codec: "aac", language: "en", isDefault: false),
        ])
    }

    private func mp4Version(audioTracks: [AudioTrack]) -> FileVersion {
        makeTestVersion(
            container: "mp4",
            codecVideo: "h264",
            codecAudio: "aac",
            resolution: "1080p",
            bitrate: 8_000,
            audioTracks: audioTracks
        )
    }

    func testContainerDefaultAudioKeepsNativeDirect() {
        let result = plan(version: twoTrackVersion, session: makeTestSession(audioTrackIndex: 0))
        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
        XCTAssertFalse(result.decisionTrace.contains("audio_selection_non_default"))
    }

    func testNonDefaultAudioSelectionRoutesToLoopback() {
        let result = plan(version: twoTrackVersion, session: makeTestSession(audioTrackIndex: 1))
        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertTrue(result.decisionTrace.contains("audio_selection_non_default"))
        // The loopback spec must carry the selected (non-default) track.
        XCTAssertEqual(result.loopbackSession?.selectedAudio.trackIndex, 1)
    }

    func testNoServerSelectionKeepsNativeDirect() {
        let result = plan(version: twoTrackVersion, session: makeTestSession(audioTrackIndex: nil))
        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
    }

    func testSingleTrackNeverBlocks() {
        let single = mp4Version(
            audioTracks: [makeTestAudioTrack(index: 1, codec: "aac", language: "en", isDefault: false)]
        )
        let result = plan(version: single, session: makeTestSession(audioTrackIndex: 0))
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
