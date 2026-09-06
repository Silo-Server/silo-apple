import Foundation
import XCTest
@testable import Silo

@MainActor
final class DiagnosticsIngressV2Tests: XCTestCase {
    private func fixture() async throws -> (DiagnosticsAPI, TokenStore) {
        let name = "DiagnosticsIngressV2Tests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://diagnostics.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("active-profile")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsIngressProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        DiagnosticsIngressProtocol.reset()
        addTeardownBlock { suite.removePersistentDomain(forName: name); DiagnosticsIngressProtocol.reset() }
        return (DiagnosticsAPI(http: http, tokens: tokens), tokens)
    }

    func testMultipartUsesCapturedProfileAndDoesNotReplay401() async throws {
        let (api, _) = try await fixture()
        DiagnosticsIngressProtocol.status = 401
        DiagnosticsIngressProtocol.enqueue([Data(#"{"type":"urn:silo:problem:authentication_required","title":"Authentication required","status":401}"#.utf8)])
        do {
            _ = try await api.upload(manifestData: Data("manifest-content".utf8), bundleData: Data("bundle-content".utf8), capturedProfileID: "captured-profile")
            XCTFail("accepted401")
        } catch {}
        let requests = DiagnosticsIngressProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v2/diagnostics/reports")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "captured-profile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        let text = try XCTUnwrap(String(data: DiagnosticsIngressProtocol.bodies().first ?? Data(), encoding: .utf8))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("Content-Type: application/gzip"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "manifest-content")).lowerBound,
                          try XCTUnwrap(text.range(of: "bundle-content")).lowerBound)
    }

    func testAccountOnlyCapabilityAdvertisesNoChunkFallback() async throws {
        let (api, _) = try await fixture()
        DiagnosticsIngressProtocol.status = 200
        DiagnosticsIngressProtocol.enqueue([Data(#"{"revision":"1","state":"available","status":"available","server_instance_id":"instance","accepted_schema_versions":[1],"max_bundle_bytes":1024,"max_manifest_bytes":65536,"retention_days":7,"consent_notice_version":1,"upload_chunk_bytes":0}"#.utf8)])
        let result = try await api.getDiagnosticsStatus()
        XCTAssertFalse(result.supportsChunkedUpload)
        let request = try XCTUnwrap(DiagnosticsIngressProtocol.requests().first)
        XCTAssertEqual(request.url?.path, "/api/v2/diagnostics/capabilities")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id") ?? "", "")
    }

    func testAccountChangeCannotPublishReceiptOrDispatchWithOldExpectedAccount() async throws {
        let (api, tokens) = try await fixture()
        let snapshot = await tokens.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(snapshot)
        DiagnosticsIngressProtocol.enqueue([Data(#"{"report_id":"report","short_id":"SILO-TEST"}"#.utf8)])
        DiagnosticsIngressProtocol.beforeNextReply {
            try? await tokens.installAccountSession(accessToken: "replacement", refreshToken: "replacement", accountID: "2")
        }
        do { _ = try await api.upload(manifestData: Data(), bundleData: Data(), expectedAccount: captured.account); XCTFail("stale receipt") } catch {}
        do { _ = try await api.upload(manifestData: Data(), bundleData: Data(), expectedAccount: captured.account); XCTFail("stale dispatch") } catch {}
        XCTAssertEqual(DiagnosticsIngressProtocol.requests().count, 1)
    }
}

private final class DiagnosticsIngressProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [Data] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data] = []
    nonisolated(unsafe) private static var hook: (@Sendable () async -> Void)?
    nonisolated(unsafe) static var status = 201
    static func reset() { lock.withLock { pages = []; captured = []; capturedBodies = []; hook = nil; status = 201 } }
    static func enqueue(_ values: [Data]) { lock.withLock { pages.append(contentsOf: values) } }
    static func beforeNextReply(_ value: @escaping @Sendable () async -> Void) { lock.withLock { hook = value } }
    static func requests() -> [URLRequest] { lock.withLock { captured } }
    static func bodies() -> [Data] { lock.withLock { capturedBodies } }
    static func cursors() -> [String?] {
        requests().map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let state = Self.lock.withLock { () -> (Data?, (@Sendable () async -> Void)?) in
            Self.captured.append(request)
            Self.capturedBodies.append(body)
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
