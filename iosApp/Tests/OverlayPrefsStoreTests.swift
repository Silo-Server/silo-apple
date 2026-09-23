import XCTest
@testable import Silo

/// Card-overlay prefs come only from the canonical settings contract. A
/// server without it gets the update message, never the retired string
/// setting, and a profile switch mid-read never applies the old profile's
/// answer.
@MainActor
final class OverlayPrefsStoreTests: XCTestCase {
    private static let configPath = "/api/v2/settings/overlay-config"
    private static let effectivePath = "/settings/values/effective"
    /// A saved document that differs from the registry defaults.
    private static let savedDocument = #"{"version":2,"preset":"minimal","order":[],"items":{}}"#

    func testServerWithoutCanonicalSettingsReportsUpdateRequired() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.pathSuffix(Self.configPath)) { _ in
            .json(#"{"enabled":true,"quick_actions_enabled":false,"quick_actions_default":"both"}"#)
        }
        // The router's own 404: the canonical routes are not mounted.
        stub.route(StubURLProtocol.pathSuffix(Self.effectivePath)) { _ in
            .text("404 page not found", status: 404)
        }
        let (api, _) = try await makeAPI(stub: stub, profileId: "profile-a")
        let store = OverlayPrefsStore(api: api)

        await store.refresh()

        XCTAssertEqual(store.lastError, UpdateRequirement.serverMessage)
        XCTAssertEqual(store.prefs, OverlaySchema.buildDefaults())
        XCTAssertEqual(
            stub.requests.map(\.path).filter { !$0.hasSuffix(Self.configPath) && !$0.hasSuffix(Self.effectivePath) },
            [],
            "no request may fall back to the retired string setting"
        )
        XCTAssertTrue(stub.unmatched.isEmpty)
        let retried = await store.hydrateIfNeeded()
        XCTAssertTrue(retried, "an update-required answer must not mark the store hydrated")
    }

    func testUpdateRequiredServerRendersTheAdminBaseline() async throws {
        // The router 404 and a settings revision behind this app's contract
        // both mean the user value can't be read; neither may drop the admin
        // baseline that overlay-config just returned.
        let effectiveAnswers: [StubURLProtocol.Response] = [
            .text("404 page not found", status: 404),
            .json(#"{"items":[{"key":"ui.card_overlays","value":null,"source":"default"}],"revision":1}"#),
        ]
        let baseline = #"{"version":2,"preset":"pill","order":[],"items":{}}"#
        for answer in effectiveAnswers {
            let stub = StubURLProtocol.Handler()
            stub.route(StubURLProtocol.pathSuffix(Self.configPath)) { _ in
                .json(#"{"enabled":true,"defaults":"{\"version\":2,\"preset\":\"pill\",\"order\":[],\"items\":{}}","quick_actions_enabled":false,"quick_actions_default":"both"}"#)
            }
            stub.route(StubURLProtocol.pathSuffix(Self.effectivePath)) { _ in answer }
            let (api, _) = try await makeAPI(stub: stub, profileId: "profile-a")
            let store = OverlayPrefsStore(api: api)

            await store.refresh()

            XCTAssertEqual(store.lastError, UpdateRequirement.serverMessage)
            XCTAssertEqual(store.prefs, OverlaySchema.parse(baseline))
            XCTAssertNotEqual(store.prefs, OverlaySchema.buildDefaults())
            let retried = await store.hydrateIfNeeded()
            XCTAssertTrue(retried, "an update-required answer must not mark the store hydrated")
        }
    }

    func testProfileSwitchDuringRefreshDropsTheOldProfilesAnswer() async throws {
        let stub = StubURLProtocol.Handler()
        let gate = StubURLProtocol.Gate()
        stub.route(StubURLProtocol.pathSuffix(Self.configPath)) { _ in
            .json(#"{"enabled":true,"quick_actions_enabled":false,"quick_actions_default":"both"}"#)
        }
        stub.route(StubURLProtocol.pathSuffix(Self.effectivePath)) { request in
            guard request.header("X-Profile-Id") == "profile-a" else {
                return .json(#"{"items":[{"key":"ui.card_overlays","value":null,"source":"default"}],"revision":99}"#)
            }
            await gate.wait()
            return .json(#"""
            {"items":[{"key":"ui.card_overlays","value":\#(Self.savedDocument),
             "source":"profile","scope":"profile"}],"revision":99}
            """#)
        }
        let (api, tokens) = try await makeAPI(stub: stub, profileId: "profile-a")
        let store = OverlayPrefsStore(api: api)

        let staleRefresh = Task { await store.refresh() }
        try await stub.waitForRequest { $0.path.hasSuffix(Self.effectivePath) }

        store.clear()
        await tokens.setProfileId("profile-b")
        let hydrated = await store.hydrateIfNeeded()
        XCTAssertTrue(hydrated)
        await gate.open()
        await staleRefresh.value

        XCTAssertEqual(store.prefs, OverlaySchema.buildDefaults(), "profile A's saved layout must not reach profile B")
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isLoading)
        let effectiveProfiles = stub.requests
            .filter { $0.path.hasSuffix(Self.effectivePath) }
            .map { $0.header("X-Profile-Id") }
        XCTAssertEqual(effectiveProfiles, ["profile-a", "profile-b"])
    }

    func testSavedProfileDocumentWinsOverAdminDefaults() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.pathSuffix(Self.configPath)) { _ in
            .json(#"{"enabled":false,"defaults":"{\"version\":2,\"preset\":\"pill\",\"order\":[],\"items\":{}}","quick_actions_enabled":false,"quick_actions_default":"both"}"#)
        }
        stub.route(StubURLProtocol.pathSuffix(Self.effectivePath)) { _ in
            .json(#"""
            {"items":[{"key":"ui.card_overlays","value":\#(Self.savedDocument),
             "source":"profile","scope":"profile"}],"revision":99}
            """#)
        }
        let (api, _) = try await makeAPI(stub: stub, profileId: "profile-a")
        let store = OverlayPrefsStore(api: api)

        await store.refresh()

        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.prefs.preset, .minimal)
        let effective = try XCTUnwrap(stub.requests.first { $0.path.hasSuffix(Self.effectivePath) })
        XCTAssertEqual(effective.query["keys"], "ui.card_overlays")
    }

    func testConfigReplyWithoutRequiredMembersKeepsTheCachedKillSwitch() async throws {
        // The first reply disables overlays; the second omits the required
        // quick-action members, so it is not an overlay config and must not
        // read as "enabled".
        let stub = StubURLProtocol.Handler()
        stub.expect(StubURLProtocol.path(Self.configPath)) { _ in
            .json(#"{"enabled":false,"quick_actions_enabled":true,"quick_actions_default":"both"}"#)
        }
        stub.expect(StubURLProtocol.path(Self.configPath)) { _ in .json(#"{"enabled":true}"#) }
        stub.route(StubURLProtocol.pathSuffix(Self.effectivePath)) { _ in
            .json(#"{"items":[{"key":"ui.card_overlays","value":null,"source":"default"}],"revision":99}"#)
        }
        let (api, _) = try await makeAPI(stub: stub, profileId: "profile-a")
        let store = OverlayPrefsStore(api: api)

        await store.refresh()
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.enabled)

        await store.refresh()
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.enabled, "an unreadable config must not re-enable overlays")
        let configRequests = stub.requests.filter { $0.path == Self.configPath }
        XCTAssertEqual(configRequests.count, 2)
        XCTAssertEqual(configRequests.map(\.method), ["GET", "GET"])
        XCTAssertTrue(stub.unmatched.isEmpty)
    }

    // MARK: - Harness

    private func makeAPI(
        stub: StubURLProtocol.Handler,
        profileId: String
    ) async throws -> (SiloAPI, TokenStore) {
        let suiteName = "overlay-prefs-tests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: "OverlayPrefsStoreTests.\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "server-a")
        await tokens.setServerUrl("https://overlay.example")
        await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        await tokens.setProfileId(profileId)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }
}
