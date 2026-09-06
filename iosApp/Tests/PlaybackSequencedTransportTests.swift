import Foundation
import XCTest
@testable import Silo

final class PlaybackSequencedTransportTests: XCTestCase {
    private func fixture(writer: PlaybackTestWriter? = nil) async throws -> (PlaybackMutationCoordinator, TokenStore, CapturedDurableAccountAuth) {
        let name = "PlaybackSequencedTransportTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let auth = try XCTUnwrap(captured)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequencedPlaybackProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let store = PlaybackMutationStore(url: root.appendingPathComponent("sessions.json"), write: { data, url in
            if let writer { try writer.write(data, url) } else { try data.write(to: url, options: .atomic) }
        })
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: name)
            SequencedPlaybackProtocol.reset()
        }
        return (PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: []), tokens, auth)
    }

    func testAppRetryPersistsOriginalStopAfterDiskFailureAndPlayerTeardown() async throws {
        let writer = PlaybackTestWriter()
        let (owner, _, auth) = try await fixture(writer: writer)
        try await owner.register(sessionID: "session", features: [PlaybackSequencedContract.feature], auth: auth)
        writer.fail(true)
        do { _ = try await owner.stop(sessionID: "session", position: 17, isPaused: false); XCTFail() } catch {}
        XCTAssertTrue(SequencedPlaybackProtocol.requests().isEmpty)
        // The player has gone away. Only the application-level Retry remains.
        writer.fail(false)
        SequencedPlaybackProtocol.status(202)
        await owner.retryPendingStops()
        SequencedPlaybackProtocol.status(200)
        await owner.retryPendingStops()
        let requests = SequencedPlaybackProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        let stop = try JSONDecoder().decode(PlaybackSequencedStop.self, from: requests[0].1)
        XCTAssertEqual(stop.sample?.position, 17)
        XCTAssertEqual(stop.sample?.isPaused, false)
        XCTAssertEqual(requests[0].1, requests[1].1)
        let failed = try XCTUnwrap(writer.failedBody())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: failed) as? [String: Any])
        // UUID-keyed dictionaries encode as alternating key/value arrays.
        let sessions = try XCTUnwrap(object["sessions"] as? [Any])
        let session = try XCTUnwrap(sessions[1] as? [String: Any])
        let proposed = try JSONDecoder().decode(PlaybackSequencedStop.self,
            from: JSONSerialization.data(withJSONObject: try XCTUnwrap(session["stop"])))
        XCTAssertEqual(stop, proposed)
    }

    func testDrainingRetryRetainsExactBodyAndCapturedProfile() async throws {
        let (owner, _, auth) = try await fixture()
        try await owner.register(sessionID: "session", features: [PlaybackSequencedContract.feature], auth: auth)
        SequencedPlaybackProtocol.status(202)
        let pending = try await owner.stop(sessionID: "session", position: 3, isPaused: true)
        XCTAssertFalse(pending)
        SequencedPlaybackProtocol.status(200)
        let terminal = try await owner.stop(sessionID: "session", position: 99, isPaused: false)
        XCTAssertTrue(terminal)
        let requests = SequencedPlaybackProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].0.httpMethod, "DELETE")
        XCTAssertEqual(requests[0].0.url?.path, "/api/v1/playback/session")
        XCTAssertEqual(requests[0].0.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        XCTAssertEqual(requests[0].0.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        XCTAssertEqual(requests[0].1, requests[1].1)
    }

    func testLostProgressReplyReusesSampleAndThenAcceptsBackwardPosition() async throws {
        let (owner, _, auth) = try await fixture()
        try await owner.register(sessionID: "session", features: [PlaybackSequencedContract.feature], auth: auth)
        SequencedPlaybackProtocol.status(-1)
        do { try await owner.report(sessionID: "session", position: 120, isPaused: false); XCTFail() } catch {}
        SequencedPlaybackProtocol.status(200)
        try await owner.report(sessionID: "session", position: 30, isPaused: true)
        try await owner.report(sessionID: "session", position: 30, isPaused: true)
        let requests = SequencedPlaybackProtocol.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].1, requests[1].1)
        let third = try JSONDecoder().decode(PlaybackSequencedSample.self, from: requests[2].1)
        XCTAssertEqual(third.sequence, 2)
        XCTAssertEqual(third.position, 30)
    }

    func testUnavailableStopStaysPendingAndIdentitySwitchCannotDispatch() async throws {
        let (owner, tokens, auth) = try await fixture()
        try await owner.register(sessionID: "session", features: [PlaybackSequencedContract.feature], auth: auth)
        SequencedPlaybackProtocol.status(503)
        let pending = try await owner.stop(sessionID: "session", position: nil, isPaused: true)
        XCTAssertFalse(pending)
        let requests = SequencedPlaybackProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].1) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["stop_id"])
        await tokens.setProfileId("other")
        let stillPending = try await owner.stop(sessionID: "session", position: nil, isPaused: true)
        XCTAssertFalse(stillPending)
        XCTAssertEqual(SequencedPlaybackProtocol.requests().count, 1)
    }

    func testSameSessionIDCannotRetargetAnOlderBridgeAcrossProfiles() async throws {
        let (owner, tokens, auth) = try await fixture()
        try await owner.register(sessionID: "session", features: [PlaybackSequencedContract.feature], auth: auth)
        await tokens.setProfileId("different")
        let current = await tokens.captureDurableAccountAuth()
        let other = try XCTUnwrap(current)
        do { try await owner.register(sessionID: "session", features: [PlaybackSequencedContract.feature], auth: other); XCTFail() } catch {}
        do { try await owner.report(sessionID: "session", position: 2, isPaused: false); XCTFail() } catch {}
        XCTAssertTrue(SequencedPlaybackProtocol.requests().isEmpty)
    }

    func testFeatureAbsentNeverRegistersSequencedOwner() async throws {
        let (owner, _, auth) = try await fixture()
        try await owner.register(sessionID: "legacy", features: [], auth: auth)
        let handles = await owner.handles("legacy")
        XCTAssertFalse(handles)
        XCTAssertTrue(SequencedPlaybackProtocol.requests().isEmpty)
    }
}

private final class SequencedPlaybackProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var code = 200
    nonisolated(unsafe) private static var captured: [(URLRequest, Data)] = []
    static func status(_ value: Int) { lock.withLock { code = value } }
    static func requests() -> [(URLRequest, Data)] { lock.withLock { captured } }
    static func reset() { lock.withLock { code = 200; captured = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let status = Self.lock.withLock { Self.captured.append((request, body)); return Self.code }
        if status == -1 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let input = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let output: [String: Any]
        if request.httpMethod == "DELETE" {
            output = ["outcome": status == 202 ? "draining" : "stopped", "stop_id": input["stop_id"] ?? ""]
        } else { output = ["outcome": "applied", "accepted": input] }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: output))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PlaybackTestWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private var failed: Data?
    func fail(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failing = value }
    func failedBody() -> Data? { lock.lock(); defer { lock.unlock() }; return failed }
    func write(_ data: Data, _ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { failed = data; throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}
