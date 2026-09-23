import Foundation
import XCTest
@testable import Silo

final class WatchPartyAPITests: XCTestCase {
    private var stub = APIv2TestStub()
    private let roomId = "96207173-607f-40a2-a9a1-ea406fb8f35d"

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, TokenStore, CapturedOrdinaryRequestAuth) {
        let name = "WatchPartyAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "party-server")
        await tokens.setServerUrl("https://party.example")
        await tokens.saveTokens(accessToken: "access-one", refreshToken: "refresh-one")
        await tokens.setProfileId("profile-one")
        await tokens.setProfileToken("profile-proof")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        return (api, tokens, auth)
    }

    private func roomObject(fileId: Any = "9007199254740993", userId: Any = "9") -> [String: Any] {
        ["room_id": roomId, "phase": "lobby", "playback_state": "idle", "selection_mode": "host_pick",
         "selection_revision": 8, "selected_content_id": "movie:123", "selected_file_id": fileId,
         "selected_library_id": "3", "code": "ABCDEFGH", "guest_control_policy": "host_only",
         "is_paused": true, "anchor_position_seconds": 41.25, "anchor_updated_at": "2026-09-21T15:30:00.123456789Z",
         "generation": 11, "member_count": 1, "host_connected": true, "self_role": "host",
         "self_can_control_transport": true, "self_can_manage_room": true, "self_ignore_wait": false,
         "members": [["user_id": userId, "profile_id": "profile-one", "display_name": "Viewer",
                       "is_host": true, "is_self": true, "connected": true, "lobby_ready": true]]]
    }

    private func response(room: [String: Any]? = nil, token: String = "room-proof") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["room": room ?? roomObject(), "room_access_token": token])
        return String(decoding: data, as: UTF8.self)
    }

    func testHTTPAndSocketIDsDecodeExactlyAndStagedContentIsNotPlaying() throws {
        for room in [roomObject(), roomObject(fileId: Int64(9_007_199_254_740_993), userId: 9)] {
            let data = try JSONSerialization.data(withJSONObject: room)
            let decoded = try HTTPClient.makeJSONDecoder().decode(WatchPartyRoom.self, from: data)
            XCTAssertEqual(decoded.selectedFileId, "9007199254740993")
            XCTAssertEqual(decoded.members.first?.userId, "9")
            XCTAssertTrue(decoded.members.first?.lobbyReady == true)
            XCTAssertFalse(decoded.members.first?.isReady ?? true)
            XCTAssertFalse(decoded.isPlaying)
            XCTAssertEqual(decoded.selectionRevision, 8)
            XCTAssertGreaterThan(decoded.anchorUpdatedAt.timeIntervalSince1970, 0)
        }
        var malformed = roomObject(fileId: 1.25)
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(WatchPartyRoom.self,
            from: JSONSerialization.data(withJSONObject: malformed)))
        malformed = roomObject()
        malformed["selected_content_id"] = 123
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(WatchPartyRoom.self,
            from: JSONSerialization.data(withJSONObject: malformed)))
    }

    func testCapabilitiesFailClosedAndUnknownRoomEnumsRemainDecodable() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let minimal = try decoder.decode(WatchPartyCapabilities.self, from: Data(#"{"state":"available","allowed":true}"#.utf8))
        XCTAssertTrue(minimal.isAvailable)
        XCTAssertFalse(minimal.supportsSocket)
        XCTAssertFalse(minimal.memberState)
        XCTAssertFalse(minimal.picker)
        XCTAssertFalse(minimal.stagedSelection)
        XCTAssertFalse(minimal.connectionReplaced)
        let unknown = try decoder.decode(WatchPartyCapabilities.self,
            from: Data(#"{"state":"future","allowed":true,"socket_protocol":"silo.room.v2"}"#.utf8))
        XCTAssertFalse(unknown.isAvailable)
        var futureRoom = roomObject()
        futureRoom["phase"] = "future_phase"
        let decoded = try decoder.decode(WatchPartyRoom.self, from: JSONSerialization.data(withJSONObject: futureRoom))
        XCTAssertEqual(decoded.phase, .unknown("future_phase"))
        XCTAssertFalse(decoded.isPlaying)
    }

    func testReplacementIsTerminalMessageRatherThanRoomClosure() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let data = Data(#"{"type":"connection_replaced","reason":"This profile joined the Watch Party on another device."}"#.utf8)
        guard case .connectionReplaced(let reason) = try decoder.decode(WatchPartyServerMessage.self, from: data) else {
            return XCTFail("Expected the deployed replacement message")
        }
        XCTAssertEqual(reason, "This profile joined the Watch Party on another device.")
        let caps = try decoder.decode(WatchPartyCapabilities.self,
            from: Data(#"{"state":"available","allowed":true,"connection_replaced":true,"socket_protocol":"silo.room.v2"}"#.utf8))
        XCTAssertTrue(caps.connectionReplaced)
    }

    func testInvitationKeepsServerAndBasePathAndRejectsAmbiguousProofs() throws {
        let invitation = try XCTUnwrap(WatchPartyInvitation(url: URL(string: "https://example.test/silo/rooms/join?token=invite%2Bproof")!))
        XCTAssertEqual(invitation.serverURL, "https://example.test/silo")
        XCTAssertEqual(invitation.joinToken, "invite+proof")
        for value in ["https://example.test/rooms/join?token=", "https://example.test/rooms/join?token=a&token=b",
                      "https://user:pass@example.test/rooms/join?token=a", "https://example.test/rooms/other?token=a",
                      "file:///rooms/join?token=a", "https://example.test/rooms/join?token=a#fragment"] {
            XCTAssertNil(WatchPartyInvitation(url: URL(string: value)!), value)
        }
    }

    func testStageCarriesCapturedProfileRoomProofAndStringIDs() async throws {
        stub.reply(200, try response())
        let (api, _, auth) = try await client()
        _ = try await api.stageWatchPartySelection(roomId: roomId, token: "room-proof",
            selection: WatchPartySelection(contentId: "movie:123", fileId: "9007199254740993", libraryId: "3"), auth: auth)
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v2/watch-together/rooms/\(roomId)/staged-selection")
        XCTAssertEqual(request.header("authorization"), "Bearer access-one")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(request.header("x-profile-token"), "profile-proof")
        XCTAssertEqual(request.header("x-room-token"), "room-proof")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body["file_id"], "9007199254740993")
        XCTAssertEqual(body["library_id"], "3")
    }

    func testOwnerReplacementPreventsDispatchAndRejectsInflightReply() async throws {
        stub.reply(200, try response())
        let (api, tokens, auth) = try await client()
        stub.hold()
        let pending = Task { try await api.watchPartyRoom(id: roomId, token: "room-proof", auth: auth) }
        await stub.waitUntilHeld()
        await tokens.setProfileToken("replacement-proof")
        stub.release()
        do {
            _ = try await pending.value
            XCTFail("Old room state must not publish into a replacement profile")
        } catch HTTPError.authorityChanged { }
        do {
            _ = try await api.startWatchPartyPlayback(roomId: roomId, token: "room-proof", auth: auth)
            XCTFail("An old owner must not dispatch a mutation")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testStart401IsNeverRefreshedOrReplayed() async throws {
        stub.reply(401, #"{"type":"https://siloserver.org/docs/api/v2/problems/authentication_required","title":"Unauthorized","status":401,"detail":"Expired","instance":"urn:test"}"#)
        let (api, _, auth) = try await client()
        do {
            _ = try await api.startWatchPartyPlayback(roomId: roomId, token: "room-proof", auth: auth)
            XCTFail("Expected the first dispatch failure")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 401)
        }
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(stub.requests.first?.path, "/api/v2/watch-together/rooms/\(roomId)/playback/start")
    }

    func testRoomReceiptsRequireMatchingIdentityAndProof() async throws {
        let (api, _, auth) = try await client()
        var different = roomObject()
        different["room_id"] = "other-room"
        for payload in [try response(room: different), try response(token: "")] {
            stub.reply(200, payload)
            do {
                _ = try await api.watchPartyRoom(id: roomId, token: "room-proof", auth: auth)
                XCTFail("Invalid receipt accepted")
            } catch WatchPartyAPIError.invalidResponse { }
        }
        stub.reply(200, "")
        do {
            try await api.closeWatchPartyRoom(roomId: roomId, token: "room-proof", auth: auth)
            XCTFail("Close must return 204")
        } catch APIv2Error.httpStatus(200) { }
    }

    func testMemberStateAllowsOmittedInaccessibleIDsAndBoundsRequests() async throws {
        stub.reply(200, #"{"members":[],"items":[{"content_id":"movie:1","members":[]}]}"#)
        let (api, _, auth) = try await client()
        let result = try await api.watchPartyMemberState(roomId: roomId, token: "room-proof", contentIds: ["movie:1", "movie:2"], auth: auth)
        XCTAssertEqual(result.items.map(\.contentId), ["movie:1"])
        for ids in [[], Array(repeating: "movie:1", count: 201)] {
            do {
                _ = try await api.watchPartyMemberState(roomId: roomId, token: "room-proof", contentIds: ids, auth: auth)
                XCTFail("Invalid bounded request was sent")
            } catch WatchPartyAPIError.invalidRequest { }
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSuggestionReceiptAndPaginationAreValidated() async throws {
        let (api, _, auth) = try await client()
        stub.reply(201, #"{"suggestion_id":"wrong"}"#)
        do {
            _ = try await api.addWatchPartySuggestion(roomId: roomId, token: "room-proof",
                suggestion: WatchPartyNewSuggestion(contentId: "movie:1", contentType: "movie", title: "Movie"), auth: auth)
            XCTFail("Mismatched suggestion receipt accepted")
        } catch WatchPartyAPIError.invalidResponse { }
        stub.reply(200, #"{"items":[],"page":{"has_more":true}}"#)
        do {
            _ = try await api.watchPartySuggestions(roomId: roomId, token: "room-proof", auth: auth)
            XCTFail("Incomplete suggestion page accepted")
        } catch WatchPartyAPIError.invalidResponse { }
    }

    func testSocketTicketChecksProtocolAndKeepsProofOutOfURL() async throws {
        let (api, _, auth) = try await client()
        for proto in ["silo.room.v2", "future.protocol"] {
            stub.reply(200, #"{"ticket":"single_use-ticket","expires_in":30,"max_connection_seconds":300,"protocol":"\#(proto)"}"#)
            do {
                let ticket = try await api.watchPartySocketTicket(roomId: roomId, token: "room-proof", auth: auth)
                XCTAssertEqual(proto, "silo.room.v2")
                XCTAssertEqual(ticket.protocol, proto)
            } catch WatchPartyAPIError.invalidResponse {
                XCTAssertNotEqual(proto, "silo.room.v2")
            }
        }
        for request in stub.requests {
            XCTAssertEqual(request.header("x-room-token"), "room-proof")
            XCTAssertNil(request.url?.query)
            XCTAssertFalse(request.url?.absoluteString.contains("room-proof") ?? true)
        }
    }
}
