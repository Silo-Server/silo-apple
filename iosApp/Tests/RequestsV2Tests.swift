import Foundation
import XCTest
@testable import Silo

final class RequestsV2Tests: XCTestCase {
    override func tearDown() {
        APIv2StubProtocol.reset()
        super.tearDown()
    }

    private func client() async throws -> APIv2Client {
        let name = "RequestsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://requests.example")
        await tokens.setProfileId("test-profile")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIv2StubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens)
        return APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
    }

    func testEmptyTerminalCollection() async throws {
        APIv2StubProtocol.configure(["/api/v2/requests/mine": .response(200,
            #"{"items":[],"page":{"has_more":false}}"#, "application/json")])
        let api = try await client()
        let records = try await api.myRequests()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(APIv2StubProtocol.requestedPaths(), ["/api/v2/requests/mine"])
    }

    func testMissingContinuationFailsInsteadOfReturningPartialList() async throws {
        APIv2StubProtocol.configure(["/api/v2/requests/mine": .response(200,
            #"{"items":[],"page":{"has_more":true}}"#, "application/json")])
        let api = try await client()
        do {
            _ = try await api.myRequests()
            XCTFail("Expected incomplete list error")
        } catch APIv2Error.incompleteRequestList { }
        XCTAssertEqual(APIv2StubProtocol.requestedPaths().count, 1)
    }

    func testRepeatedCursorTerminatesWithError() async throws {
        APIv2StubProtocol.configure(["/api/v2/requests/mine": .response(200,
            #"{"items":[],"page":{"has_more":true,"next_cursor":"same"}}"#, "application/json")])
        let api = try await client()
        do {
            _ = try await api.myRequests()
            XCTFail("Expected repeated cursor error")
        } catch APIv2Error.incompleteRequestList { }
        XCTAssertEqual(APIv2StubProtocol.requestedPaths().count, 2)
    }

    func testFailedCreateIsNotReplayed() async throws {
        APIv2StubProtocol.configure(["/api/v2/requests": .response(503,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/dependency_unavailable","title":"Unavailable","status":503,"detail":"Try later","instance":"urn:test"}"#,
            "application/problem+json")])
        let api = try await client()
        do {
            let _: MediaRequest = try await api.requestPost("/api/v2/requests", body: ["title": "Film"])
            XCTFail("Expected dependency error")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 503)
        }
        XCTAssertEqual(APIv2StubProtocol.requestedPaths(), ["/api/v2/requests"])
    }
}
