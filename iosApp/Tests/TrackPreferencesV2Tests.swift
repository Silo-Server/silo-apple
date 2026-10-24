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
            request: TrackSelectionPersistence.subtitleOffRequest(),
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
        let request = TrackSelectionPersistence.subtitleOffRequest()
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

        // Dispatched back to back, the first would be superseded unsent.
        await TrackSelectionPersistence.clearAudio(prefKey: "series-fail", client: api, tokenStore: tokens).value
        await TrackSelectionPersistence.clearAudio(prefKey: "series-fail", client: api, tokenStore: tokens).value

        XCTAssertEqual(stub.methods, ["DELETE", "DELETE"], "the lost write is dropped, not replayed")
    }

    func testOrdinaryPicksAndOffNeverSendTheForcedSubtitleOverride() async throws {
        let (api, tokens) = try await client()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let version = try decoder.decode(FileVersion.self, from: Data(#"""
        {"file_id": 1, "subtitle_tracks": [{"index": 2, "language": "en", "codec": "subrip"}]}
        """#.utf8))
        let track = PlayerTrack(
            trackId: 7, kind: .sub, title: "English", lang: "en", codec: "subrip", audioChannelCount: nil,
            bitrate: nil, isDefault: false, isForced: false, isHearingImpaired: false,
            isExternal: true, isSelected: false, ffIndex: nil, srcId: nil
        )
        // The builders the player, the detail selectors and the Next Up
        // selectors use for a track pick and for Off.
        let requests = [
            try XCTUnwrap(TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: 2)),
            try XCTUnwrap(TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: -1)),
            TrackSelectionPersistence.subtitleRequest(track: track),
            TrackSelectionPersistence.subtitleOffRequest(),
        ]

        for request in requests {
            await TrackSelectionPersistence.saveSubtitle(prefKey: "series-forced", request: request,
                                                         client: api, tokenStore: tokens).value
        }

        XCTAssertEqual(stub.requests.count, requests.count)
        for sent in stub.requests {
            XCTAssertNil(try jsonBody(sent)["show_forced_subtitles"],
                         "a present member would pin the profile's forced-subtitle toggle on the series")
        }
    }

    // MARK: - Pending-write barrier

    func testReadWaitsForAnInFlightPickAndRereadsOnceItIsStored() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        stub.hold()
        let pick = TrackSelectionPersistence.saveSubtitle(
            prefKey: "series-barrier-wait", request: TrackSelectionPersistence.subtitleOffRequest(),
            client: api, tokenStore: tokens
        )
        await stub.waitUntilHeld()
        let mark = TrackSelectionPersistence.pendingWriteMark()

        let read = Task {
            await TrackSelectionPersistence.settlePendingWrites(
                prefKey: "series-barrier-wait", owner: owner, since: mark, timeout: .seconds(30)
            )
        }
        stub.release()
        let settlement = await read.value
        await pick.value

        XCTAssertTrue(settlement.rereads, "a response fetched before the write landed must be read again")
        XCTAssertTrue(settlement.unsettled.isEmpty, "the read returned only after the pick was stored")
    }

    func testWriteStoredWhileTheFirstReadWasInFlightForcesAReread() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        let key = "series-barrier-race"
        await TrackSelectionPersistence.clearAudio(prefKey: key, client: api, tokenStore: tokens).value
        let mark = TrackSelectionPersistence.pendingWriteMark()
        let before = await TrackSelectionPersistence.settlePendingWrites(prefKey: key, owner: owner, since: mark)
        XCTAssertFalse(before.rereads, "a write stored before the read was sent is in its response")

        // The PUT's 204 lands after the mark, before the GET's body: nothing
        // is in flight any more when the read settles, but it still rereads.
        await TrackSelectionPersistence.saveSubtitle(
            prefKey: key, request: TrackSelectionPersistence.subtitleOffRequest(), client: api, tokenStore: tokens
        ).value
        let after = await TrackSelectionPersistence.settlePendingWrites(prefKey: key, owner: owner, since: mark)

        XCTAssertTrue(after.rereads)
        XCTAssertTrue(after.unsettled.isEmpty)
    }

    func testReadThatOutwaitsTheBoundCarriesThePendingPickWithoutRereading() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        let request = AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "ja", trackSignature: nil)
        stub.hold()
        let pick = TrackSelectionPersistence.saveAudio(prefKey: "series-barrier-slow", request: request,
                                                       client: api, tokenStore: tokens)
        await stub.waitUntilHeld()

        let settlement = await TrackSelectionPersistence.settlePendingWrites(
            prefKey: "series-barrier-slow", owner: owner,
            since: TrackSelectionPersistence.pendingWriteMark(), timeout: .milliseconds(50)
        )

        XCTAssertFalse(settlement.rereads, "a second read cannot see a write still in flight")
        guard case .audio(let carried)? = settlement.unsettled[.audio] else {
            return XCTFail("the unanswered pick is carried into the read")
        }
        XCTAssertEqual(carried.audioLanguage, "ja")
        XCTAssertNil(settlement.unsettled[.subtitle])
        stub.release()
        await pick.value
    }

    func testRecheckAfterARereadCarriesANewerPickWithoutWaiting() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        stub.hold()
        let pick = TrackSelectionPersistence.saveSubtitle(
            prefKey: "series-barrier-recheck", request: TrackSelectionPersistence.subtitleOffRequest(),
            client: api, tokenStore: tokens
        )
        await stub.waitUntilHeld()
        let clock = ContinuousClock()
        let started = clock.now

        let recheck = await TrackSelectionPersistence.settlePendingWrites(
            prefKey: "series-barrier-recheck", owner: owner,
            since: TrackSelectionPersistence.pendingWriteMark(), timeout: .zero
        )

        XCTAssertLessThan(clock.now - started, .seconds(1), "the re-check after a reread does not wait again")
        XCTAssertFalse(recheck.rereads)
        guard case .subtitle? = recheck.unsettled[.subtitle] else {
            return XCTFail("the pick made while the reread was out is carried")
        }
        stub.release()
        await pick.value
    }

    func testSettledReadFoldsThePicksUnsavedAsOfItsLastRead() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        let key = "series-settled-read"
        var reads = 0
        var held: Task<Void, Never>?

        let detail = try await TrackSelectionPersistence.settledRead(owner: owner, wait: .milliseconds(50)) {
            reads += 1
            if reads < 3 {
                // A write stored while this GET was out: its response may predate it.
                await TrackSelectionPersistence.clearAudio(prefKey: key, client: api, tokenStore: tokens).value
            } else {
                // A newer pick made during the last GET, still unanswered.
                stub.hold()
                held = TrackSelectionPersistence.saveSubtitle(
                    prefKey: key, request: TrackSelectionPersistence.subtitleOffRequest(),
                    client: api, tokenStore: tokens
                )
                await stub.waitUntilHeld()
            }
            return Self.watchDetail(seriesId: key)
        }

        XCTAssertEqual(reads, 3, "two stores during reads, then the bound")
        XCTAssertEqual(detail.effectiveSubtitleMode, "off", "the pick made during the last GET is carried")
        stub.release()
        await held?.value
    }

    func testOneProfilesPickNeverReplacesAnothersCarriedPick() async throws {
        let (api, tokens) = try await client()
        let key = "series-two-profiles"
        stub.sequence([.failure(URLError(.networkConnectionLost)), .response(.status(204))])
        await TrackSelectionPersistence.saveSubtitle(
            prefKey: key, request: TrackSelectionPersistence.subtitleOffRequest(), client: api, tokenStore: tokens
        ).value

        await tokens.setProfileId("profile-two")
        await TrackSelectionPersistence.clearSubtitle(prefKey: key, client: api, tokenStore: tokens).value
        await tokens.setProfileId("profile-one")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let profileOne = try XCTUnwrap(captured)

        let settlement = await TrackSelectionPersistence.settlePendingWrites(
            prefKey: key, owner: profileOne, since: TrackSelectionPersistence.pendingWriteMark()
        )
        guard case .subtitle(let carried)? = settlement.unsettled[.subtitle] else {
            return XCTFail("profile-one's failed Off is still carried after profile-two's Auto")
        }
        XCTAssertEqual(carried.subtitleMode, "off")
        XCTAssertEqual(stub.requests.map(\.method), ["PUT", "DELETE"])
        XCTAssertEqual(stub.requests.last?.header("X-Profile-Id"), "profile-two")
    }

    func testWriteGoesOutOnlyUnderTheOwnerThePickWasMadeUnder() async throws {
        let persistent = UUID(), scopeA = UUID(), scopeB = UUID()
        func auth(_ generation: UUID, _ profile: String, temporary: Bool = false) -> CapturedOrdinaryRequestAuth {
            CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: "s", serverURL: "https://s.example", credentialGenerationID: generation),
                credentialOwner: temporary ? .temporary : .persistentServer(serverId: "s"),
                accessToken: "a", profileId: profile, profileToken: nil
            )
        }
        let pickedOne = CredentialOwnerSnapshot(credentialGenerationID: persistent, profileId: "profile-one")
        XCTAssertNotNil(TrackSelectionPersistence.writeOwner(captured: auth(persistent, "profile-one"), pickedBy: pickedOne))
        XCTAssertNil(TrackSelectionPersistence.writeOwner(captured: auth(persistent, "profile-two"), pickedBy: pickedOne),
                     "a profile switch before the write's task ran must not send the pick as the next profile")
        let pickedInScopeA = CredentialOwnerSnapshot(credentialGenerationID: scopeA, profileId: "remote")
        XCTAssertNotNil(TrackSelectionPersistence.writeOwner(captured: auth(scopeA, "remote", temporary: true),
                                                             pickedBy: pickedInScopeA))
        XCTAssertNil(TrackSelectionPersistence.writeOwner(captured: auth(scopeB, "remote", temporary: true),
                                                          pickedBy: pickedInScopeA),
                     "a pick made in one remote-playback scope never goes out under the next")
        XCTAssertNil(TrackSelectionPersistence.writeOwner(captured: nil, pickedBy: pickedOne))

        // The snapshot read without awaiting agrees with the captured owner.
        let (_, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        XCTAssertTrue(tokens.ownerSnapshot.matches(try XCTUnwrap(captured)))
        await tokens.setProfileId("profile-two")
        XCTAssertFalse(tokens.ownerSnapshot.matches(try XCTUnwrap(captured)))
    }

    private static func watchDetail(seriesId: String) -> WatchDetail {
        WatchDetail(
            contentId: "ep-1", type: "episode", title: "One", year: nil, overview: nil,
            versions: [], subtitles: nil, intro: nil, credits: nil, userData: nil,
            seriesId: seriesId, seriesTitle: nil, seasonNumber: 1, episodeNumber: 1,
            effectiveSubtitleLanguage: "en", effectiveSubtitleMode: "always",
            effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
        )
    }

    func testCancelledReadStopsWaitingPromptly() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        stub.hold()
        let pick = TrackSelectionPersistence.saveSubtitle(
            prefKey: "series-barrier-cancel", request: TrackSelectionPersistence.subtitleOffRequest(),
            client: api, tokenStore: tokens
        )
        await stub.waitUntilHeld()
        let clock = ContinuousClock()
        let started = clock.now

        let read = Task {
            await TrackSelectionPersistence.settlePendingWrites(
                prefKey: "series-barrier-cancel", owner: owner,
                since: TrackSelectionPersistence.pendingWriteMark(), timeout: .seconds(30)
            )
        }
        read.cancel()
        _ = await read.value

        XCTAssertLessThan(clock.now - started, .seconds(5), "a cancelled read must not sit out the wait")
        stub.release()
        await pick.value
    }

    func testFailedPickIsCarriedForALimitedTimeOrUntilANewerWriteIsStored() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        let key = "series-barrier-fail"
        stub.sequence([.failure(URLError(.networkConnectionLost)), .response(.status(204))])

        await TrackSelectionPersistence.saveSubtitle(
            prefKey: key, request: TrackSelectionPersistence.subtitleOffRequest(),
            client: api, tokenStore: tokens
        ).value
        let mark = TrackSelectionPersistence.pendingWriteMark()
        let failed = await TrackSelectionPersistence.settlePendingWrites(prefKey: key, owner: owner, since: mark)
        XCTAssertFalse(failed.rereads, "a failed write changed nothing on the server")
        guard case .subtitle(let carried)? = failed.unsettled[.subtitle] else {
            return XCTFail("the failed Off is carried, not dropped")
        }
        XCTAssertEqual(carried.subtitleMode, "off")
        let expired = await TrackSelectionPersistence.settlePendingWrites(
            prefKey: key, owner: owner, since: mark,
            now: .now + TrackSelectionPersistence.failedPickLifetime + .seconds(1)
        )
        XCTAssertTrue(expired.unsettled.isEmpty, "after the lifetime the server's state wins again")

        await TrackSelectionPersistence.clearSubtitle(prefKey: key, client: api, tokenStore: tokens).value
        let cleared = await TrackSelectionPersistence.settlePendingWrites(prefKey: key, owner: owner, since: mark)
        XCTAssertTrue(cleared.unsettled.isEmpty, "the stored Auto replaces the failed pick")
    }

    func testNewerWriteSupersedesOneStillQueued() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(captured)
        let key = "series-barrier-supersede"
        stub.hold()
        let first = TrackSelectionPersistence.saveSubtitle(
            prefKey: key, request: TrackSelectionPersistence.subtitleOffRequest(), client: api, tokenStore: tokens
        )
        await stub.waitUntilHeld()
        let queued = TrackSelectionPersistence.saveAudio(
            prefKey: key, request: AudioPrefRequest(audioTrackIndex: 1, audioLanguage: "en", trackSignature: nil),
            client: api, tokenStore: tokens
        )
        let second = TrackSelectionPersistence.saveSubtitle(
            prefKey: key,
            request: SubtitlePrefRequest(subtitleLanguage: "en", subtitleTrackIndex: 3, externalSubtitlePath: "",
                                         subtitleMode: "always", trackSignature: nil),
            client: api, tokenStore: tokens
        )
        let auto = TrackSelectionPersistence.clearSubtitle(prefKey: key, client: api, tokenStore: tokens)
        await queued.value

        stub.release()
        await first.value
        await second.value
        await auto.value

        XCTAssertEqual(stub.methods, ["PUT", "PUT", "DELETE"],
                       "the queued subtitle pick is skipped; the in-flight one and the newest still go out")
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/subtitle-prefs/\(key)", "/api/v2/audio-prefs/\(key)",
                                             "/api/v2/subtitle-prefs/\(key)"])
        let settled = await TrackSelectionPersistence.settlePendingWrites(
            prefKey: key, owner: owner, since: TrackSelectionPersistence.pendingWriteMark()
        )
        XCTAssertTrue(settled.unsettled.isEmpty)
    }

    func testReadUnderAnotherOwnerNeitherWaitsNorCarries() async throws {
        let (api, tokens) = try await client()
        stub.hold()
        let pick = TrackSelectionPersistence.saveSubtitle(
            prefKey: "series-barrier-owner", request: TrackSelectionPersistence.subtitleOffRequest(),
            client: api, tokenStore: tokens
        )
        await stub.waitUntilHeld()
        await tokens.setProfileId("profile-two")
        let capturedOther = await tokens.captureOrdinaryRequestAuth()
        let other = try XCTUnwrap(capturedOther)
        let clock = ContinuousClock()
        let started = clock.now

        let settlement = await TrackSelectionPersistence.settlePendingWrites(
            prefKey: "series-barrier-owner", owner: other,
            since: TrackSelectionPersistence.pendingWriteMark(), timeout: .seconds(30)
        )

        XCTAssertLessThan(clock.now - started, .seconds(5), "profile-one's write is not waited on")
        XCTAssertTrue(settlement.unsettled.isEmpty, "profile-one's pick never reaches profile-two's reads")
        stub.release()
        await pick.value
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
