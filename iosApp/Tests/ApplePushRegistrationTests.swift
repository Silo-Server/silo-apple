import Foundation
import UserNotifications
import XCTest
@testable import Silo

final class ApplePushRegistrationTests: XCTestCase {
    @MainActor
    private func orderedFixture(barrier: (@Sendable (TokenStore) async -> Void)? = nil) async throws -> (APIv2Client, TokenStore, SharedKeychain, ApplePushDisplayTokenStore) {
        let name = "AppleOrderedTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let tokens = TokenStore(keychain: keychain, defaults: defaults)
        await tokens.switchActiveServer(serverId: "synthetic")
        await tokens.setServerUrl("https://push.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppleOrderedProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens,
            requestCaptureBarrier: { await barrier?(tokens) })
        AppleOrderedProtocol.reset()
        addTeardownBlock {
            suite.removePersistentDomain(forName: name)
            keychain.delete("apple-push-ordered-intents-v1")
            keychain.delete(SharedStorage.applePushDisplayTokenAccount)
            AppleOrderedProtocol.reset()
        }
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens, keychain,
                ApplePushDisplayTokenStore(keychain: keychain, defaults: defaults))
    }

    private var orderedBody: ApplePushRegistrationRequest {
        ApplePushRegistrationRequest(deviceId: "installation", apnsToken: String(repeating: "ab", count: 32),
            apnsEnvironment: "sandbox", apnsTopic: "org.siloserver.silo", pushMode: "private_push")
    }

    private func orderedReceipt(generation: Int = 1, enabled: Bool = true, removed: Bool = false, token: String = "display") -> String {
        #"{"generation":"GEN","id":"registration","server_device_id":"device","push_mode":"private_push","enabled":ENABLED,"removed":REMOVED,"display_token":"TOKEN","display_token_expires_at":"2099-01-01T00:00:00Z"}"#
            .replacingOccurrences(of: "GEN", with: String(generation))
            .replacingOccurrences(of: "ENABLED", with: String(enabled))
            .replacingOccurrences(of: "REMOVED", with: String(removed))
            .replacingOccurrences(of: "TOKEN", with: token)
    }

    @MainActor
    func testOrderedJournalPersistsOriginalCommandAndAdvancesOnlyNewIntent() async throws {
        let (_, tokens, keychain, _) = try await orderedFixture()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let journal = ApplePushRegistrationJournal(keychain: keychain)
        let first = try journal.prepare(body: orderedBody, auth: auth)
        let recovered = ApplePushRegistrationJournal(keychain: keychain)
        let rotation = CapturedOrdinaryRequestAuth(account: auth.account, credentialOwner: auth.credentialOwner,
            accessToken: "rotated", profileId: auth.profileId, profileToken: auth.profileToken)
        let renewed = try recovered.prepare(body: orderedBody, auth: rotation)
        XCTAssertEqual(renewed.generation, 1)
        XCTAssertEqual(renewed.authority, first.authority)
        XCTAssertEqual(renewed.installationKey, first.installationKey)
        XCTAssertEqual(renewed.installationKey.count, 43)
        await tokens.setProfileId("new-profile")
        let nextAuth = await tokens.captureOrdinaryRequestAuth()
        let next = try recovered.prepare(body: orderedBody, auth: XCTUnwrap(nextAuth))
        XCTAssertEqual(next.generation, 2)
        XCTAssertEqual(next.installationKey, first.installationKey)
        XCTAssertEqual(first.authority.profileID, "profile")
        XCTAssertFalse(try recovered.isCurrent(first))
        XCTAssertTrue(try recovered.isCurrent(next))
    }

    @MainActor
    func testOrderedRegistrationSuccessAndRenewalReuseExactPersistedWire() async throws {
        let (api, tokens, keychain, display) = try await orderedFixture()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        AppleOrderedProtocol.reply(200, orderedReceipt())
        let journal = ApplePushRegistrationJournal(keychain: keychain)
        let engine = ApplePushOrderedRegistration(api: api, tokens: tokens, journal: journal, display: display)
        try await engine.register(body: orderedBody, auth: auth)
        XCTAssertEqual(keychain.get(SharedStorage.applePushDisplayTokenAccount), "display")
        let count = AppleOrderedProtocol.requests().count
        try await engine.register(body: orderedBody, auth: auth)
        XCTAssertEqual(AppleOrderedProtocol.requests().count, count)
        XCTAssertTrue(display.store(nil, expiresAt: nil, serverId: "synthetic"))
        let restarted = ApplePushOrderedRegistration(api: api, tokens: tokens,
            journal: ApplePushRegistrationJournal(keychain: keychain), display: display)
        try await restarted.register(body: orderedBody, auth: auth)
        let writes = AppleOrderedProtocol.requests().filter { $0.0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].0.url?.path, "/api/v2/devices/push/apple")
        XCTAssertEqual(writes[0].0.value(forHTTPHeaderField: "X-Push-Generation"), "1")
        XCTAssertEqual(writes[0].0.value(forHTTPHeaderField: "X-Push-Installation-Key"), writes[1].0.value(forHTTPHeaderField: "X-Push-Installation-Key"))
        XCTAssertEqual(writes[0].1, writes[1].1)
        XCTAssertEqual(try journal.latest()?.generation, 1)
    }

    @MainActor
    func testOrderedDisabledRemovedAndConflictNeverStoreCredentialOrRebase() async throws {
        for outcome in ["disabled", "removed", "conflict", "mismatch"] {
            let (api, tokens, keychain, display) = try await orderedFixture()
            let captured = await tokens.captureOrdinaryRequestAuth()
            let auth = try XCTUnwrap(captured)
            display.store("old", expiresAt: "2099-01-01T00:00:00Z", serverId: "synthetic")
            let journal = ApplePushRegistrationJournal(keychain: keychain)
            let engine = ApplePushOrderedRegistration(api: api, tokens: tokens, journal: journal, display: display)
            if outcome == "conflict" { AppleOrderedProtocol.reply(409, "{}") }
            else { AppleOrderedProtocol.reply(200, orderedReceipt(generation: outcome == "mismatch" ? 2 : 1,
                enabled: outcome != "disabled", removed: outcome == "removed", token: "must-not-store")) }
            do { try await engine.register(body: orderedBody, auth: auth) }
            catch { XCTAssertTrue(outcome == "conflict" || outcome == "mismatch") }
            XCTAssertNil(keychain.get(SharedStorage.applePushDisplayTokenAccount))
            let count = AppleOrderedProtocol.requests().count
            try? await engine.register(body: orderedBody, auth: auth)
            XCTAssertEqual(AppleOrderedProtocol.requests().count, count)
            XCTAssertEqual(try journal.latest()?.generation, 1)
        }
    }

    @MainActor
    func testOrderedPersistenceFailureAndCaptureReplacementSendNothing() async throws {
        let (api, tokens, keychain, display) = try await orderedFixture()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let failed = ApplePushRegistrationJournal(keychain: keychain, writer: { _ in false })
        let engine = ApplePushOrderedRegistration(api: api, tokens: tokens, journal: failed, display: display)
        do { try await engine.register(body: orderedBody, auth: auth); XCTFail("Persistence must precede dispatch") }
        catch ApplePushOrderedError.persistence { }
        XCTAssertTrue(AppleOrderedProtocol.requests().isEmpty)
        let (blockedAPI, blockedTokens, blockedKeychain, blockedDisplay) = try await orderedFixture(barrier: { await $0.setProfileToken("replacement") })
        let original = await blockedTokens.captureOrdinaryRequestAuth()
        let blocked = ApplePushOrderedRegistration(api: blockedAPI, tokens: blockedTokens,
            journal: ApplePushRegistrationJournal(keychain: blockedKeychain), display: blockedDisplay)
        do { try await blocked.register(body: orderedBody, auth: XCTUnwrap(original)); XCTFail("PIN rebound") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(AppleOrderedProtocol.requests().isEmpty)
    }

    @MainActor
    func testOrderedUncertainAnd401RetriesKeepGenerationAndNeverAuthReplay() async throws {
        for status in [500, 401] {
            let (api, tokens, keychain, display) = try await orderedFixture()
            let captured = await tokens.captureOrdinaryRequestAuth()
            let auth = try XCTUnwrap(captured)
            let journal = ApplePushRegistrationJournal(keychain: keychain)
            let engine = ApplePushOrderedRegistration(api: api, tokens: tokens, journal: journal, display: display)
            AppleOrderedProtocol.reply(status, "{}")
            do { try await engine.register(body: orderedBody, auth: auth); XCTFail("Expected failure") } catch { }
            XCTAssertEqual(AppleOrderedProtocol.requests().filter { $0.0.httpMethod == "POST" }.count, 1)
            XCTAssertFalse(AppleOrderedProtocol.requests().contains { $0.0.url?.path.contains("auth/refresh") == true })
            AppleOrderedProtocol.reply(200, orderedReceipt())
            try await engine.register(body: orderedBody, auth: auth)
            let writes = AppleOrderedProtocol.requests().filter { $0.0.httpMethod == "POST" }
            XCTAssertEqual(writes.count, 2)
            XCTAssertEqual(writes[0].0.value(forHTTPHeaderField: "X-Push-Generation"), writes[1].0.value(forHTTPHeaderField: "X-Push-Generation"))
            XCTAssertEqual(writes[0].1, writes[1].1)
        }
    }

    @MainActor
    func testOrderedDisplayWriteFailureCannotDeduplicateAgainstOldCurrentToken() async throws {
        let (api, tokens, keychain, baseDisplay) = try await orderedFixture()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        baseDisplay.store("old-current-token", expiresAt: "2099-01-01T00:00:00Z", serverId: "synthetic")
        var failingDisplay = baseDisplay
        failingDisplay.writeToken = { _ in false }
        let journal = ApplePushRegistrationJournal(keychain: keychain)
        AppleOrderedProtocol.reply(200, orderedReceipt(token: "new-token"))
        let failed = ApplePushOrderedRegistration(api: api, tokens: tokens, journal: journal, display: failingDisplay)
        do { try await failed.register(body: orderedBody, auth: auth); XCTFail("Expected display write failure") }
        catch ApplePushOrderedError.persistence { }
        XCTAssertEqual(try journal.latest()?.displayApplied, false)
        XCTAssertEqual(keychain.get(SharedStorage.applePushDisplayTokenAccount), "old-current-token")
        let restarted = ApplePushOrderedRegistration(api: api, tokens: tokens,
            journal: ApplePushRegistrationJournal(keychain: keychain), display: baseDisplay)
        try await restarted.register(body: orderedBody, auth: auth)
        XCTAssertEqual(keychain.get(SharedStorage.applePushDisplayTokenAccount), "new-token")
        XCTAssertEqual(try journal.latest()?.displayApplied, true)
        let writes = AppleOrderedProtocol.requests().filter { $0.0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map { $0.0.value(forHTTPHeaderField: "X-Push-Generation") }, ["1", "1"])
    }

    @MainActor
    func testOrderedLateReceiptAndAtomicStorageRejectOldIntentOrPIN() async throws {
        let (api, tokens, keychain, display) = try await orderedFixture()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let journal = ApplePushRegistrationJournal(keychain: keychain)
        let engine = ApplePushOrderedRegistration(api: api, tokens: tokens, journal: journal, display: display)
        AppleOrderedProtocol.reply(200, orderedReceipt(token: "old"))
        let held = expectation(description: "old Apple POST held")
        AppleOrderedProtocol.holdNextPost { held.fulfill() }
        let old = Task { try await engine.register(body: orderedBody, auth: auth) }
        await fulfillment(of: [held], timeout: 2)
        let oldIntent = try XCTUnwrap(journal.latest())
        let newBody = ApplePushRegistrationRequest(deviceId: orderedBody.deviceId, apnsToken: String(repeating: "cd", count: 32),
            apnsEnvironment: "sandbox", apnsTopic: orderedBody.apnsTopic, pushMode: "private_push")
        AppleOrderedProtocol.reply(200, orderedReceipt(generation: 2, token: "new"))
        try await engine.register(body: newBody, auth: auth)
        AppleOrderedProtocol.release()
        try await old.value
        XCTAssertEqual(keychain.get(SharedStorage.applePushDisplayTokenAccount), "new")
        let staleEffect = journal.credentialEffect(for: oldIntent, clearing: false) {
            XCTFail("Stale journal must not reach credential effect")
        }
        do { try await tokens.withCurrentOrdinaryAuthority(auth, operation: staleEffect); XCTFail("Old intent accepted") }
        catch ApplePushOrderedError.conflict { }
        await tokens.setProfileToken("replacement")
        do {
            try await tokens.withCurrentOrdinaryAuthority(auth) { XCTFail("Old PIN must not store credentials") }
            XCTFail("Old PIN accepted")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(keychain.get(SharedStorage.applePushDisplayTokenAccount), "new")
    }

    func testTokenHexEncodesToLowercasePaddedHex() {
        let data = Data([0x00, 0x01, 0x0f, 0x10, 0xab, 0xff])

        XCTAssertEqual(ApplePushRegistrationWire.tokenHex(from: data), "00010f10abff")
    }

    func testEmptyBundleIdentifiersFallBackToSiloTopic() {
        XCTAssertEqual(ApplePushRegistrationWire.topic(bundleIdentifier: nil), "org.siloserver.silo")
        XCTAssertEqual(ApplePushRegistrationWire.topic(bundleIdentifier: "   "), "org.siloserver.silo")
        XCTAssertEqual(ApplePushRegistrationWire.topic(bundleIdentifier: "org.example.app"), "org.example.app")
    }

    func testAPNsEnvironmentParsesFromProvisioningProfile() {
        XCTAssertEqual(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: "development")
            ),
            "sandbox"
        )
        XCTAssertEqual(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: "production")
            ),
            "production"
        )
    }

    func testAPNsEnvironmentIsNilWithoutPushEntitlement() {
        XCTAssertNil(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: nil)
            )
        )
        XCTAssertNil(ApplePushRegistrationWire.apnsEnvironment(fromProvisioningProfile: Data([0x30, 0x82, 0x01])))
        XCTAssertNil(
            ApplePushRegistrationWire.apnsEnvironment(
                fromProvisioningProfile: Self.provisioningProfileData(apsEnvironment: "bogus")
            )
        )
    }

    func testNotificationSyncQueryIncludesLimitAndOptionalCursor() {
        XCTAssertEqual(ApplePushNotificationSyncWire.query(cursor: nil), ["limit": "50"])
        XCTAssertEqual(ApplePushNotificationSyncWire.query(cursor: "cursor"), [
            "limit": "50",
            "cursor": "cursor"
        ])
    }

    func testNotificationSyncResponseDecodesSnakeCasePayload() throws {
        let json = """
        {
          "items": [
            {
              "id": "delivery-1",
              "type": "new_episode",
              "profile_id": "profile-1",
              "series_title": "Example",
              "reason_flags": {"watchlist": true},
              "created_at": "2026-07-01T12:30:00Z",
              "read_at": null
            }
          ],
          "page": {"has_more": false},
          "sync_cursor": "cursor-1",
          "initial_snapshot": true,
          "unread_count": 3
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(ApplePushNotificationSyncResponse.self, from: json)

        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items.first?.id, "delivery-1")
        XCTAssertEqual(response.items.first?.profileId, "profile-1")
        XCTAssertNotNil(response.items.first?.createdAt)
        XCTAssertNil(response.items.first?.readAt)
        XCTAssertEqual(response.syncCursor, "cursor-1")
        XCTAssertEqual(response.unreadCount, 3)
    }

    func testNotificationDisplayDeliveryIDParsesFromAPNsPayload() {
        XCTAssertEqual(ApplePushDisplayWire.deliveryID(from: ["silo_delivery_id": "  delivery-1  "]), "delivery-1")
        XCTAssertNil(ApplePushDisplayWire.deliveryID(from: ["silo_delivery_id": "   "]))
        XCTAssertNil(ApplePushDisplayWire.deliveryID(from: [:]))
    }

    func testNotificationDisplayEndpointURLAppendsDeliveryID() throws {
        let url = try XCTUnwrap(ApplePushDisplayWire.displayURL(
            serverURL: "https://silo.example.test/",
            deliveryID: "delivery-1"
        ))

        XCTAssertEqual(url.absoluteString, "https://silo.example.test/api/v2/notifications/push/apple/display/delivery-1")
    }

    func testNotificationDisplayResponseDecodesAndMutatesNotificationContent() throws {
        let json = """
        {
          "delivery_id": "delivery-1",
          "title": "New episode of Example",
          "body": "S1E2 - Pilot",
          "thread_id": "series:series-1",
          "category": "episode_available",
          "url": "/item/episode-1"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ApplePushDisplayResponse.self, from: json)
        let content = UNMutableNotificationContent()
        content.title = "Silo"
        content.body = "New notification available"
        content.userInfo = ["silo_delivery_id": "delivery-1"]

        response.apply(to: content)

        XCTAssertEqual(content.title, "New episode of Example")
        XCTAssertEqual(content.body, "S1E2 - Pilot")
        XCTAssertEqual(content.threadIdentifier, "series:series-1")
        XCTAssertEqual(content.categoryIdentifier, "episode_available")
        XCTAssertEqual(content.userInfo["silo_delivery_id"] as? String, "delivery-1")
        XCTAssertEqual(content.userInfo["silo_url"] as? String, "/item/episode-1")
    }

    func testDisplayAuthStatePrefersDisplayTokenOverAccessToken() {
        let withDisplay = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "expired-access",
            profileToken: "",
            displayToken: " display-token "
        )
        XCTAssertTrue(withDisplay.isUsable)
        XCTAssertEqual(withDisplay.bearerToken, "display-token")

        // Older servers return no display token: the access token still works.
        let legacy = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "access",
            profileToken: ""
        )
        XCTAssertTrue(legacy.isUsable)
        XCTAssertEqual(legacy.bearerToken, "access")

        // A display token alone is enough: the access mirror may be gone
        // after a refresh race while the registration token remains valid.
        let displayOnly = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "",
            profileToken: "",
            displayToken: "display-token"
        )
        XCTAssertTrue(displayOnly.isUsable)

        let neither = ApplePushDisplayAuthState(
            serverURL: "https://silo.example.test",
            profileID: "profile-1",
            accessToken: "  ",
            profileToken: ""
        )
        XCTAssertFalse(neither.isUsable)

        // A rejected display token falls back to the access token once;
        // without a distinct access token there is nothing to retry with.
        let fallback = try? XCTUnwrap(withDisplay.accessTokenFallback)
        XCTAssertEqual(fallback?.bearerToken, "expired-access")
        XCTAssertEqual(fallback?.displayToken, "")
        XCTAssertNil(legacy.accessTokenFallback)
        XCTAssertNil(displayOnly.accessTokenFallback)
    }

    func testRegistrationResponseDecodesOptionalDisplayToken() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let modern = try decoder.decode(ApplePushRegistrationResponse.self, from: Data("""
        {"id":"push-1","server_device_id":"dev-1","enabled":true,"push_mode":"private_push","display_token":"tok","display_token_expires_at":"2026-10-03T00:00:00Z"}
        """.utf8))
        XCTAssertEqual(modern.displayToken, "tok")
        XCTAssertEqual(modern.displayTokenExpiresAt, "2026-10-03T00:00:00Z")

        let legacy = try decoder.decode(ApplePushRegistrationResponse.self, from: Data("""
        {"id":"push-1","server_device_id":"dev-1","enabled":true,"push_mode":"private_push"}
        """.utf8))
        XCTAssertNil(legacy.displayToken)
        XCTAssertNil(legacy.displayTokenExpiresAt)
    }

    func testDisplayTokenExpiryParsesWithAndWithoutFractionalSeconds() throws {
        let plain = try XCTUnwrap(ApplePushDisplayTokenStore.parseExpiry("2026-10-03T00:00:00Z"))
        let fractional = try XCTUnwrap(ApplePushDisplayTokenStore.parseExpiry("2026-10-03T00:00:00.250Z"))
        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.25, accuracy: 0.001)
        XCTAssertNil(ApplePushDisplayTokenStore.parseExpiry("not-a-date"))
    }

    func testNotificationDisplayURLMapsToAppDeepLink() throws {
        let itemURL = try XCTUnwrap(ApplePushDeepLinkCoordinator.deepLinkURL(from: [
            "silo_url": "/item/episode-1"
        ]))
        XCTAssertEqual(itemURL.absoluteString, "continuum://item/episode-1")

        let absoluteURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "https://silo.example.test/item/movie-123?from=push")
        )
        XCTAssertEqual(absoluteURL.absoluteString, "continuum://item/movie-123")

        let existingURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "continuum://play/episode-1")
        )
        XCTAssertEqual(existingURL.absoluteString, "continuum://play/episode-1")

        // Routes are forwarded without an allowlist — ContentView's
        // handleDeepLink owns validity and ignores unknown hosts — so new
        // push destinations can't silently drift out of sync here.
        let forwardedURL = try XCTUnwrap(
            ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "/settings/notifications")
        )
        XCTAssertEqual(forwardedURL.absoluteString, "continuum://settings/notifications")

        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "/item"))
        XCTAssertNil(ApplePushDeepLinkCoordinator.deepLinkURL(fromDisplayURL: "   "))
    }

    /// Builds a fake `embedded.mobileprovision`: an XML plist wrapped in
    /// leading/trailing binary junk, like the real CMS envelope.
    private static func provisioningProfileData(apsEnvironment: String?) -> Data {
        let entitlement = apsEnvironment.map {
            "<key>aps-environment</key><string>\($0)</string>"
        } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Test Profile</string>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key><string>TEAMID.org.example.app</string>
                \(entitlement)
            </dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x0a, 0x0b])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x01, 0x02]))
        return data
    }
}

private final class AppleOrderedProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (200, "{}")
    nonisolated(unsafe) private static var calls: [(URLRequest, Data?)] = []
    nonisolated(unsafe) private static var hold: (() -> Void)?
    nonisolated(unsafe) private static var pending: (() -> Void)?
    static func reset() { lock.withLock { response = (200, "{}"); calls = []; hold = nil; pending = nil } }
    static func reply(_ status: Int, _ body: String) { lock.withLock { response = (status, body) } }
    static func requests() -> [(URLRequest, Data?)] { lock.withLock { calls } }
    static func holdNextPost(_ notify: @escaping () -> Void) { lock.withLock { hold = notify } }
    static func release() { let send = lock.withLock { let send = pending; pending = nil; return send }; send?() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
            body = data
        }
        let reply = Self.lock.withLock {
            Self.calls.append((request, body))
            return request.httpMethod == "GET" ? (200, #"{"revision":"ordered_apple_v1","registration_available":true}"#) : Self.response
        }
        let send = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let notify = Self.lock.withLock { () -> (() -> Void)? in
            guard request.httpMethod == "POST", let notify = Self.hold else { return nil }
            Self.hold = nil; Self.pending = send
            return notify
        }
        if let notify { notify() } else { send() }
    }
    override func stopLoading() { }
}
