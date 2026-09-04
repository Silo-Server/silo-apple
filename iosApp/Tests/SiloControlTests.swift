import XCTest
@testable import Silo

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

    func testServerIdentityMatchesURLCapitalizationAcrossDevices() {
        let phone = ServerRegistry.serverId(for: "https://Media.Example.test")
        let tv = ServerRegistry.serverId(for: "HTTPS://media.example.test/")

        XCTAssertNotEqual(phone, tv, "persisted registry keys remain unchanged")
        XCTAssertTrue(ServerRegistry.serverIdsMatch(phone, tv))
    }

    func testServerIdentityMatchesDefaultPortsButNotDifferentOrigins() {
        let canonical = ServerRegistry.serverId(for: "https://media.example.test/library")
        let explicitDefault = ServerRegistry.serverId(for: "https://MEDIA.example.test:443/library/")
        let otherPort = ServerRegistry.serverId(for: "https://media.example.test:8443/library")
        let otherScheme = ServerRegistry.serverId(for: "http://media.example.test/library")
        let pathCase = ServerRegistry.serverId(for: "https://media.example.test/Library")

        XCTAssertTrue(ServerRegistry.serverIdsMatch(canonical, explicitDefault))
        XCTAssertFalse(ServerRegistry.serverIdsMatch(canonical, otherPort))
        XCTAssertFalse(ServerRegistry.serverIdsMatch(canonical, otherScheme))
        XCTAssertFalse(ServerRegistry.serverIdsMatch(canonical, pathCase))
    }

    func testServerIdentityDecoderRequiresAValidRoundTrippingHTTPURL() {
        let original = "https://Média.example.test:443/silo?mode=A#top"
        let serverId = ServerRegistry.serverId(for: original)

        XCTAssertEqual(ServerRegistry.url(forServerId: serverId), original)
        XCTAssertNil(ServerRegistry.url(forServerId: "not-a-registry-id"))
        XCTAssertNil(ServerRegistry.url(forServerId: ServerRegistry.serverId(for: "file:///tmp/silo")))
        XCTAssertFalse(ServerRegistry.serverIdsMatch(nil, serverId))
        XCTAssertTrue(ServerRegistry.serverIdsMatch("future-format", "future-format"))
        XCTAssertFalse(ServerRegistry.serverIdsMatch("future-format-a", "future-format-b"))
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

extension SiloControlTests {
    func testHeldVolumeSurvivesAStaleReplyMidBurst() {
        var reconciler = RemoteVolumeReconciler()
        let t0 = Date(timeIntervalSince1970: 1000)
        // Two hardware steps before the TV answers either one.
        reconciler.requested(0.5625, at: t0)
        reconciler.requested(0.625, at: t0.addingTimeInterval(0.1))
        // The reply to the first step must not rewind the level, or the next
        // step would recompute 0.625 and the second press would be lost.
        XCTAssertEqual(reconciler.reconcile(inbound: 0.5625, at: t0.addingTimeInterval(0.2)),
                       0.625, accuracy: 0.0001)
        // Once the TV catches up, its value is authoritative again.
        XCTAssertEqual(reconciler.reconcile(inbound: 0.625, at: t0.addingTimeInterval(0.3)),
                       0.625, accuracy: 0.0001)
        XCTAssertEqual(reconciler.reconcile(inbound: 0.2, at: t0.addingTimeInterval(0.4)),
                       0.2, accuracy: 0.0001)
    }

    func testHeldVolumeIsReleasedWhenTheWindowLapses() {
        var reconciler = RemoteVolumeReconciler()
        let t0 = Date(timeIntervalSince1970: 1000)
        reconciler.requested(0.9, at: t0)
        // A dropped command, or a change made on the TV itself, must not leave
        // the remote showing a level the TV does not have.
        let lapsed = t0.addingTimeInterval(RemoteVolumeReconciler.window + 0.1)
        XCTAssertEqual(reconciler.reconcile(inbound: 0.3, at: lapsed), 0.3, accuracy: 0.0001)
    }

    func testMuteClearsTheHeldVolume() {
        var reconciler = RemoteVolumeReconciler()
        let t0 = Date(timeIntervalSince1970: 1000)
        reconciler.requested(0.9, at: t0)
        reconciler.clear()
        XCTAssertEqual(reconciler.reconcile(inbound: 0.3, at: t0.addingTimeInterval(0.1)),
                       0.3, accuracy: 0.0001)
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
