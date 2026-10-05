import Foundation
import XCTest
@testable import Silo

final class TopShelfHTTPClientTests: XCTestCase {
    private static let sectionsPath = "/api/v2/home/sections"
    private static let refreshPath = "/api/v2/auth/refresh"
    private static let refreshedTokens =
        #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":28800}"#

    private struct Harness {
        let client: TopShelfHTTPClient
        let keychain: SharedKeychain
        let stub: APIv2TestStub
        let defaults: UserDefaults

        /// The user picks another profile, so the remembered one no longer
        /// allows personalized content.
        func switchProfile() {
            defaults.set("other-profile", forKey: SharedStorage.profileIdKey)
        }

        /// The user picks another profile that is also remembered, so the
        /// profile policy still allows personalized content, but for them.
        func switchToAnotherAllowedProfile() throws {
            defaults.set("other-profile", forKey: SharedStorage.profileIdKey)
            let state = ProfileLaunchState(rememberedByServerID: [
                "server": RememberedProfile(profileID: "other-profile", requiredPINAtSelection: false, accountEpoch: "epoch"),
            ])
            defaults.set(try JSONEncoder().encode(state), forKey: SharedStorage.profileLaunchStateKey)
        }
    }

    private func harness() throws -> Harness {
        let name = "TopShelfHTTPClientTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let account = keychain.withAudience(.userIndependent)
        addTeardownBlock {
            _ = account.delete(SharedStorage.accessTokenAccount(for: "server"))
            _ = account.delete(SharedStorage.refreshTokenAccount(for: "server"))
            _ = account.delete(SharedStorage.accountEpochAccount(for: "server"))
            UserDefaults().removePersistentDomain(forName: name)
        }
        suite.set("server", forKey: SharedStorage.activeServerIdKey)
        suite.set("https://media.example", forKey: SharedStorage.serverUrlKey)
        // A remembered PIN-less profile, so the profile policy allows requests.
        suite.set("profile", forKey: SharedStorage.profileIdKey)
        XCTAssertTrue(account.set("epoch", for: SharedStorage.accountEpochAccount(for: "server")))
        let launchState = ProfileLaunchState(rememberedByServerID: [
            "server": RememberedProfile(profileID: "profile", requiredPINAtSelection: false, accountEpoch: "epoch"),
        ])
        suite.set(try JSONEncoder().encode(launchState), forKey: SharedStorage.profileLaunchStateKey)
        XCTAssertTrue(account.set("stale-access", for: SharedStorage.accessTokenAccount(for: "server")))
        XCTAssertTrue(account.set("stored-refresh", for: SharedStorage.refreshTokenAccount(for: "server")))
        let stub = APIv2TestStub()
        let client = TopShelfHTTPClient(
            defaults: SharedDefaults(suite: suite, standard: suite),
            keychain: keychain,
            session: stub.makeSession()
        )
        return Harness(client: try XCTUnwrap(client.authenticated()), keychain: account, stub: stub, defaults: suite)
    }

    func testExpiredAccessTokenRefreshesInMemoryAndRetriesOnce() async throws {
        let h = try harness()
        h.stub.sequence(path: Self.sectionsPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        let response = try await h.client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertTrue(response.sections.isEmpty)
        XCTAssertEqual(h.stub.requestedPaths, [Self.sectionsPath, Self.refreshPath, Self.sectionsPath])
        let refresh = h.stub.requests[1]
        XCTAssertEqual(refresh.method, "POST")
        XCTAssertNil(refresh.header("Authorization"))
        XCTAssertEqual(refresh.bodyString, #"{"refresh_token":"stored-refresh"}"#)
        XCTAssertEqual(h.stub.requests[2].header("Authorization"), "Bearer fresh-access")
        // The app owns the shared Keychain; the extension never writes back.
        XCTAssertEqual(h.keychain.get(SharedStorage.accessTokenAccount(for: "server")), "stale-access")
        XCTAssertEqual(h.keychain.get(SharedStorage.refreshTokenAccount(for: "server")), "stored-refresh")
    }

    func testLaterRequestsReuseTheRefreshedToken() async throws {
        let h = try harness()
        h.stub.sequence(path: Self.sectionsPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])
        _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requestedPaths.filter { $0 == Self.refreshPath }.count, 1)
        XCTAssertEqual(h.stub.requests.last?.header("Authorization"), "Bearer fresh-access")
    }

    func testRejectedRefreshLeavesTheOriginal401AndIsNotRetried() async throws {
        let h = try harness()
        h.stub.reply(path: Self.sectionsPath, 401, "{}")
        h.stub.reply(path: Self.refreshPath, 401, "{}")

        for _ in 0..<2 {
            do {
                _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])
                XCTFail("Expected the 401 to surface")
            } catch TopShelfHTTPClient.Error.unexpectedStatus(let status) {
                XCTAssertEqual(status, 401)
            }
        }
        XCTAssertEqual(h.stub.requestedPaths, [Self.sectionsPath, Self.refreshPath, Self.sectionsPath])
    }

    func testRefreshedTokenThatIsAlsoRejectedIsNotRetriedAgain() async throws {
        let h = try harness()
        h.stub.reply(path: Self.sectionsPath, 401, "{}")
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)

        for _ in 0..<2 {
            do {
                _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])
                XCTFail("Expected the 401 to surface")
            } catch TopShelfHTTPClient.Error.unexpectedStatus(let status) {
                XCTAssertEqual(status, 401)
            }
        }
        // First call: stale, refresh, fresh. Second call starts with the fresh
        // token and gives up on its 401 without another refresh.
        XCTAssertEqual(h.stub.requestedPaths,
                       [Self.sectionsPath, Self.refreshPath, Self.sectionsPath, Self.sectionsPath])
    }

    func testProfileChangeDuringTheRefreshSendsNoRetry() async throws {
        let h = try harness()
        h.stub.sequence(path: Self.sectionsPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.refreshPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        h.switchProfile()
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertEqual(h.stub.requestedPaths, [Self.sectionsPath, Self.refreshPath])
    }

    func testProfileChangeDuringASuccessfulRequestReturnsNothing() async throws {
        let h = try harness()
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.sectionsPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        h.switchProfile()
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertEqual(h.stub.requestedPaths, [Self.sectionsPath])
    }

    func testSwitchToAnotherAllowedProfileDuringARequestReturnsNothing() async throws {
        let h = try harness()
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.sectionsPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        try h.switchToAnotherAllowedProfile()
        XCTAssertTrue(h.client.isPersonalizedContentAllowed)
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertFalse(h.client.isCurrentScope)
    }

    private func assertNotAuthenticated<T>(
        _ fetch: Task<T, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fetch.value
            XCTFail("Expected no personalized content", file: file, line: line)
        } catch TopShelfHTTPClient.Error.notAuthenticated {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
