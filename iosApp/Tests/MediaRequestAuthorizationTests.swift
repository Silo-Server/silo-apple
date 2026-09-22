import Foundation
import XCTest
@testable import Silo

final class MediaRequestAuthorizationTests: XCTestCase {
    private struct Harness {
        let store: TokenStore
        let http: HTTPClient
        let stub: APIv2TestStub
        let owner: CapturedOrdinaryRequestAuth
    }

    private func harness(
        accessToken: String = "old-access",
        refreshJoined: (@Sendable (RefreshFlightJoinKind) -> Void)? = nil
    ) async throws -> Harness {
        let name = "MediaRequestAuthorizationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keys = SharedKeychain(service: name, accessGroup: nil)
        let store = TokenStore(keychain: keys, defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await store.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await store.switchActiveServer(serverId: "server")
        await store.setServerUrl("https://media.example")
        let saved = await store.saveTokens(accessToken: accessToken, refreshToken: "refresh")
        XCTAssertTrue(saved)
        await store.setProfileId("profile")
        let profileSaved = await store.setProfileToken("proof")
        XCTAssertTrue(profileSaved)
        let captured = await store.captureOrdinaryRequestAuth()
        let stub = APIv2TestStub()
        stub.reply(200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
        return Harness(store: store, http: HTTPClient(session: stub.makeSession(), tokenStore: store,
                                                       refreshFlightJoinObserver: refreshJoined),
                       stub: stub, owner: try XCTUnwrap(captured))
    }

    func testCurrentHeadersReplaceFrozenCredentialsWithoutRefreshing() async throws {
        let h = try await harness()
        let headers = try await h.http.mediaRequestHeaders(
            expectedAuth: h.owner,
            baseHeaders: ["authorization": "Bearer frozen", "x-profile-id": "wrong",
                          "X-Profile-Token": "wrong", "X-Transport": "preserved"]
        )
        XCTAssertEqual(headers["Authorization"], "Bearer old-access")
        XCTAssertEqual(headers["X-Profile-Id"], "profile")
        XCTAssertEqual(headers["X-Profile-Token"], "proof")
        XCTAssertEqual(headers["X-Transport"], "preserved")
        XCTAssertNil(headers["authorization"])
        XCTAssertNil(headers["x-profile-id"])
        XCTAssertTrue(h.stub.requests.isEmpty)
    }

    func testLateChallengeUsesAlreadyRotatedTokenWithoutAnotherRefresh() async throws {
        let h = try await harness()
        let rotated = await h.store.saveRefreshedTokens("already-rotated", "new-refresh", replacing:
            CapturedRefreshCredential(account: h.owner.account, refreshToken: "refresh", owner: h.owner.credentialOwner))
        XCTAssertTrue(rotated)
        let headers = try await h.http.mediaRequestHeaders(
            expectedAuth: h.owner, baseHeaders: [:], rejectedHeaders: ["authorization": "Bearer old-access"]
        )
        XCTAssertEqual(headers["Authorization"], "Bearer already-rotated")
        XCTAssertTrue(h.stub.requests.isEmpty)
    }

    func testMediaChallengeAndProgressRequestShareOneRefreshFlight() async throws {
        let joined = expectation(description: "Progress joins media refresh")
        let h = try await harness(refreshJoined: { _ in joined.fulfill() })
        h.stub.reply(path: "/api/v1/playback/session/progress", 401, "{}")
        h.stub.hold()
        async let media = h.http.mediaRequestHeaders(
            expectedAuth: h.owner, baseHeaders: [:], rejectedHeaders: ["Authorization": "Bearer old-access"]
        )
        await h.stub.waitUntilHeld()
        async let progress: Void = h.http.postVoid("/api/v1/playback/session/progress", body: ["position": 1])
        // The normal request reaches the same refresh flight before it is released.
        await fulfillment(of: [joined], timeout: 5)
        h.stub.reply(path: "/api/v1/playback/session/progress", 204, "")
        h.stub.release()
        let headers = try await media
        try await progress
        XCTAssertEqual(headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(h.stub.requests.filter { $0.path == "/api/v1/auth/refresh" }.count, 1)
    }

    func testExpiredTokenRefreshesBeforeSendingAMediaRequest() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = try await harness(accessToken: Self.jwt(issuedAt: now.addingTimeInterval(-3500), expiresAt: now.addingTimeInterval(-1)))
        let headers = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:], now: now)
        XCTAssertEqual(headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(h.stub.requests.map(\.path), ["/api/v1/auth/refresh"])
    }

    func testHealthyShortLivedTokenDoesNotRefreshOnEverySegment() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = Self.jwt(issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let h = try await harness(accessToken: token)
        for _ in 0..<3 {
            let headers = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:], now: now)
            XCTAssertEqual(headers["Authorization"], "Bearer \(token)")
        }
        XCTAssertTrue(h.stub.requests.isEmpty)
    }

    func testSlowProactiveRefreshDoesNotBlockStillValidMedia() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = Self.jwt(issuedAt: now.addingTimeInterval(-3500), expiresAt: now.addingTimeInterval(30))
        let h = try await harness(accessToken: token)
        h.stub.hold()
        let returnedHeaders = expectation(description: "Valid media does not wait for refresh")
        let pending = Task {
            let headers = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:], now: now)
            returnedHeaders.fulfill()
            return headers
        }
        await h.stub.waitUntilHeld()
        await fulfillment(of: [returnedHeaders], timeout: 1)
        h.stub.release()
        let headers = try await pending.value
        XCTAssertEqual(headers["Authorization"], "Bearer \(token)")
        let refreshed = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:],
            rejectedHeaders: ["Authorization": "Bearer \(token)"], now: now)
        XCTAssertEqual(refreshed["Authorization"], "Bearer new-access")
        XCTAssertEqual(h.stub.requests.count, 1)
    }

    func testProfileChangeWhileRefreshingDoesNotAuthorizeTheOldPlayback() async throws {
        let h = try await harness()
        h.stub.hold()
        let pending = Task {
            try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:],
                                                rejectedHeaders: ["Authorization": "Bearer old-access"])
        }
        await h.stub.waitUntilHeld()
        await h.store.setProfileId("new-profile")
        h.stub.release()
        do {
            _ = try await pending.value
            XCTFail("A completed refresh must not rebind old playback to a new profile")
        } catch {}
    }

    func testChangedAccountIsRejectedBeforeRefresh() async throws {
        let h = try await harness()
        _ = await h.store.saveTokens(accessToken: "new-login", refreshToken: "new-login-refresh")
        do {
            _ = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:],
                                                    rejectedHeaders: ["Authorization": "Bearer old-access"])
            XCTFail("A new credential owner must invalidate the old playback")
        } catch {}
        XCTAssertTrue(h.stub.requests.isEmpty)
    }

    func testRejectedRefreshCannotReturnOrKeepUsingTheOldCredential() async throws {
        let h = try await harness()
        h.stub.reply(401, "{}")
        do {
            _ = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:],
                                                    rejectedHeaders: ["Authorization": "Bearer old-access"])
            XCTFail("A revoked refresh must refuse media authorization")
        } catch {}
        let token = await h.store.getAccessToken()
        XCTAssertNil(token)
        XCTAssertEqual(h.stub.requests.count, 1)
    }

    func testSchedulingHintIgnoresMalformedTokens() {
        for token in ["opaque", "a.!!!.c", "a.e30.c"] {
            XCTAssertFalse(MediaAccessTokenExpiry.shouldRefresh(token, now: Date()))
        }
    }

    func testTransientProactiveFailureKeepsValidTokenAndBacksOff() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let token = Self.jwt(issuedAt: now.addingTimeInterval(-3500), expiresAt: now.addingTimeInterval(30))
        let joined = expectation(description: "Progress joins the background refresh")
        let h = try await harness(accessToken: token, refreshJoined: { _ in joined.fulfill() })
        h.stub.reply(503, "{}")
        h.stub.reply(path: "/progress", 401, "{}")
        h.stub.hold()
        _ = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:], now: now)
        await h.stub.waitUntilHeld()
        let progress = Task { try await h.http.postVoid("/progress", body: ["position": 1]) }
        await fulfillment(of: [joined], timeout: 5)
        h.stub.release()
        do { try await progress.value; XCTFail("Refresh outage must leave the API request failed") }
        catch {}
        for _ in 0..<3 {
            let headers = try await h.http.mediaRequestHeaders(expectedAuth: h.owner, baseHeaders: [:], now: now)
            XCTAssertEqual(headers["Authorization"], "Bearer \(token)")
        }
        XCTAssertEqual(h.stub.requests.filter { $0.path == "/api/v1/auth/refresh" }.count, 1)
    }

    private static func jwt(issuedAt: Date, expiresAt: Date) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["iat": issuedAt.timeIntervalSince1970,
                                                              "exp": expiresAt.timeIntervalSince1970])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "test.\(payload).signature"
    }
}
