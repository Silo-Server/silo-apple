import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class WatchPartySessionRecoveryTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 0
        private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
        var pendingCount: Int { sleepers.count }
        func hasDeadline(_ deadline: TimeInterval) -> Bool {
            sleepers.values.contains { abs($0.0 - deadline) < 0.000001 }
        }

        func sleep(_ delay: TimeInterval) async throws {
            let id = UUID()
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    sleepers[id] = (now + delay, continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
            }
        }

        func advance(_ delta: TimeInterval) {
            now += delta
            for (id, sleeper) in sleepers where sleeper.0 <= now {
                sleepers.removeValue(forKey: id)?.1.resume()
            }
        }

        func finish() {
            let pending = sleepers.values
            sleepers.removeAll()
            for sleeper in pending { sleeper.1.resume(throwing: CancellationError()) }
        }
    }

    private final class Socket: WatchPartySocketConnection {
        var sent: [WatchPartyClientMessage] = []
        var failSend = false
        var closed = false
        var connections = 0
        private var continuation: AsyncThrowingStream<WatchPartySocket.Event, Error>.Continuation?

        func connect(serverURL: String, roomId: String, ticket: WatchPartySocketTicket) throws -> AsyncThrowingStream<WatchPartySocket.Event, Error> {
            connections += 1
            closed = false
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
                continuation.yield(.opened)
            }
        }

        func send(_ message: WatchPartyClientMessage) async throws {
            if failSend { throw WatchPartySocketError.closed }
            sent.append(message)
        }

        func emit(_ message: WatchPartyServerMessage) { continuation?.yield(.message(message)) }
        func finish(_ error: Error) { continuation?.finish(throwing: error) }
        func close() { closed = true; continuation?.finish(); continuation = nil }
    }

    private struct Fixture {
        let session: WatchPartySession
        let socket: Socket
        let clock: Clock
        let stub: APIv2TestStub
        let tokens: TokenStore
    }

    private func waitUntil(_ predicate: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<5000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected observable fixture state", file: file, line: line)
    }

    private func fixture(admissionCapability: Bool = true, admissionTicket: Bool = false) async throws -> Fixture {
        let name = "WatchPartyRecovery.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let tokens = TokenStore(keychain: keychain, defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "synthetic-server")
        await tokens.setServerUrl("https://synthetic.invalid")
        await tokens.saveTokens(accessToken: "synthetic-access", refreshToken: "synthetic-refresh")
        await tokens.setProfileId("synthetic-profile")
        let stub = APIv2TestStub()
        let metadata = #", "work_admission":{"version":1,"backend":"memory","scope":"node","epoch":"synthetic"}"#
        stub.reply(200, #"{"revision":"synthetic","state":"available","allowed":true,"connection_replaced":true,"lobby_ready":true,"socket_protocol":"silo.room.v2","protocol_versions":[3],"features":["watch_party_coordinator_v1","fixed_media_file_v1"],"deliveries":[]\#(admissionCapability ? metadata : "")}"#)
        let room = WatchPartyRoom(roomId: "synthetic-room", code: "TESTROOM",
            anchorUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000), memberCount: 2, hostConnected: true,
            members: [WatchPartyMember(userId: "9", profileId: "host", displayName: "Host", isHost: true, connected: true),
                      WatchPartyMember(userId: "10", profileId: "synthetic-profile", displayName: "Viewer", isSelf: true, connected: true)])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let response = WatchPartyRoomResponse(room: room, roomAccessToken: "synthetic-room-proof")
        let json = String(decoding: try encoder.encode(response), as: UTF8.self)
        stub.reply(path: "/api/v2/watch-together/join", 200, json)
        stub.reply(path: "/api/v2/watch-together/rooms/synthetic-room", 200, json)
        stub.reply(path: "/api/v2/watch-together/rooms/synthetic-room/ws-ticket", 200,
                   #"{"ticket":"synthetic-ticket","protocol":"silo.room.v2","expires_in":30,"max_connection_seconds":300\#(admissionTicket ? metadata : "")}"#)
        stub.reply(path: "/api/v2/watch-together/rooms/synthetic-room/suggestions", 200, #"{"items":[],"page":{"has_more":false}}"#)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens, isUpdateRequired: { false })
        let socket = Socket()
        let clock = Clock()
        let session = WatchPartySession(api: api, tokenStore: tokens,
            recentStore: WatchPartyRecentStore(keychain: keychain), workNow: { clock.now }, retryJitter: { 0 },
            makeSocket: { socket }, workSleep: { try await clock.sleep($0) })
        addTeardownBlock { @MainActor in
            session.leave(forgetRecent: true)
            clock.finish()
            _ = await tokens.clearTokens()
        }
        let joined = await session.join(code: "TESTROOM")
        XCTAssertTrue(joined, session.errorMessage ?? "Synthetic join failed")
        guard joined else { throw WatchPartyAPIError.invalidResponse }
        await waitUntil { session.connection == .connected }
        await waitUntil { socket.sent.contains { $0.type == "ping" } && clock.pendingCount > 0 }
        return Fixture(session: session, socket: socket, clock: clock, stub: stub, tokens: tokens)
    }

    func testLobbyRefusalHonorsFloorRecomputesLatestDesireAndWaitsForAppliedResult() async throws {
        let fixture = try await fixture()
        fixture.session.setLobbyReady(true)
        await waitUntil { fixture.socket.sent.contains { $0.type == "lobby_ready" } }
        let first = try XCTUnwrap(fixture.socket.sent.first { $0.type == "lobby_ready" })
        XCTAssertEqual(fixture.session.lobbyReadyDesired, true)
        XCTAssertFalse(fixture.session.room?.members.first(where: \.isSelf)?.lobbyReady ?? true)
        fixture.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: first.requestId,
                                         retryAfterMilliseconds: 1000, workStarted: false)))
        await waitUntil { fixture.session.workStatusMessage?.contains("delayed") == true }
        fixture.session.setLobbyReady(false)
        fixture.clock.advance(0.9)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.socket.sent.filter { $0.type == "lobby_ready" }.count, 1)
        fixture.clock.advance(0.6)
        await waitUntil { fixture.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
        let second = try XCTUnwrap(fixture.socket.sent.last { $0.type == "lobby_ready" })
        XCTAssertEqual(second.ready, false, "A retry recomputes the current desire")
        XCTAssertNotEqual(first.requestId, second.requestId)
        fixture.socket.emit(.actionResult(requestId: first.requestId, action: "lobby_ready", status: "applied"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(fixture.session.lobbyReadyDesired, "Old acknowledgement cannot confirm a replacement desire")
        fixture.socket.emit(.actionResult(requestId: second.requestId, action: "lobby_ready", status: "applied"))
        await waitUntil { fixture.session.lobbyReadyDesired == nil }
        XCTAssertNil(fixture.session.workStatusMessage)
    }

    func testLobbySnapshotEchoAndIdentityLossFenceRecovery() async throws {
        let fixture = try await fixture()
        fixture.session.setLobbyReady(true)
        await waitUntil { fixture.socket.sent.contains { $0.type == "lobby_ready" } }
        var echoed = try XCTUnwrap(fixture.session.room)
        echoed.members[1].lobbyReady = true
        echoed.generation += 1
        fixture.socket.emit(.snapshot(echoed))
        await waitUntil { fixture.session.lobbyReadyDesired == nil }
        XCTAssertTrue(fixture.session.room?.members[1].lobbyReady == true)
        fixture.session.setLobbyReady(false)
        await waitUntil { fixture.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
        let message = try XCTUnwrap(fixture.socket.sent.last { $0.type == "lobby_ready" })
        fixture.socket.emit(.error(.init(code: "realtime_unavailable", message: "Synthetic outage", requestId: message.requestId,
                                         retryAfterMilliseconds: 2000, workStarted: false)))
        await waitUntil { fixture.session.workStatusMessage?.contains("delayed") == true }
        await fixture.tokens.setProfileId("replacement-profile")
        fixture.clock.advance(3)
        await waitUntil { fixture.session.connection == .idle }
        XCTAssertNil(fixture.session.lobbyReadyDesired)
        XCTAssertEqual(fixture.socket.sent.filter { $0.type == "lobby_ready" }.count, 2)
        XCTAssertTrue(fixture.socket.closed)
    }

    func testLocalSendFailureNeverMarksLobbyReadySaved() async throws {
        let fixture = try await fixture()
        fixture.socket.failSend = true
        fixture.session.setLobbyReady(true)
        await waitUntil { fixture.session.workStatusMessage?.contains("could not be confirmed") == true }
        XCTAssertNil(fixture.session.lobbyReadyDesired)
        XCTAssertFalse(fixture.session.room?.members.first(where: \.isSelf)?.lobbyReady ?? true)
    }

    func testDownstreamLobbyErrorReconcilesWithoutAutomaticReplay() async throws {
        let fixture = try await fixture()
        fixture.session.setLobbyReady(true)
        await waitUntil { fixture.socket.sent.contains { $0.type == "lobby_ready" } }
        let message = try XCTUnwrap(fixture.socket.sent.last { $0.type == "lobby_ready" })
        fixture.socket.emit(.error(.init(code: "bad_request", message: "Synthetic downstream failure", requestId: message.requestId,
                                         workStarted: true)))
        await waitUntil { fixture.session.lobbyReadyDesired == nil }
        fixture.clock.advance(3)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.socket.sent.filter { $0.type == "lobby_ready" }.count, 1)
        XCTAssertTrue(fixture.session.workStatusMessage?.contains("could not be confirmed") == true)
    }

    func testCapabilityAbsenceKeepsLegacyLobbyDeliveryAndTicketMetadataEnablesRecovery() async throws {
        let legacy = try await fixture(admissionCapability: false)
        legacy.session.setLobbyReady(true)
        await waitUntil { legacy.socket.sent.contains { $0.type == "lobby_ready" } }
        XCTAssertNil(legacy.socket.sent.last { $0.type == "lobby_ready" }?.requestId)
        XCTAssertNil(legacy.session.lobbyReadyDesired)
        let current = try await fixture(admissionCapability: false, admissionTicket: true)
        current.session.setLobbyReady(true)
        await waitUntil { current.socket.sent.contains { $0.type == "lobby_ready" } }
        XCTAssertNotNil(current.socket.sent.last { $0.type == "lobby_ready" }?.requestId)
        XCTAssertEqual(current.session.lobbyReadyDesired, true)
        XCTAssertEqual(current.session.capabilities?.workAdmission?.epoch, "synthetic")
    }

    func testShieldCloseWaitsFiveThenTenSecondsAcrossSuccessfulOpens() async throws {
        let fixture = try await fixture()
        fixture.socket.finish(WatchPartySocketError.remoteClose(code: 1008, reason: "realtime input shield"))
        await waitUntil { fixture.session.connection == .reconnecting && fixture.clock.hasDeadline(5) }
        fixture.clock.advance(4.9)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.socket.connections, 1)
        fixture.clock.advance(0.11)
        await waitUntil { fixture.socket.connections == 2 && fixture.session.connection == .connected }
        let secondDeadline = fixture.clock.now + 10
        fixture.socket.finish(WatchPartySocketError.remoteClose(code: 1008, reason: "realtime input shield"))
        await waitUntil { fixture.session.connection == .reconnecting && fixture.clock.hasDeadline(secondDeadline) }
        fixture.clock.advance(9.9)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.socket.connections, 2)
        fixture.clock.advance(0.11)
        await waitUntil { fixture.socket.connections == 3 && fixture.session.connection == .connected }
    }

    func testReadableTicketRefusalHonorsFloorWithoutCapabilityOrTerminalPermissionFailure() async throws {
        let fixture = try await fixture(admissionCapability: false)
        let path = "/api/v2/watch-together/rooms/synthetic-room/ws-ticket"
        fixture.stub.reply(path: path, 503, #"{"retry_after_ms":4000}"#)
        fixture.socket.finish(WatchPartySocketError.closed)
        await waitUntil { fixture.session.connection == .reconnecting && fixture.clock.hasDeadline(1) }
        fixture.clock.advance(1)
        await waitUntil { fixture.session.workStatusMessage?.contains("unavailable") == true && fixture.clock.hasDeadline(5) }
        XCTAssertTrue(fixture.session.isEngaged)
        let attempts = fixture.stub.requests.filter { $0.path == path }.count
        fixture.clock.advance(3.9)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.stub.requests.filter { $0.path == path }.count, attempts)
        fixture.stub.reply(path: path, 200, #"{"ticket":"synthetic-ticket","protocol":"silo.room.v2","expires_in":30,"max_connection_seconds":300}"#)
        fixture.clock.advance(0.11)
        await waitUntil { fixture.socket.connections == 2 && fixture.session.connection == .connected }
    }

    func testOther1008ReasonUsesOpaqueBackoffEvenAfterInputNotice() async throws {
        let fixture = try await fixture()
        fixture.socket.emit(.error(.init(code: "realtime_input_limited", message: "Synthetic input notice")))
        await waitUntil { fixture.session.errorMessage == "Synthetic input notice" }
        fixture.socket.finish(WatchPartySocketError.remoteClose(code: 1008, reason: "selection required"))
        await waitUntil { fixture.session.connection == .reconnecting && fixture.clock.hasDeadline(1) }
        fixture.clock.advance(1.01)
        await waitUntil { fixture.socket.connections == 2 && fixture.session.connection == .connected }
    }

    /// Render the actual shared lobby against an in-process socket/HTTP fixture.
    /// These attachments prove fixture rendering, not a real server or media flow.
    func testRenderedLobbyRefusalAndAcknowledgedRecovery() async throws {
        let fixture = try await fixture()
        func capture(_ name: String) async throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let sizes = [scene.coordinateSpace.bounds.size]
            for size in sizes {
                let view = WatchPartyHubView(session: fixture.session)
                    .environment(AppRouter())
                let host = UIHostingController(rootView: view
                    .environment(\.colorScheme, .dark)
                    .frame(width: size.width, height: size.height))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                // Hosting scroll views need a native layout pass; ImageRenderer
                // omits their contents and would create misleading evidence.
                for _ in 0..<20 { await Task.yield() }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "C30 synthetic lobby \(name) \(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                let traits = XCTAttachment(string: "Native viewport \(size); idiom \(host.traitCollection.userInterfaceIdiom.rawValue); horizontal size class \(host.traitCollection.horizontalSizeClass.rawValue)")
                traits.name = "C30 native traits \(name)"
                traits.lifetime = .keepAlways
                add(traits)
            }
        }
        try await capture("connected")
        fixture.session.setLobbyReady(true)
        await waitUntil { fixture.socket.sent.contains { $0.type == "lobby_ready" } }
        let message = try XCTUnwrap(fixture.socket.sent.last { $0.type == "lobby_ready" })
        fixture.socket.emit(.error(.init(code: "realtime_unavailable", message: "Synthetic outage", requestId: message.requestId,
                                         retryAfterMilliseconds: 2000, workStarted: false)))
        await waitUntil { fixture.session.workStatusMessage?.contains("delayed") == true }
        try await capture("refused")
        fixture.clock.advance(2.5)
        await waitUntil { fixture.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
        let retry = try XCTUnwrap(fixture.socket.sent.last { $0.type == "lobby_ready" })
        var room = try XCTUnwrap(fixture.session.room)
        room.members[1].lobbyReady = true
        fixture.socket.emit(.snapshot(room))
        fixture.socket.emit(.actionResult(requestId: retry.requestId, action: "lobby_ready", status: "applied"))
        await waitUntil { fixture.session.lobbyReadyDesired == nil }
        try await capture("recovered")
        fixture.socket.failSend = true
        fixture.session.setLobbyReady(false)
        await waitUntil { fixture.session.workStatusMessage?.contains("could not be confirmed") == true }
        try await capture("uncertain")
    }
}
