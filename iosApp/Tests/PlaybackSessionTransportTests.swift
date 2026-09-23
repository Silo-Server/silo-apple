import Foundation
import XCTest
@testable import Silo

/// The v2 playback session operations on the wire: the exact body each one
/// sends, the one success status each accepts, and how the receipts are
/// checked.
final class PlaybackSessionTransportTests: XCTestCase {
    private typealias Support = APIv2FixtureTestSupport

    private let installation = "11111111-1111-4111-8111-111111111111"
    private let session = "22222222-2222-4222-8222-222222222222"

    private struct Harness {
        let api: APIv2Client
        let stub: APIv2TestStub
        let tokens: TokenStore
        let auth: CapturedOrdinaryRequestAuth
    }

    private func makeHarness() async throws -> Harness {
        let name = "PlaybackSessionTransportTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        await tokens.setProfileId("profile-one")
        let stub = APIv2TestStub()
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let captured = await tokens.captureOrdinaryRequestAuth()
        return Harness(api: api, stub: stub, tokens: tokens, auth: try XCTUnwrap(captured))
    }

    private func fixture(_ name: String) throws -> String {
        String(decoding: try Support.data(named: name, bundleClass: Self.self), as: UTF8.self)
    }

    private func body(_ request: StubURLProtocol.Request?) throws -> [String: Any] {
        try Support.jsonObject(try XCTUnwrap(request?.body))
    }

    private func assertInvalidResponse(_ operation: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("expected an invalid response", file: file, line: line)
        } catch PlaybackSequencedError.invalidResponse {
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // `PlaybackStartBody` and `ClientPlaybackContextV3` in the server's
    // contracts/api/v2/openapi.json at the commit Fixtures/APIv2/SOURCE pins.
    // Both declare additionalProperties: false.
    private static let startRequired: Set<String> = [
        "installation_id", "protocol_version", "client_features", "file_id", "profile_id",
        "playback_attempt_id", "quality_preference", "subtitle_fidelity_preference", "metered",
        "client_capabilities", "client_playback_context",
    ]
    private static let startMembers = startRequired.union([
        "allow_alternate_versions", "audio_track_id", "audio_track_index", "bandwidth_cap_kbps",
        "bandwidth_estimate_kbps", "progress_persistence", "start_position", "subtitle_track_id",
        "subtitle_track_index",
    ])
    private static let contextRequired: Set<String> = [
        "protocol_version", "form_factor", "app_version", "device", "output", "deliveries",
    ]
    private static let contextMembers = contextRequired.union(["app_build", "app_channel"])

    private func startRequest() -> PlaybackV3StartRequest {
        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        return PlaybackV3StartRequest(
            protocolVersion: 3, clientFeatures: ApplePlaybackV3Capabilities.audiobookFeatures, fileId: 42,
            profileId: "profile-one", playbackAttemptId: "apple-audio:attempt", qualityPreference: "auto",
            subtitleFidelityPreference: "preserve", progressPersistence: "client", startPosition: 0,
            audioTrackId: nil, audioTrackIndex: nil, subtitleTrackId: nil, subtitleTrackIndex: nil,
            metered: false, bandwidthEstimateKbps: nil, bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context)
    }

    private func terminalRouteEvent() -> PlaybackV3RouteEvent {
        PlaybackSessionBridge.terminalStartRouteEvent(
            playbackAttemptId: "apple:attempt", snapshot: ApplePlaybackV3Capabilities.snapshot(),
            terminal: PlaybackV3Terminal(reason: "no_route", message: "No route", retryable: false))
    }

    // MARK: Start and replan

    func testStartSendsTheV2BodyAndProjectsTheCreatedDecision() async throws {
        let h = try await makeHarness()
        h.stub.reply(201, try fixture("playback_start_opaque_ids"))

        let decision = try await h.api.startPlayback(startRequest(), installationID: installation, auth: h.auth)

        let request = try XCTUnwrap(h.stub.requests.single)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/playback/start")
        XCTAssertEqual(request.headers["x-profile-id"], "profile-one")
        let sent = try body(request)
        XCTAssertEqual(sent["installation_id"] as? String, installation)
        XCTAssertEqual(sent["file_id"] as? String, "42", "v2 file ids are opaque strings")
        XCTAssertEqual(sent["progress_persistence"] as? String, "client")
        XCTAssertEqual(sent["start_position"] as? Double, 0, "an explicit zero start is sent, not omitted")
        XCTAssertTrue(Self.startRequired.isSubset(of: sent.keys), "missing \(Self.startRequired.subtracting(sent.keys))")
        XCTAssertTrue(Set(sent.keys).isSubset(of: Self.startMembers),
                      "the schema refuses unknown members: \(Set(sent.keys).subtracting(Self.startMembers))")
        let context = try XCTUnwrap(sent["client_playback_context"] as? [String: Any])
        XCTAssertTrue(Self.contextRequired.isSubset(of: context.keys), "missing \(Self.contextRequired.subtracting(context.keys))")
        XCTAssertTrue(Set(context.keys).isSubset(of: Self.contextMembers),
                      "the schema refuses unknown members: \(Set(context.keys).subtracting(Self.contextMembers))")
        guard case .playable(let plan, let sessionID) = decision.validatedForApple() else {
            return XCTFail("expected a playable decision")
        }
        XCTAssertEqual(sessionID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(plan.effectiveMediaFileId, 42)
        XCTAssertEqual(plan.stream.url, "/api/v2/stream/11111111-1111-4111-8111-111111111111")
    }

    func testStartAcceptsOnlyCreated() async throws {
        let h = try await makeHarness()
        h.stub.reply(200, try fixture("playback_start_opaque_ids"))
        await assertInvalidResponse {
            _ = try await h.api.startPlayback(startRequest(), installationID: installation, auth: h.auth)
        }
    }

    func testStartSurfacesInstallationChangedForTheCapabilityRefresh() async throws {
        let h = try await makeHarness()
        h.stub.reply(409, try fixture("playback_installation_changed"))
        do {
            _ = try await h.api.startPlayback(startRequest(), installationID: installation, auth: h.auth)
            XCTFail("expected installation_changed")
        } catch {
            XCTAssertTrue(PlaybackV3CapabilityGate.isInstallationChanged(error))
        }
    }

    func testReplanPostsToTheSessionWithTheInstallation() async throws {
        let h = try await makeHarness()
        h.stub.reply(200, try fixture("playback_start_opaque_ids"))
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let replan = PlaybackV3ReplanRequest(
            protocolVersion: 3, clientFeatures: ApplePlaybackV3Capabilities.features,
            operation: PlaybackProtocolV3.ReplanOperation.qualityChange, playbackAttemptId: "apple:attempt",
            replanRequestId: "apple-replan:request", failedPlanId: "plan:fixture", planAttemptId: "apple-plan:attempt",
            planAttemptKey: "v3:opaque-fixture", attemptedPlanKeys: [], attemptCount: 1, qualityPreference: "auto",
            positionSeconds: 42.5, metered: false, bandwidthEstimateKbps: nil, bandwidthCapKbps: nil,
            selectedTracks: PlaybackV3SelectedTracks(audio: nil, subtitle: nil), failure: nil, localMutations: [],
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context)

        _ = try await h.api.replanPlayback(sessionID: session, replan, installationID: installation, auth: h.auth)

        let request = try XCTUnwrap(h.stub.requests.single)
        XCTAssertEqual(request.path, "/api/v2/playback/\(session)/replan")
        let sent = try body(request)
        XCTAssertEqual(sent["installation_id"] as? String, installation)
        XCTAssertEqual(sent["replan_request_id"] as? String, "apple-replan:request")
        XCTAssertNil(sent["failure"], "an intent replan carries no failure block")
    }

    // MARK: Route events

    func testRouteEventMintsAnEventIDAndRequiresItsEcho() async throws {
        let h = try await makeHarness()
        let event = terminalRouteEvent()
        // The receipt must echo the id the client minted; the stub cannot
        // know it, so the first call sees a foreign id and is refused.
        h.stub.reply(202, #"{"event_id":"33333333-3333-4333-8333-333333333333","outcome":"accepted"}"#)
        await assertInvalidResponse {
            try await h.api.reportPlaybackRouteEvent(event, installationID: installation, auth: h.auth)
        }
        let sent = try body(h.stub.requests.last)
        let eventID = try XCTUnwrap(sent["event_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: eventID))
        XCTAssertEqual(eventID, eventID.lowercased())
        XCTAssertEqual(sent["installation_id"] as? String, installation)
        XCTAssertEqual(sent["event"] as? String, "terminal")
        XCTAssertEqual(h.stub.requests.last?.path, "/api/v2/playback/route-events")
        XCTAssertEqual(h.stub.requests.count, 1, "a route event is never sent again")
    }

    func testRouteEventAcceptsTheEchoedReceipt() async throws {
        let h = try await makeHarness()
        let echo = StubURLProtocol.Handler()
        echo.route(StubURLProtocol.any) { request in
            let sent = try Support.jsonObject(request.body ?? Data())
            let eventID = sent["event_id"] as? String ?? ""
            return .json(#"{"event_id":"\#(eventID)","outcome":"accepted"}"#, status: 202)
        }
        let api = APIv2Client(http: HTTPClient(session: echo.makeSession(), tokenStore: h.tokens),
            tokenStore: h.tokens, isUpdateRequired: { false })
        let event = terminalRouteEvent()

        try await api.reportPlaybackRouteEvent(event, installationID: installation, auth: h.auth)

        XCTAssertEqual(echo.requests.count, 1)
    }

    func testRouteEventTooManyRequestsIsAProblemTheCallerDrops() async throws {
        let h = try await makeHarness()
        h.stub.reply(429, try fixture("rate_limited"))
        let event = terminalRouteEvent()
        do {
            try await h.api.reportPlaybackRouteEvent(event, installationID: installation, auth: h.auth)
            XCTFail("expected a problem")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 429)
        }
        XCTAssertEqual(h.stub.requests.count, 1)
    }

    // MARK: Progress

    func testProgressSendsTheSequencedSampleAndAcceptsEveryRecordedOutcome() async throws {
        let h = try await makeHarness()
        h.stub.sequence([.json(200, try fixture("playback_progress_applied")),
                         .json(200, try fixture("playback_progress_stale")),
                         .json(200, #"{"outcome":"replayed"}"#)])
        let sample = try PlaybackSequencedSample(sequence: 7, position: 120.5, isPaused: true)

        let applied = try await h.api.updatePlaybackProgress(sessionID: session, sample: sample,
            installationID: installation, auth: h.auth)
        let stale = try await h.api.updatePlaybackProgress(sessionID: session, sample: sample,
            installationID: installation, auth: h.auth)
        let replayed = try await h.api.updatePlaybackProgress(sessionID: session, sample: sample,
            installationID: installation, auth: h.auth)

        XCTAssertEqual(applied.outcome, "applied")
        XCTAssertEqual(stale.outcome, "stale_sample")
        XCTAssertEqual(stale.accepted?.sequence, 42)
        XCTAssertEqual(replayed.outcome, "replayed")
        let request = try XCTUnwrap(h.stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/playback/\(session)/progress")
        let sent = try body(request)
        XCTAssertEqual(Set(sent.keys), ["installation_id", "sequence", "position", "is_paused"])
        XCTAssertEqual(sent["sequence"] as? Int, 7)
        XCTAssertEqual(sent["position"] as? Double, 120.5)
        XCTAssertEqual(sent["is_paused"] as? Bool, true)
    }

    func testProgressRefusesAnUnknownOutcomeAndSurfacesAMissingSession() async throws {
        let h = try await makeHarness()
        let sample = try PlaybackSequencedSample(sequence: 1, position: 0, isPaused: false)
        h.stub.sequence([.json(200, #"{"outcome":"draining"}"#), .json(404, try fixture("not_found"))])

        await assertInvalidResponse {
            _ = try await h.api.updatePlaybackProgress(sessionID: session, sample: sample,
                installationID: installation, auth: h.auth)
        }
        do {
            _ = try await h.api.updatePlaybackProgress(sessionID: session, sample: sample,
                installationID: installation, auth: h.auth)
            XCTFail("expected a 404 problem")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 404)
        }
    }

    func testSequenceIsStrictlyIncreasingPerSession() {
        var sequence = PlaybackProgressSequence()
        XCTAssertEqual(sequence.next(for: "a"), 1)
        XCTAssertEqual(sequence.next(for: "a"), 2)
        XCTAssertEqual(sequence.next(for: "b"), 1, "each server session has its own counter")
        XCTAssertEqual(sequence.next(for: "a"), 3)
        sequence.forget("a")
        XCTAssertEqual(sequence.next(for: "a"), 1)
    }

    // MARK: Stop

    func testStopCarriesTheFinalSampleAndSettlesOnItsOwnStopID() async throws {
        let h = try await makeHarness()
        let stopID = "44444444-4444-4444-8444-444444444444"
        h.stub.reply(200, try fixture("playback_stop_completed"))
        let sample = try PlaybackSequencedSample(sequence: 9, position: 61, isPaused: true)

        let receipt = try await h.api.stopPlayback(sessionID: session, stopID: stopID, finalSample: sample,
            installationID: installation, auth: h.auth)

        XCTAssertEqual(receipt.outcome, "stopped")
        let request = try XCTUnwrap(h.stub.requests.single)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/api/v2/playback/\(session)")
        let sent = try body(request)
        XCTAssertEqual(sent["installation_id"] as? String, installation)
        XCTAssertEqual(sent["stop_id"] as? String, stopID)
        XCTAssertEqual(sent["sequence"] as? Int, 9)
        XCTAssertEqual(sent["position"] as? Double, 61)
    }

    func testStopWithoutASampleSendsNeitherSequenceNorPosition() async throws {
        let h = try await makeHarness()
        h.stub.reply(200, #"{"outcome":"replayed","stop_id":"55555555-5555-4555-8555-555555555555"}"#)

        let receipt = try await h.api.stopPlayback(sessionID: session, stopID: "44444444-4444-4444-8444-444444444444",
            finalSample: nil, installationID: installation, auth: h.auth)

        XCTAssertEqual(receipt.outcome, "replayed", "an earlier stop already ended the session")
        XCTAssertEqual(Set(try body(h.stub.requests.single).keys), ["installation_id", "stop_id"])
    }

    func testStopRefusesAReceiptForAnotherStopOrADrainingOutcome() async throws {
        let h = try await makeHarness()
        h.stub.sequence([.json(200, try fixture("playback_stop_completed")),
                         .json(200, try fixture("playback_stop_draining"))])
        for _ in 0..<2 {
            await assertInvalidResponse {
                _ = try await h.api.stopPlayback(sessionID: session, stopID: "66666666-6666-4666-8666-666666666666",
                    finalSample: nil, installationID: installation, auth: h.auth)
            }
        }
    }

    // MARK: Fences

    func testNonCanonicalSessionIDNeverLeavesTheDevice() async throws {
        let h = try await makeHarness()
        let sample = try PlaybackSequencedSample(sequence: 1, position: 0, isPaused: false)
        for bad in ["session-1", "../admin", "ABCDEF12-3456-4789-8ABC-DEF012345678"] {
            do {
                _ = try await h.api.updatePlaybackProgress(sessionID: bad, sample: sample,
                    installationID: installation, auth: h.auth)
                XCTFail("expected invalidSession for \(bad)")
            } catch PlaybackSequencedError.invalidSession {}
        }
        XCTAssertTrue(h.stub.requests.isEmpty)
    }

    func testMutationForAReplacedProfileIsNotSent() async throws {
        let h = try await makeHarness()
        await h.tokens.setProfileId("profile-two")
        do {
            _ = try await h.api.stopPlayback(sessionID: session, stopID: "44444444-4444-4444-8444-444444444444",
                finalSample: nil, installationID: installation, auth: h.auth)
            XCTFail("a stop captured for the old profile must not run for the new one")
        } catch HTTPError.authorityChanged {}
        XCTAssertTrue(h.stub.requests.isEmpty)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
