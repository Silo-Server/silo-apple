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
    nonisolated(unsafe) private static var body = Data()
    static func lastBody() -> Data { lock.withLock { body } }
    static func reset() { lock.withLock { pages = []; captured = []; hook = nil; status = 200; body = Data() } }
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
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
