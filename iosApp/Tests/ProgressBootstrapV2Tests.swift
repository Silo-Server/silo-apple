import Foundation
import XCTest
@testable import Silo

/// Wire-only tests: no persistent replacement, upload acknowledgement or queue activation.
final class ProgressBootstrapV2Tests: XCTestCase {
    private let snapshotID = "11111111-1111-4111-8111-111111111111"
    private var location: String { "/api/v2/sync/progress/snapshots/\(snapshotID)" }
    private func client(blocked: Bool = false) async throws -> (APIv2Client, TokenStore, HTTPClient) {
        let name = "ProgressBootstrapV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name); BootstrapProtocol.reset() }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://bootstrap.example")
        await tokens.setProfileId("profile-one")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BootstrapProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { blocked }), tokens, http)
    }
    private func page(items: [String] = [], total: Int = 0, next: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["snapshot_id": snapshotID, "installation_id": "installation", "account_id": "12",
            "profile_id": "profile-one", "generation": "generation", "mode": "full_replace",
            "captured_at": "2026-09-05T12:00:00.000Z", "expires_at": "2026-09-05T13:00:00.000Z",
            "item_count": total, "complete": next == nil,
            "items": items.map { ["media_item_id": $0, "position_seconds": 0, "duration_seconds": 0,
                                  "completed": false, "updated_at": "2026-09-05T11:00:00.000Z"] as [String: Any] },
            "page": ["has_more": next != nil] as [String: Any]]
        if let next { value["page"] = ["has_more": true, "next_cursor": next] }
        else { value["completion_token"] = "opaque-receipt" }
        return value
    }
    private func respond(_ value: [String: Any], status: Int = 201, path: String? = nil) throws {
        BootstrapProtocol.reply(status, try JSONSerialization.data(withJSONObject: value), headers: ["Location": path ?? location])
    }
    func testCapabilityStates() async throws {
        let (api, _, _) = try await client()
        for state in ["unsupported", "not_configured", "available"] {
            try respond(["revision": "1", "state": state, "allowed": state == "available", "mode": "full_replace",
                "incremental": false, "installation_id": "installation", "generation": "generation", "max_page_size": 200,
                "max_snapshot_items": 100000, "max_snapshot_bytes": 10000000, "snapshot_ttl_seconds": 3600,
                "max_active_snapshots_per_account": 2], status: 200)
            let value = try await api.progressBootstrapCapabilities()
            XCTAssertEqual(value.supportsFullReplacement, state == "available")
            XCTAssertEqual(BootstrapProtocol.requests().last?.0.url?.path, "/api/v2/sync/progress/capabilities")
        }
    }
    func testLostReplyReplaysSameUUIDBodyAndEmptyReceipt() async throws {
        let (api, _, _) = try await client()
        let id = UUID()
        let intent = try await api.makeProgressSnapshotIntent(requestId: id, limit: 7)
        BootstrapProtocol.fail()
        do { _ = try await api.createProgressSnapshot(intent); XCTFail() } catch {}
        XCTAssertEqual(BootstrapProtocol.requests().count, 1)
        try respond(page())
        let result = try await api.createProgressSnapshot(intent)
        let requests = BootstrapProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].1, requests[1].1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].1)) as? [String: Any])
        XCTAssertEqual(body["request_id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(body["limit"] as? Int, 7)
        XCTAssertEqual(result.location, location)
        XCTAssertNil(result.continuation)
        XCTAssertEqual(result.receipt?.token, "opaque-receipt")
    }
    func testContinuationPreservesFalseZeroAndDispatchGrammar() async throws {
        let (api, _, _) = try await client()
        let intent = try await api.makeProgressSnapshotIntent(requestId: UUID(), limit: 1)
        try respond(page(items: ["first"], total: 2, next: "opaque/+cursor"))
        let first = try await api.createProgressSnapshot(intent)
        XCTAssertFalse(first.value.items[0].completed)
        XCTAssertEqual(first.value.items[0].positionSeconds, 0)
        XCTAssertEqual(first.value.items[0].durationSeconds, 0)
        XCTAssertNil(first.receipt)
        try respond(page(items: ["second"], total: 2), status: 200)
        let last = try await api.progressSnapshotPage(XCTUnwrap(first.continuation))
        XCTAssertNotNil(last.receipt)
        XCTAssertNil(last.continuation)
        let request = try XCTUnwrap(BootstrapProtocol.requests().last?.0)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, location)
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "cursor", value: "opaque/+cursor")])
    }
    func testMalformedTerminalAndRequiredFields() async throws {
        let (api, _, _) = try await client()
        let intent = try await api.makeProgressSnapshotIntent(requestId: UUID())
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["completion_token"] = nil }, { $0["page"] = ["has_more": true, "next_cursor": "wrong"] },
            { $0["item_count"] = 1 }, { $0["account_id"] = 12 }, { $0["captured_at"] = nil }, { $0["profile_id"] = "other" }]
        for edit in edits {
            var value = page(); edit(&value); try respond(value)
            do { _ = try await api.createProgressSnapshot(intent); XCTFail("Malformed snapshot accepted") } catch {}
        }
        try respond(page(), path: "https://foreign.example" + location)
        do { _ = try await api.createProgressSnapshot(intent); XCTFail("Foreign Location accepted") } catch {}
    }
    func testRepeatedCursorDuplicateItemsAndMetadataChange() async throws {
        let (api, _, _) = try await client()
        let intent = try await api.makeProgressSnapshotIntent(requestId: UUID(), limit: 1)
        try respond(page(items: ["one"], total: 3, next: "next"))
        let first = try await api.createProgressSnapshot(intent)
        var changed = page(items: ["two"], total: 3, next: "third"); changed["generation"] = "changed"
        for value in [page(items: ["two"], total: 3, next: "next"), page(items: ["one"], total: 3, next: "third"), changed] {
            try respond(value, status: 200)
            do { _ = try await api.progressSnapshotPage(XCTUnwrap(first.continuation)); XCTFail() } catch {}
        }
    }
    func testProblemsPreserveHeadersAndDoNotReplay() async throws {
        let (api, _, _) = try await client()
        let intent = try await api.makeProgressSnapshotIntent(requestId: UUID())
        for status in [401, 403, 409, 413, 429] {
            let data = try JSONSerialization.data(withJSONObject: ["type": "https://siloserver.org/docs/api/v2/problems/rate_limited",
                "title": "Stopped", "status": status, "detail": "Review intent"])
            BootstrapProtocol.reply(status, data, headers: ["Retry-After": "30"])
            do { _ = try await api.createProgressSnapshot(intent); XCTFail() }
            catch APIv2ProgressBootstrapError.response(let actual, let problem, let retryAfter) {
                XCTAssertEqual(actual, status); XCTAssertEqual(problem?.detail, "Review intent"); XCTAssertEqual(retryAfter, "30")
            }
        }
        XCTAssertEqual(BootstrapProtocol.requests().count, 5)
    }
    func testOptInRetainsDefaultTransportErrors() async throws {
        let (_, tokens, http) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: "profile-one", clientFamily: AppleDeviceIdentity.current.clientFamily)
        BootstrapProtocol.reply(429, Data("{}".utf8), headers: ["Retry-After": "30"])
        do { _ = try await http.requestData(method: "GET", path: "/api/v2/progress", requestIdentity: identity); XCTFail() }
        catch HTTPError.http(let status, _) { XCTAssertEqual(status, 429) }
        let result = try await http.requestData(method: "GET", path: "/api/v2/progress", requestIdentity: identity, acceptedStatuses: [429])
        XCTAssertEqual(result.statusCode, 429); XCTAssertEqual(result.header("Retry-After"), "30")
    }
    func testInFlightIdentitySwitchAndCancellationDoNotReturnSnapshot() async throws {
        for cancel in [false, true] {
            BootstrapProtocol.reset()
            let (api, tokens, _) = try await client()
            let intent = try await api.makeProgressSnapshotIntent(requestId: UUID())
            try respond(page())
            let dispatched = expectation(description: "Snapshot request held")
            BootstrapProtocol.hold { dispatched.fulfill() }
            let request = Task { try await api.createProgressSnapshot(intent) }
            await fulfillment(of: [dispatched], timeout: 5)
            if cancel { request.cancel() } else { await tokens.setProfileId("different") }
            BootstrapProtocol.release()
            do { _ = try await request.value; XCTFail("Stale/canceled request returned a snapshot") } catch {}
            XCTAssertEqual(BootstrapProtocol.requests().count, 1)
        }
    }

    func testMissingCursorReceiptConflictAndMissingProgressFields() async throws {
        let (api, _, _) = try await client()
        let intent = try await api.makeProgressSnapshotIntent(requestId: UUID(), limit: 1)
        var missingCursor = page(items: ["one"], total: 2, next: "next")
        missingCursor["page"] = ["has_more": true]
        var receiptConflict = page(items: ["one"], total: 2, next: "next")
        receiptConflict["completion_token"] = "not-a-cursor"
        var invalidValues = [missingCursor, receiptConflict]
        for field in ["updated_at", "completed", "duration_seconds"] {
            var value = page(items: ["one"], total: 1)
            var items = value["items"] as! [[String: Any]]
            items[0][field] = nil
            value["items"] = items
            invalidValues.append(value)
        }
        for value in invalidValues {
            try respond(value)
            do { _ = try await api.createProgressSnapshot(intent); XCTFail("Invalid fields accepted") } catch {}
        }
    }

    func testIdentityAndGateBeforeDispatch() async throws {
        let (api, tokens, _) = try await client()
        let intent = try await api.makeProgressSnapshotIntent(requestId: UUID())
        await tokens.setProfileId("different")
        do { _ = try await api.createProgressSnapshot(intent); XCTFail() } catch HTTPError.requestIdentityChanged {}
        XCTAssertTrue(BootstrapProtocol.requests().isEmpty)
        let (blocked, _, _) = try await client(blocked: true)
        do { _ = try await blocked.progressBootstrapCapabilities(); XCTFail() } catch APIv2Error.serverUpdateRequired {}
        XCTAssertTrue(BootstrapProtocol.requests().isEmpty)
    }
}

private final class BootstrapProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (200, Data(), [String: String]())
    nonisolated(unsafe) private static var failure = false
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data?)] = []
    nonisolated(unsafe) private static var onHeldRequest: (() -> Void)?
    nonisolated(unsafe) private static var pending: (() -> Void)?
    static func hold(_ notify: @escaping () -> Void) { lock.withLock { onHeldRequest = notify } }
    static func release() {
        let deliver = lock.withLock { let value = pending; pending = nil; onHeldRequest = nil; return value }
        deliver?()
    }
    static func reset() { lock.withLock { response = (200, Data(), [:]); failure = false; recorded = []; onHeldRequest = nil; pending = nil } }
    static func reply(_ status: Int, _ body: Data, headers: [String: String] = [:]) { lock.withLock { response = (status, body, headers); failure = false } }
    static func fail() { lock.withLock { failure = true } }
    static func requests() -> [(URLRequest, Data?)] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let (reply, failed) = Self.lock.withLock { Self.recorded.append((request, data)); return (Self.response, Self.failure) }
        if failed { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let deliver: () -> Void = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: reply.2)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.1)
            client?.urlProtocolDidFinishLoading(self)
        }
        let notify: (() -> Void)? = Self.lock.withLock {
            if let notify = Self.onHeldRequest { Self.pending = deliver; return notify }
            return nil
        }
        if let notify { notify() } else { deliver() }
    }
    override func stopLoading() {}
}
