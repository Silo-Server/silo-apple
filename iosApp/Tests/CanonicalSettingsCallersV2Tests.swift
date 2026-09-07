import Foundation
import XCTest
@testable import Silo

@MainActor
final class CanonicalSettingsCallersV2Tests: XCTestCase {
    private struct Harness {
        let api: SiloAPI
        let tokens: TokenStore
        let journal: SettingsMutationJournal
        let url: URL
        let defaults: UserDefaults
    }

    private func harness() async throws -> Harness {
        let name = "CanonicalSettingsCallersV2Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://settings.example")
        try await tokens.installAccountSession(accessToken: "test-access", refreshToken: "test-refresh", accountID: "account")
        await tokens.setProfileId("profile")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanonicalSettingsCallerProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens,
            v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathComponent("journal.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            defaults.removePersistentDomain(forName: name)
        }
        CanonicalSettingsCallerProtocol.reset()
        return Harness(api: api, tokens: tokens, journal: SettingsMutationJournal(url: url), url: url, defaults: defaults)
    }

    func testPlayerAndOnboardingShareSymmetricUncertaintyBarrier() async throws {
        let h = try await harness()
        let queue = PlayerSettingsV2Queue(api: h.api, tokens: h.tokens, defaults: h.defaults, journal: h.journal)
        _ = try await queue.read(keys: [.playbackAutoSkipIntro, .playbackAutoSkipCredits])
        let canonical = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal, defaults: h.defaults)
        let owner = try await canonical.capture()
        CanonicalSettingsCallerProtocol.setStatus(503)
        do { try await canonical.write(key: .playbackAutoSkipIntro, value: .bool(true), scope: .profileDevice, owner: owner); XCTFail() } catch {}
        queue.enqueue(.playbackAutoSkipIntro, operation: .set(.bool(false)))
        await queue.flush()
        XCTAssertEqual(CanonicalSettingsCallerProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
        queue.enqueue(.playbackAutoSkipCredits, operation: .set(.bool(true)))
        await queue.flush()
        do { try await canonical.write(key: .playbackAutoSkipCredits, value: .bool(false), scope: .profileDevice, owner: owner); XCTFail() } catch {}
        XCTAssertEqual(CanonicalSettingsCallerProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 2)
        XCTAssertEqual(try h.journal.snapshot().filter { $0.state == .uncertain }.count, 2)
    }

    func testSharedPreparedIntentUsesItsExistingReceiptWithoutSecondHTTP() async throws {
        let h = try await harness()
        let queue = PlayerSettingsV2Queue(api: h.api, tokens: h.tokens, defaults: h.defaults, journal: h.journal)
        _ = try await queue.read(keys: [.playbackAutoSkipIntro])
        let canonical = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal)
        let owner = try await canonical.capture()
        let id = try await canonical.prepare(key: .playbackAutoSkipIntro, value: .bool(true), scope: .profileDevice, owner: owner)
        await queue.flush()
        try await canonical.send(id, owner: owner)
        XCTAssertEqual(try h.journal.snapshot().first?.state, .applied)
        XCTAssertEqual(CanonicalSettingsCallerProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testConcurrentCanonicalPreparationRetainsEveryOriginalIntent() async throws {
        let h = try await harness()
        let first = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal)
        let second = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal)
        let owner = try await first.capture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await (index.isMultiple(of: 2) ? first : second).prepare(
                        key: .playbackSubtitleLanguage, value: .string("value-\(index)"), owner: owner)
                }
            }
            try await group.waitForAll()
        }
        let commands = try h.journal.snapshot()
        XCTAssertEqual(commands.count, 20)
        XCTAssertEqual(Set(commands.map(\.id)).count, 20)
        XCTAssertEqual(Set(commands.compactMap(\.body)).count, 20)
        XCTAssertTrue(commands.allSatisfy { $0.state == .prepared })
        XCTAssertTrue(CanonicalSettingsCallerProtocol.requests().isEmpty)
    }

    func testOnboardingDoesNotConvertOrBypassLegacyDeviceIntent() async throws {
        let h = try await harness()
        let canonical = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal, defaults: h.defaults)
        let owner = try await canonical.capture()
        let authority = try SettingsMutationAuthority(owner)
        let name = "player.pendingDeviceSettingWrites." + authority.legacyPlayerScope
        let bytes = Data(#"{ "playback.auto_skip_intro" : { "legacy" : true } }"#.utf8)
        h.defaults.set(bytes, forKey: name)
        do { try await canonical.write(key: .playbackAutoSkipIntro, value: .bool(false), scope: .profileDevice, owner: owner); XCTFail() } catch {}
        XCTAssertEqual(h.defaults.data(forKey: name), bytes)
        XCTAssertEqual(try h.journal.snapshot().first?.state, .legacyHeld)
        XCTAssertTrue(CanonicalSettingsCallerProtocol.requests().isEmpty)
    }

    func testOwnerSwitchDuringPlayerRefreshCannotProjectOrDispatchWrites() async throws {
        let h = try await harness()
        let canonical = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal)
        let owner = try await canonical.capture()
        let player = PlayerSettings(defaults: h.defaults)
        player.autoSkipIntro = true
        CanonicalSettingsCallerProtocol.beforeReadResponse {
            let completed = DispatchSemaphore(value: 0)
            Task { await h.tokens.setProfileId("other"); completed.signal() }
            XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        }
        do { try await player.refreshFromServer(owner: owner, api: h.api, tokens: h.tokens, journal: h.journal); XCTFail() } catch {}
        XCTAssertTrue(player.autoSkipIntro)
        XCTAssertEqual(CanonicalSettingsCallerProtocol.requests().count, 1)
        XCTAssertTrue(CanonicalSettingsCallerProtocol.requests().allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(try h.journal.snapshot().isEmpty)
    }

    func testProfileProductionWriterPersistsExactCanonicalNullWithoutRevisionHeaders() async throws {
        let h = try await harness()
        let transport = SiloProfileSettingsTransport(api: h.api, tokens: h.tokens, journal: h.journal)
        _ = try await transport.effectiveValues(keys: [.playbackSubtitleLanguage])
        try await transport.putValue(key: .playbackSubtitleLanguage, value: .null,
            mutationId: UUID().uuidString, profileId: "profile")
        let saved = try XCTUnwrap(h.journal.snapshot().first)
        XCTAssertEqual(saved.body, Data(#"{"value":null}"#.utf8))
        XCTAssertEqual(saved.query, ["scope": "profile"])
        XCTAssertEqual(saved.state, .applied)
        let request = try XCTUnwrap(CanonicalSettingsCallerProtocol.requests().first { $0.httpMethod == "PUT" })
        XCTAssertEqual(request.url?.path, "/api/v2/settings/values/playback.subtitle_language")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Silo-Mutation-Id"))
    }

    func testProfileSwitchCannotAdoptLoadedEditor() async throws {
        let h = try await harness()
        let transport = SiloProfileSettingsTransport(api: h.api, tokens: h.tokens, journal: h.journal)
        _ = try await transport.effectiveValues(keys: [.playbackSubtitleMode])
        await h.tokens.setProfileId("other")
        do { try await transport.putValue(key: .playbackSubtitleMode, value: .string("auto"), mutationId: UUID().uuidString, profileId: nil); XCTFail() } catch {}
        XCTAssertTrue(try h.journal.snapshot().isEmpty)
        XCTAssertFalse(CanonicalSettingsCallerProtocol.requests().contains { $0.httpMethod == "PUT" })
    }

    func testPersistenceFailurePreventsDispatch() async throws {
        let h = try await harness()
        let broken = SettingsMutationJournal(url: h.url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let transport = SiloProfileSettingsTransport(api: h.api, tokens: h.tokens, journal: broken)
        _ = try await transport.effectiveValues(keys: [.playbackSubtitleMode])
        do { try await transport.putValue(key: .playbackSubtitleMode, value: .string("auto"), mutationId: UUID().uuidString, profileId: "profile"); XCTFail() } catch {}
        XCTAssertFalse(CanonicalSettingsCallerProtocol.requests().contains { $0.httpMethod == "PUT" })
    }

    func testRestartRetainsUncertaintyBytesAndBlocksDeleteWithoutFallback() async throws {
        let h = try await harness()
        let writer = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal)
        let owner = try await writer.capture()
        CanonicalSettingsCallerProtocol.setStatus(401)
        do { try await writer.write(key: .uiCardOverlays, value: .null, owner: owner); XCTFail() } catch {}
        let original = try XCTUnwrap(h.journal.snapshot().first)
        let restarted = CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: SettingsMutationJournal(url: h.url))
        CanonicalSettingsCallerProtocol.setStatus(200)
        do { try await restarted.write(key: .uiCardOverlays, value: nil, owner: owner); XCTFail() } catch {}
        XCTAssertEqual(try h.journal.snapshot().first, original)
        XCTAssertEqual(original.state, .uncertain)
        let writes = CanonicalSettingsCallerProtocol.requests().filter { $0.httpMethod != "GET" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(writes.contains { $0.url!.path.contains("/api/v1/") || $0.url!.path.contains("/auth/refresh") })
    }

    func testOverlayResetUsesCanonicalDeleteAndMissingV2DoesNotUseLegacy() async throws {
        let h = try await harness()
        let store = OverlayPrefsStore(api: h.api, tokens: h.tokens, journal: h.journal)
        await store.refresh()
        XCTAssertNil(store.lastError)
        await store.setPrefs(OverlaySchema.buildDefaults())
        XCTAssertTrue(store.hasUserOverride)
        await store.resetToDefaults()
        XCTAssertFalse(store.hasUserOverride)
        XCTAssertEqual(try h.journal.snapshot().map(\.method), ["PUT", "DELETE"])
        CanonicalSettingsCallerProtocol.setStatus(404)
        await store.setPrefs(OverlaySchema.buildDefaults())
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(CanonicalSettingsCallerProtocol.requests().contains { $0.url!.path.contains("/api/v1/") })
    }

    func testOverlayReceiptCannotProjectIntoChangedProfile() async throws {
        let h = try await harness()
        let store = OverlayPrefsStore(api: h.api, tokens: h.tokens, journal: h.journal)
        await store.refresh()
        CanonicalSettingsCallerProtocol.beforeMutationResponse {
            let completed = DispatchSemaphore(value: 0)
            Task { await h.tokens.setProfileId("other"); completed.signal() }
            XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        }
        await store.setPrefs(OverlaySchema.buildDefaults())
        XCTAssertFalse(store.hasUserOverride)
        XCTAssertEqual(try h.journal.snapshot().first?.state, .uncertain)
    }

    func testOnboardingDeviceSettingUsesCapturedDeviceHeaderAndCanonicalBoolean() async throws {
        let h = try await harness()
        let adapter = OnboardingSettingsV2Transport(api: h.api, tokens: h.tokens, journal: h.journal)
        _ = try await adapter.onboardingFlow(surface: "phone")
        try await adapter.setDeviceSetting(key: "playback.auto_play_next", value: "true")
        let saved = try XCTUnwrap(h.journal.snapshot().first)
        XCTAssertEqual(saved.query, ["scope": "profile_device"])
        XCTAssertEqual(saved.body, Data(#"{"value":true}"#.utf8))
        let request = try XCTUnwrap(CanonicalSettingsCallerProtocol.requests().first { $0.httpMethod == "PUT" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Silo-Device-Id"), saved.authority.deviceID)
        await h.tokens.setProfileId("other")
        do { try await adapter.setSetting(key: "playback.auto_play_next", value: "false"); XCTFail() } catch {}
        XCTAssertEqual(try h.journal.snapshot().count, 1)
    }

    func testOnboardingRejectsLegacySettingAliasWithoutConversion() async throws {
        let h = try await harness()
        let adapter = OnboardingSettingsV2Transport(api: h.api, tokens: h.tokens, journal: h.journal)
        _ = try await adapter.onboardingFlow(surface: "phone")
        do { try await adapter.setDeviceSetting(key: "playback.quality", value: "1080p"); XCTFail() } catch {}
        XCTAssertTrue(try h.journal.snapshot().isEmpty)
    }

    func testOnboardingProfileUncertaintyPersistsExactPatchAndDoesNotReplay() async throws {
        let h = try await harness()
        let adapter = OnboardingSettingsV2Transport(api: h.api, tokens: h.tokens, profileJournal: h.journal)
        _ = try await adapter.onboardingFlow(surface: "phone")
        CanonicalSettingsCallerProtocol.setStatus(503)
        var body = UpdateProfileBody(); body.autoSkipIntro = true
        do { try await adapter.updateProfile(profileId: "profile", body: body); XCTFail() } catch {}
        let original = try XCTUnwrap(h.journal.snapshot().first)
        XCTAssertEqual(original.body, Data(#"{"auto_skip_intro":true}"#.utf8))
        XCTAssertEqual(original.state, .uncertain)
        do { try await adapter.updateProfile(profileId: "profile", body: body); XCTFail() } catch {}
        XCTAssertEqual(try h.journal.snapshot().first, original)
        XCTAssertEqual(CanonicalSettingsCallerProtocol.requests().filter { $0.httpMethod == "PATCH" }.count, 1)
    }

    func testProfileReceiptIdentityAndCapturedOwnerAreBothRequired() async throws {
        let h = try await harness()
        let auth = try await CanonicalProfileSettingsV2(api: h.api, tokens: h.tokens, journal: h.journal).capture()
        let fixture = try APIv2FixtureTestSupport.data(named: "update_profile_ok", bundleClass: Self.self)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        CanonicalSettingsCallerProtocol.setPatchReply(fixture)
        do { _ = try await h.api.v2.updateProfile(id: "profile", patch: APIv2ProfilePatch(), auth: auth.request); XCTFail("Foreign receipt") } catch {}
        object["id"] = "profile"
        CanonicalSettingsCallerProtocol.setPatchReply(try JSONSerialization.data(withJSONObject: object))
        let profile = try await h.api.v2.updateProfile(id: "profile", patch: APIv2ProfilePatch(), auth: auth.request)
        XCTAssertEqual(profile.id, "profile")
        CanonicalSettingsCallerProtocol.beforeMutationResponse {
            let completed = DispatchSemaphore(value: 0)
            Task { await h.tokens.setProfileId("other"); completed.signal() }
            XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        }
        do { _ = try await h.api.v2.updateProfile(id: "profile", patch: APIv2ProfilePatch(), auth: auth.request); XCTFail("Stale receipt") } catch {}
        XCTAssertEqual(CanonicalSettingsCallerProtocol.requests().filter { $0.httpMethod == "PATCH" }.count, 3)
    }

    func testCapturedProfileOverloadRejectsForeignTargetBeforeHTTP() async throws {
        let h = try await harness()
        let auth = await h.tokens.captureOrdinaryRequestAuth()
        do { _ = try await h.api.v2.updateProfile(id: "foreign", patch: APIv2ProfilePatch(), auth: XCTUnwrap(auth)); XCTFail() } catch {}
        XCTAssertTrue(CanonicalSettingsCallerProtocol.requests().isEmpty)
    }
}

private final class CanonicalSettingsCallerProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var status = 200
    private static var patchReply: Data?
    private static var beforeResponse: (@Sendable () -> Void)?
    private static var readResponse: (@Sendable () -> Void)?
    static func beforeReadResponse(_ action: @escaping @Sendable () -> Void) { lock.withLock { readResponse = action } }
    static func setPatchReply(_ data: Data) { lock.withLock { patchReply = data } }
    static func beforeMutationResponse(_ action: @escaping @Sendable () -> Void) { lock.withLock { beforeResponse = action } }
    static func reset() { lock.withLock { recorded = []; status = 200; patchReply = nil; beforeResponse = nil; readResponse = nil } }
    static func setStatus(_ code: Int) { lock.withLock { status = code } }
    static func requests() -> [URLRequest] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock { Self.recorded.append(request); return Self.status }
        let path = request.url!.path
        let code: Int
        let body: Data
        if request.httpMethod == "GET" {
            code = 200
            if path.hasSuffix("/onboarding/flow") {
                body = Data(#"{"version":1,"tour_id":"tour","steps":[]}"#.utf8)
            } else if path.hasSuffix("/onboarding/state") {
                body = Data(#"{"tour_id":"tour","done":false}"#.utf8)
            } else if path.hasSuffix("/overlay-config") {
                body = Data(#"{"enabled":true,"defaults":null}"#.utf8)
            } else {
                body = Data("{\"items\":[],\"page\":{\"has_more\":false},\"revision\":\(SettingKey.revision)}".utf8)
            }
        } else if status != 200 { code = status; body = Data("{}".utf8) }
        else if request.httpMethod == "PATCH", let reply = Self.lock.withLock({ Self.patchReply }) { code = 200; body = reply }
        else if request.httpMethod == "DELETE" { code = 204; body = Data() }
        else {
            code = 200
            let scope = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value ?? "profile"
            body = try! JSONSerialization.data(withJSONObject: ["key": request.url!.lastPathComponent,
                "scope": scope, "profile_id": "profile", "device_id": AppleDeviceIdentity.current.id,
                "value": true, "revision": 1])
        }
        if request.httpMethod != "GET" { Self.lock.withLock { Self.beforeResponse }?() }
        else { Self.lock.withLock { Self.readResponse }?() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "ETag": "\"rev0\""])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
