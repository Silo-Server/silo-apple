import Foundation
import XCTest
@testable import Silo

final class TopShelfHTTPClientTests: XCTestCase {
    /// The first request of every Home read.
    private static let layoutPath = "/api/v2/home/layout"
    private static let fullHomePath = "/api/v2/home/sections"
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
        h.stub.sequence(path: Self.layoutPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.reply(path: Self.layoutPath, 200, #"{"sections":[]}"#)

        let response = try await h.client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertTrue(response.sections.isEmpty)
        XCTAssertEqual(h.stub.requestedPaths, [Self.layoutPath, Self.refreshPath, Self.layoutPath])
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
        h.stub.sequence(path: Self.layoutPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.reply(path: Self.layoutPath, 200, #"{"sections":[]}"#)

        _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])
        _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requestedPaths.filter { $0 == Self.refreshPath }.count, 1)
        XCTAssertEqual(h.stub.requests.last?.header("Authorization"), "Bearer fresh-access")
    }

    func testRejectedRefreshLeavesTheOriginal401AndIsNotRetried() async throws {
        let h = try harness()
        h.stub.reply(path: Self.layoutPath, 401, "{}")
        h.stub.reply(path: Self.refreshPath, 401, "{}")

        for _ in 0..<2 {
            do {
                _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])
                XCTFail("Expected the 401 to surface")
            } catch TopShelfHTTPClient.Error.unexpectedStatus(let status) {
                XCTAssertEqual(status, 401)
            }
        }
        XCTAssertEqual(h.stub.requestedPaths, [Self.layoutPath, Self.refreshPath, Self.layoutPath])
    }

    func testRefreshedTokenThatIsAlsoRejectedIsNotRetriedAgain() async throws {
        let h = try harness()
        h.stub.reply(path: Self.layoutPath, 401, "{}")
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
                       [Self.layoutPath, Self.refreshPath, Self.layoutPath, Self.layoutPath])
    }

    func testProfileChangeDuringTheRefreshSendsNoRetry() async throws {
        let h = try harness()
        h.stub.sequence(path: Self.layoutPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.reply(path: Self.layoutPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.refreshPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        h.switchProfile()
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertEqual(h.stub.requestedPaths, [Self.layoutPath, Self.refreshPath])
    }

    func testProfileChangeDuringTheRejectedRequestSendsNoRefresh() async throws {
        let h = try harness()
        h.stub.sequence(path: Self.layoutPath, [.json(401, "{}")])
        h.stub.reply(path: Self.refreshPath, 200, Self.refreshedTokens)
        h.stub.hold(path: Self.layoutPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        h.switchProfile()
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertEqual(h.stub.requestedPaths, [Self.layoutPath])
    }

    func testProfileChangeDuringASuccessfulRequestReturnsNothing() async throws {
        let h = try harness()
        h.stub.reply(path: Self.layoutPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.layoutPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        h.switchProfile()
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertEqual(h.stub.requestedPaths, [Self.layoutPath])
    }

    func testSwitchToAnotherAllowedProfileDuringARequestReturnsNothing() async throws {
        let h = try harness()
        h.stub.reply(path: Self.layoutPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.layoutPath)

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        try h.switchToAnotherAllowedProfile()
        XCTAssertTrue(h.client.isPersonalizedContentAllowed)
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertFalse(h.client.isCurrentScope)
    }

    // MARK: - Home rows

    private static func itemsPath(_ id: String) -> String { "/api/v2/home/sections/\(id)/items" }

    private static func row(_ id: String, _ type: String, cards: [String]) -> String {
        let items = cards.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }
        return #"{"id":"\#(id)","section_type":"\#(type)","title":"\#(id)","items":[\#(items.joined(separator: ","))]}"#
    }

    private static func layout(_ rows: [(String, String)]) -> String {
        let entries = rows.map { #"{"id":"\#($0.0)","section_type":"\#($0.1)","title":"\#($0.0)","featured":false,"item_limit":100}"# }
        return #"{"sections":[\#(entries.joined(separator: ","))],"included_sections":[]}"#
    }

    /// Stubs the layout and each row's read, and the whole Home with the same
    /// rows, so a client that still reads the whole Home gets the same cards.
    private func stubHome(_ h: Harness, _ rows: [(id: String, type: String, cards: [String])]) {
        h.stub.reply(path: Self.layoutPath, 200, Self.layout(rows.map { ($0.id, $0.type) }))
        for row in rows {
            h.stub.reply(path: Self.itemsPath(row.id), 200, Self.row(row.id, row.type, cards: row.cards))
        }
        let all = rows.map { Self.row($0.id, $0.type, cards: $0.cards) }.joined(separator: ",")
        h.stub.reply(path: Self.fullHomePath, 200, #"{"sections":[\#(all)]}"#)
    }

    func testReadsOnlyTheShelfRowsNeverTheWholeHome() async throws {
        let h = try harness()
        stubHome(h, [
            ("hero", "recently_added", ["new"]),
            ("cw", "continue_watching", ["a", "b"]),
            ("genre", "genre", ["c"]),
            ("nu", "next_up", ["d"]),
            ("books", "next_in_series", ["e"]),
        ])

        let response = try await h.client.fetchHomeSections(imageSizeQuery: ["image_size": "large"])

        XCTAssertFalse(h.stub.requestedPaths.contains(Self.fullHomePath))
        XCTAssertEqual(h.stub.requestedPaths.first, Self.layoutPath)
        XCTAssertEqual(Set(h.stub.requestedPaths.dropFirst()),
                       [Self.itemsPath("cw"), Self.itemsPath("nu"), Self.itemsPath("books")])
        XCTAssertEqual(h.stub.requestedPaths.count, 4)
        XCTAssertEqual(response.sections.map(\.id), ["cw", "nu", "books"])
        XCTAssertEqual(response.sections.map { $0.items.map(\.contentId) }, [["a", "b"], ["d"], ["e"]])
        let rowRead = try XCTUnwrap(h.stub.requests.first { $0.path == Self.itemsPath("cw") })
        // The artwork query, and no item_limit: the row answers at its own limit.
        XCTAssertEqual(rowRead.query, ["image_size": "large"])
        XCTAssertEqual(rowRead.header("X-Profile-Id"), "profile")
    }

    func testAFailedOrRetypedRowIsLeftOutAndTheOthersKept() async throws {
        let h = try harness()
        stubHome(h, [
            ("cw", "continue_watching", ["a"]),
            ("nu", "next_up", ["b"]),
            ("later", "next_up", ["c"]),
        ])
        h.stub.reply(path: Self.itemsPath("nu"), 500, "{}")
        // An admin retyped the section after the layout was read.
        h.stub.reply(path: Self.itemsPath("later"), 200, Self.row("later", "recently_added", cards: ["c"]))

        let response = try await h.client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertFalse(h.stub.requestedPaths.contains(Self.fullHomePath))
        XCTAssertEqual(response.sections.map(\.id), ["cw"])
    }

    func testWhenEveryRowFailsTheReadFails() async throws {
        let h = try harness()
        stubHome(h, [("cw", "continue_watching", ["a"]), ("nu", "next_up", ["b"])])
        h.stub.reply(path: Self.itemsPath("cw"), 500, "{}")
        h.stub.reply(path: Self.itemsPath("nu"), 500, "{}")

        do {
            _ = try await h.client.fetchHomeSections(imageSizeQuery: [:])
            XCTFail("Expected the outage to surface, not an empty shelf")
        } catch TopShelfHTTPClient.Error.unexpectedStatus(let status) {
            XCTAssertEqual(status, 500)
        }
        XCTAssertFalse(h.stub.requestedPaths.contains(Self.fullHomePath))
    }

    func testAnEmptyRowIsKeptEmpty() async throws {
        let h = try harness()
        stubHome(h, [("cw", "continue_watching", ["a"]), ("nu", "next_up", [])])

        let response = try await h.client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertFalse(h.stub.requestedPaths.contains(Self.fullHomePath))
        XCTAssertEqual(response.sections.map(\.id), ["cw", "nu"])
        XCTAssertEqual(response.sections.last?.items.count, 0)
    }

    func testRowsKeepLayoutOrderWhicheverReadFinishesFirst() async throws {
        let h = try harness()
        stubHome(h, [("nu", "next_up", ["a"]), ("books", "next_in_series", ["b"])])
        h.stub.hold(path: Self.itemsPath("nu"))

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        let deadline = Date().addingTimeInterval(5)
        while !h.stub.requestedPaths.contains(Self.itemsPath("books")), Date() < deadline { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
        h.stub.release()

        let response = try await fetch.value
        XCTAssertFalse(h.stub.requestedPaths.contains(Self.fullHomePath))
        XCTAssertEqual(response.sections.map(\.id), ["nu", "books"])
    }

    func testProfileChangeDuringARowReadReturnsNothing() async throws {
        let h = try harness()
        stubHome(h, [("cw", "continue_watching", ["a"]), ("nu", "next_up", ["b"])])
        h.stub.hold(path: Self.itemsPath("cw"))

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        h.switchProfile()
        h.stub.release()

        await assertNotAuthenticated(fetch)
        XCTAssertFalse(h.stub.requestedPaths.contains(Self.fullHomePath))
    }

    func testProfileChangeBeforeARowFailsReturnsNothing() async throws {
        let h = try harness()
        stubHome(h, [("cw", "continue_watching", ["a"]), ("nu", "next_up", ["b"])])
        h.stub.reply(path: Self.itemsPath("nu"), 500, "{}")
        h.stub.hold(path: Self.itemsPath("nu"))

        let fetch = Task { try await h.client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()
        // Let the Continue Watching read finish under the first profile.
        let deadline = Date().addingTimeInterval(5)
        while !h.stub.requestedPaths.contains(Self.itemsPath("cw")), Date() < deadline { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
        h.switchProfile()
        h.stub.release()

        // The previous profile's Continue Watching row must not come back.
        await assertNotAuthenticated(fetch)
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
