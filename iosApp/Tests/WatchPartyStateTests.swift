import Foundation
import XCTest
@testable import Silo

final class WatchPartyStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_024_000)

    private func room(generation: Int64 = 1, revision: Int64 = 1, phase: WatchPartyPhase = .playing) -> WatchPartyRoom {
        WatchPartyRoom(roomId: "room-one", phase: phase, playbackState: phase == .playing ? .playing : .idle,
            selectionRevision: revision, selectedContentId: "movie:123", selectedFileId: "42",
            isPaused: phase != .playing, anchorPositionSeconds: 100, anchorUpdatedAt: now,
            generation: generation, memberCount: 1, selfRole: .host)
    }

    private func command(id: String = "command-one", revision: Int64 = 1,
                         session: String? = nil, issued: Date? = nil,
                         playback: WatchPartyPlaybackState = .playing) -> WatchPartyTransportCommand {
        WatchPartyTransportCommand(commandId: id, sessionId: session, selectionRevision: revision,
            action: .seek, positionSeconds: 100, executeAt: now.addingTimeInterval(1),
            issuedAt: issued ?? now, playbackState: playback)
    }

    private func suggestion(id: String = "suggestion-one", voted: Bool = false, count: Int = 0) -> WatchPartySuggestion {
        WatchPartySuggestion(id: id, roomId: "room-one", suggesterUserId: "1", suggesterProfileId: "profile-one",
            contentId: "movie:123", contentType: "movie", title: "Movie", voteCount: count, votedByMe: voted, createdAt: now)
    }

    func testSocketReadinessSurvivesAnOlderSameGenerationHTTPRead() {
        var state = WatchPartyRoomState()
        XCTAssertTrue(state.accept(room()))
        let requestReceipt = state.receipt
        var socketRoom = room()
        socketRoom.attachedSessionId = "playback-one"
        socketRoom.members = [WatchPartyMember(userId: "1", profileId: "profile-one", displayName: "Viewer", isReady: true)]
        XCTAssertTrue(state.accept(socketRoom))
        XCTAssertFalse(state.accept(room(), requestReceipt: requestReceipt))
        XCTAssertEqual(state.room?.attachedSessionId, "playback-one")
        XCTAssertEqual(state.room?.members.first?.isReady, true)
        XCTAssertTrue(state.accept(room(generation: 2), requestReceipt: requestReceipt), "A newer persisted generation remains authoritative")
    }

    func testSameGenerationSocketMembershipUpdatesRemainVisible() {
        var state = WatchPartyRoomState()
        var incoming = room(phase: .lobby)
        XCTAssertTrue(state.accept(incoming))
        incoming.memberCount = 2
        incoming.members = [WatchPartyMember(userId: "1", profileId: "guest", displayName: "Guest", lobbyReady: true)]
        XCTAssertTrue(state.accept(incoming))
        XCTAssertEqual(state.room?.memberCount, 2)
        XCTAssertTrue(state.room?.members.first?.lobbyReady == true)
    }

    func testOlderGenerationRevisionAndDifferentRoomCannotReplaceCurrentRoom() {
        var state = WatchPartyRoomState()
        XCTAssertTrue(state.accept(room(generation: 4, revision: 3)))
        XCTAssertFalse(state.accept(room(generation: 3, revision: 3)))
        XCTAssertFalse(state.accept(room(generation: 5, revision: 2)))
        var other = room(generation: 5, revision: 4)
        other.roomId = "other-room"
        XCTAssertFalse(state.accept(other))
        XCTAssertEqual(state.room?.generation, 4)
        XCTAssertEqual(state.room?.selectionRevision, 3)
    }

    func testTerminalStateCannotBeRevivedByQueuedSnapshots() {
        for explicitClose in [false, true] {
            var state = WatchPartyRoomState()
            XCTAssertTrue(state.accept(room()))
            if explicitClose { state.end() }
            else { XCTAssertTrue(state.accept(room(generation: 2, revision: 2, phase: .ended))) }
            XCTAssertTrue(state.terminal)
            XCTAssertFalse(state.accept(room(generation: 3, revision: 3)))
        }
    }

    func testCommandsRejectWrongEpochSessionDuplicateAndOldIssuedTime() {
        var state = WatchPartyCommandState()
        let currentRoom = room()
        XCTAssertFalse(state.receive(command(revision: 2), room: currentRoom, sessionId: "session-one"))
        XCTAssertFalse(state.receive(command(session: "session-two"), room: currentRoom, sessionId: "session-one"))
        XCTAssertFalse(state.receive(command(), room: room(phase: .lobby), sessionId: "session-one"))
        XCTAssertTrue(state.receive(command(), room: currentRoom, sessionId: "session-one"), "Untargeted commands apply to any attached session")
        XCTAssertFalse(state.receive(command(), room: currentRoom, sessionId: "session-one"))
        XCTAssertFalse(state.receive(command(id: "older", issued: now.addingTimeInterval(-1)), room: currentRoom, sessionId: "session-one"))
        XCTAssertTrue(state.receive(command(id: "newer", issued: now.addingTimeInterval(1)), room: currentRoom, sessionId: "session-one"))
        XCTAssertEqual(state.pending?.commandId, "newer")
        state.complete("command-one")
        XCTAssertEqual(state.pending?.commandId, "newer", "Finishing an obsolete command cannot clear its replacement")
        state.complete("newer")
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.completed?.commandId, "newer")
    }

    func testUnknownCommandSemanticsAndInvalidPositionsCannotMovePlayback() {
        var state = WatchPartyCommandState()
        var candidate = command()
        candidate.action = .unknown("future_action")
        XCTAssertFalse(state.receive(candidate, room: room(), sessionId: nil))
        candidate = command()
        candidate.playbackState = .unknown("future_state")
        XCTAssertFalse(state.receive(candidate, room: room(), sessionId: nil))
        for position in [Double(-1), .infinity, .nan] {
            candidate = command()
            candidate.positionSeconds = position
            XCTAssertFalse(state.receive(candidate, room: room(), sessionId: nil))
        }
    }

    func testLatePlayingCommandsAdvanceFromExecutionTimeButWaitingAndPausedDoNot() {
        let late = now.addingTimeInterval(3.5)
        XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(), serverNow: late), 102.5, accuracy: 0.001)
        XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(), serverNow: now), 100, accuracy: 0.001)
        for playback in [WatchPartyPlaybackState.waiting, .paused] {
            XCTAssertEqual(WatchPartyCommandState.projectedPosition(command(playback: playback), serverNow: late), 100, accuracy: 0.001)
        }
    }

    func testWaitingPauseDoesNotRequireSeekAccuracyButWaitingSeekDoes() {
        var completed = command(playback: .waiting)
        completed.action = .pause
        XCTAssertTrue(WatchPartyCommandState.canAcknowledge(completed, roomPlaybackState: .waiting,
            sourceTime: 101.5, isHost: false), "A small pause correction outside the seekable window must not hold the readiness barrier")
        completed.action = .seek
        XCTAssertFalse(WatchPartyCommandState.canAcknowledge(completed, roomPlaybackState: .waiting,
            sourceTime: 101.5, isHost: false), "A guest must still land within one second of an explicit seek")
        XCTAssertTrue(WatchPartyCommandState.canAcknowledge(completed, roomPlaybackState: .waiting,
            sourceTime: 101, isHost: false))
        XCTAssertTrue(WatchPartyCommandState.canAcknowledge(completed, roomPlaybackState: .waiting,
            sourceTime: 115, isHost: true))
        XCTAssertFalse(WatchPartyCommandState.canAcknowledge(completed, roomPlaybackState: .waiting,
            sourceTime: 115.1, isHost: true))
        XCTAssertFalse(WatchPartyCommandState.canAcknowledge(nil, roomPlaybackState: .waiting,
            sourceTime: 100, isHost: false), "An unapplied command cannot satisfy readiness")
    }

    func testReadinessIsSentOnlyAtABarrierOrWhileCatchingUp() {
        let me = WatchPartyMember(userId: "1", profileId: "p", displayName: "Me", isSelf: true, connected: true)
        var waiting = room()
        waiting.playbackState = .waiting
        waiting.members = [me]
        XCTAssertTrue(WatchPartyCommandState.awaitsReadiness(waiting))
        waiting.members[0].isReady = true
        XCTAssertFalse(WatchPartyCommandState.awaitsReadiness(waiting), "An acknowledged member does not repeat ready")

        var playing = room()
        playing.members = [me]
        XCTAssertFalse(WatchPartyCommandState.awaitsReadiness(playing),
            "A late joiner in a playing room is marked ready by a matching report; a ready would resync it again")
        playing.selfIgnoreWait = true
        XCTAssertTrue(WatchPartyCommandState.awaitsReadiness(playing), "A member the room resumed without acknowledges recovery")
        playing.selfIgnoreWait = false
        playing.members[0].isBuffering = true
        XCTAssertTrue(WatchPartyCommandState.awaitsReadiness(playing), "A member reported buffering acknowledges recovery")
        playing.playbackState = .paused
        XCTAssertTrue(WatchPartyCommandState.awaitsReadiness(playing))
        playing.phase = .lobby
        XCTAssertFalse(WatchPartyCommandState.awaitsReadiness(playing))
    }

    func testOutboundPingPreservesFractionalTimeForClockSynchronization() throws {
        let sentAt = now.addingTimeInterval(0.875)
        let wire = try WatchPartyClientMessage(type: "ping", clientSentAt: sentAt).encoded()
        struct Ping: Decodable { let type: String; let clientSentAt: Date }
        let decoded = try HTTPClient.makeJSONDecoder().decode(Ping.self, from: Data(wire.utf8))
        XCTAssertEqual(decoded.type, "ping")
        XCTAssertEqual(decoded.clientSentAt.timeIntervalSince(sentAt), 0, accuracy: 0.001,
                       "Rounding the echoed send time to a second corrupts the midpoint clock offset")
    }

    func testSharedVoteBroadcastCannotOverwritePersonalVotes() {
        var votes = WatchPartyVotes()
        XCTAssertTrue(votes.reconcile([suggestion(voted: true, count: 1)], requestedAt: votes.revision))
        votes.receive([suggestion(voted: false, count: 4), suggestion(id: "new", voted: true, count: 1)])
        XCTAssertTrue(votes.rows[0].votedByMe)
        XCTAssertEqual(votes.rows[0].voteCount, 4)
        XCTAssertFalse(votes.rows[1].votedByMe, "A shared broadcast cannot claim a personal vote on a new row")
    }

    func testStaleVoteReadsCannotEraseNewRowsOrUndoUserMutation() {
        var votes = WatchPartyVotes()
        let readRevision = votes.revision
        votes.receive([suggestion(), suggestion(id: "new")])
        XCTAssertFalse(votes.reconcile([suggestion(voted: true)], requestedAt: readRevision))
        XCTAssertEqual(votes.rows.map(\.id), ["suggestion-one", "new"])
        let beforeMutation = votes.revision
        votes.invalidatePersonalReads()
        XCTAssertFalse(votes.reconcile([suggestion()], requestedAt: beforeMutation))
        XCTAssertTrue(votes.reconcile([suggestion(voted: true)], requestedAt: votes.revision))
        XCTAssertEqual(votes.personal["suggestion-one"], true)
    }

    @MainActor
    func testPlaybackContextRequiresPlayingAndUsesRoomPositionForSoloHostRejoin() throws {
        let staged = room(revision: 8, phase: .lobby)
        XCTAssertNil(WatchPartySession.playbackContext(for: staged, elapsedSinceSnapshot: 5))
        var playing = room(revision: 9)
        let context = try XCTUnwrap(WatchPartySession.playbackContext(for: playing, elapsedSinceSnapshot: 5))
        XCTAssertEqual(context.startPosition, 105, accuracy: 0.001)
        XCTAssertEqual(context.fileId, 42)
        XCTAssertEqual(context.selectionRevision, 9)
        playing.isPaused = true
        XCTAssertEqual(WatchPartySession.playbackContext(for: playing, elapsedSinceSnapshot: 5)?.startPosition, 100)
        playing.selectedFileId = nil
        XCTAssertNil(WatchPartySession.playbackContext(for: playing))
    }

    @MainActor
    func testSnapshotAnchorIsAlreadyProjectedToItsBuildTime() throws {
        // The server sends expectedPosition(now) as anchor_position_seconds but
        // keeps anchor_updated_at at the last re-anchor. A viewer joining 40
        // minutes after that re-anchor starts at the reported position, not
        // 40 minutes further on.
        var playing = room()
        playing.anchorPositionSeconds = 2_500
        playing.anchorUpdatedAt = Date().addingTimeInterval(-40 * 60)
        let context = try XCTUnwrap(WatchPartySession.playbackContext(for: playing))
        XCTAssertEqual(context.startPosition, 2_500, accuracy: 0.001)
    }

    @MainActor
    func testStopStartSameContentCreatesANewPlaybackEpoch() throws {
        var state = WatchPartyRoomState()
        let first = room(generation: 2, revision: 1)
        XCTAssertTrue(state.accept(first))
        let firstContext = try XCTUnwrap(WatchPartySession.playbackContext(for: first))
        let stopped = room(generation: 3, revision: 2, phase: .lobby)
        XCTAssertTrue(state.accept(stopped))
        XCTAssertNil(WatchPartySession.playbackContext(for: stopped))
        let restarted = room(generation: 4, revision: 3)
        XCTAssertTrue(state.accept(restarted))
        let nextContext = try XCTUnwrap(WatchPartySession.playbackContext(for: restarted))
        XCTAssertEqual(firstContext.contentId, nextContext.contentId)
        XCTAssertNotEqual(firstContext, nextContext)
    }

    func testObservedDevSocketFramesDecodeNumericMembersReadinessAndFractionalPong() throws {
        // Observed shared-dev frames captured 2026-09-22; identities were
        // replaced and invite/room credentials omitted before adding the fixture.
        let snapshot = #"{"room":{"room_id":"00000000-0000-4000-8000-000000000001","phase":"lobby","playback_state":"idle","selection_mode":"host_pick","selection_revision":0,"code":"TESTROOM","guest_control_policy":"host_only","is_paused":true,"anchor_position_seconds":0,"anchor_updated_at":"2026-09-22T00:09:44Z","generation":1,"member_count":2,"host_connected":true,"self_role":"guest","self_can_control_transport":false,"self_can_manage_room":false,"self_ignore_wait":false,"members":[{"user_id":1,"profile_id":"profile-host","display_name":"Test Host","is_host":true,"is_self":false,"connected":true,"lobby_ready":false},{"user_id":1,"profile_id":"profile-guest","display_name":"Test Guest","is_host":false,"is_self":true,"connected":true,"lobby_ready":true}]},"type":"snapshot"}"#
        let decoder = HTTPClient.makeJSONDecoder()
        guard case .snapshot(let decoded) = try decoder.decode(WatchPartyServerMessage.self, from: Data(snapshot.utf8)) else {
            return XCTFail("Expected observed snapshot")
        }
        XCTAssertEqual(decoded.members.map(\.userId), ["1", "1"])
        XCTAssertEqual(decoded.members.map(\.id), ["1:profile-host", "1:profile-guest"])
        XCTAssertTrue(decoded.members[1].lobbyReady)
        XCTAssertFalse(decoded.members[1].isReady)
        let pong = #"{"client_sent_at":"2026-09-22T00:09:45.037Z","server_received_at":"2026-09-22T00:09:45.074218282Z","server_sent_at":"2026-09-22T00:09:45.074224932Z","type":"pong"}"#
        guard case .pong(let client, let received, let sent) = try decoder.decode(WatchPartyServerMessage.self, from: Data(pong.utf8)) else {
            return XCTFail("Expected observed pong")
        }
        XCTAssertEqual(received.timeIntervalSince(client), 0.037218282, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(sent, received)
        let closed = #"{"reason":"host_left","type":"room_closed"}"#
        guard case .closed(let reason) = try decoder.decode(WatchPartyServerMessage.self, from: Data(closed.utf8)) else {
            return XCTFail("Expected observed terminal frame")
        }
        XCTAssertEqual(reason, "host_left")
    }

    func testInvitationAuthorityIncludesDeploymentPathAndRejectsCredentials() throws {
        XCTAssertTrue(WatchPartyLobbyPolicy.sameServer("https://SILO.example/base/", "https://silo.example:443/base"))
        XCTAssertFalse(WatchPartyLobbyPolicy.sameServer("https://silo.example/base", "https://silo.example/other"))
        XCTAssertFalse(WatchPartyLobbyPolicy.sameServer("http://silo.example/base", "https://silo.example/base"))
        XCTAssertFalse(WatchPartyLobbyPolicy.sameServer("https://user@silo.example/base", "https://silo.example/base"))
        XCTAssertFalse(WatchPartyLobbyPolicy.sameServer("https://silo.example/base?tenant=other", "https://silo.example/base"))
        let url = try XCTUnwrap(WatchPartyLobbyPolicy.inviteURL(path: "/rooms/join?token=invitation-proof", serverURL: "https://silo.example/base/"))
        let invitation = try XCTUnwrap(WatchPartyInvitation(url: url))
        XCTAssertEqual(invitation.serverURL, "https://silo.example/base")
        XCTAssertEqual(invitation.joinToken, "invitation-proof")
        XCTAssertNil(WatchPartyLobbyPolicy.inviteURL(path: "https://other.example/rooms/join?token=proof", serverURL: "https://silo.example"))
        XCTAssertNil(WatchPartyLobbyPolicy.inviteURL(path: "//other.example/rooms/join?token=proof", serverURL: "https://silo.example"))
        XCTAssertNil(WatchPartyLobbyPolicy.inviteURL(path: "/rooms/join?token=one&token=two", serverURL: "https://silo.example"))
    }

    func testVoteWinnerNeedsVotesAndUsesStableTieBreaks() {
        XCTAssertNil(WatchPartyLobbyPolicy.voteWinner([suggestion()]))
        var first = suggestion(id: "a", count: 2)
        first.createdAt = now.addingTimeInterval(-1)
        let later = suggestion(id: "b", count: 2)
        XCTAssertEqual(WatchPartyLobbyPolicy.voteWinner([later, first])?.id, "a")
        XCTAssertEqual(WatchPartyLobbyPolicy.voteWinner([first, suggestion(id: "popular", count: 3)])?.id, "popular")
        XCTAssertEqual(WatchPartyLobbyPolicy.voteWinner([suggestion(id: "b", count: 2), suggestion(id: "a", count: 2)])?.id, "a")
    }

    func testMemberStateBatchDeduplicatesAndHonorsBothAdvertisedAndWireLimits() {
        let ids = [""] + ["movie:0", "movie:0"] + (1...250).map { "movie:\($0)" }
        let wireLimited = WatchPartyLobbyPolicy.memberStateIDs(ids, maximum: 500)
        XCTAssertEqual(wireLimited.count, 200)
        XCTAssertEqual(wireLimited.first, "movie:0")
        XCTAssertEqual(wireLimited.last, "movie:199")
        XCTAssertEqual(WatchPartyLobbyPolicy.memberStateIDs(ids, maximum: 2), ["movie:0", "movie:1"])
        XCTAssertTrue(WatchPartyLobbyPolicy.memberStateIDs(ids, maximum: 0).isEmpty)
    }

    func testSuggestionRemovalUsesBothUserAndProfileIdentity() {
        var current = room(phase: .lobby)
        current.selfRole = .guest
        current.members = [WatchPartyMember(userId: "1", profileId: "profile-one", displayName: "Viewer", isSelf: true)]
        XCTAssertTrue(WatchPartyLobbyPolicy.canRemove(suggestion(), room: current))
        current.members[0].profileId = "another-profile"
        XCTAssertFalse(WatchPartyLobbyPolicy.canRemove(suggestion(), room: current))
        current.members[0].profileId = "profile-one"
        current.members[0].userId = "2"
        XCTAssertFalse(WatchPartyLobbyPolicy.canRemove(suggestion(), room: current))
        current.selfCanManageRoom = true
        XCTAssertTrue(WatchPartyLobbyPolicy.canRemove(suggestion(), room: current))
        current.roomId = "other-room"
        XCTAssertFalse(WatchPartyLobbyPolicy.canRemove(suggestion(), room: current))
        current.roomId = "room-one"
        current.phase = .ended
        XCTAssertFalse(WatchPartyLobbyPolicy.canRemove(suggestion(), room: current))
    }



    private var sessionCapabilities: String {
        #"{"revision":"test","state":"available","allowed":true,"socket_protocol":"silo.room.v2","connection_replaced":true,"staged_selection":true,"protocol_versions":[3],"features":["watch_party_coordinator_v1","fixed_media_file_v1"],"deliveries":[]}"#
    }

    @MainActor
    private func sessionClient(urlSession: URLSession) async throws -> WatchPartySession {
        let name = "WatchPartyStateTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "party-server")
        await tokens.setServerUrl("https://party.example")
        await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: urlSession, tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        return WatchPartySession(api: api, tokenStore: tokens,
            recentStore: WatchPartyRecentStore(keychain: SharedKeychain(service: name, accessGroup: nil)))
    }

    @MainActor
    func testLeavingDuringCapabilitiesReadCannotCreateOrReenterRoom() async throws {
        let stub = APIv2TestStub()
        stub.reply(200, sessionCapabilities)
        let session = try await sessionClient(urlSession: stub.makeSession())
        stub.hold()
        let pending = Task { await session.create() }
        await stub.waitUntilHeld()
        XCTAssertTrue(session.isBusy)
        session.leave()
        stub.release()
        let entered = await pending.value
        XCTAssertFalse(entered)
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.room)
        XCTAssertTrue(stub.requests.allSatisfy { $0.method == "GET" && $0.path.hasSuffix("/capabilities") })
    }

    @MainActor
    func testConcurrentJoinDoesNotDispatchASecondEntry() async throws {
        let stub = APIv2TestStub()
        stub.reply(200, sessionCapabilities)
        stub.reply(path: "/api/v2/watch-together/join", 400, #"{"type":"urn:test","title":"Invalid code","status":400,"detail":"Test refusal"}"#)
        let session = try await sessionClient(urlSession: stub.makeSession())
        stub.hold()
        let pending = Task { await session.join(code: "FIRST") }
        await stub.waitUntilHeld()
        let second = await session.join(code: "SECOND")
        XCTAssertFalse(second)
        XCTAssertTrue(session.isBusy)
        stub.release()
        _ = await pending.value
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(stub.requests.filter { $0.path == "/api/v2/watch-together/join" }.count, 1)
        XCTAssertFalse(stub.requests.contains { $0.bodyString?.contains("SECOND") == true })
    }

    @MainActor
    func testForeignInvitationAndOldServerNeverDispatchRoomMutation() async throws {
        let stub = APIv2TestStub()
        let session = try await sessionClient(urlSession: stub.makeSession())
        let foreign = await session.join(invitation: "https://other.example/rooms/join?token=foreign-proof")
        XCTAssertFalse(foreign)
        XCTAssertTrue(stub.requests.isEmpty, "An invitation cannot send its proof to the currently selected unrelated server")
        stub.reply(200, sessionCapabilities.replacingOccurrences(of: #""connection_replaced":true"#, with: #""connection_replaced":false"#))
        let entered = await session.create()
        XCTAssertFalse(entered)
        XCTAssertTrue(stub.requests.allSatisfy { $0.method == "GET" })
        XCTAssertFalse(session.isEngaged)
    }

    @MainActor
    func testLostVoteReplyRefreshesPersonalVoteWithoutReplayingMutation() async throws {
        let handler = StubURLProtocol.Handler()
        let socketGate = StubURLProtocol.Gate()
        let caps = sessionCapabilities
        handler.route(StubURLProtocol.pathSuffix("/capabilities")) { _ in .json(caps) }
        var lobby = room(phase: .lobby)
        lobby.selectedContentId = nil
        lobby.selectedFileId = nil
        lobby.selfCanManageRoom = true
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let receipt = String(decoding: try encoder.encode(WatchPartyRoomResponse(room: lobby, roomAccessToken: "room-proof")), as: UTF8.self)
        handler.route(StubURLProtocol.path("/api/v2/watch-together/join")) { _ in .json(receipt) }
        handler.route(StubURLProtocol.path("/api/v2/watch-together/rooms/room-one")) { _ in .json(receipt) }
        handler.route(StubURLProtocol.pathSuffix("/ws-ticket")) { _ in
            await socketGate.wait()
            return .status(503)
        }
        let id = "96207173-607f-40a2-a9a1-ea406fb8f35d"
        let path = "/api/v2/watch-together/rooms/room-one/suggestions"
        handler.route(StubURLProtocol.method("POST", path: path)) { _ in .json(#"{"suggestion_id":"\#(id)"}"#, status: 201) }
        let before = String(decoding: try encoder.encode([suggestion(id: id)]), as: UTF8.self)
        let after = String(decoding: try encoder.encode([suggestion(id: id, voted: true, count: 1)]), as: UTF8.self)
        handler.expect(StubURLProtocol.method("GET", path: path)) { _ in .json(#"{"items":\#(before),"page":{"has_more":false}}"#) }
        handler.route(StubURLProtocol.method("GET", path: path)) { _ in .json(#"{"items":\#(after),"page":{"has_more":false}}"#) }
        handler.route(StubURLProtocol.pathSuffix("/vote")) { _ in throw URLError(.networkConnectionLost) }
        let session = try await sessionClient(urlSession: handler.makeSession())
        defer { session.leave() }
        let entered = await session.join(code: "PARTY")
        XCTAssertTrue(entered)
        try await handler.waitForRequest { $0.path.hasSuffix("/ws-ticket") }
        let added = await session.addSuggestion(WatchPartyNewSuggestion(suggestionId: id, contentId: "movie:123", contentType: "movie", title: "Movie"))
        XCTAssertTrue(added)
        XCTAssertEqual(session.votes.rows.first?.votedByMe, false)
        let voted = await session.setVote(suggestionId: id, voted: true)
        XCTAssertFalse(voted, "The mutation response was lost, so the UI must retain the failure")
        XCTAssertEqual(session.votes.rows.first?.votedByMe, true, "HTTP refresh reveals the server applied the vote")
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(handler.requests.filter { $0.path.hasSuffix("/vote") }.count, 1)
        XCTAssertEqual(handler.requests.filter { $0.method == "GET" && $0.path == path }.count, 2)
        session.leave()
        await socketGate.open()
    }

    @MainActor
    func testReconnectEndsWhenTheRoomReadReportsTheRoomClosed() async throws {
        // A member whose socket was down when the room ended never receives
        // room_closed. The server refuses the reconnect's room read with 409.
        let handler = StubURLProtocol.Handler()
        let caps = sessionCapabilities
        handler.route(StubURLProtocol.pathSuffix("/capabilities")) { _ in .json(caps) }
        var lobby = room(phase: .lobby)
        lobby.selectedContentId = nil
        lobby.selectedFileId = nil
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let receipt = String(decoding: try encoder.encode(WatchPartyRoomResponse(room: lobby, roomAccessToken: "room-proof")), as: UTF8.self)
        handler.route(StubURLProtocol.path("/api/v2/watch-together/join")) { _ in .json(receipt) }
        let roomPath = "/api/v2/watch-together/rooms/room-one"
        handler.route(StubURLProtocol.method("GET", path: roomPath)) { _ in
            .json(#"{"type":"https://silo.example/problems/conflict","title":"Conflict","status":409,"detail":"The room is closed."}"#,
                  status: 409, headers: ["Content-Type": "application/problem+json"])
        }
        let session = try await sessionClient(urlSession: handler.makeSession())
        defer { session.leave() }
        let entered = await session.join(code: "PARTY")
        XCTAssertTrue(entered)
        for _ in 0..<250 where session.connection != .ended {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.connection, .ended)
        XCTAssertFalse(session.isEngaged)
        XCTAssertEqual(session.errorMessage, "This party has ended.")
        XCTAssertNil(session.recentRoom, "An ended room is not offered for rejoin")
        XCTAssertEqual(handler.requests.filter { $0.method == "GET" && $0.path == roomPath }.count, 1)
        XCTAssertFalse(handler.requests.contains { $0.path.hasSuffix("/ws-ticket") })
    }

    @MainActor
    func testLeavingTheRoomKeepsServerSupportButAnIdentityResetDropsIt() async throws {
        let stub = APIv2TestStub()
        stub.reply(200, sessionCapabilities)
        let session = try await sessionClient(urlSession: stub.makeSession())
        await session.refreshCapabilities()
        XCTAssertEqual(session.capabilities?.supportsSocket, true)
        XCTAssertTrue(session.supportsPlayback)
        session.leaveRoom()
        XCTAssertEqual(session.capabilities?.supportsSocket, true, "Leaving the room does not change what this server supports")
        XCTAssertTrue(session.supportsPlayback)
        session.leave(forgetRecent: true)
        XCTAssertNil(session.capabilities)
        XCTAssertFalse(session.supportsPlayback)
    }

    private func recentOwner(accountID: String = "account-one", epoch: UUID = UUID(uuidString: "96207173-607f-40a2-a9a1-ea406fb8f35d")!,
                             serverID: String = "server-one", serverURL: String = "https://party.example", profileID: String = "profile-one") throws -> WatchPartyRecentOwner {
        let account = RefreshAccountIdentity(serverId: serverID, serverURL: serverURL, credentialGenerationID: UUID())
        let request = CapturedOrdinaryRequestAuth(account: account, credentialOwner: .persistentServer(serverId: serverID),
            accessToken: "must-not-persist-access", profileId: profileID, profileToken: "must-not-persist-pin")
        return try XCTUnwrap(WatchPartyRecentOwner(auth: CapturedDurableAccountAuth(accountID: accountID, accountEpoch: epoch, request: request)))
    }

    func testRecentRoomRestoresAcrossStoreInstancesOnlyForTheVerifiedOwner() throws {
        let keychain = SharedKeychain(service: "WatchPartyRecentStoreTests.\(UUID().uuidString)", accessGroup: nil)
        let store = WatchPartyRecentStore(keychain: keychain)
        defer { store.clear() }
        let owner = try recentOwner()
        let recent = WatchPartyRecentRoom(roomId: "room-one", code: "PARTYCODE", selectedTitle: "Movie")
        XCTAssertTrue(store.save(recent, owner: owner, now: now))
        let restarted = WatchPartyRecentStore(keychain: keychain)
        XCTAssertEqual(restarted.load(owner: try recentOwner(), now: now.addingTimeInterval(60)), recent,
                       "The process-local credential generation changes on restart, while the verified account epoch remains stable")
        let raw = try XCTUnwrap(keychain.get(WatchPartyRecentStore.key))
        XCTAssertFalse(raw.contains("must-not-persist"), "Access and profile verification tokens do not belong in a recent-room entry")
        for foreign in [try recentOwner(accountID: "other-account"), try recentOwner(epoch: UUID()),
                        try recentOwner(serverID: "other-server"), try recentOwner(serverURL: "https://party.example/other"),
                        try recentOwner(profileID: "other-profile")] {
            XCTAssertNil(restarted.load(owner: foreign, now: now))
        }
        XCTAssertEqual(restarted.load(owner: owner, now: now), recent)
        XCTAssertNil(restarted.load(owner: owner, now: now.addingTimeInterval(WatchPartyRecentStore.lifetime)))
        XCTAssertNil(keychain.get(WatchPartyRecentStore.key))
    }

    func testForgettingRecentRoomPreventsAnAlreadyQueuedSaveFromRestoringIt() throws {
        let keychain = SharedKeychain(service: "WatchPartyRecentStoreTests.\(UUID().uuidString)", accessGroup: nil)
        let store = WatchPartyRecentStore(keychain: keychain)
        defer { store.clear() }
        let pendingGeneration = store.writeGeneration
        store.clear()
        XCTAssertFalse(store.save(WatchPartyRecentRoom(roomId: "room-one", code: "CODE", selectedTitle: nil),
            owner: try recentOwner(), now: now, expectedGeneration: pendingGeneration))
        XCTAssertNil(keychain.get(WatchPartyRecentStore.key))
    }

    @MainActor
    func testTransientCapabilityRefreshPreservesKnownSupportForTheSameOwner() async throws {
        let stub = APIv2TestStub()
        stub.reply(200, sessionCapabilities)
        let session = try await sessionClient(urlSession: stub.makeSession())
        await session.refreshCapabilities()
        let known = try XCTUnwrap(session.capabilities)
        XCTAssertTrue(known.stagedSelection)
        XCTAssertTrue(session.supportsPlayback)
        stub.fail(.notConnectedToInternet)
        await session.refreshCapabilities()
        XCTAssertEqual(session.capabilities, known)
        XCTAssertTrue(session.supportsPlayback)
        XCTAssertNotNil(session.errorMessage)
        let entered = await session.create()
        XCTAssertFalse(entered, "A new room still requires a successful capability check")
        XCTAssertTrue(stub.requests.allSatisfy { $0.method == "GET" })
        session.leave()
    }

    @MainActor
    func testColdProfileVerificationRestoresRecentOnlyAfterMatchingIdentityReturns() async throws {
        let name = "WatchPartyColdRestoreTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let tokens = TokenStore(keychain: keychain, defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "party-server")
        await tokens.setServerUrl("https://party.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "account-one")
        await tokens.setProfileId("profile-one")
        await tokens.setProfileToken("original-pin-proof")
        let captured = await tokens.captureDurableAccountAuth()
        let durable = try XCTUnwrap(captured)
        let store = WatchPartyRecentStore(keychain: keychain)
        defer { store.clear() }
        let recent = WatchPartyRecentRoom(roomId: "room-one", code: "PARTYCODE", selectedTitle: "Movie")
        XCTAssertTrue(store.save(recent, owner: try XCTUnwrap(WatchPartyRecentOwner(auth: durable))))
        let stub = APIv2TestStub()
        stub.reply(200, sessionCapabilities)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let session = WatchPartySession(
            api: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokenStore: tokens,
            recentStore: store)
        let deactivated = await tokens.deactivateProfile(expectedAccount: durable.request.account)
        XCTAssertTrue(deactivated)
        session.leave()
        await session.refreshCapabilities()
        XCTAssertNil(session.recentRoom)
        XCTAssertTrue(stub.requests.isEmpty)
        let activated = await tokens.activateProfile(profileID: "profile-one", profileToken: "fresh-pin-proof", expectedAccount: durable.request.account)
        XCTAssertTrue(activated)
        session.leave()
        await session.refreshCapabilities()
        XCTAssertEqual(session.recentRoom, recent, "Renewed profile proof does not change the durable room owner")
        session.leave(forgetRecent: true)
        await session.refreshCapabilities()
        XCTAssertNil(session.recentRoom, "An explicit identity cleanup still removes the saved party")
        XCTAssertNil(keychain.get(WatchPartyRecentStore.key))
    }

    @MainActor
    func testUnlockingAPINProfileAgainKeepsItsRestoredRecentParty() async throws {
        let name = "WatchPartyRelockTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let tokens = TokenStore(keychain: keychain, defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "party-server")
        await tokens.setServerUrl("https://party.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "account-one")
        await tokens.setProfileId("profile-one")
        await tokens.setProfileToken("original-pin-proof")
        let captured = await tokens.captureDurableAccountAuth()
        let durable = try XCTUnwrap(captured)
        let store = WatchPartyRecentStore(keychain: keychain)
        defer { store.clear() }
        let recent = WatchPartyRecentRoom(roomId: "room-one", code: "PARTYCODE", selectedTitle: "Movie")
        XCTAssertTrue(store.save(recent, owner: try XCTUnwrap(WatchPartyRecentOwner(auth: durable))))
        let stub = APIv2TestStub()
        stub.reply(200, sessionCapabilities)
        let session = WatchPartySession(
            api: APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
                             isUpdateRequired: { false }),
            tokenStore: tokens, recentStore: store)
        await session.refreshCapabilities()
        XCTAssertEqual(session.recentRoom, recent)

        let deactivated = await tokens.deactivateProfile(expectedAccount: durable.request.account)
        XCTAssertTrue(deactivated)
        session.leave()
        let activated = await tokens.activateProfile(profileID: "profile-one", profileToken: "fresh-pin-proof",
                                                     expectedAccount: durable.request.account)
        XCTAssertTrue(activated)
        await session.refreshCapabilities()
        XCTAssertEqual(session.recentRoom, recent, "A fresh PIN proof is still the same owner")
        XCTAssertNotNil(keychain.get(WatchPartyRecentStore.key))
    }


    // MARK: - Lobby presentation policy

    private func member(_ name: String, host: Bool = false, isSelf: Bool = false, connected: Bool = true,
                        lobbyReady: Bool = false, isReady: Bool = false, buffering: Bool = false) -> WatchPartyMember {
        WatchPartyMember(userId: "1", profileId: name.lowercased(), displayName: name, isHost: host, isSelf: isSelf,
                         connected: connected, isReady: isReady, isBuffering: buffering, lobbyReady: lobbyReady)
    }

    func testSeatStateTreatsHostAsReadyAndDisconnectedAsAway() {
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Host", host: true), phase: .lobby), .ready)
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Guest"), phase: .lobby), .notReady)
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Guest", lobbyReady: true), phase: .lobby), .ready)
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Guest", connected: false, lobbyReady: true), phase: .lobby), .away)
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Guest", isReady: true), phase: .playing), .watching)
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Guest", isReady: true, buffering: true), phase: .playing), .buffering)
        XCTAssertEqual(WatchPartyLobbyPolicy.seatState(member("Guest"), phase: .playing), .joining)
    }

    func testPresenceSummaryCountsOnlyConnectedMembers() {
        let members = [member("Host", host: true), member("A", lobbyReady: true), member("B"), member("C", connected: false, lobbyReady: true)]
        XCTAssertEqual(WatchPartyLobbyPolicy.presenceSummary(members: members, phase: .lobby), "2 of 3 ready")
        XCTAssertEqual(WatchPartyLobbyPolicy.presenceSummary(members: [member("Host", host: true)], phase: .lobby), "only you so far")
        XCTAssertEqual(WatchPartyLobbyPolicy.waitingNames(members: members), ["B"])
    }

    func testPrimaryActionFollowsRoleModeAndSelection() {
        var room = WatchPartyRoom(roomId: "room")
        room.selfCanManageRoom = true
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: room, capabilities: nil, canStart: false, winnerTitle: nil), .chooseTitle)
        room.selectedContentId = "42"
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: room, capabilities: nil, canStart: true, winnerTitle: nil), .start(title: nil))
        room.selectionMode = .vote
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: room, capabilities: nil, canStart: false, winnerTitle: nil), .waitingForVotes)
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: room, capabilities: nil, canStart: true, winnerTitle: "Heat"), .start(title: "Heat"))
        var guestRoom = WatchPartyRoom(roomId: "room")
        guestRoom.members = [member("Me", isSelf: true, lobbyReady: true)]
        var caps = WatchPartyCapabilities()
        caps.lobbyReady = true
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: guestRoom, capabilities: caps, canStart: false, winnerTitle: nil), .ready(isReady: true))
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: guestRoom, capabilities: nil, canStart: false, winnerTitle: nil), .none)
        // A guest who cannot see the selected title has nothing to ready up for.
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: guestRoom, capabilities: caps, canStart: false, winnerTitle: nil, selectionUnavailable: true), .none)
        guestRoom.phase = .playing
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: guestRoom, capabilities: caps, canStart: false, winnerTitle: nil), .returnToPlayback)
        XCTAssertEqual(WatchPartyLobbyPolicy.primaryAction(room: guestRoom, capabilities: caps, canStart: false, winnerTitle: nil, selectionUnavailable: true), .none)
    }

    @MainActor func testRejoinConflictIsRecognizedAsARefusal() {
        XCTAssertTrue(WatchPartySession.isConflict(APIv2Error.httpStatus(409)))
        XCTAssertFalse(WatchPartySession.isConflict(APIv2Error.httpStatus(500)))
        XCTAssertTrue(WatchPartySession.isAccessRefusal(APIv2Error.httpStatus(404)))
        XCTAssertTrue(WatchPartySession.isAccessRefusal(APIv2Error.httpStatus(403)))
        XCTAssertFalse(WatchPartySession.isAccessRefusal(APIv2Error.httpStatus(503)))
    }

}
