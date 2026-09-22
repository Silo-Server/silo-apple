import AetherEngine
import AVFoundation
import Foundation
import XCTest
@testable import Silo

@MainActor
final class MediaAuthorizationPlaybackTests: XCTestCase {
    private enum Rotation: String {
        case none
        case mediaChallenge
        case progressRequest
    }

    private struct AuthorizationHarness {
        let store: TokenStore
        let http: HTTPClient
        let stub: APIv2TestStub
        let owner: CapturedOrdinaryRequestAuth
        let serverURL: String
    }

    private static let progressPath = "/api/v1/playback/\(RotatingMediaOrigin.sessionID)/progress"
    private static let refreshPath = "/api/v1/auth/refresh"
    private static let refreshedTokens = #"{"access_token":"synthetic-rotated","refresh_token":"synthetic-refresh-rotated","expires_in":3600}"#

    func testSyntheticHLSContinuesWhenLaterSegmentsAreReleased() async throws {
        try await assertPlaybackContinues(rotation: .none)
    }

    func testBearerRotationContinuesOnTheSamePlayerAndItem() async throws {
        try await assertPlaybackContinues(rotation: .mediaChallenge)
    }

    func testProgressTokenRotationContinuesWithoutMedia401OrItemReplacement() async throws {
        try await assertPlaybackContinues(rotation: .progressRequest)
    }

    private func assertPlaybackContinues(rotation: Rotation) async throws {
        let origin = try RotatingMediaOrigin(bundle: Bundle(for: Self.self))
        let url = try await origin.start()
        defer { origin.stop() }
        let auth = try await authorizationHarness(sourceURL: url)
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.nativeRemoteHLS = true
        options.httpHeaders = ["Authorization": RotatingMediaOrigin.initialAuthorization]
        options.httpRequestAuthorization = try PlaybackMediaAuthorization.make(
            sourceURL: url,
            serverURL: auth.serverURL,
            sessionID: RotatingMediaOrigin.sessionID,
            expectedAuth: auth.owner,
            baseHeaders: options.httpHeaders,
            http: auth.http
        )
        options.autoplay = false

        var loadCompleted = false
        var loadError: Error?
        let load = Task {
            do { try await engine.load(url: url, options: options) }
            catch { loadError = error }
            loadCompleted = true
        }
        defer { load.cancel() }
        guard await waitUntil(timeout: 20, { loadCompleted }) else {
            return XCTFail("Aether load did not complete within 20 seconds. \(origin.snapshot().description)")
        }
        if let loadError { throw loadError }
        let player = try XCTUnwrap(engine.currentAVPlayer)
        let item = try XCTUnwrap(player.currentItem)
        // The native HLS load returns before AVFoundation has decoded its
        // initial buffer. Starting at rate 1 with waiting disabled before
        // readiness can immediately exhaust an empty buffer on a cold boot.
        guard await waitUntil(timeout: 10, { item.status == .readyToPlay }) else {
            return XCTFail("Synthetic HLS item never became ready. \(diagnostics(player, origin: origin))")
        }
        // This is a media-authorization test, independent of audio rendering.
        // The simulator's CoreAudio device can block startup and extrapolate
        // its clock past the gated buffer before any later bytes arrive.
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = false
        }
        player.automaticallyWaitsToMinimizeStalling = false
        engine.play()

        guard await waitUntil(timeout: 15, {
            player.currentTime().seconds > 0.25 && origin.snapshot().pendingSegments > 0
        }) else {
            return XCTFail("Synthetic HLS must play while a later request waits at the origin. \(diagnostics(player, origin: origin))")
        }
        let timeBeforeRotation = player.currentTime().seconds
        let before = origin.snapshot()
        XCTAssertEqual(before.rejectedRequests, 0, "Initial synthetic bearer must be accepted")
        XCTAssertEqual(before.acceptedLaterSegments, 0, "Future segments must remain unavailable before rotation")
        XCTAssertLessThan(timeBeforeRotation, Double(RotatingMediaOrigin.firstGatedSegment))
        XCTAssertTrue(auth.stub.requests.isEmpty, "Opening healthy media must not refresh credentials")
        print("MEDIA_AUTH_PLAYBACK before release rotation=\(rotation.rawValue) time=\(timeBeforeRotation)\n\(before.description)")

        if rotation == .progressRequest {
            // Exercise the ordinary API 401/refresh/retry path while playback
            // is already active. The authorizer must see TokenStore's rotation
            // on its next media request without rebuilding the loaded item.
            auth.stub.sequence([
                .json(401, "{}"),
                .json(200, Self.refreshedTokens),
                .json(204, ""),
            ])
            try await auth.http.postVoid(Self.progressPath, body: ["position": timeBeforeRotation])
            XCTAssertEqual(auth.stub.requestedPaths, [Self.progressPath, Self.refreshPath, Self.progressPath])
            let progressRequests = auth.stub.requests.filter { $0.path == Self.progressPath }
            XCTAssertEqual(progressRequests.first?.header("Authorization"), RotatingMediaOrigin.initialAuthorization)
            XCTAssertEqual(progressRequests.last?.header("Authorization"), RotatingMediaOrigin.rotatedAuthorization)
        }

        // This is the only origin state change. The existing engine, player,
        // and item must continue without load(), seek(), or replacement.
        origin.releaseLaterSegments(
            rotatingAuthorization: rotation != .none,
            acceptingPreviouslyIssuedRequests: rotation == .progressRequest
        )
        var retainedPlayerAndItem = true
        let advanced = await waitUntil(timeout: 18) {
            retainedPlayerAndItem = retainedPlayerAndItem
                && engine.currentAVPlayer === player && player.currentItem === item
            return player.currentTime().seconds > 8.5 && player.rate > 0
                && origin.snapshot().acceptedLaterSegments > 0
        }
        let after = origin.snapshot()
        let evidence = "rotation=\(rotation.rawValue) initialTime=\(timeBeforeRotation) "
            + "refreshRequests=\(auth.stub.requests.filter { $0.path == Self.refreshPath }.count) "
            + diagnostics(player, origin: origin)
        print("MEDIA_AUTH_PLAYBACK after release \(evidence)")
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "Media authorization playback: \(rotation.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(retainedPlayerAndItem, "Auth changes must preserve AVPlayer and AVPlayerItem identity")
        XCTAssertTrue(advanced, "Playback must advance past the six-second pre-rotation buffer on the same item. \(evidence)")
        XCTAssertEqual(auth.stub.requests.filter { $0.path == Self.refreshPath }.count, rotation == .none ? 0 : 1,
            "An expired bearer must use exactly one shared HTTPClient refresh")
        if rotation != .none {
            XCTAssertGreaterThan(after.acceptedRotatedSegments, 0,
                "The origin must receive a later media request with the rotated bearer. \(evidence)")
            let accessToken = await auth.store.getAccessToken()
            XCTAssertEqual(accessToken, RotatingMediaOrigin.rotatedAccessToken)
            if rotation == .mediaChallenge {
                XCTAssertGreaterThan(after.rejectedRequests, 0, "The held old request must exercise reactive refresh")
                try await auth.http.postVoid(Self.progressPath, body: ["position": player.currentTime().seconds])
            } else {
                XCTAssertEqual(after.rejectedRequests, 0, "API rotation must authorize future media before its first attempt")
            }
            let currentHeaders = try await auth.http.mediaRequestHeaders(expectedAuth: auth.owner, baseHeaders: [:])
            XCTAssertFalse(AetherAuthenticationRecoveryPolicy.shouldReloadAfterProgress(
                .success,
                activeHeaders: options.httpHeaders,
                currentHeaders: currentHeaders,
                hasRequestAuthorization: options.httpRequestAuthorization != nil
            ), "A progress-triggered rotation must not reload media that resolves request credentials")
            XCTAssertTrue(engine.currentAVPlayer === player && player.currentItem === item)
        } else {
            XCTAssertEqual(after.rejectedRequests, 0)
            XCTAssertGreaterThan(after.acceptedLaterSegments, 0)
        }
    }

    private func authorizationHarness(sourceURL: URL) async throws -> AuthorizationHarness {
        let name = "MediaAuthorizationPlaybackTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keys = SharedKeychain(service: name, accessGroup: nil)
        let store = TokenStore(keychain: keys, defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await store.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        var components = try XCTUnwrap(URLComponents(url: sourceURL, resolvingAgainstBaseURL: false))
        components.path = ""
        components.query = nil
        let serverURL = try XCTUnwrap(components.url).absoluteString
        await store.switchActiveServer(serverId: "synthetic-server")
        await store.setServerUrl(serverURL)
        let saved = await store.saveTokens(accessToken: RotatingMediaOrigin.initialAccessToken,
                                           refreshToken: "synthetic-refresh-initial")
        XCTAssertTrue(saved)
        await store.setProfileId("synthetic-profile")
        let profileSaved = await store.setProfileToken("synthetic-profile-proof")
        XCTAssertTrue(profileSaved)
        let captured = await store.captureOrdinaryRequestAuth()
        let stub = APIv2TestStub(fallback: .json(500, #"{"error":"unarranged API request"}"#))
        stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        stub.reply(path: Self.progressPath, 204, "")
        return AuthorizationHarness(store: store, http: HTTPClient(session: stub.makeSession(), tokenStore: store),
                                    stub: stub, owner: try XCTUnwrap(captured), serverURL: serverURL)
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1_000))
        while !predicate(), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        return predicate()
    }

    private func diagnostics(_ player: AVPlayer, origin: RotatingMediaOrigin) -> String {
        "time=\(player.currentTime().seconds) rate=\(player.rate) "
            + "itemStatus=\(player.currentItem?.status.rawValue ?? -1) "
            + "itemError=\(String(describing: player.currentItem?.error))\n"
            + origin.snapshot().description
    }
}
