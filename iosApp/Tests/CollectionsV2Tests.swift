import Foundation
import XCTest
@testable import Silo

final class CollectionsV2Tests: XCTestCase {
    private let collection = #"{"id":"c1","name":"Saved","collection_type":"manual","group_id":"g1"}"#

    private func api() async throws -> SiloAPI {
        let name = "CollectionsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name); CollectionProtocol.reset() }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://collections.example")
        await tokens.setProfileId("profile-one")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CollectionProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens,
            v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
    }

    func testMoveUsesObservedETagAndExplicitNull() async throws {
        CollectionProtocol.reply(status: 200, body: collection, etag: #""observed""#)
        let api = try await api()
        let editor = try await api.collectionEditor(id: "c1")
        CollectionProtocol.reply(status: 200, body: collection, etag: #""new""#)
        _ = try await api.moveCollectionToGroup(version: editor.version, groupId: nil)
        let sent = try XCTUnwrap(CollectionProtocol.requests().last)
        XCTAssertEqual(sent.httpMethod, "PATCH")
        XCTAssertEqual(sent.url?.path, "/api/v2/collections/c1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-Match"), #""observed""#)
        let body = try XCTUnwrap(CollectionProtocol.lastBody())
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(decoded["group_id"] is NSNull)
    }

    @MainActor
    func testConflictKeepsActionAndRequiresExplicitReload() async throws {
        CollectionProtocol.reply(status: 200, body: collection, etag: #""first""#)
        let api = try await api()
        let model = CollectionsViewModel(api: api)
        let value = try HTTPClient.makeJSONDecoder().decode(UserCollection.self, from: Data(collection.utf8))
        model.pendingGroupAction = .move(value)
        await model.reloadEditor()
        CollectionProtocol.reply(status: 412,
            body: #"{"type":"https://siloserver.org/docs/api/v2/problems/stale_version","title":"Conflict","status":412,"detail":"Changed","instance":"urn:test"}"#,
            etag: #""other""#)
        await model.moveCollection(id: "c1", toGroupId: nil)
        XCTAssertEqual(model.pendingGroupAction?.id, "move:c1")
        XCTAssertTrue(model.editorNeedsReload)
        XCTAssertEqual(model.editorVersion?.etag, #""first""#)
        let count = CollectionProtocol.requests().count
        await model.moveCollection(id: "c1", toGroupId: nil)
        XCTAssertEqual(CollectionProtocol.requests().count, count)
        CollectionProtocol.reply(status: 200, body: collection, etag: #""reviewed""#)
        await model.reloadEditor()
        XCTAssertFalse(model.editorNeedsReload)
        XCTAssertEqual(model.editorVersion?.etag, #""reviewed""#)
        XCTAssertEqual(model.pendingGroupAction?.id, "move:c1")
    }

    func testPersonalCardsFollowOpaqueCursorAndNeverDecodeMembership() async throws {
        CollectionProtocol.sequence([
            (200, #"{"items":[{"content_id":"film1","type":"movie","title":"Film"}],"page":{"has_more":true,"next_cursor":"opaque-next"}}"#, nil),
            (200, #"{"items":[],"page":{"has_more":false}}"#, nil),
        ])
        let api = try await api()
        let result = try await api.collectionItems(collectionId: "c1")
        XCTAssertEqual(result.items.map(\.contentId), ["film1"])
        XCTAssertEqual(result.hasMore, false)
        let sent = CollectionProtocol.requests()
        XCTAssertEqual(sent.count, 2)
        for request in sent {
            XCTAssertEqual(request.url?.path, "/api/v2/catalog")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "source" }?.value, "user_collection")
            XCTAssertEqual(query.first { $0.name == "collection_id" }?.value, "c1")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
            XCTAssertFalse(query.contains { $0.name == "offset" || $0.name == "sort" })
        }
        XCTAssertTrue(sent[1].url!.absoluteString.contains("cursor=opaque-next"))
    }

    func testPersonalCardsRejectIncompletePage() async throws {
        CollectionProtocol.reply(status: 200,
            body: #"{"items":[],"page":{"has_more":true}}"#, etag: nil)
        let api = try await api()
        do {
            _ = try await api.collectionItems(collectionId: "c1")
            XCTFail("Expected incomplete page error")
        } catch APIv2Error.incompleteCollection { }
    }

    func testMissingETagCannotOpenEditor() async throws {
        CollectionProtocol.reply(status: 200, body: collection, etag: nil)
        let api = try await api()
        do {
            _ = try await api.collectionEditor(id: "c1")
            XCTFail("Expected missing version")
        } catch APIv2Error.missingCollectionVersion { }
    }
}

private final class CollectionProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (200, "{}", Optional<String>.none)
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var body: Data?
    nonisolated(unsafe) private static var queued: [(Int, String, String?)] = []
    static func reset() { lock.withLock { recorded = []; body = nil; queued = [] } }
    static func reply(status: Int, body: String, etag: String?) {
        lock.withLock { response = (status, body, etag) }
    }
    static func sequence(_ values: [(Int, String, String?)]) { lock.withLock { queued = values } }
    static func requests() -> [URLRequest] { lock.withLock { recorded } }
    static func lastBody() -> Data? { lock.withLock { body } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let reply = Self.lock.withLock { Self.recorded.append(request); Self.body = data; return Self.queued.isEmpty ? Self.response : Self.queued.removeFirst() }
        var headers = ["Content-Type": reply.0 >= 400 ? "application/problem+json" : "application/json"]
        if let tag = reply.2 { headers["ETag"] = tag }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
