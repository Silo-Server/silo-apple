import AVFoundation
import XCTest
@testable import Silo

/// Wave 1A smoke coverage for the `PlaybackBackend` seam: the real backend
/// satisfies the protocol, and `FakePlaybackBackend` is a faithful enough
/// stand-in for the control-plane tests that follow (it records call order and
/// lets a test fire any backend callback).
@MainActor
final class PlaybackBackendProtocolTests: XCTestCase {

    /// Compile-level: `AVPlayerBackend` is usable through the protocol without
    /// any call site change, and a protocol-typed call reaches the real
    /// implementation (`isPaused()` returns the backend's own
    /// `isUserPaused`, which starts `false`).
    func testAVPlayerBackendIsUsableAsPlaybackBackend() {
        let concrete = AVPlayerBackend(player: AVPlayer())
        let backend: any PlaybackBackend = concrete
        XCTAssertFalse(backend.isPaused())
        XCTAssertEqual(backend.currentUserVolume, 1.0)
        backend.dispose()
    }

    /// The fake records calls in order with their arguments, and its `fire…`
    /// helpers invoke whatever the system under test installed on the callback
    /// properties.
    func testFakeRecordsCallOrderAndFiresCallbacks() {
        let fake = FakePlaybackBackend()
        let backend: any PlaybackBackend = fake

        backend.loadRemoteHLS(
            url: URL(string: "http://127.0.0.1:9/master.m3u8")!,
            headers: ["X-Silo": "1"],
            startTime: 12.5
        )
        backend.play()
        backend.seek(to: 42)
        backend.pause()

        XCTAssertEqual(
            fake.calls,
            [
                "loadRemoteHLS(http://127.0.0.1:9/master.m3u8,1,12.5)",
                "play()",
                "seek(42.0)",
                "pause()",
            ]
        )

        var loadedReasons: [String] = []
        var failures: [PlaybackFailure] = []
        backend.onFileLoaded = { loadedReasons.append($0) }
        backend.onError = { failures.append($0) }

        fake.fireFileLoaded(reason: "first_frame")
        fake.fireError(.unknown("boom"))
        fake.fireError(.loopbackPlaylistURLUnavailable)

        XCTAssertEqual(loadedReasons, ["first_frame"])
        XCTAssertEqual(failures, [.unknown("boom"), .loopbackPlaylistURLUnavailable])
    }

    /// The fake's getters read plain stored values and the pull-direction
    /// providers round-trip, so a control-plane test can pose any backend
    /// state without logic in the double.
    func testFakeGettersAndProvidersRoundTrip() {
        let fake = FakePlaybackBackend()
        let backend: any PlaybackBackend = fake

        fake.isPausedValue = true
        fake.userVolumeValue = 0.25
        fake.externalPlaybackActive = true
        fake.externalPlaybackAllowed = true
        fake.hasControlledSubtitleSelectionValue = true

        XCTAssertTrue(backend.isPaused())
        XCTAssertEqual(backend.currentUserVolume, 0.25)
        XCTAssertTrue(backend.isExternalPlaybackActive)
        XCTAssertTrue(backend.isExternalPlaybackAllowed)
        XCTAssertTrue(backend.hasControlledSubtitleSelection)

        backend.isPictureInPictureActiveProvider = { true }
        backend.sourceOutageStateProvider = { true }
        XCTAssertEqual(fake.isPictureInPictureActiveProvider?(), true)
        XCTAssertEqual(fake.sourceOutageStateProvider?(), true)
        XCTAssertEqual(fake.calls, ["isPaused()"])
    }
}
