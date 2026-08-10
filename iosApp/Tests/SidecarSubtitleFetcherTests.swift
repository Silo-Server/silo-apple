import Foundation
import XCTest
@testable import Silo

final class SidecarSubtitleFetcherTests: XCTestCase {
    override func tearDown() {
        FontBundleURLProtocol.reset()
        super.tearDown()
    }

    func testFontBundleRejectsOversizedDeclaredResponse() async throws {
        FontBundleURLProtocol.configure { request in
            let data = Data("[]".utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": "11"
                ]
            ))
            return (response, data)
        }
        let fetcher = SidecarSubtitleFetcher(
            session: makeSession(),
            fontBundleResponseByteLimit: 10,
            fontBundleCacheByteLimit: 10
        )

        do {
            _ = try await fetcher.fetchFontBundle(url: try XCTUnwrap(URL(string: "https://example.invalid/large")))
            XCTFail("Expected an oversized font bundle to be rejected")
        } catch let error as SidecarSubtitleFetchError {
            guard case .responseTooLarge(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 10)
        }
    }

    func testFontBundleStopsStreamingAtResponseLimitWithoutContentLength() async throws {
        FontBundleURLProtocol.configure { request in
            let data = Data("12345678901".utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, data)
        }
        let fetcher = SidecarSubtitleFetcher(
            session: makeSession(),
            fontBundleResponseByteLimit: 10,
            fontBundleCacheByteLimit: 10
        )

        do {
            _ = try await fetcher.fetchFontBundle(url: try XCTUnwrap(URL(string: "https://example.invalid/streamed")))
            XCTFail("Expected streaming to stop at the font-bundle limit")
        } catch let error as SidecarSubtitleFetchError {
            guard case .responseTooLarge(let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 10)
        }
    }

    func testFontBundleCacheEvictsLeastRecentlyUsedEntryByDecodedBytes() async throws {
        FontBundleURLProtocol.configure { request in
            let payload = #"[{"name":"font.ttf","data":"YWE="}]"#
            let data = Data(payload.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": String(data.count)
                ]
            ))
            return (response, data)
        }
        let fetcher = SidecarSubtitleFetcher(
            session: makeSession(),
            fontBundleResponseByteLimit: 1_024,
            fontBundleCacheByteLimit: 2
        )
        let first = try XCTUnwrap(URL(string: "https://example.invalid/first"))
        let second = try XCTUnwrap(URL(string: "https://example.invalid/second"))

        _ = try await fetcher.fetchFontBundle(url: first)
        _ = try await fetcher.fetchFontBundle(url: second)
        _ = try await fetcher.fetchFontBundle(url: first)

        XCTAssertEqual(FontBundleURLProtocol.requestCount(for: first), 2)
        XCTAssertEqual(FontBundleURLProtocol.requestCount(for: second), 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FontBundleURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

private final class FontBundleURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
        var requestCounts: [URL: Int] = [:]
    }

    private static let state = State()

    static func configure(_ handler: @escaping Handler) {
        state.lock.lock()
        state.handler = handler
        state.requestCounts = [:]
        state.lock.unlock()
    }

    static func reset() {
        state.lock.lock()
        state.handler = nil
        state.requestCounts = [:]
        state.lock.unlock()
    }

    static func requestCount(for url: URL) -> Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requestCounts[url, default: 0]
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: Handler?
        Self.state.lock.lock()
        if let url = request.url {
            Self.state.requestCounts[url, default: 0] += 1
        }
        handler = Self.state.handler
        Self.state.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
