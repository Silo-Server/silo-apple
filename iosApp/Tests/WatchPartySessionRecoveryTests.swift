import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class WatchPartySessionRecoveryTests: XCTestCase {
    @MainActor private final class Clock {
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
        var holdTransportSend = false
        var transportWaiters: [CheckedContinuation<Void, Never>] = []
        var holdNextLobbySend = false
        var lobbyWaiters: [CheckedContinuation<Void, Error>] = []
        var lobbyCompletions = 0
        var lobbyCompletionWasCancelled = false
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
            if message.type == "lobby_ready", holdNextLobbySend {
                holdNextLobbySend = false
                do { try await withCheckedThrowingContinuation { lobbyWaiters.append($0) } }
                catch {
                    lobbyCompletions += 1
                    lobbyCompletionWasCancelled = Task.isCancelled
                    throw error
                }
            }
            if message.type == "transport_request", holdTransportSend {
                await withCheckedContinuation { transportWaiters.append($0) }
            }
        }

        func emit(_ message: WatchPartyServerMessage) { continuation?.yield(.message(message)) }
        func finish(_ error: Error) { continuation?.finish(throwing: error) }
        func close() { closed = true; continuation?.finish(); continuation = nil }
    }

    @MainActor private final class ValidationGate {
        var holding = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard holding else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func resumeFirst() { waiters.removeFirst().resume() }
        func release() {
            holding = false
            let pending = waiters; waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class Playback: WatchPartyPlaybackBinding {
        var context: WatchPartyPlaybackContext?
        var snapshot = WatchPartyPlaybackSnapshot(sessionId: "synthetic-playback", fileId: 42,
            sourceTime: 30, duration: 120, isReady: true)
        var canPlayPause = false
        var canSeek = false
        var onSnapshot: ((WatchPartyPlaybackSnapshot) -> Void)?
        var onSessionCommitted: ((String) -> Void)?
        var onUserTransport: ((WatchPartyPlaybackAction, Double, Bool) -> Bool)?
        var onLocalExit: (() -> Void)?
        var onResyncRequired: (() -> Void)?
        var onFailure: ((String?, String) -> Void)?
        var heldTarget: Double?
        var releases = 0
        var appliedActions: [WatchPartyPlaybackAction] = []
        func prepare(_ context: WatchPartyPlaybackContext) { self.context = context }
        func apply(_ action: WatchPartyPlaybackAction, origin: WatchPartySeekOrigin) async throws -> WatchPartyPlaybackSnapshot {
            appliedActions.append(action)
            return snapshot
        }
        func correct(to position: Double, seekBand: Double) async throws -> WatchPartyPlaybackSnapshot { snapshot }
        func cancelCorrection() {}
        func roomSeekArrived(at position: Double) {}
        func roomCommandStarts(seekingTo position: Double?) {}
        func releaseHeldSeek() { releases += 1; heldTarget = nil }
        func nudge(drift: Double) {}
        func canReachInPlace(_ position: Double) -> Bool { false }
        func restoreIfNeeded(at position: Double) {}
        func stop() { context = nil }
        func request(_ action: WatchPartyPlaybackAction) -> Bool {
            let accepted = onUserTransport?(action, snapshot.sourceTime, !snapshot.isPlaying) == true
            if accepted, case .seek(let target) = action { heldTarget = target }
            return accepted
        }
        func replaceSession() {
            snapshot.sessionId = "replacement-playback"
            onSessionCommitted?("replacement-playback")
            onSnapshot?(snapshot)
        }
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

    private func fixture(admissionCapability: Bool = true, admissionTicket: Bool = false, validationGate: ValidationGate? = nil) async throws -> Fixture {
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
            makeSocket: { socket }, workSleep: { try await clock.sleep($0) },
            identityIsCurrent: { captured in
                await validationGate?.wait()
                return await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: captured) != nil
            })
        addTeardownBlock { @MainActor in
            validationGate?.release()
            socket.transportWaiters.forEach { $0.resume() }; socket.transportWaiters.removeAll()
            socket.lobbyWaiters.forEach { $0.resume(throwing: CancellationError()) }; socket.lobbyWaiters.removeAll()
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

    private func playingFixture(validationGate: ValidationGate? = nil) async throws -> (Fixture, Playback) {
        let f = try await fixture(validationGate: validationGate)
        var room = try XCTUnwrap(f.session.room)
        room.phase = .playing; room.playbackState = .paused; room.selectionRevision = 1
        room.selectedContentId = "synthetic-content"; room.selectedFileId = "42"
        room.selfRole = .host; room.selfCanControlTransport = true; room.generation += 1
        f.socket.emit(.snapshot(room))
        await waitUntil { f.session.playbackContext != nil }
        let playback = Playback()
        f.session.bind(playback, context: try XCTUnwrap(f.session.playbackContext))
        f.clock.advance(0.5)
        await waitUntil { f.socket.sent.contains { $0.type == "attach_session" } }
        room.attachedSessionId = "synthetic-playback"; room.members[1].isReady = true; room.generation += 1
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(WatchPartyRoomResponse(room: room, roomAccessToken: "synthetic-room-proof")), as: UTF8.self)
        f.stub.reply(path: "/api/v2/watch-together/rooms/synthetic-room", 200, json)
        f.socket.emit(.snapshot(room))
        await waitUntil { f.session.room?.attachedSessionId == "synthetic-playback" }
        return (f, playback)
    }

    func testQuietHealthyLifetimeResetsOutageBeforeFreshTransportRefusal() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.play))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let first = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "realtime_unavailable", message: "Synthetic outage", requestId: first.requestId,
            retryAfterMilliseconds: 2000, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
        f.clock.advance(2.1)
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
        f.socket.emit(.error(.init(code: "realtime_unavailable", message: "Second synthetic outage", requestId: first.requestId,
            retryAfterMilliseconds: 2000, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("not applied") == true }
        f.clock.advance(4.1)
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 3 }
        let accepted = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        // Current room is already paused: this is an accepted no-op, not a
        // fabricated command or a reason to replay either refused operation.
        f.socket.emit(.actionResult(requestId: accepted.requestId, action: "transport_request", status: "applied"))
        await waitUntil { f.session.workStatusMessage == nil }
        f.clock.advance(30) // No incoming frames during the accepted healthy lifetime.
        XCTAssertTrue(playback.request(.play))
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 4 }
        let fresh = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "realtime_unavailable", message: "Fresh synthetic outage", requestId: fresh.requestId,
            retryAfterMilliseconds: 2000, workStarted: false)))
        f.socket.emit(.error(.init(code: "synthetic_marker", message: "fresh refusal processed")))
        await waitUntil { f.session.errorMessage == "fresh refusal processed" }
        XCTAssertTrue(f.session.workStatusMessage?.contains("delayed") == true, "The reset two-second floor keeps this fresh intent within five seconds")
        f.clock.advance(2.1)
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 5 }
        XCTAssertEqual(f.socket.sent.last { $0.type == "transport_request" }?.requestId, fresh.requestId)
        f.socket.emit(.error(.init(code: "realtime_unavailable", message: "Retry refused", requestId: fresh.requestId,
            retryAfterMilliseconds: 2000, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("not applied") == true }
        f.clock.advance(4.1)
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 5)
    }

    func testQuietAcceptedRoomRenewsWithoutEscalatingOpaqueBackoff() async throws {
        let f = try await fixture()
        for connection in 1...3 {
            f.clock.advance(300)
            f.socket.finish(WatchPartySocketError.closed)
            await waitUntil { f.session.connection == .reconnecting && f.clock.pendingCount > 0 }
            XCTAssertTrue(f.clock.hasDeadline(f.clock.now), "A valid initial snapshot and healthy lifetime qualify without another frame")
            f.clock.advance(0)
            await waitUntil { f.socket.connections == connection + 1 && f.session.connection == .connected }
        }
    }

    func testNewTransportIntentDiscardsOlderRefusedRetryBeforeReportTick() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.play))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: original.requestId,
            retryAfterMilliseconds: 250, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
        f.clock.advance(0.3)
        XCTAssertTrue(playback.request(.pause))
        XCTAssertTrue(f.session.workStatusMessage?.contains("not sent") == true, "Discard is visible before the new send can suspend")
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
        f.clock.advance(0.2)
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.action), [.play, .pause])
        XCTAssertEqual(f.socket.sent.filter { $0.requestId == original.requestId }.count, 1)
    }

    func testLateRefusalOfSupersededDispatchedIntentCannotAuthorizeReplay() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.play))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: original.requestId,
            retryAfterMilliseconds: 250, workStarted: false)))
        f.socket.emit(.error(.init(code: "synthetic_marker", message: "late refusal processed")))
        await waitUntil { f.session.errorMessage == "late refusal processed" }
        f.clock.advance(0.5)
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.action), [.play, .pause])
    }

    func testLateRefusalCannotReplayAfterNewerPlayOrSeek() async throws {
        for seek in [false, true] {
            let (f, playback) = try await playingFixture()
            XCTAssertTrue(playback.request(seek ? .play : .pause))
            await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
            let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
            XCTAssertTrue(playback.request(seek ? .seek(70) : .play))
            if !seek { await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 } }
            f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: original.requestId,
                retryAfterMilliseconds: 250, workStarted: false)))
            f.socket.emit(.error(.init(code: "synthetic_marker", message: "late refusal processed")))
            await waitUntil { f.session.errorMessage == "late refusal processed" }
            XCTAssertTrue(f.session.workStatusMessage?.contains("not applied") == true, "The older refused intent is visibly discarded")
            if seek {
                await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
                f.clock.advance(0.25)
                await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
                XCTAssertEqual(f.socket.sent.last { $0.type == "transport_request" }?.positionSeconds, 70)
                f.clock.advance(0.25)
            } else { f.clock.advance(0.5) }
            await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
            XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.action), seek ? [.play, .seek] : [.pause, .play])
            XCTAssertEqual(f.socket.sent.filter { $0.requestId == original.requestId }.count, 1)
        }
    }

    func testUnchangedIntentRetriesSameRequestOnceAndStillHonorsIdentityAndExpiry() async throws {
        for invalidation in ["none", "session", "expiry"] {
            let (f, playback) = try await playingFixture()
            XCTAssertTrue(playback.request(.pause))
            await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
            let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
            f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: original.requestId,
                retryAfterMilliseconds: 1000, workStarted: false)))
            await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
            if invalidation == "session" { playback.replaceSession() }
            f.clock.advance(invalidation == "expiry" ? 5 : 0.5)
            await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
            XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
            if invalidation == "none" {
                f.clock.advance(0.5)
                await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 && f.clock.hasDeadline(f.clock.now + 0.5) }
                let retry = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
                let originalJSON = try JSONSerialization.jsonObject(with: Data(original.encoded().utf8)) as? NSDictionary
                let retryJSON = try JSONSerialization.jsonObject(with: Data(retry.encoded().utf8)) as? NSDictionary
                XCTAssertEqual(retryJSON, originalJSON, "The sole retry retains request ID and payload")
                f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy again", requestId: retry.requestId,
                    retryAfterMilliseconds: 250, workStarted: false)))
                await waitUntil { f.session.workStatusMessage?.contains("not applied") == true }
                f.clock.advance(0.5)
                await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
                XCTAssertEqual(f.socket.sent.filter { $0.requestId == original.requestId }.count, 2)
            } else {
                f.clock.advance(0.5)
                await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
                XCTAssertEqual(f.socket.sent.filter { $0.requestId == original.requestId }.count, 1)
            }
        }
    }

    func testNewIntentCancelsSelectedRetryAcrossValidationWithoutDroppingNewControl() async throws {
        let gate = ValidationGate()
        let (f, playback) = try await playingFixture(validationGate: gate)
        XCTAssertTrue(playback.request(.play))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: original.requestId,
            retryAfterMilliseconds: 250, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
        gate.holding = true
        f.clock.advance(0.5)
        await waitUntil { gate.waiters.count == 1 }
        gate.resumeFirst()
        await waitUntil { gate.waiters.count == 1 }
        XCTAssertTrue(playback.request(.pause))
        XCTAssertTrue(f.session.workStatusMessage?.contains("not sent") == true)
        gate.release()
        await waitUntil { f.socket.sent.contains { $0.action == .pause } && f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.action), [.play, .pause])
    }

    func testSelectedRetryDefersWhenAnotherRefusalAdvancesFloorDuringValidation() async throws {
        let gate = ValidationGate()
        let (f, playback) = try await playingFixture(validationGate: gate)
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: original.requestId,
            retryAfterMilliseconds: 250, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
        gate.holding = true
        f.clock.advance(0.5)
        await waitUntil { gate.waiters.count == 1 }
        gate.resumeFirst()
        await waitUntil { gate.waiters.count == 1 }
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Another refusal", requestId: "unrelated",
            retryAfterMilliseconds: 1000, workStarted: false)))
        await waitUntil { gate.waiters.count == 2 }
        gate.waiters.removeLast().resume() // Receive the new floor while retry validation remains suspended.
        f.socket.emit(.error(.init(code: "synthetic_marker", message: "floor advanced")))
        await waitUntil { gate.waiters.count == 2 }
        gate.waiters.removeLast().resume()
        await waitUntil { f.session.errorMessage == "floor advanced" }
        gate.release()
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
        f.clock.advance(0.5)
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
        f.clock.advance(0.5)
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.requestId), [original.requestId, original.requestId])
    }

    func testOldDownstreamLobbyErrorPreservesUniqueReplacementDesire() async throws {
        for replacement in [false, true] {
            let f = try await fixture()
            f.session.setLobbyReady(true)
            await waitUntil { f.socket.sent.contains { $0.type == "lobby_ready" } }
            let original = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
            f.session.setLobbyReady(false)
            if replacement { f.session.setLobbyReady(true) }
            let notice = f.session.workStatusMessage
            f.socket.emit(.error(.init(code: "bad_request", message: "Old downstream failure", requestId: original.requestId, workStarted: true)))
            f.socket.emit(.error(.init(code: "synthetic_marker", message: "old failure processed")))
            await waitUntil { f.session.errorMessage == "old failure processed" }
            XCTAssertEqual(f.session.lobbyReadyDesired, replacement)
            XCTAssertEqual(f.session.workStatusMessage, notice)
            f.clock.advance(0.5)
            await waitUntil { f.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
            let current = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
            XCTAssertEqual(current.ready, replacement)
            f.socket.emit(.actionResult(requestId: current.requestId, action: "lobby_ready", status: "applied"))
            await waitUntil { f.session.lobbyReadyDesired == nil }
        }
    }

    func testCurrentReconciliationSettlesUncertaintyWithoutAcknowledgingOrReplayingWrite() async throws {
        let (f, playback) = try await playingFixture()
        let path = "/api/v2/watch-together/rooms/synthetic-room"
        f.stub.hold(path: path)
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "bad_request", message: "Synthetic failure", requestId: original.requestId, workStarted: true)))
        await f.stub.waitUntilHeld()
        XCTAssertTrue(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        f.stub.release()
        await waitUntil { f.session.workStatusMessage == nil }
        XCTAssertEqual(f.session.room?.playbackState, .paused)
        f.clock.advance(1)
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
    }

    func testOlderReconciliationCannotClearNewerUncertaintyAndStartsItsOwnRead() async throws {
        let (f, playback) = try await playingFixture()
        let path = "/api/v2/watch-together/rooms/synthetic-room"
        let reads = f.stub.requests.filter { $0.path == path }.count
        f.stub.hold(path: path)
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let first = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "operation_failed", message: "First failure", requestId: first.requestId, workStarted: true)))
        await f.stub.waitUntilHeld()
        XCTAssertTrue(playback.request(.play))
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
        let second = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        f.socket.emit(.error(.init(code: "operation_failed", message: "Second failure", requestId: second.requestId, workStarted: true)))
        f.socket.emit(.error(.init(code: "synthetic_marker", message: "second failure processed")))
        await waitUntil { f.session.errorMessage == "second failure processed" }
        f.stub.reply(path: path, 503, "{}") // Only the newer reconciliation fails; the held old read succeeds.
        f.stub.release()
        await waitUntil { f.stub.requests.filter { $0.path == path }.count == reads + 2 }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 2)
    }

    func testFailedOrObsoleteReconciliationKeepsUncertaintyVisible() async throws {
        for obsolete in [false, true] {
            let (f, playback) = try await playingFixture()
            let path = "/api/v2/watch-together/rooms/synthetic-room"
            if !obsolete { f.stub.reply(path: path, 503, "{}") }
            f.stub.hold(path: path)
            XCTAssertTrue(playback.request(.pause))
            await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
            let original = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
            f.socket.emit(.error(.init(code: "bad_request", message: "Synthetic failure", requestId: original.requestId, workStarted: true)))
            await f.stub.waitUntilHeld()
            if obsolete {
                var room = try XCTUnwrap(f.session.room); room.generation += 1; room.selfCanControlTransport = false
                f.socket.emit(.snapshot(room))
                await waitUntil { f.session.room?.selfCanControlTransport == false }
            }
            f.stub.release()
            for _ in 0..<100 { await Task.yield() }
            XCTAssertTrue(f.session.workStatusMessage?.contains("could not be confirmed") == true)
            XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
        }
    }

    func testQueuedSeekPrecedesLaterPauseWithoutShorteningItsWindow() async throws {
        let (f, playback) = try await playingFixture()
        playback.snapshot.isPlaying = true
        XCTAssertTrue(playback.request(.seek(70)))
        let deadline = f.clock.now + 0.25
        await waitUntil { f.clock.hasDeadline(deadline) }
        f.clock.advance(0.1)
        XCTAssertTrue(playback.request(.pause))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
        f.clock.advance(0.149)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
        f.clock.advance(0.002)
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
        let messages = f.socket.sent.filter { $0.type == "transport_request" }
        XCTAssertEqual(messages.map(\.action), [.seek, .pause])
        XCTAssertEqual(messages.first?.positionSeconds, 70)
        XCTAssertEqual(messages.first?.isPaused, false)
    }

    func testSeekBatchAndFollowingControlStayOrderedAcrossSuspendedSend() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.seek(70)))
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        XCTAssertTrue(playback.request(.pause))
        f.socket.holdTransportSend = true
        f.clock.advance(0.251)
        await waitUntil { f.socket.transportWaiters.count == 1 }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.action), [.seek])
        XCTAssertTrue(playback.request(.play))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
        f.socket.holdTransportSend = false
        f.socket.transportWaiters.removeFirst().resume()
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 3 }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.map(\.action), [.seek, .pause, .play])
    }

    func testOwnSeekCommitBetweenValidationAndAppliedResultPreservesFollowingControls() async throws {
        let gate = ValidationGate()
        let (f, playback) = try await playingFixture(validationGate: gate)
        XCTAssertTrue(playback.request(.seek(70)))
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        XCTAssertTrue(playback.request(.pause))
        XCTAssertTrue(playback.request(.play))
        f.socket.holdTransportSend = true
        f.clock.advance(0.251)
        await waitUntil { f.socket.transportWaiters.count == 1 }
        let seek = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
        gate.holding = true
        f.socket.holdTransportSend = false
        f.socket.transportWaiters.removeFirst().resume()
        await waitUntil { gate.waiters.count == 1 }
        var committed = try XCTUnwrap(f.session.room)
        committed.generation += 1; committed.anchorPositionSeconds = 70; committed.playbackState = .waiting
        f.socket.emit(.snapshot(committed))
        await waitUntil { gate.waiters.count == 2 }
        gate.waiters.removeLast().resume()
        await waitUntil { f.session.room?.generation == committed.generation }
        // Let the next control finish validation after the snapshot but before
        // the command/result. It must wait for correlated completion, not drop.
        gate.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
        f.socket.emit(.transport(.init(commandId: "own-seek-command", sessionId: "synthetic-playback", selectionRevision: 1,
            action: .seek, positionSeconds: 70, executeAt: .distantFuture, issuedAt: Date(), playbackState: .paused)))
        f.socket.emit(.actionResult(requestId: seek.requestId, action: "transport_request", status: "applied"))
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 3 }
        let controls = f.socket.sent.filter { $0.type == "transport_request" }
        XCTAssertEqual(controls.map(\.action), [.seek, .pause, .play])
        XCTAssertEqual(Set(controls.compactMap(\.requestId)).count, 3)
        XCTAssertFalse(f.session.workStatusMessage?.contains("not sent") == true)
    }

    func testUnconfirmedSeekCommitExpiresWithoutSendingFollowingControls() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.seek(70)))
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        XCTAssertTrue(playback.request(.pause))
        f.socket.holdTransportSend = true
        f.clock.advance(0.251)
        await waitUntil { f.socket.transportWaiters.count == 1 }
        var committed = try XCTUnwrap(f.session.room)
        committed.generation += 1; committed.anchorPositionSeconds = 70
        f.socket.emit(.snapshot(committed))
        await waitUntil { f.session.room?.generation == committed.generation }
        f.socket.holdTransportSend = false
        f.socket.transportWaiters.removeFirst().resume()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
        f.clock.advance(5.1)
        await waitUntil { f.session.workStatusMessage?.contains("Later controls were not sent") == true }
        XCTAssertTrue(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
    }

    func testIndependentChangeAfterOwnSeekAppliedStillFencesFollowingControls() async throws {
        for change in ["generation", "generation-before-result", "session", "authority"] {
            let gate = ValidationGate()
            let (f, playback) = try await playingFixture(validationGate: gate)
            XCTAssertTrue(playback.request(.seek(70)))
            await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
            XCTAssertTrue(playback.request(.pause))
            f.socket.holdTransportSend = true
            f.clock.advance(0.251)
            await waitUntil { f.socket.transportWaiters.count == 1 }
            let seek = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" })
            var committed = try XCTUnwrap(f.session.room)
            committed.generation += 1; committed.anchorPositionSeconds = 70
            f.socket.emit(.snapshot(committed))
            f.socket.emit(.transport(.init(commandId: "own-seek-command", sessionId: "synthetic-playback", selectionRevision: 1,
                action: .seek, positionSeconds: 70, executeAt: .distantFuture, issuedAt: Date(), playbackState: .paused)))
            if change == "generation-before-result" {
                committed.generation += 1
                f.socket.emit(.snapshot(committed))
            }
            f.socket.emit(.actionResult(requestId: seek.requestId, action: "transport_request", status: "applied"))
            f.socket.emit(.error(.init(code: "synthetic_marker", message: "own seek applied")))
            await waitUntil { f.session.errorMessage == "own seek applied" }
            if change == "session" { playback.replaceSession() }
            else if change != "generation-before-result" {
                committed.generation += 1
                if change == "authority" { committed.selfCanControlTransport = false }
                f.socket.emit(.snapshot(committed))
                await waitUntil { f.session.room?.generation == committed.generation }
            }
            f.socket.holdTransportSend = false
            f.socket.transportWaiters.removeFirst().resume()
            await waitUntil { f.session.workStatusMessage?.contains("not sent") == true }
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1, change)
        }
    }

    func testSeekWindowKeepsLatestTargetAndEveryDistinctFollowingControlInOrder() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.seek(70)))
        let deadline = f.clock.now + 0.25
        await waitUntil { f.clock.hasDeadline(deadline) }
        f.clock.advance(0.05)
        XCTAssertTrue(playback.request(.pause))
        f.clock.advance(0.05)
        XCTAssertTrue(playback.request(.seek(80)))
        f.clock.advance(0.05)
        XCTAssertTrue(playback.request(.play))
        f.clock.advance(0.05)
        XCTAssertTrue(playback.request(.pause))
        f.clock.advance(0.04)
        XCTAssertTrue(playback.request(.seek(90)))
        XCTAssertEqual(playback.heldTarget, 90)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
        f.clock.advance(0.011)
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 4 }
        let messages = f.socket.sent.filter { $0.type == "transport_request" }
        XCTAssertEqual(messages.map(\.action), [.seek, .pause, .play, .pause])
        XCTAssertEqual(messages.first?.positionSeconds, 90)
        XCTAssertEqual(Set(messages.compactMap(\.requestId)).count, 4)
        XCTAssertTrue(playback.request(.seek(100)))
        let nextDeadline = f.clock.now + 0.25
        await waitUntil { f.clock.hasDeadline(nextDeadline) }
        f.clock.advance(0.249)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 4)
        f.clock.advance(0.002)
        await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 5 }
        XCTAssertEqual(f.socket.sent.last { $0.type == "transport_request" }?.positionSeconds, 100)
    }

    func testAuthorityChangeDiscardsSeekAndFollowingControlsWithoutReplay() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.seek(70)))
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        XCTAssertTrue(playback.request(.pause))
        let releases = playback.releases
        var room = try XCTUnwrap(f.session.room)
        room.generation += 1
        f.socket.emit(.snapshot(room))
        await waitUntil { f.session.room?.generation == room.generation }
        XCTAssertNil(playback.heldTarget)
        XCTAssertEqual(playback.releases, releases + 1)
        XCTAssertTrue(f.session.workStatusMessage?.contains("not sent") == true)
        f.clock.advance(0.3)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
    }

    func testOldLobbyFailureAfterRealLeaveAndJoinCannotEraseReplacementDesire() async throws {
        // Include a replacement with the same bool: value equality is not ownership.
        for replacement in [false, true] {
            let f = try await fixture()
            f.socket.holdNextLobbySend = true
            f.session.setLobbyReady(true)
            await waitUntil { f.socket.lobbyWaiters.count == 1 }
            f.session.leaveRoom()
            XCTAssertEqual(f.session.connection, .idle)
            let joined = await f.session.join(code: "TESTROOM")
            XCTAssertTrue(joined)
            await waitUntil { f.socket.connections == 2 && f.session.connection == .connected }
            f.session.setLobbyReady(replacement)
            await waitUntil { f.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
            let current = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
            let status = f.session.workStatusMessage
            let reads = f.stub.requestedPaths.filter { $0 == "/api/v2/watch-together/rooms/synthetic-room" }.count
            f.socket.lobbyWaiters.removeFirst().resume(throwing: WatchPartySocketError.closed)
            await waitUntil { f.socket.lobbyCompletions == 1 }
            for _ in 0..<30 { await Task.yield() }
            XCTAssertFalse(f.socket.lobbyCompletionWasCancelled)
            XCTAssertEqual(f.session.lobbyReadyDesired, replacement)
            XCTAssertEqual(f.session.workStatusMessage, status)
            XCTAssertEqual(f.stub.requestedPaths.filter { $0 == "/api/v2/watch-together/rooms/synthetic-room" }.count, reads)
            f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: current.requestId,
                retryAfterMilliseconds: 1000, workStarted: false)))
            await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
            f.clock.advance(0.9)
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(f.socket.sent.filter { $0.type == "lobby_ready" }.count, 2)
            f.clock.advance(0.6)
            await waitUntil { f.socket.sent.filter { $0.type == "lobby_ready" }.count == 3 }
            let retry = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
            XCTAssertEqual(retry.ready, replacement)
            f.socket.emit(.actionResult(requestId: retry.requestId, action: "lobby_ready", status: "applied"))
            await waitUntil { f.session.lobbyReadyDesired == nil }
        }
    }

    func testOlderLobbyFailureCannotOwnANewerToggleBackToTheSameValue() async throws {
        let f = try await fixture()
        f.socket.holdNextLobbySend = true
        f.session.setLobbyReady(true)
        await waitUntil { f.socket.lobbyWaiters.count == 1 }
        let old = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
        f.session.setLobbyReady(false)
        f.session.setLobbyReady(true)
        let status = f.session.workStatusMessage
        let reads = f.stub.requestedPaths.count
        f.socket.lobbyWaiters.removeFirst().resume(throwing: WatchPartySocketError.closed)
        await waitUntil { f.socket.lobbyCompletions == 1 }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.session.lobbyReadyDesired, true)
        XCTAssertEqual(f.session.workStatusMessage, status)
        XCTAssertEqual(f.stub.requestedPaths.count, reads)
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: old.requestId,
            retryAfterMilliseconds: 250, workStarted: false)))
        await waitUntil { f.session.workStatusMessage?.contains("delayed") == true }
        f.clock.advance(0.5)
        await waitUntil { f.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
        let retry = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
        XCTAssertEqual(retry.ready, true)
    }

    func testCurrentLobbyFailureStillReconcilesAndNeverMarksReadinessSaved() async throws {
        let f = try await fixture()
        f.socket.holdNextLobbySend = true
        f.session.setLobbyReady(true)
        await waitUntil { f.socket.lobbyWaiters.count == 1 }
        let reads = f.stub.requestedPaths.filter { $0 == "/api/v2/watch-together/rooms/synthetic-room" }.count
        f.socket.lobbyWaiters.removeFirst().resume(throwing: WatchPartySocketError.closed)
        await waitUntil { f.session.lobbyReadyDesired == nil && f.session.workStatusMessage?.contains("could not be confirmed") == true }
        await waitUntil { f.stub.requestedPaths.filter { $0 == "/api/v2/watch-together/rooms/synthetic-room" }.count == reads + 1 }
        XCTAssertFalse(f.session.room?.members.first(where: \.isSelf)?.lobbyReady ?? true)
        f.clock.advance(0.5)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "lobby_ready" }.count, 1)
    }

    func testReportEchoCannotEraseFreshGenerationDiscardNotice() async throws {
        let (f, playback) = try await playingFixture()
        f.socket.emit(.transport(.init(commandId: "synthetic-command", sessionId: "synthetic-playback", selectionRevision: 1,
            action: .pause, positionSeconds: 30, executeAt: .distantPast, issuedAt: Date(), playbackState: .paused)))
        await waitUntil { !playback.appliedActions.isEmpty }
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        f.clock.advance(0.5)
        await waitUntil { f.socket.sent.contains { $0.type == "state_report" } }
        XCTAssertTrue(playback.request(.seek(70)))
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        let releases = playback.releases
        var room = try XCTUnwrap(f.session.room)
        room.generation += 1
        room.members[1].isReady = true
        f.socket.emit(.snapshot(room))
        await waitUntil { f.session.room?.generation == room.generation }
        XCTAssertNil(playback.heldTarget)
        XCTAssertEqual(playback.releases, releases + 1)
        XCTAssertTrue(f.session.workStatusMessage?.contains("not sent") == true)
        f.clock.advance(0.3)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
    }

    func testSameGenerationReportEchoKeepsTheQueuedSeekEligible() async throws {
        let (f, playback) = try await playingFixture()
        f.socket.emit(.transport(.init(commandId: "synthetic-command", sessionId: "synthetic-playback", selectionRevision: 1,
            action: .pause, positionSeconds: 30, executeAt: .distantPast, issuedAt: Date(), playbackState: .paused)))
        await waitUntil { !playback.appliedActions.isEmpty }
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.5) }
        f.clock.advance(0.5)
        await waitUntil { f.socket.sent.contains { $0.type == "state_report" } }
        XCTAssertTrue(playback.request(.seek(70)))
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        let releases = playback.releases
        let generation = try XCTUnwrap(f.session.room?.generation)
        f.socket.emit(.snapshot(try XCTUnwrap(f.session.room)))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.session.room?.generation, generation)
        XCTAssertEqual(playback.heldTarget, 70)
        XCTAssertEqual(playback.releases, releases)
        f.clock.advance(0.251)
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
    }

    func testOldLobbySnapshotCannotSaveUnsentOppositeReplacement() async throws {
        let gate = ValidationGate()
        let f = try await fixture(validationGate: gate)
        f.session.setLobbyReady(true)
        await waitUntil { f.socket.sent.contains { $0.type == "lobby_ready" } }
        let older = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
        gate.holding = true
        f.session.setLobbyReady(false)
        // The queued old snapshot is not an acknowledgement of the unsent false.
        f.socket.emit(.snapshot(try XCTUnwrap(f.session.room)))
        await waitUntil { !gate.waiters.isEmpty }
        gate.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.session.lobbyReadyDesired, false)
        XCTAssertEqual(f.socket.sent.filter { $0.type == "lobby_ready" }.count, 1)
        var committed = try XCTUnwrap(f.session.room)
        committed.members[1].lobbyReady = true; committed.generation += 1
        f.socket.emit(.snapshot(committed))
        f.socket.emit(.actionResult(requestId: older.requestId, action: "lobby_ready", status: "applied"))
        await waitUntil { f.session.room?.members[1].lobbyReady == true }
        XCTAssertEqual(f.session.lobbyReadyDesired, false, "Older commit/result must not confirm its replacement")
        f.clock.advance(0.5)
        await waitUntil { f.socket.sent.filter { $0.type == "lobby_ready" }.count == 2 }
        let replacement = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
        XCTAssertEqual(replacement.ready, false)
        f.socket.emit(.actionResult(requestId: replacement.requestId, action: "lobby_ready", status: "applied"))
        await waitUntil { f.session.lobbyReadyDesired == nil }
    }

    func testTwoLobbyWritersAcrossControlledValidationBarrierSendOnlyOneCurrentDesire() async throws {
        let gate = ValidationGate()
        let f = try await fixture(validationGate: gate)
        gate.holding = true
        f.session.setLobbyReady(true)
        await waitUntil { gate.waiters.count == 1 }
        f.clock.advance(0.5)
        await waitUntil { gate.waiters.count == 2 }
        // Resume the periodic loop's identity check, parking it again inside
        // sendReport alongside the setter's already suspended sendReport.
        gate.waiters.removeLast().resume()
        await waitUntil { gate.waiters.count == 2 }
        gate.release()
        await waitUntil { f.socket.sent.contains { $0.type == "lobby_ready" } }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "lobby_ready" }.count, 1)
        let only = try XCTUnwrap(f.socket.sent.last { $0.type == "lobby_ready" })
        f.socket.emit(.actionResult(requestId: only.requestId, action: "lobby_ready", status: "applied"))
        await waitUntil { f.session.lobbyReadyDesired == nil }
    }

    func testSessionReplacementDiscardsQueuedSeekAndReleasesHeldTargetWithoutReplay() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.seek(70)))
        XCTAssertEqual(playback.heldTarget, 70)
        await waitUntil { f.clock.hasDeadline(f.clock.now + 0.25) }
        let releases = playback.releases
        playback.replaceSession()
        XCTAssertNil(playback.heldTarget)
        XCTAssertEqual(playback.releases, releases + 1)
        XCTAssertTrue(f.session.workStatusMessage?.contains("not sent") == true)
        XCTAssertFalse(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        f.clock.advance(0.3)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
    }

    func testLateRefusalsRetryOnlyNewestDispatchedIntentInEitherRefusalOrder() async throws {
        for reversed in [false, true] {
            let (f, playback) = try await playingFixture()
            XCTAssertTrue(playback.request(.play))
            await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 1 }
            XCTAssertTrue(playback.request(.pause))
            await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 2 }
            let originals = f.socket.sent.filter { $0.type == "transport_request" }
            for message in reversed ? Array(originals.reversed()) : originals {
                f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: message.requestId,
                    retryAfterMilliseconds: 250, workStarted: false)))
            }
            // An ordered stream marker proves both preceding refusals were handled.
            f.socket.emit(.error(.init(code: "synthetic_marker", message: "refusals processed")))
            await waitUntil { f.session.errorMessage == "refusals processed" }
            f.clock.advance(0.5)
            await waitUntil { f.socket.sent.filter { $0.type == "transport_request" }.count == 3 && f.clock.hasDeadline(f.clock.now + 0.5) }
            let sent = f.socket.sent.filter { $0.type == "transport_request" }
            XCTAssertEqual(sent.map(\.action), [.play, .pause, .pause])
            XCTAssertEqual(sent.map(\.requestId), [originals[0].requestId, originals[1].requestId, originals[1].requestId])
        }
    }

    func testDisconnectWhileSelectedRetryValidatesShowsNotSentAndDoesNotReplay() async throws {
        let gate = ValidationGate()
        let (f, playback) = try await playingFixture(validationGate: gate)
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let id = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" }?.requestId)
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: id,
            retryAfterMilliseconds: 250, workStarted: false)))
        f.socket.emit(.error(.init(code: "synthetic_marker", message: "refusal processed")))
        await waitUntil { f.session.errorMessage == "refusal processed" }
        gate.holding = true
        f.clock.advance(0.5)
        await waitUntil { gate.waiters.count == 1 }
        gate.resumeFirst() // Reporting's outer identity check.
        await waitUntil { gate.waiters.count == 1 } // Selected retry's final validation.
        f.socket.finish(WatchPartySocketError.closed)
        await waitUntil { f.session.connection == .reconnecting }
        XCTAssertTrue(f.session.workStatusMessage?.contains("not sent") == true)
        XCTAssertFalse(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        gate.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 1)
    }

    func testDisconnectAfterRetrySendBeginsKeepsUncertaintyWithoutAnotherReplay() async throws {
        let (f, playback) = try await playingFixture()
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.socket.sent.contains { $0.type == "transport_request" } }
        let id = try XCTUnwrap(f.socket.sent.last { $0.type == "transport_request" }?.requestId)
        f.socket.emit(.error(.init(code: "realtime_rate_limited", message: "Synthetic busy", requestId: id,
            retryAfterMilliseconds: 250, workStarted: false)))
        f.socket.emit(.error(.init(code: "synthetic_marker", message: "refusal processed")))
        await waitUntil { f.session.errorMessage == "refusal processed" }
        f.socket.holdTransportSend = true
        f.clock.advance(0.5)
        await waitUntil { f.socket.transportWaiters.count == 1 }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 2)
        f.socket.finish(WatchPartySocketError.closed)
        await waitUntil { f.session.connection == .reconnecting }
        XCTAssertTrue(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        f.socket.holdTransportSend = false
        f.socket.transportWaiters.removeFirst().resume()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(f.socket.sent.filter { $0.type == "transport_request" }.count, 2)
    }

    func testClosingFailedTransportUsesReconnectReadWithoutStandaloneReconciliation() async throws {
        let (f, playback) = try await playingFixture()
        let path = "/api/v2/watch-together/rooms/synthetic-room"
        let initialReads = f.stub.requests.filter { $0.path == path }.count
        f.socket.failSend = true
        XCTAssertTrue(playback.request(.pause))
        await waitUntil { f.session.connection == .reconnecting && f.clock.hasDeadline(f.clock.now + 1) }
        XCTAssertTrue(f.session.workStatusMessage?.contains("could not be confirmed") == true)
        XCTAssertEqual(f.stub.requests.filter { $0.path == path }.count, initialReads)
        f.socket.failSend = false
        f.clock.advance(1)
        await waitUntil { f.socket.connections == 2 && f.session.connection == .connected }
        XCTAssertEqual(f.stub.requests.filter { $0.path == path }.count, initialReads + 1)
        XCTAssertNil(f.session.workStatusMessage, "The current reconnect read settles uncertainty without replay")
        XCTAssertTrue(f.socket.sent.filter { $0.type == "transport_request" }.isEmpty)
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
                attachment.name = "Synthetic recovery lobby \(name) \(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                let traits = XCTAttachment(string: "Native viewport \(size); idiom \(host.traitCollection.userInterfaceIdiom.rawValue); horizontal size class \(host.traitCollection.horizontalSizeClass.rawValue)")
                traits.name = "Recovery fixture traits \(name)"
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
