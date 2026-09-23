import Foundation
import XCTest
@testable import Silo

/// Per-series audio and subtitle preferences on the v2 wire. Both request
/// schemas are closed (`additionalProperties: false`), so the bodies are
/// pinned member by member; the writes go out only under the owner captured
/// at dispatch and require exactly 204.
final class TrackPreferencesV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub(fallback: .response(.status(204)))
    }

    private func client() async throws -> (APIv2Client, TokenStore) {
        let name = "TrackPreferencesV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://prefs.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private func jsonBody(_ request: StubURLProtocol.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    private func encodedPath(_ request: StubURLProtocol.Request) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
    }

    func testAudioSaveSendsTheClosedUpdateBodyUnderTheActingProfile() async throws {
        let (api, tokens) = try await client()
        let request = AudioPrefRequest(
            audioTrackIndex: 1,
            audioLanguage: "ja",
            trackSignature: AudioTrackSignature(
                language: "ja", title: "Japanese 5.1", embeddedTitle: "JPN Surround",
                codec: "eac3", layout: "5.1", channels: 6, isDefault: true
            )
        )

        await TrackSelectionPersistence.saveAudio(prefKey: "series-9", request: request,
                                                  client: api, tokenStore: tokens).value

        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.path, "/api/v2/audio-prefs/series-9")
        XCTAssertEqual(sent.header("X-Profile-Id"), "profile-one")
        let body = try jsonBody(sent)
        XCTAssertEqual(Set(body.keys), ["audio_track_index", "audio_language", "track_signature"])
        XCTAssertEqual(body["audio_track_index"] as? Int, 1)
        let signature = try XCTUnwrap(body["track_signature"] as? [String: Any])
        XCTAssertEqual(Set(signature.keys),
                       ["language", "title", "embedded_title", "codec", "layout", "channels", "default"])
        XCTAssertEqual(signature["default"] as? Bool, true)
    }

    func testSubtitleOffSendsMinusOneAndOmitsUnsetMembers() async throws {
        let (api, tokens) = try await client()

        await TrackSelectionPersistence.saveSubtitle(
            prefKey: "series-9",
            request: TrackSelectionPersistence.subtitleOffRequest(showForced: nil),
            client: api, tokenStore: tokens
        ).value

        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.path, "/api/v2/subtitle-prefs/series-9")
        let body = try jsonBody(sent)
        XCTAssertEqual(body["subtitle_track_index"] as? Int, -1)
        XCTAssertEqual(body["subtitle_mode"] as? String, "off")
        XCTAssertNil(body["track_signature"], "no signature member for an explicit Off")
        XCTAssertNil(body["show_forced_subtitles"], "omitted keeps the stored forced override")
    }

    func testSubtitleSignatureUsesTheContractMemberNames() async throws {
        let (api, tokens) = try await client()
        let request = SubtitlePrefRequest(
            subtitleLanguage: "en", subtitleTrackIndex: 3, externalSubtitlePath: "",
            subtitleMode: "always",
            trackSignature: SubtitleTrackSignature(source: "embedded", language: "en", codec: "subrip",
                                                   label: "English (SDH)", forced: false, hearingImpaired: true),
            showForcedSubtitles: true
        )

        await TrackSelectionPersistence.saveSubtitle(prefKey: "movie-7", request: request,
                                                     client: api, tokenStore: tokens).value

        let body = try jsonBody(XCTUnwrap(stub.requests.last))
        XCTAssertEqual(Set(body.keys), ["subtitle_language", "subtitle_track_index", "external_subtitle_path",
                                        "subtitle_mode", "track_signature", "show_forced_subtitles"])
        let signature = try XCTUnwrap(body["track_signature"] as? [String: Any])
        XCTAssertEqual(Set(signature.keys), ["source", "language", "codec", "label", "forced", "hearing_impaired"])
    }

    func testClearSendsDeleteWithAnEncodedKey() async throws {
        let (api, tokens) = try await client()

        await TrackSelectionPersistence.clearAudio(prefKey: "a/b", client: api, tokenStore: tokens).value
        await TrackSelectionPersistence.clearSubtitle(prefKey: "series-9", client: api, tokenStore: tokens).value

        XCTAssertEqual(stub.methods, ["DELETE", "DELETE"])
        XCTAssertEqual(encodedPath(stub.requests[0]), "/api/v2/audio-prefs/a%2Fb")
        XCTAssertEqual(encodedPath(stub.requests[1]), "/api/v2/subtitle-prefs/series-9")
        XCTAssertNil(stub.requests[0].body)
    }

    func testAutoAfterAPickWaitsForThePickToFinish() async throws {
        let (api, tokens) = try await client()
        let request = TrackSelectionPersistence.subtitleOffRequest(showForced: nil)
        stub.hold()

        let pick = TrackSelectionPersistence.saveSubtitle(prefKey: "series-order", request: request,
                                                          client: api, tokenStore: tokens)
        await stub.waitUntilHeld()
        let auto = TrackSelectionPersistence.clearSubtitle(prefKey: "series-order",
                                                           client: api, tokenStore: tokens)
        let otherKind = TrackSelectionPersistence.clearAudio(prefKey: "series-order",
                                                             client: api, tokenStore: tokens)
        await otherKind.value
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stub.methods, ["PUT", "DELETE"],
                       "the subtitle clear must not overtake the unanswered subtitle pick; audio is not blocked")
        XCTAssertEqual(stub.requestedPaths.last, "/api/v2/audio-prefs/series-order")

        stub.release()
        await pick.value
        await auto.value
        XCTAssertEqual(stub.methods, ["PUT", "DELETE", "DELETE"])
        XCTAssertEqual(stub.requestedPaths.last, "/api/v2/subtitle-prefs/series-order")
    }

    func testAFailedWriteDoesNotBlockTheNextOneForTheSameKey() async throws {
        let (api, tokens) = try await client()
        stub.sequence([.failure(URLError(.networkConnectionLost)), .response(.status(204))])

        let first = TrackSelectionPersistence.clearAudio(prefKey: "series-fail", client: api, tokenStore: tokens)
        let second = TrackSelectionPersistence.clearAudio(prefKey: "series-fail", client: api, tokenStore: tokens)
        await first.value
        await second.value

        XCTAssertEqual(stub.methods, ["DELETE", "DELETE"], "the lost write is dropped, not replayed")
    }

    func testWriteCapturedForAnotherOwnerIsNeverSent() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        await tokens.setProfileId("profile-two")

        do {
            try await api.deleteTrackPreference(kind: .subtitle, seriesId: "series-9", auth: auth)
            XCTFail("a write captured under profile-one must not go out as profile-two")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testOnlyNoContentCountsAsStored() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)

        stub.reply(200, "{}")
        do {
            try await api.writeTrackPreference(kind: .audio, seriesId: "series-9",
                body: TrackSelectionPersistence.audioRequest(track: .init(
                    trackId: 1, kind: .audio, title: nil, lang: "en", codec: "aac", audioChannelCount: 2,
                    bitrate: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                    isExternal: false, isSelected: false, ffIndex: nil, srcId: nil), ordinal: nil),
                auth: auth)
            XCTFail("the operation answers 204; any other 2xx is not a confirmed store")
        } catch APIv2Error.httpStatus(200) { }

        stub.reply(422, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Unprocessable","status":422,"detail":"bad","instance":"urn:test"}"#)
        do {
            try await api.deleteTrackPreference(kind: .audio, seriesId: "series-9", auth: auth)
            XCTFail("a problem response is a definite failure")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 422)
        }
        XCTAssertEqual(stub.requests.count, 2, "no retry after either failure")
    }
}
