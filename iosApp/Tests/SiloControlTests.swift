import XCTest
@testable import Silo

/// NOTE: This project has no unit-test target wired into project.yml yet, so
/// these tests are not currently compiled or executed. They document the
/// intended behavior and will run once a SiloTests target is added.
final class SiloControlTests: XCTestCase {
    private func roundTrip(_ message: SiloControlMessage) throws -> SiloControlMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(SiloControlMessage.self, from: data)
    }

    func testPingPongRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.ping), .ping)
        XCTAssertEqual(try roundTrip(.pong), .pong)
    }

    func testVolumeMuteNextCommandsRoundTrip() throws {
        let setVol = SiloControlCommand.setVolume(0.4)
        XCTAssertEqual(try roundTrip(.control(setVol)), .control(setVol))
        let mute = SiloControlCommand.setMuted(true)
        XCTAssertEqual(try roundTrip(.control(mute)), .control(mute))
        XCTAssertEqual(try roundTrip(.control(.playNext)), .control(.playNext))
    }

    func testProtocolNegotiatesHighestCommonVersion() {
        XCTAssertEqual(SiloControlProtocol.negotiatedVersion(with: [1]), 1)
        XCTAssertEqual(SiloControlProtocol.negotiatedVersion(with: [1, 2]), 2)
        XCTAssertNil(SiloControlProtocol.negotiatedVersion(with: [3]))
    }

    func testRemoteIdentityHandoffMessagesRoundTrip() throws {
        let offer = SiloControlHandoffOffer(
            requestId: "request-1",
            serverId: "server-1",
            serverURL: "https://silo.example",
            serverName: "Home",
            profileId: "profile-1",
            profileName: "Alex"
        )
        let challenge = SiloControlHandoffChallenge(
            requestId: "request-1",
            userCode: "ABCD-EFGH",
            matchCode: "WXYZ",
            expiresAt: "2026-07-09T20:00:00Z"
        )
        let ready = SiloControlHandoffReady(
            requestId: "request-1",
            serverId: "server-1",
            profileId: "profile-1",
            sessionExpiresAt: "2026-07-10T20:00:00Z",
            reused: false
        )
        let cancel = SiloControlHandoffCancel(
            requestId: "request-1",
            reason: "denied",
            message: "The handoff was denied."
        )

        XCTAssertEqual(try roundTrip(.handoffOffer(offer)), .handoffOffer(offer))
        XCTAssertEqual(try roundTrip(.handoffChallenge(challenge)), .handoffChallenge(challenge))
        XCTAssertEqual(try roundTrip(.handoffReady(ready)), .handoffReady(ready))
        XCTAssertEqual(try roundTrip(.handoffCancel(cancel)), .handoffCancel(cancel))
    }

    func testHandoffOfferDecodesWithoutDisplayMetadata() throws {
        let data = Data(
            #"{"type":"handoff_offer","v":2,"handoffOffer":{"requestId":"request-1","serverId":"server-1","serverURL":"https://silo.example","profileId":"profile-1"}}"#
                .utf8
        )
        guard case .handoffOffer(let offer) = try JSONDecoder().decode(SiloControlMessage.self, from: data) else {
            return XCTFail("Expected a handoff offer")
        }
        XCTAssertNil(offer.serverName)
        XCTAssertNil(offer.profileName)
    }
}

extension SiloControlTests {
    @MainActor func testClockInterpolatesWhilePlaying() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        clock.ingest(.fixture(), asOf: t0)
        XCTAssertEqual(clock.displayTime(asOf: t0.addingTimeInterval(3)), 3, accuracy: 0.01)
    }

    @MainActor func testClockClampsToDuration() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        clock.ingest(.fixture(), asOf: t0)
        XCTAssertEqual(clock.displayTime(asOf: t0.addingTimeInterval(999)), 100, accuracy: 0.01)
    }

    @MainActor func testOptimisticPlayingWinsUntilConfirmed() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        clock.ingest(.fixture(isPlaying: false), asOf: t0)
        clock.setOptimisticPlaying(true, asOf: t0)
        // Optimistic override wins within the window (evaluated against the
        // injected clock, not the wall clock).
        XCTAssertTrue(clock.isPlaying(asOf: t0))
        clock.ingest(.fixture(isPlaying: true), asOf: t0.addingTimeInterval(0.5))
        XCTAssertTrue(clock.isPlaying(asOf: t0.addingTimeInterval(0.5)))
    }

    @MainActor func testOptimisticSeekHoldsUntilSnapshotCatchesUp() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        clock.ingest(.fixture(isPlaying: false, currentTime: 10), asOf: t0)
        // Scrub to 1200s; a stale snapshot still reporting ~10s must not snap
        // the scrubber back.
        clock.setOptimisticTime(1200, asOf: t0)
        clock.ingest(.fixture(isPlaying: false, currentTime: 10, duration: 3000),
                     asOf: t0.addingTimeInterval(0.5))
        XCTAssertEqual(clock.displayTime(asOf: t0.addingTimeInterval(0.5)), 1200, accuracy: 0.01)
        // Once the TV confirms the seek, the clock tracks it again.
        clock.ingest(.fixture(isPlaying: false, currentTime: 1200, duration: 3000),
                     asOf: t0.addingTimeInterval(1.0))
        XCTAssertEqual(clock.displayTime(asOf: t0.addingTimeInterval(1.0)), 1200, accuracy: 0.01)
    }
}

private extension SiloControlPlaybackState {
    static func fixture(isPlaying: Bool = true, currentTime: Double = 0, duration: Double = 100,
                        playbackSpeed: Double = 1.0) -> SiloControlPlaybackState {
        SiloControlPlaybackState(
            contentId: "c", sessionId: nil, title: "T", subtitle: nil,
            isPlaying: isPlaying, isLoading: false, isBuffering: false,
            currentTime: currentTime, duration: duration,
            audioTracks: [], subtitleTracks: [],
            selectedAudioTrackId: nil, selectedSubtitleTrackId: nil,
            qualityOptions: [], activeQualityId: "auto", isQualitySwitching: false,
            playbackSpeed: playbackSpeed, videoGravity: "fit", hdrEnabled: false,
            supportsVideoGravity: false,
            volume: 1.0, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil,
            error: nil)
    }
}
