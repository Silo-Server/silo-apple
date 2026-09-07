import Foundation
import XCTest
@testable import Silo

@MainActor
final class SettingsMutationJournalTests: XCTestCase {
    private func harness() async throws -> (PlayerSettingsV2Queue, SettingsMutationJournal, TokenStore, UserDefaults, URL) {
        let name = "SettingsMutationJournalTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://settings.example")
        try await tokens.installAccountSession(accessToken: "access-secret", refreshToken: "refresh-secret", accountID: "1")
        await tokens.setProfileId("profile")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsMutationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens,
            v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let url = root.appendingPathComponent("commands.json")
        let journal = SettingsMutationJournal(url: url)
        SettingsMutationProtocol.reset()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: name)
        }
        return (PlayerSettingsV2Queue(api: api, tokens: tokens, defaults: defaults, journal: journal), journal, tokens, defaults, url)
    }

    private func restart(defaults: UserDefaults, url: URL) async throws -> (PlayerSettingsV2Queue, TokenStore) {
        let name = url.deletingLastPathComponent().lastPathComponent
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://settings.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsMutationProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens,
            v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
        return (PlayerSettingsV2Queue(api: api, tokens: tokens, defaults: defaults,
            journal: SettingsMutationJournal(url: url)), tokens)
    }

    func testColdTokenStoreRetainsUncertaintyBarrierAndOriginalCommand() async throws {
        let (queue, journal, tokens, defaults, url) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        SettingsMutationProtocol.setStatus(503)
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        await queue.flush()
        let original = try XCTUnwrap(journal.snapshot().first)
        let oldAuth = await tokens.captureDurableAccountAuth()
        let (coldQueue, coldTokens) = try await restart(defaults: defaults, url: url)
        let newAuth = await coldTokens.captureDurableAccountAuth()
        XCTAssertEqual(oldAuth?.accountEpoch, newAuth?.accountEpoch)
        XCTAssertNotEqual(oldAuth?.request.account.credentialGenerationID, newAuth?.request.account.credentialGenerationID)
        SettingsMutationProtocol.setStatus(200)
        do { _ = try await coldQueue.read(keys: [.playbackAutoSkipIntro]); XCTFail("Uncertain target must remain held") } catch {}
        coldQueue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(false)))
        await coldQueue.flush()
        XCTAssertEqual(SettingsMutationProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(try journal.snapshot().first, original)
        XCTAssertTrue(coldQueue.hasPending)
    }

    func testColdTokenStoreDispatchesPreparedEnvelopeWithoutChangingOriginalOwner() async throws {
        let (_, journal, tokens, defaults, url) = try await harness()
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try SettingsMutationAuthority(XCTUnwrap(captured))
        let prepared = SettingsMutationCommand(id: UUID(), authority: authority, key: SettingKey.playbackAutoSkipIntro.rawValue,
            method: "PUT", path: "/api/v2/settings/values/\(SettingKey.playbackAutoSkipIntro.rawValue)",
            query: ["scope": "profile_device"], body: Data(#"{"value":true}"#.utf8), state: .prepared)
        try journal.append(prepared)
        let (coldQueue, _) = try await restart(defaults: defaults, url: url)
        _ = try await coldQueue.read(keys: [.playbackAutoSkipIntro])
        let saved = try XCTUnwrap(journal.snapshot().first)
        XCTAssertEqual(saved.state, .applied)
        XCTAssertEqual(saved.authority, prepared.authority)
        XCTAssertEqual(saved.body, prepared.body)
        XCTAssertEqual(saved.query, prepared.query)
        XCTAssertEqual(SettingsMutationProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testChangedProfileProofCannotAdoptPreparedCommand() async throws {
        let (queue, journal, tokens, _, _) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        let prepared = try XCTUnwrap(journal.snapshot().first)
        _ = await tokens.setProfileToken("replacement-profile-proof")
        await queue.flush()
        XCTAssertEqual(try journal.snapshot().first, prepared)
        XCTAssertTrue(SettingsMutationProtocol.requests().allSatisfy { $0.httpMethod == "GET" })
    }

    func testOldExplicitDeviceCommandStillBlocksNewHeaderOnlyTargetWithoutReencoding() async throws {
        let (queue, journal, tokens, _, _) = try await harness()
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try SettingsMutationAuthority(XCTUnwrap(captured))
        let old = SettingsMutationCommand(id: UUID(), authority: authority, key: SettingKey.playbackAutoSkipIntro.rawValue,
            method: "PUT", path: "/api/v2/settings/values/\(SettingKey.playbackAutoSkipIntro.rawValue)",
            query: ["scope": "profile_device", "device_id": authority.deviceID],
            body: Data(#"{ "value" : true }"#.utf8), state: .uncertain)
        try journal.append(old)
        do { _ = try await queue.read(keys: [.playbackAutoSkipIntro]); XCTFail() } catch {}
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(false)))
        await queue.flush()
        XCTAssertEqual(try journal.snapshot().first, old)
        XCTAssertEqual(try journal.snapshot().last?.query, ["scope": "profile_device"])
        XCTAssertFalse(SettingsMutationProtocol.requests().contains { $0.httpMethod == "PUT" })
    }

    func testOwnFirstDeviceWriteUsesDeclaredHeaderNotExplicitRegistryTarget() async throws {
        let (queue, journal, _, _, _) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        // The accepted seam rejects explicit query targets before lazy registration.
        SettingsMutationProtocol.rejectUnregisteredExplicitDevice()
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        await queue.flush()
        let sent = try XCTUnwrap(SettingsMutationProtocol.requests().first { $0.httpMethod == "PUT" })
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Silo-Device-Id"), AppleDeviceIdentity.current.id)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "scope", value: "profile_device")])
        XCTAssertEqual(try journal.snapshot().first?.state, .applied)
    }

    func testFreshProductionWritesUseExactV2EnvelopeAndDoNotReplay() async throws {
        let (queue, journal, _, _, url) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        let prepared = try XCTUnwrap(journal.snapshot().first)
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.body, Data(#"{"value":true}"#.utf8))
        await queue.flush()
        await queue.flush()
        let requests = SettingsMutationProtocol.requests().filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v2/settings/values/\(SettingKey.playbackAutoSkipIntro.rawValue)")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Silo-Mutation-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
        XCTAssertEqual(try journal.snapshot().first?.state, .applied)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("access-secret")); XCTAssertFalse(saved.contains("refresh-secret"))
        queue.enqueue(.playbackAutoSkipIntro, operation: .delete)
        await queue.flush()
        XCTAssertEqual(SettingsMutationProtocol.requests().filter { $0.httpMethod == "DELETE" }.count, 1)
        XCTAssertTrue(try journal.snapshot().allSatisfy { $0.state == .applied })
    }

    func test401HoldsExactCommandAndLaterSameSettingWithoutAuthReplay() async throws {
        let (queue, journal, _, _, url) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        SettingsMutationProtocol.setStatus(401)
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        await queue.flush()
        let sent = try XCTUnwrap(journal.snapshot().first)
        XCTAssertEqual(sent.state, .uncertain)
        SettingsMutationProtocol.setStatus(200)
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(false)))
        await queue.flush()
        let restarted = SettingsMutationJournal(url: url)
        XCTAssertThrowsError(try restarted.claim(sent.id))
        XCTAssertEqual(try restarted.snapshot().first, sent)
        let requests = SettingsMutationProtocol.requests()
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("/auth/refresh") || $0.url!.path.contains("/api/v1/") })
        queue.enqueue(.playbackAutoSkipCredits, operation: .set(.bool(true)))
        await queue.flush()
        XCTAssertEqual(SettingsMutationProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 2)
        XCTAssertNotNil(queue.issue)
    }

    func testForeignReceiptCannotAcknowledgeThePersistedCommand() async throws {
        let (queue, journal, _, _, _) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        SettingsMutationProtocol.setReceiptProfile("other-profile")
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        let prepared = try XCTUnwrap(journal.snapshot().first)
        await queue.flush()
        let retained = try XCTUnwrap(journal.snapshot().first)
        XCTAssertEqual(retained.id, prepared.id)
        XCTAssertEqual(retained.body, prepared.body)
        XCTAssertEqual(retained.authority, prepared.authority)
        XCTAssertEqual(retained.state, .uncertain)
        await queue.flush()
        XCTAssertEqual(SettingsMutationProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testNewLoginCannotDispatchOldPreparedCommand() async throws {
        let (queue, journal, tokens, _, _) = try await harness()
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        let original = try journal.snapshot()
        try await tokens.installAccountSession(accessToken: "next", refreshToken: "next", accountID: "1")
        await tokens.setProfileId("profile")
        await queue.flush()
        XCTAssertEqual(try journal.snapshot(), original)
        XCTAssertFalse(SettingsMutationProtocol.requests().contains { $0.httpMethod == "PUT" })
    }

    func testLegacyIntentBytesRemainUntouchedAndBlockOnlyTheirSetting() async throws {
        let (queue, journal, tokens, defaults, _) = try await harness()
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try SettingsMutationAuthority(XCTUnwrap(captured))
        let name = "player.pendingDeviceSettingWrites.\(authority.legacyPlayerScope)"
        let legacy = Data("{ \"\(SettingKey.playbackAutoSkipIntro.rawValue)\": {\"old\":\"unresolved exact bytes\"} }".utf8)
        defaults.set(legacy, forKey: name)
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(true)))
        queue.enqueue(.playbackAutoSkipCredits, operation: .set(.bool(true)))
        await queue.flush()
        XCTAssertEqual(defaults.data(forKey: name), legacy)
        XCTAssertEqual(try journal.snapshot().first?.state, .legacyHeld)
        XCTAssertEqual(SettingsMutationProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testFailedDispatchClaimPersistsPreparedBytesAndSendsNothing() async throws {
        let (_, _, tokens, _, url) = try await harness()
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try SettingsMutationAuthority(XCTUnwrap(captured))
        let journal = SettingsMutationJournal(url: url, write: { data, url in
            if String(decoding: data, as: UTF8.self).contains("\"state\":\"uncertain\"") {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        let command = SettingsMutationCommand(id: UUID(), authority: authority, key: "key", method: "PUT",
            path: "/api/v2/settings/values/key", query: ["scope": "profile_device"], body: Data(), state: .prepared)
        try journal.append(command)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try journal.claim(command.id))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(SettingsMutationProtocol.requests().isEmpty)
    }

    func testProductionFlusherUsesV2QueueAndNeverImportsLegacyValues() async throws {
        let (queue, journal, _, _, _) = try await harness()
        let flusher = PlayerSettingsFlusher(transport: ForbiddenLegacySettingsTransport(), v2Queue: queue)
        XCTAssertFalse(flusher.permitsLegacyImport)
        _ = try await flusher.effectiveValues(keys: [.playbackAutoSkipIntro])
        flusher.enqueue(.playbackAutoSkipIntro, value: .bool(true))
        await flusher.flushNow()
        XCTAssertEqual(try journal.snapshot().first?.state, .applied)
        XCTAssertFalse(flusher.hasPendingWrites)
    }

    func testFailedDurabilityCannotClaimDispatch() async throws {
        let (_, _, tokens, _, url) = try await harness()
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try SettingsMutationAuthority(XCTUnwrap(captured))
        let journal = SettingsMutationJournal(url: url, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let command = SettingsMutationCommand(id: UUID(), authority: authority, key: "key", method: "PUT",
            path: "/api/v2/settings/values/key", query: ["scope": "profile_device"], body: Data(), state: .prepared)
        XCTAssertThrowsError(try journal.append(command))
        XCTAssertThrowsError(try journal.claim(command.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class SettingsMutationProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var status = 200
    private static var receiptProfile = "profile"
    private static var rejectExplicitDevice = false
    static func rejectUnregisteredExplicitDevice() { lock.withLock { rejectExplicitDevice = true } }
    static func reset() { lock.withLock { recorded = []; status = 200; receiptProfile = "profile"; rejectExplicitDevice = false } }
    static func setReceiptProfile(_ value: String) { lock.withLock { receiptProfile = value } }
    static func setStatus(_ value: Int) { lock.withLock { status = value } }
    static func requests() -> [URLRequest] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock { Self.recorded.append(request); return Self.status }
        let code: Int
        let body: Data
        if request.httpMethod == "GET" {
            code = 200
            body = Data("{\"items\":[],\"page\":{\"has_more\":false},\"revision\":\(SettingKey.revision)}".utf8)
        } else if Self.lock.withLock({ Self.rejectExplicitDevice }),
                  URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "device_id" }) == true {
            code = 404; body = Data("{}".utf8)
        } else if status != 200 {
            code = status; body = Data("{}".utf8)
        } else if request.httpMethod == "DELETE" {
            code = 204; body = Data()
        } else {
            code = 200
            let key = request.url!.lastPathComponent
            body = try! JSONSerialization.data(withJSONObject: ["key": key, "scope": "profile_device", "profile_id": Self.lock.withLock { Self.receiptProfile },
                "device_id": AppleDeviceIdentity.current.id, "value": true, "revision": 1])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ForbiddenLegacySettingsTransport: PlayerSettingsTransport, @unchecked Sendable {
    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        XCTFail("Production v2 path used legacy read transport"); throw SettingsMutationHold.uncertain
    }
    func putValue(key: SettingKey, value: SettingJSONValue, mutationId: String, profileId: String?) async throws {
        XCTFail("Production v2 path used legacy write transport"); throw SettingsMutationHold.uncertain
    }
    func deleteValue(key: SettingKey, profileId: String?) async throws {
        XCTFail("Production v2 path used legacy delete transport"); throw SettingsMutationHold.uncertain
    }
}
