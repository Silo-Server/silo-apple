import Foundation
import XCTest
@testable import Silo

@MainActor
final class UICustomizationV2Tests: XCTestCase {
    private func harness(writer: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) async throws -> (UICustomizationPreferences, SiloUICustomizationTransport, SettingsMutationJournal, TokenStore, UserDefaults, String, URL) {
        let name = "UICustomizationV2Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let shared = SharedDefaults(suite: defaults, standard: defaults)
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: shared)
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://settings.example")
        try await tokens.installAccountSession(accessToken: "test-access", refreshToken: "test-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterfaceSettingsProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens,
            v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let journal = SettingsMutationJournal(url: root.appendingPathComponent("commands.json"), write: writer)
        let transport = SiloUICustomizationTransport(api: api, tokens: tokens, defaults: shared, journal: journal)
        let identity = HTTPRequestIdentity(serverId: "server", serverURL: "https://settings.example",
            profileId: "profile", clientFamily: AppleDeviceIdentity.current.clientFamily)
        let legacyKey = "silo.uiCustomization.server.profile.\(identity.clientFamily)"
        let preferences = UICustomizationPreferences(defaults: shared, transport: transport,
            cacheKey: { legacyKey }, requestIdentity: { identity })
        InterfaceSettingsProtocol.reset()
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        return (preferences, transport, journal, tokens, defaults, legacyKey, root)
    }

    func testColdTokenStorePreservesCacheNamespaceAndUncertainOriginalCommand() async throws {
        let (preferences, transport, journal, _, defaults, legacyKey, root) = try await harness()
        await preferences.refresh()
        let key = try XCTUnwrap(transport.storageKey(for: legacyKey))
        InterfaceSettingsProtocol.status(503)
        preferences.setCardPresentation(.init(posterSize: .large, caption: .title))
        await preferences.refresh()
        let original = try XCTUnwrap(journal.snapshot().first)
        let shared = SharedDefaults(suite: defaults, standard: defaults)
        let tokens = TokenStore(keychain: SharedKeychain(service: root.lastPathComponent, accessGroup: nil), defaults: shared)
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://settings.example")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [InterfaceSettingsProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens, v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
        let cold = SiloUICustomizationTransport(api: api, tokens: tokens, defaults: shared,
            journal: SettingsMutationJournal(url: root.appendingPathComponent("commands.json")))
        let identity = HTTPRequestIdentity(serverId: "server", serverURL: "https://settings.example",
            profileId: "profile", clientFamily: AppleDeviceIdentity.current.clientFamily)
        let newPreferences = UICustomizationPreferences(defaults: shared, transport: cold,
            cacheKey: { legacyKey }, requestIdentity: { identity })
        InterfaceSettingsProtocol.status(200)
        await newPreferences.refresh()
        XCTAssertEqual(cold.storageKey(for: legacyKey), key)
        XCTAssertNotEqual(cold.authority(for: identity)?.credentialGeneration, original.authority.credentialGeneration)
        newPreferences.setCardPresentation(.init(posterSize: .compact, caption: .artwork))
        await newPreferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().count, 1)
        XCTAssertEqual(try journal.snapshot().first, original)
        XCTAssertNotNil(newPreferences.syncErrorMessage)
    }

    func testLegacyProjectionCannotBecomeV2MutationWithoutAuthoritativeRead() async throws {
        let (preferences, transport, journal, _, defaults, legacyKey, _) = try await harness()
        let legacy = Data(#"{"shortcuts":{"items":[]},"cardPresentation":{"poster_size":"large","caption":"artwork"},"pendingSyncWrites":{"nav.primary_menu":{"value":{"items":[{"type":"builtin","key":"home"}]},"mutationId":"old-intent"}}}"#.utf8)
        defaults.set(legacy, forKey: legacyKey)
        InterfaceSettingsProtocol.failReads(true)
        await preferences.refresh()
        XCTAssertFalse(preferences.allowsEditing)
        preferences.setCardPresentation(.standard)
        XCTAssertTrue(try journal.snapshot().isEmpty)
        XCTAssertEqual(defaults.data(forKey: legacyKey), legacy)
        XCTAssertNil(defaults.data(forKey: try XCTUnwrap(transport.storageKey(for: legacyKey))))
    }

    func testInitialShortcutAppendFailurePreservesProjectionAndAllowsExplicitRetry() async throws {
        let writer = InterfaceShortcutWriter()
        let (preferences, _, journal, _, _, _, _) = try await harness(writer: writer.write)
        await preferences.refresh()
        let library = try HTTPClient.makeJSONDecoder().decode(Library.self,
            from: Data(#"{"id":7,"name":"Library","type":"movie"}"#.utf8))
        preferences.setLibraryPinned(library, isPinned: true)
        XCTAssertFalse(preferences.isLibraryPinned(library.id))
        XCTAssertTrue(try journal.snapshot().isEmpty)
        XCTAssertTrue(InterfaceSettingsProtocol.mutations().isEmpty)
        XCTAssertNotNil(preferences.syncErrorMessage)

        // Storage recovery alone must allow the same explicit action, without a refresh.
        writer.allowWrites()
        preferences.setLibraryPinned(library, isPinned: true)
        let original = try XCTUnwrap(journal.snapshot().first)
        XCTAssertTrue(preferences.isLibraryPinned(library.id))
        XCTAssertEqual(original.path, "/api/v2/settings/values/nav.shortcuts/item")
        await preferences.refresh()
        let writes = InterfaceSettingsProtocol.mutations()
        XCTAssertEqual(writes.map { $0.0.url!.lastPathComponent }, ["item", "nav.primary_menu"])
        XCTAssertEqual(writes.first?.1, original.body)
        XCTAssertEqual(try journal.snapshot().first?.authority, original.authority)
    }

    func testDependentMenuSurvivesJournalFailureWithoutReplayingAcceptedShortcut() async throws {
        let writer = InterfaceMenuWriter()
        let (preferences, _, journal, _, _, _, _) = try await harness(writer: writer.write)
        await preferences.refresh()
        let library = try HTTPClient.makeJSONDecoder().decode(Library.self,
            from: Data(#"{"id":7,"name":"Library","type":"movie"}"#.utf8))
        preferences.setLibraryPinned(library, isPinned: true)
        await preferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().count, 1)
        XCTAssertEqual(try journal.snapshot().first?.state, .applied)
        XCTAssertNotNil(preferences.syncErrorMessage)
        writer.allowMenu()
        await preferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().map { $0.0.url!.lastPathComponent }, ["item", "nav.primary_menu"])
        XCTAssertEqual(try journal.snapshot().count, 2)
        XCTAssertTrue(try journal.snapshot().allSatisfy { $0.state == .applied })
    }

    func testFreshUIWriteAndDeletePersistBeforeSingleV2Dispatch() async throws {
        let (preferences, transport, journal, _, defaults, legacyKey, _) = try await harness()
        await preferences.refresh()
        XCTAssertTrue(preferences.allowsEditing)
        preferences.setCardPresentation(.init(posterSize: .large, caption: .artwork))
        let prepared = try XCTUnwrap(journal.snapshot().first)
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.body, Data(#"{"value":{"caption":"artwork","poster_size":"large"}}"#.utf8))
        await preferences.refresh()
        await preferences.refresh()
        let puts = InterfaceSettingsProtocol.mutations()
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts[0].0.url?.path, "/api/v2/settings/values/ui.card_presentation")
        XCTAssertEqual(puts[0].1, prepared.body)
        XCTAssertNil(puts[0].0.value(forHTTPHeaderField: "X-Silo-Mutation-Id"))
        XCTAssertNil(puts[0].0.value(forHTTPHeaderField: "If-Match"))
        XCTAssertEqual(try journal.snapshot().first?.state, .applied)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNotNil(defaults.data(forKey: try XCTUnwrap(transport.storageKey(for: legacyKey))))
        preferences.resetCardPresentationToInherited()
        await preferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().filter { $0.0.httpMethod == "DELETE" }.count, 1)
    }

    func testShortcutReceiptPrecedesDependentMenuDispatch() async throws {
        let (preferences, _, journal, _, _, _, _) = try await harness()
        await preferences.refresh()
        let library = try HTTPClient.makeJSONDecoder().decode(Library.self,
            from: Data(#"{"id":7,"name":"Library","type":"movie"}"#.utf8))
        preferences.setLibraryPinned(library, isPinned: true)
        XCTAssertEqual(try journal.snapshot().count, 1)
        XCTAssertEqual(try journal.snapshot().first?.path, "/api/v2/settings/values/nav.shortcuts/item")
        await preferences.refresh()
        let writes = InterfaceSettingsProtocol.mutations()
        XCTAssertEqual(writes.map { $0.0.url!.lastPathComponent }, ["item", "nav.primary_menu"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: writes[0].1) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["item", "present"])
        XCTAssertEqual(body["present"] as? Bool, true)
        XCTAssertTrue(try journal.snapshot().allSatisfy { $0.state == .applied })
    }

    func testUncertainShortcutNeverReplaysOrAllocatesDependentMenu() async throws {
        let (preferences, _, journal, _, _, _, _) = try await harness()
        await preferences.refresh()
        let library = try HTTPClient.makeJSONDecoder().decode(Library.self,
            from: Data(#"{"id":7,"name":"Library","type":"movie"}"#.utf8))
        InterfaceSettingsProtocol.status(503)
        preferences.setLibraryPinned(library, isPinned: true)
        await preferences.refresh()
        let original = try XCTUnwrap(journal.snapshot().first)
        InterfaceSettingsProtocol.status(200)
        await preferences.refresh()
        await preferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().count, 1)
        XCTAssertEqual(try journal.snapshot(), [original])
        XCTAssertEqual(original.state, .uncertain)
        XCTAssertNotNil(preferences.syncErrorMessage)
        preferences.setCardPresentation(.init(posterSize: .compact, caption: .title))
        await preferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().count, 2)
    }

    func testLegacyQueueBytesRemainUntouchedWhileOtherFreshSettingsWork() async throws {
        let (preferences, _, journal, _, defaults, legacyKey, _) = try await harness()
        let legacy = Data(#"{ "pendingSyncWrites": {"ui.card_presentation":{"original":"intent"}} }"#.utf8)
        defaults.set(legacy, forKey: legacyKey)
        await preferences.refresh()
        preferences.setCardPresentation(.init(posterSize: .large, caption: .title))
        await preferences.refresh()
        XCTAssertEqual(defaults.data(forKey: legacyKey), legacy)
        XCTAssertEqual(try journal.snapshot().first?.state, .legacyHeld)
        XCTAssertTrue(InterfaceSettingsProtocol.mutations().isEmpty)
        preferences.setPrimaryMenuItems([.builtin(.home), .builtin(.movies)])
        await preferences.refresh()
        XCTAssertEqual(InterfaceSettingsProtocol.mutations().count, 1)
        XCTAssertEqual(defaults.data(forKey: legacyKey), legacy)
        XCTAssertNotNil(preferences.syncErrorMessage)
    }

    func testReloginCannotDispatchOrTakeOwnershipOfPreparedEnvelope() async throws {
        let (preferences, transport, journal, tokens, _, legacyKey, _) = try await harness()
        await preferences.refresh()
        let originalKey = transport.storageKey(for: legacyKey)
        let identity = HTTPRequestIdentity(serverId: "server", serverURL: "https://settings.example",
            profileId: "profile", clientFamily: AppleDeviceIdentity.current.clientFamily)
        let id = UUID().uuidString
        try transport.prepareValue(id: id, key: .uiCardPresentation, scope: .profileClient,
            value: .null, identity: identity)
        let saved = try journal.snapshot()
        try await tokens.installAccountSession(accessToken: "next", refreshToken: "next-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        do { try await transport.send(id: id, identity: identity); XCTFail() } catch {}
        await preferences.refresh()
        XCTAssertNotEqual(transport.storageKey(for: legacyKey), originalKey)
        XCTAssertEqual(try journal.snapshot(), saved)
        XCTAssertTrue(InterfaceSettingsProtocol.mutations().isEmpty)
    }
}

private final class InterfaceSettingsProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [(URLRequest, Data)] = []
    nonisolated(unsafe) private static var code = 200
    nonisolated(unsafe) private static var readFailure = false
    static func failReads(_ value: Bool) { lock.withLock { readFailure = value } }
    static func reset() { lock.withLock { requests = []; code = 200; readFailure = false } }
    static func status(_ value: Int) { lock.withLock { code = value } }
    static func mutations() -> [(URLRequest, Data)] { lock.withLock { requests.filter { $0.0.httpMethod != "GET" } } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
        }
        let configured = Self.lock.withLock { Self.requests.append((request, bytes)); return Self.code }
        var code = 200
        let body: Data
        if request.url!.path.hasSuffix("/capabilities") {
            body = Data("""
            {"api_version":1,"revision":\(SettingKey.revision),"contract_etag":"fixture","definition_count":3,"scopes":["profile","profile_client","profile_device"],"supports_batched_effective":true,"supports_idempotent_writes":true,"supports_atomic_shortcuts":true}
            """.utf8)
        } else if request.httpMethod == "GET", Self.lock.withLock({ Self.readFailure }) {
            code = 503; body = Data("{}".utf8)
        } else if request.httpMethod == "GET" {
            body = Data("""
            {"items":[{"key":"nav.primary_menu","value":null,"source":"contract_default","profile_id":"profile"},{"key":"nav.shortcuts","value":{"items":[]},"source":"contract_default","profile_id":"profile"},{"key":"ui.card_presentation","value":{"poster_size":"standard","caption":"title_metadata"},"source":"profile_client","scope":"profile_client","profile_id":"profile"}],"page":{"has_more":false},"revision":\(SettingKey.revision)}
            """.utf8)
        } else if configured != 200 { code = configured; body = Data("{}".utf8) }
        else if request.httpMethod == "DELETE" { code = 204; body = Data() }
        else {
            let shortcut = request.url!.lastPathComponent == "item"
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let scope = shortcut ? "profile" : query.first(where: { $0.name == "scope" })!.value!
            body = try! JSONSerialization.data(withJSONObject: ["key": shortcut ? "nav.shortcuts" : request.url!.lastPathComponent,
                "scope": scope, "profile_id": "profile", "client_family": AppleDeviceIdentity.current.clientFamily,
                "device_id": AppleDeviceIdentity.current.id, "revision": 1, "value": true])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class InterfaceMenuWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = true
    func allowMenu() { lock.withLock { fails = false } }
    func write(_ data: Data, _ url: URL) throws {
        if lock.withLock({ fails }), String(decoding: data, as: UTF8.self).contains("nav.primary_menu") {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class InterfaceShortcutWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = true
    func allowWrites() { lock.withLock { fails = false } }
    func write(_ data: Data, _ url: URL) throws {
        if lock.withLock({ fails }) { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
