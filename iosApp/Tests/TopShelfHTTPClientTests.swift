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
    }

    private func harness() throws -> Harness {
        let name = "TopShelfHTTPClientTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let account = keychain.withAudience(.userIndependent)
        addTeardownBlock {
            _ = account.delete(SharedStorage.accessTokenAccount(for: "server"))
            _ = account.delete(SharedStorage.refreshTokenAccount(for: "server"))
            UserDefaults().removePersistentDomain(forName: name)
        }
        suite.set("server", forKey: SharedStorage.activeServerIdKey)
        suite.set("https://media.example", forKey: SharedStorage.serverUrlKey)
        XCTAssertTrue(account.set("stale-access", for: SharedStorage.accessTokenAccount(for: "server")))
        XCTAssertTrue(account.set("stored-refresh", for: SharedStorage.refreshTokenAccount(for: "server")))
        let stub = APIv2TestStub()
        let client = TopShelfHTTPClient(
            defaults: SharedDefaults(suite: suite, standard: suite),
            keychain: keychain,
            session: stub.makeSession()
        )
        return Harness(client: try XCTUnwrap(client.authenticated()), keychain: account, stub: stub)
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
}
