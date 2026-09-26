import MediaPlayer
import XCTest
@testable import Silo

/// Checks how often the audiobook coordinator republishes Now Playing info
/// against the real process-wide info center, with a hand-driven clock.
/// Clock ticks may publish only every couple of seconds; transport changes
/// must still publish at once.
@MainActor
final class AudioNowPlayingCoordinatorTests: XCTestCase {
    private var instant = ContinuousClock.now
    private var audio: AudioNowPlayingCoordinator?
    private var video: AetherVideoNowPlayingCoordinator?

    override func setUp() async throws {
        try await super.setUp()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    override func tearDown() async throws {
        // The arbiter is a process-wide singleton; leave it with no claims.
        video?.detach()
        audio?.detach()
        video = nil
        audio = nil
        try await super.tearDown()
    }

    func testPlayheadTicksPublishAtMostEveryTwoSeconds() {
        let audio = attachPlayingBook(at: 10)

        advance(0.5)
        audio.updatePlayhead(position: 10.5)
        XCTAssertEqual(publishedElapsed, 10)

        advance(1.4)
        audio.updatePlayhead(position: 11.9)
        XCTAssertEqual(publishedElapsed, 10)

        advance(0.1)
        audio.updatePlayhead(position: 12)
        XCTAssertEqual(publishedElapsed, 12)

        advance(0.5)
        audio.updatePlayhead(position: 12.5)
        XCTAssertEqual(publishedElapsed, 12)
    }

    func testTransportUpdatePublishesAtOnceAndRestartsTheWindow() {
        let audio = attachPlayingBook(at: 10)

        advance(0.3)
        audio.updatePlayhead(position: 10.3)
        advance(0.2)
        // A seek while playing.
        update(audio, position: 100, isPlaying: true)
        XCTAssertEqual(publishedElapsed, 100)

        // Two seconds after the first publish, but only 1.5 after the seek.
        advance(1.5)
        audio.updatePlayhead(position: 101.5)
        XCTAssertEqual(publishedElapsed, 100)

        advance(0.5)
        audio.updatePlayhead(position: 102)
        XCTAssertEqual(publishedElapsed, 102)

        advance(0.1)
        update(audio, position: 102.1, isPlaying: false)
        XCTAssertEqual(publishedElapsed, 102.1)
        XCTAssertEqual(publishedRate, 0)
    }

    func testRestoredPublishCarriesTheLatestPlayhead() {
        let audio = attachPlayingBook(at: 10)
        advance(0.5)
        audio.updatePlayhead(position: 10.5)
        XCTAssertEqual(publishedElapsed, 10)

        let video = attachVideo()
        XCTAssertEqual(publishedTitle, "Movie")
        video.detach()

        XCTAssertEqual(publishedTitle, "Book")
        XCTAssertEqual(publishedElapsed, 10.5)
    }

    // MARK: - Helpers

    private var publishedInfo: [String: Any]? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo
    }

    private var publishedTitle: String? {
        publishedInfo?[MPMediaItemPropertyTitle] as? String
    }

    private var publishedElapsed: Double? {
        publishedNumber(MPNowPlayingInfoPropertyElapsedPlaybackTime)
    }

    private var publishedRate: Double? {
        publishedNumber(MPNowPlayingInfoPropertyPlaybackRate)
    }

    /// The center can hand a whole number back as an integer, so read every
    /// number through NSNumber.
    private func publishedNumber(_ key: String) -> Double? {
        (publishedInfo?[key] as? NSNumber)?.doubleValue
    }

    private func advance(_ seconds: Double) {
        // Whole milliseconds, so steps such as 0.5 + 1.4 + 0.1 add up to
        // exactly two seconds.
        instant = instant.advanced(by: .milliseconds(Int((seconds * 1000).rounded())))
    }

    private func attachPlayingBook(at position: Double) -> AudioNowPlayingCoordinator {
        let audio = AudioNowPlayingCoordinator(now: { [unowned self] in self.instant })
        self.audio = audio
        audio.attach(session: nil, handlers: AudioNowPlayingCoordinator.Handlers(
            play: {},
            pause: {},
            isPaused: { false },
            currentTime: { 0 },
            seek: { _ in },
            skip: { _ in }
        ))
        update(audio, position: position, isPlaying: true)
        XCTAssertEqual(publishedElapsed, position)
        return audio
    }

    private func update(_ audio: AudioNowPlayingCoordinator, position: Double, isPlaying: Bool) {
        audio.update(
            title: "Book",
            artist: nil,
            albumTitle: "Audiobook",
            duration: 3600,
            position: position,
            isPlaying: isPlaying,
            playbackRate: 1
        )
    }

    private func attachVideo() -> AetherVideoNowPlayingCoordinator {
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
        video.update(title: "Movie", duration: 100, position: 0, isPlaying: true)
        return video
    }
}
