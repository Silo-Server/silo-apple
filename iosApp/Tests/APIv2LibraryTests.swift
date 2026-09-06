import Foundation
import XCTest
@testable import Silo

@MainActor
final class APIv2LibraryTests: XCTestCase {
    private func fixture() async throws -> (APIv2Client, TokenStore) {
        let name = "APIv2LibraryTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: defaults)
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://libraries.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryReadProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens)
        LibraryReadProtocol.reset()
        addTeardownBlock {
            suite.removePersistentDomain(forName: name)
            LibraryReadProtocol.reset()
        }
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private var onboardingStateBody: Data { Data(#"{"tour_id":"tour","last_step":"welcome","done":false}"#.utf8) }
    private var onboardingFlowBody: Data { Data(#"{"version":1,"tour_id":"tour","steps":[]}"#.utf8) }

    func testOnboardingAcknowledgedValidatorAndOldWriterRefusal() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.tag = "\"rev0\""
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        let flow = try await facade.onboardingFlow(surface: "phone")
        let request = OnboardingProgressRequest(tourId: "tour", lastStep: "next", completed: false, skipped: false, writerID: flow.writerID)
        LibraryReadProtocol.tag = "\"rev1\""
        LibraryReadProtocol.enqueue([onboardingStateBody])
        try await facade.postOnboardingProgress(request)
        XCTAssertEqual(LibraryReadProtocol.requests().last?.httpMethod, "PUT")
        XCTAssertEqual(LibraryReadProtocol.requests().last?.value(forHTTPHeaderField: "If-Match"), "\"rev0\"")
        LibraryReadProtocol.enqueue([onboardingStateBody])
        try await facade.postOnboardingProgress(request)
        XCTAssertEqual(LibraryReadProtocol.requests().last?.value(forHTTPHeaderField: "If-Match"), "\"rev1\"")
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        _ = try await facade.onboardingFlow(surface: "phone")
        let count = LibraryReadProtocol.requests().count
        do { try await facade.postOnboardingProgress(request); XCTFail("old writer") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, count)
    }

    func testOnboarding401ConsumesWriterWithoutRefreshOrReplay() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.tag = "\"rev0\""
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        let flow = try await facade.onboardingFlow(surface: "phone")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        let request = OnboardingProgressRequest(tourId: "tour", lastStep: "next", completed: false, skipped: false, writerID: flow.writerID)
        for _ in 0..<2 { do { try await facade.postOnboardingProgress(request); XCTFail("replayed writer") } catch {} }
        XCTAssertEqual(LibraryReadProtocol.requests().filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(LibraryReadProtocol.requests().count, 3)
    }

    func testOnboardingWriterRefusesChangedProfileBeforeDispatch() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.tag = "\"rev0\""
        LibraryReadProtocol.enqueue([onboardingStateBody, onboardingFlowBody])
        let flow = try await facade.onboardingFlow(surface: "phone")
        await tokens.setProfileId("other")
        do { try await facade.postOnboardingProgress(OnboardingProgressRequest(tourId: "tour", lastStep: nil, completed: true, skipped: false, writerID: flow.writerID)); XCTFail("wrong profile") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testSettingsEffectiveReadPreservesRepeatedQueryAndTypedValues() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.enqueue([Data(#"{"revision":999,"items":[{"key":"ui.card_overlays","value":{"camelCase":true},"stored_value":null,"source":"profile","profile_id":"profile","library_id":"42"}],"page":{"has_more":false}}"#.utf8)])
        let result = try await facade.getEffectiveValues(keys: [.uiCardOverlays], libraryIds: [42, 43])
        XCTAssertEqual(result.settings.first?.libraryId, 42)
        XCTAssertEqual(result.settings.first?.value, .object(["camelCase": .bool(true)]))
        XCTAssertEqual(result.settings.first?.storedValue, .null)
        let request = try XCTUnwrap(LibraryReadProtocol.requests().last)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.filter { $0.name == "library_ids" }.compactMap(\.value), ["42", "43"])
        XCTAssertEqual(request.url?.path, "/api/v2/settings/values/effective")
    }

    func testSettingsReadsRejectStaleReplyAndDoNotFallback() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let facade = SiloAPI(tokenStore: tokens, v2: api)
        LibraryReadProtocol.enqueue([Data(#"{"enabled":false,"quick_actions_enabled":false,"quick_actions_default":"off"}"#.utf8)])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await facade.overlayConfig(); XCTFail("stale reply") } catch {}
        LibraryReadProtocol.status = 404
        LibraryReadProtocol.enqueue([Data()])
        do { _ = try await facade.getEffectiveValues(); XCTFail("missing route") }
        catch SettingsAPIError.serverUpgradeRequired { XCTFail("would enable legacy fallback") }
        catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testSubtitleCancellationUsesExactIDAndEmpty204() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        try await SiloAI(v2: api).cancelSubtitleJob(id: "9223372036854775807")
        let request = try XCTUnwrap(LibraryReadProtocol.requests().last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v2/subtitles/ai/jobs/9223372036854775807/cancel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        XCTAssertNil(request.httpBody)
        do { try await api.cancelSubtitleJob(id: "1/cancel"); XCTFail("invalid ID") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testSubtitleCancellationRejectsUnexpectedStatusAndStaleProfile() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 200
        LibraryReadProtocol.enqueue([Data()])
        do { try await api.cancelSubtitleJob(id: "1"); XCTFail("unexpected200") } catch {}
        LibraryReadProtocol.status = 204
        LibraryReadProtocol.enqueue([Data()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { try await api.cancelSubtitleJob(id: "1"); XCTFail("stale profile") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    func testManagedCreation401NeverReplays() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        let body = try DownloadCreateV2Body(CreateDownloadRequest(contentId: "movie", episodeId: nil, fileId: 42,
            quality: "original", series: nil, seasonNumber: nil, caps: nil), existing: nil, batchID: nil)
        do { let _: DownloadCreateV2Page = try await api.requestPost("/api/v2/downloads", body: body); XCTFail("accepted401") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    private func profileBody() throws -> Data {
        try APIv2FixtureTestSupport.data(named: "update_profile_ok", bundleClass: Self.self)
    }

    func testHouseholdListBeforeSelectionAndCreateStringLibraries() async throws {
        let (api, tokens) = try await fixture()
        let row = try profileBody()
        LibraryReadProtocol.enqueue([Data("{\"items\":[\(String(decoding: row, as: UTF8.self))]}".utf8)])
        let profiles = try await api.householdProfiles()
        XCTAssertEqual(profiles.first?.id, "p-owner")
        XCTAssertEqual(LibraryReadProtocol.requests().first?.value(forHTTPHeaderField: "X-Profile-Id") ?? "", "")
        await tokens.setProfileId("manager")
        LibraryReadProtocol.status = 201
        LibraryReadProtocol.enqueue([row])
        _ = try await api.createHouseholdProfile(CreateProfileRequestBody(name: "Reader", avatar: nil, pin: nil,
            isChild: false, maxContentRating: nil, libraryRestrictionsEnabled: true, allowedLibraryIds: [7]))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(body["allowed_library_ids"] as? [String], ["7"])
        XCTAssertNil(body["pin"]); XCTAssertNil(body["avatar"])
        XCTAssertEqual(LibraryReadProtocol.requests().last?.url?.path, "/api/v2/profiles")
    }

    func testHouseholdCreate401IsSingleSend() async throws {
        let (api, _) = try await fixture()
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        do {
            _ = try await api.createHouseholdProfile(CreateProfileRequestBody(name: "Reader", avatar: nil, pin: nil,
                isChild: false, maxContentRating: nil, libraryRestrictionsEnabled: false, allowedLibraryIds: []))
            XCTFail("accepted401")
        } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testHouseholdPINWrongAndStaleProofNeverPersist() async throws {
        let (api, tokens) = try await fixture()
        LibraryReadProtocol.enqueue([Data(#"{"valid":false,"expires_at":null}"#.utf8),
            Data(#"{"valid":true,"profile_token":"proof","expires_at":null}"#.utf8)])
        let wrong = try await api.verifyHouseholdPIN(id: "target", pin: "wrong")
        XCTAssertFalse(wrong.valid)
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("replacement") }
        do { _ = try await api.verifyHouseholdPIN(id: "target", pin: "1234"); XCTFail("stale proof") } catch {}
        let auth = await tokens.captureOrdinaryRequestAuth()
        XCTAssertNil(auth?.profileToken)
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy { $0.url?.path == "/api/v2/profiles/target/verify-pin" })
    }

    private func subtitleRequest() throws -> SubtitleDownloadBody {
        let result = try HTTPClient.makeJSONDecoder().decode(SubtitleSearchResult.self,
            from: Data(#"{"id":"opaque+/=01","provider":"provider","language":"en","format":"untrusted","release_name":"release"}"#.utf8))
        return SubtitleDownloadBody(from: result, mediaFileId: 42)
    }

    private func subtitleReply(file: String = "42") -> Data {
        Data("{\"subtitle\":{\"id\":\"9007199254740993\",\"media_file_id\":\"\(file)\",\"provider\":\"provider\",\"language\":\"en\",\"format\":\"srt\",\"release_name\":\"release\",\"score\":0,\"hearing_impaired\":false,\"created_at\":\"2026-01-01T00:00:00Z\"}}".utf8)
    }

    func testProviderDownloadUsesExactWireAndServerFormat() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.enqueue([subtitleReply()])
        let value = try await api.downloadSubtitle(subtitleRequest())
        XCTAssertEqual(value.id, 9007199254740993)
        XCTAssertEqual(value.format, "srt")
        let request = try XCTUnwrap(LibraryReadProtocol.requests().first)
        XCTAssertEqual(request.url?.path, "/api/v2/subtitles/download")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["subtitle_id"] as? String, "opaque+/=01")
        XCTAssertNil(object["format"])
    }

    func testProviderDownloadRefusesReplacedCallerBeforeDispatch() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let expected = try XCTUnwrap(captured)
        await tokens.setProfileId("replacement")
        do { _ = try await api.downloadSubtitle(subtitleRequest(), expectedAuth: expected); XCTFail("replaced caller") } catch {}
        XCTAssertTrue(LibraryReadProtocol.requests().isEmpty)
    }

    func testSubscriptionCreate401NeverRefreshesOrReplays() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        do {
            let _: ServerSubscription = try await api.requestPost("/api/v2/downloads/subscriptions",
                body: CreateSubscriptionRequest(seriesId: "series", mode: "specific_seasons", seasonNumbers: [0], deleteWatched: false, maxStorageBytes: 0))
            XCTFail("accepted401")
        } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryReadProtocol.lastBody()) as? [String: Any])
        XCTAssertEqual(object["season_numbers"] as? [Int], [0])
    }

    func testProviderDownload401NeverRefreshesOrReplays() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.status = 401
        LibraryReadProtocol.enqueue([Data(#"{"detail":"Rejected"}"#.utf8)])
        do { _ = try await api.downloadSubtitle(subtitleRequest()); XCTFail("accepted401") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 1)
    }

    func testProviderDownloadRejectsStaleProfileAndForeignFile() async throws {
        let (api, tokens) = try await fixture()
        await tokens.setProfileId("profile")
        LibraryReadProtocol.enqueue([subtitleReply(), subtitleReply(file: "43")])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await api.downloadSubtitle(subtitleRequest()); XCTFail("stale profile") } catch {}
        do { _ = try await api.downloadSubtitle(subtitleRequest()); XCTFail("foreign file") } catch {}
        XCTAssertEqual(LibraryReadProtocol.requests().count, 2)
    }

    private func body() throws -> Data {
        try APIv2FixtureTestSupport.data(named: "user_libraries", bundleClass: Self.self)
    }

    func testAccountAndProfileDiscoveryRetainProjection() async throws {
        let (api, tokens) = try await fixture()
        LibraryReadProtocol.enqueue([try body(), try body()])
        let accountRows = try await api.userLibraries()
        let library = try Library(v2: XCTUnwrap(accountRows.first))
        XCTAssertEqual(library.id, 12)
        XCTAssertEqual(library.sortOrder, 2)
        XCTAssertEqual(library.posterUrl, "https://images.example/poster")
        XCTAssertEqual(library.name, "Movies")
        XCTAssertEqual(LibraryReadProtocol.requests().first?.value(forHTTPHeaderField: "X-Profile-Id") ?? "", "")
        await tokens.setProfileId("profile")
        _ = try await api.userLibraries()
        XCTAssertEqual(LibraryReadProtocol.requests().last?.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        XCTAssertTrue(LibraryReadProtocol.requests().allSatisfy {
            $0.url?.path == "/api/v2/user/libraries" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer access"
        })
    }

    func testAuthorityChangeDuringResponseDiscardsLibraries() async throws {
        let (api, tokens) = try await fixture()
        LibraryReadProtocol.enqueue([try body(), try body()])
        LibraryReadProtocol.beforeNextReply { await tokens.setProfileId("other") }
        do { _ = try await api.userLibraries(); XCTFail("published stale profile response") } catch {}
        LibraryReadProtocol.beforeNextReply {
            try? await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "2")
        }
        do { _ = try await api.userLibraries(); XCTFail("published stale account response") } catch {}
    }

    func testLibraryIDsRequireExactSupportedProjection() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        for id in ["9007199254740993", "9223372036854775808", "01", "opaque", "0"] {
            let wire = APIv2UserLibrary(id: id, name: "Library", type: "future", sortOrder: 3, posterUrl: nil)
            if id == "9007199254740993" {
                let value = try Library(v2: wire)
                XCTAssertEqual(value.id, 9007199254740993)
                XCTAssertNil(value.posterUrl)
                XCTAssertTrue(LibrariesResponse(libraries: [value]).libraries.isEmpty)
            } else { XCTAssertThrowsError(try Library(v2: wire)) }
        }
        let numeric = Data(#"{"id":12,"name":"Movies","type":"movies","sort_order":2}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(APIv2UserLibrary.self, from: numeric))
        let empty = try decoder.decode(APIv2CatalogReadCollection<APIv2UserLibrary>.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertTrue(try empty.completeItems().isEmpty)
    }
}

private final class LibraryReadProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [Data] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var hook: (@Sendable () async -> Void)?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var tag: String?
    nonisolated(unsafe) private static var body = Data()
    static func lastBody() -> Data { lock.withLock { body } }
    static func reset() { lock.withLock { pages = []; captured = []; hook = nil; status = 200; tag = nil; body = Data() } }
    static func enqueue(_ values: [Data]) { lock.withLock { pages.append(contentsOf: values) } }
    static func beforeNextReply(_ value: @escaping @Sendable () async -> Void) { lock.withLock { hook = value } }
    static func requests() -> [URLRequest] { lock.withLock { captured } }
    static func cursors() -> [String?] {
        requests().map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data?, (@Sendable () async -> Void)?) in
            Self.captured.append(request)
            if let data = request.httpBody { Self.body = data }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                Self.body = data
            }
            let data = Self.pages.isEmpty ? nil : Self.pages.removeFirst()
            let hook = Self.hook
            Self.hook = nil
            return (data, hook)
        }
        Task {
            await state.1?()
            guard let data = state.0 else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json", "ETag": Self.tag ?? ""])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
