import Foundation
import XCTest
@testable import Silo

/// App Transport Security lets the app reach a plain-HTTP server a person
/// picks, so the API session itself has to stop a request that went out over
/// HTTPS from being redirected onto plain HTTP with its body and headers.
final class InsecureRedirectTests: XCTestCase {
    /// Never a real server, so no other test's requests can match it.
    private let secure = URL(string: "https://insecure-redirect-tests.example/api/v2/auth/refresh")!
    private let secureElsewhere = URL(string: "https://insecure-redirect-tests.example/v2/auth/refresh")!
    private let plain = URL(string: "http://insecure-redirect-tests.example/api/v2/auth/refresh")!
    private let plainElsewhere = URL(string: "http://insecure-redirect-tests.example/v2/auth/refresh")!

    private func apiSession(_ stub: StubURLProtocol.Handler) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        stub.install(into: configuration)
        return URLSession(configuration: configuration, delegate: LocalRouteTrustDelegate.shared, delegateQueue: nil)
    }

    private func postRefreshToken(to url: URL, on session: URLSession) async {
        // The stub never finishes a redirect the session refuses, so a short
        // timeout ends that request instead of the 60 s default.
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"refresh_token":"secret"}"#.utf8)
        _ = try? await session.data(for: request)
    }

    func testARedirectFromHTTPSToHTTPIsNotFollowed() async {
        let stub = StubURLProtocol.Handler()
        stub.route({ $0.url == self.plain }) { _ in .status(200) }
        stub.route(StubURLProtocol.any) { _ in .init(status: 307, redirect: self.plain) }
        let session = apiSession(stub)
        defer { session.invalidateAndCancel() }

        await postRefreshToken(to: secure, on: session)

        XCTAssertEqual(stub.requests.map(\.url), [secure])
    }

    func testARedirectThatStaysOnHTTPSIsFollowed() async {
        let stub = StubURLProtocol.Handler()
        stub.route({ $0.url == self.secureElsewhere }) { _ in .status(200) }
        stub.route(StubURLProtocol.any) { _ in .init(status: 307, redirect: self.secureElsewhere) }
        let session = apiSession(stub)
        defer { session.invalidateAndCancel() }

        await postRefreshToken(to: secure, on: session)

        XCTAssertEqual(stub.requests.map(\.url), [secure, secureElsewhere])
    }

    /// A server the person chose over plain HTTP was never encrypted, so a
    /// redirect within HTTP changes nothing.
    func testAPlainHTTPServerCanRedirectWithinHTTP() async {
        let stub = StubURLProtocol.Handler()
        stub.route({ $0.url == self.plainElsewhere }) { _ in .status(200) }
        stub.route(StubURLProtocol.any) { _ in .init(status: 307, redirect: self.plainElsewhere) }
        let session = apiSession(stub)
        defer { session.invalidateAndCancel() }

        await postRefreshToken(to: plain, on: session)

        XCTAssertEqual(stub.requests.map(\.url), [plain, plainElsewhere])
    }
}
