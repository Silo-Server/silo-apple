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
    static func reset() { lock.withLock { pages = []; captured = []; hook = nil } }
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
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
