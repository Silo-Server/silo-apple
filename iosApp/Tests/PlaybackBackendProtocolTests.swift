import AVFoundation
import XCTest
@testable import Silo

/// The one thing worth asserting about the `PlaybackBackend` seam on its own:
/// the real backend satisfies it. `FakePlaybackBackend`'s own fidelity is
/// exercised against production code by `PlaybackEngineSessionTests`, which
/// drives the session through the double.
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
}
