import MediaPlayer
import XCTest
@testable import Silo

/// Exercises the owners of the process-wide `MPRemoteCommandCenter.shared()`
/// and `MPNowPlayingInfoCenter.default()` against the real centers in the
/// hosted app, so one owner's teardown is checked for what it leaves behind
/// for the others.
@MainActor
final class SharedNowPlayingArbiterTests: XCTestCase {
    private var audio: AudioNowPlayingCoordinator?
    private var video: AetherVideoNowPlayingCoordinator?
    #if os(iOS)
    private var controller: NowPlayingController?
    #endif

    override func setUp() async throws {
        try await super.setUp()
        for command in transportCommands {
            command.isEnabled = false
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    override func tearDown() async throws {
        // The arbiter is a process-wide singleton; leave it with no claims.
        video?.detach()
        audio?.detach()
        #if os(iOS)
        controller?.detach()
        controller = nil
        #endif
        video = nil
        audio = nil
        try await super.tearDown()
    }

    // MARK: - Audio and video

    func testAudioDetachAsLastClaimantDisablesSharedCommands() {
        let audio = attachAudio(title: "Book")
        XCTAssertTrue(shared.playCommand.isEnabled)
        XCTAssertEqual(publishedTitle, "Book")

        audio.detach()

        assertTransportDisabled()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testVideoLeavingWhileAudioHoldsCentersDisablesStopAndRestoresAudio() {
        attachAudio(title: "Book")
        let video = attachVideo(title: "Movie")
        XCTAssertEqual(publishedTitle, "Movie")
        XCTAssertTrue(shared.stopCommand.isEnabled)
        XCTAssertTrue(shared.nextTrackCommand.isEnabled)

        video.detach()

        XCTAssertFalse(shared.stopCommand.isEnabled)
        XCTAssertFalse(shared.nextTrackCommand.isEnabled)
        XCTAssertTrue(shared.playCommand.isEnabled)
        XCTAssertEqual(publishedTitle, "Book")
    }

    // MARK: - SiloControl

    #if os(iOS)
    func testSiloControlDetachRestoresAudiobookMetadata() {
        attachAudio(title: "Book")
        let controller = attachController(title: "Show")
        XCTAssertEqual(publishedTitle, "Show")
        XCTAssertTrue(shared.stopCommand.isEnabled)

        controller.detach()

        XCTAssertEqual(publishedTitle, "Book")
        XCTAssertTrue(shared.playCommand.isEnabled)
        XCTAssertFalse(shared.stopCommand.isEnabled)
    }

    func testAudiobookDetachRestoresSiloControlSession() {
        attachController(title: "Show")
        let audio = attachAudio(title: "Book")
        XCTAssertEqual(publishedTitle, "Book")

        audio.detach()

        XCTAssertEqual(publishedTitle, "Show")
        XCTAssertTrue(shared.stopCommand.isEnabled)
    }

    func testSiloControlDetachAloneClearsInfoAndDisablesCommands() {
        let controller = attachController(title: "Show")
        XCTAssertEqual(publishedTitle, "Show")

        controller.detach()

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        assertTransportDisabled()
    }

    func testSiloControlDoesNotInheritAnotherOwnersFields() {
        attachAudio(title: "Book", artist: "Narrator")
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String,
            "Narrator"
        )

        attachController(title: "Show", artist: nil)

        XCTAssertEqual(publishedTitle, "Show")
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist])
    }

    func testReleaseRestoresEverySurvivingClaimant() {
        attachController(title: "Show")
        attachAudio(title: "Book")
        let video = attachVideo(title: "Movie")
        XCTAssertTrue(shared.nextTrackCommand.isEnabled)

        video.detach()

        XCTAssertEqual(publishedTitle, "Book")
        // SiloControl still drives stop; nobody left drives next.
        XCTAssertTrue(shared.stopCommand.isEnabled)
        XCTAssertFalse(shared.nextTrackCommand.isEnabled)
        XCTAssertTrue(shared.playCommand.isEnabled)
    }
    #endif

    // MARK: - Helpers

    private var shared: MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

    private var transportCommands: [MPRemoteCommand] {
        let center = shared
        return [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
            center.stopCommand,
            center.nextTrackCommand,
        ]
    }

    private var publishedTitle: String? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
    }

    private func assertTransportDisabled(file: StaticString = #filePath, line: UInt = #line) {
        for command in transportCommands {
            XCTAssertFalse(command.isEnabled, "\(command) is still enabled", file: file, line: line)
        }
    }

    @discardableResult
    private func attachAudio(title: String, artist: String? = nil) -> AudioNowPlayingCoordinator {
        let audio = AudioNowPlayingCoordinator()
        self.audio = audio
        audio.attach(session: nil, handlers: AudioNowPlayingCoordinator.Handlers(
            play: {},
            pause: {},
            isPaused: { true },
            currentTime: { 0 },
            seek: { _ in },
            skip: { _ in }
        ))
        audio.update(
            title: title,
            artist: artist,
            albumTitle: "Album",
            duration: 100,
            position: 0,
            isPlaying: true,
            playbackRate: 1
        )
        return audio
    }

    @discardableResult
    private func attachVideo(title: String) -> AetherVideoNowPlayingCoordinator {
        let video = AetherVideoNowPlayingCoordinator()
        self.video = video
        video.attach(
            session: nil,
            useSharedFallback: true,
            handlers: AetherVideoNowPlayingCoordinator.Handlers(
                play: {},
                pause: {},
                isPaused: { true },
                currentTime: { 0 },
                seek: { _ in },
                stop: {},
                next: {},
                isNextEnabled: { true }
            )
        )
        video.update(title: title, duration: 100, position: 0, isPlaying: true)
        return video
    }

    #if os(iOS)
    @discardableResult
    private func attachController(title: String, artist: String? = nil) -> NowPlayingController {
        let controller = NowPlayingController()
        self.controller = controller
        controller.attach(handlers: NowPlayingController.Handlers(
            play: {},
            pause: {},
            isPaused: { true },
            currentTime: { 0 },
            seek: { _ in },
            stop: {}
        ))
        controller.update(
            title: title,
            duration: 100,
            position: 0,
            isPlaying: true,
            artist: artist
        )
        return controller
    }
    #endif
}
