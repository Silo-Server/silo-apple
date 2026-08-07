import XCTest
@testable import Silo

final class ServerIdentityResolverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ServerIdentityStubProtocol.reset()
    }

    func testPrefersNativeBrandingName() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (200, #"{"server_name":"  Home Silo  "}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"StreamApp"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Home Silo")
        XCTAssertEqual(ServerIdentityStubProtocol.requestedPaths(), ["/api/v1/theme/branding"])
    }

    func testFallsBackToHealthForOlderServer() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (404, #"{"error":"not_found"}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"Legacy Home"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Legacy Home")
        XCTAssertEqual(
            ServerIdentityStubProtocol.requestedPaths(),
            ["/api/v1/theme/branding", "/api/v1/health"]
        )
    }

    func testBlankBrandingNameFallsBackToHealth() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (200, #"{"server_name":"  "}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"Fallback"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Fallback")
    }

    private func resolver() -> ServerIdentityResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerIdentityStubProtocol.self]
        return ServerIdentityResolver(
            httpClient: HTTPClient(session: URLSession(configuration: configuration))
        )
    }
}

private final class ServerIdentityStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var paths: [String] = []

    static func configure(_ configuredResponses: [String: (status: Int, body: String)]) {
        lock.withLock {
            responses = configuredResponses
            paths = []
        }
    }

    static func requestedPaths() -> [String] {
        lock.withLock { paths }
    }

    static func reset() {
        lock.withLock {
            responses = [:]
            paths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = Self.lock.withLock {
            Self.paths.append(url.path)
            return Self.responses[url.path] ?? (500, #"{"error":"unexpected"}"#)
        }

        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
