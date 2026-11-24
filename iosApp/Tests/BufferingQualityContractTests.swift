import Foundation
import XCTest
@testable import Silo

/// The buffering-quality wire contract (silo-server
/// docs/design/2026-10-17-buffering-quality.md, "Wire contract"): what a start
/// or replan may carry, the plan's learned limit, the connection endpoints and
/// the `plan_summary` route event. Fixtures: Tests/Fixtures/PlaybackV3/SOURCE.
final class BufferingQualityContractTests: XCTestCase {
    private let installation = "11111111-1111-4111-8111-111111111111"
    private let feature = PlaybackProtocolV3.bufferingQualityFeature
    private let observedRebuffer = PlaybackProtocolV3.BandwidthEstimateSource.observedRebuffer

    // MARK: Helpers

    private func fixtureObject(_ name: String) throws -> [String: Any] {
        try APIv2FixtureTestSupport.jsonObject(APIv2FixtureTestSupport.data(named: name, bundleClass: Self.self))
    }

    /// Encoded the way `APIv2Client` encodes playback bodies.
    private func wireObject<T: Encodable>(_ body: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try APIv2FixtureTestSupport.jsonObject(encoder.encode(body))
    }

    /// The server's `validateBufferingQualityV3`: why it would refuse a body's
    /// buffering members, or nil when it accepts them. It spells the values
    /// as the server does, so a misspelled app constant fails here.
    private func serverRefusal(_ body: [String: Any]) -> String? {
        let source = body["bandwidth_estimate_source"] as? String
        let limit = body["learned_limit"] as? String
        let observed = body["observed_throughput_kbps"]
        guard source != nil || limit != nil || observed != nil else { return nil }
        guard (body["client_features"] as? [String] ?? []).contains(feature) else {
            return "buffering_quality_v1 is required for buffering quality fields"
        }
        if let source, !["probe", "observed_rebuffer"].contains(source) {
            return "invalid bandwidth_estimate_source"
        }
        if source != nil, body["bandwidth_estimate_kbps"] == nil {
            return "bandwidth_estimate_source requires bandwidth_estimate_kbps"
        }
        if let limit, !["ignore", "clear"].contains(limit) {
            return "invalid learned_limit"
        }
        if observed != nil, source != "observed_rebuffer" {
            return "observed_throughput_kbps requires bandwidth_estimate_source observed_rebuffer"
        }
        return nil
    }

    private func startRequest(_ buffering: PlaybackV3BufferingQualityRequest) -> PlaybackV3StartRequest {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        return PlaybackV3StartRequest(
            protocolVersion: 3, clientFeatures: buffering.clientFeatures, fileId: 42, profileId: "profile-1",
            playbackAttemptId: "apple:attempt", qualityPreference: "auto", subtitleFidelityPreference: "preserve",
            progressPersistence: nil, startPosition: 0, audioTrackId: nil, audioTrackIndex: nil,
            subtitleTrackId: nil, subtitleTrackIndex: nil, metered: false,
            bandwidthEstimateKbps: buffering.bandwidthEstimateKbps, bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context,
            bandwidthEstimateSource: buffering.bandwidthEstimateSource, learnedLimit: buffering.learnedLimit)
    }

    private func replanRequest(
        clientFeatures: [String],
        bandwidthEstimateKbps: Int?,
        bandwidthEstimateSource: String?,
        learnedLimit: String?,
        observedThroughputKbps: Int? = nil
    ) -> PlaybackV3ReplanRequest {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        return PlaybackV3ReplanRequest(
            protocolVersion: 3, clientFeatures: clientFeatures,
            operation: PlaybackProtocolV3.ReplanOperation.qualityChange, playbackAttemptId: "apple:attempt",
            replanRequestId: "apple-replan:request", failedPlanId: "plan:fixture", planAttemptId: "apple-plan:attempt",
            planAttemptKey: "v3:opaque-fixture", attemptedPlanKeys: [], attemptCount: 1, qualityPreference: "auto",
            positionSeconds: 42.5, metered: false, bandwidthEstimateKbps: bandwidthEstimateKbps, bandwidthCapKbps: nil,
            selectedTracks: PlaybackV3SelectedTracks(audio: nil, subtitle: nil), failure: nil, localMutations: [],
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context,
            bandwidthEstimateSource: bandwidthEstimateSource, learnedLimit: learnedLimit,
            observedThroughputKbps: observedThroughputKbps)
    }

    private func replanRequest(_ buffering: PlaybackV3BufferingQualityRequest) -> PlaybackV3ReplanRequest {
        replanRequest(clientFeatures: buffering.clientFeatures, bandwidthEstimateKbps: buffering.bandwidthEstimateKbps,
                      bandwidthEstimateSource: buffering.bandwidthEstimateSource, learnedLimit: buffering.learnedLimit,
                      observedThroughputKbps: buffering.observedThroughputKbps)
    }

    private func stepDown(advertised: Bool, mode: BufferingQualityMode = .always) -> PlaybackV3BufferingQualityRequest {
        PlaybackV3BufferingQualityRequest(
            baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: advertised, mode: mode,
            bandwidthEstimateKbps: 44_100, bandwidthEstimateSource: observedRebuffer)
    }

    // MARK: Requests

    /// Against a server without the feature the same replan goes out with
    /// its estimate and without the two members, so nothing is refused.
    func testStartAndReplanCarryTheFeatureAndMembersOnlyWhereTheServerAdvertisesIt() throws {
        for advertised in [true, false] {
            let buffering = stepDown(advertised: advertised)
            let bodies = [
                try wireObject(APIv2PlaybackStartBody(startRequest(buffering), installationID: installation)),
                try wireObject(APIv2PlaybackReplanBody(installationID: installation, request: replanRequest(buffering))),
            ]
            for body in bodies {
                let features = try XCTUnwrap(body["client_features"] as? [String])
                XCTAssertEqual(features.contains(feature), advertised)
                XCTAssertEqual(features.filter { $0 != feature }, ApplePlaybackV3Capabilities.features,
                               "the start's list is kept, so a replan does not drop a negotiated feature")
                XCTAssertEqual(body["bandwidth_estimate_kbps"] as? Int, 44_100)
                XCTAssertEqual(body["bandwidth_estimate_source"] as? String, advertised ? observedRebuffer : nil)
                XCTAssertNil(body["learned_limit"])
                XCTAssertNil(serverRefusal(body))
            }
        }
    }

    /// A start sends a fresh probe result as its estimate, sourced `probe`
    /// only where the server takes sources.
    func testAStartCarriesTheProbeEstimate() throws {
        for advertised in [true, false] {
            let buffering = PlaybackV3BufferingQualityRequest(
                baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: advertised, mode: .always,
                bandwidthEstimateKbps: 48_000, bandwidthEstimateSource: PlaybackProtocolV3.BandwidthEstimateSource.probe)
            let body = try wireObject(APIv2PlaybackStartBody(startRequest(buffering), installationID: installation))
            XCTAssertEqual(body["bandwidth_estimate_kbps"] as? Int, 48_000)
            XCTAssertEqual(body["bandwidth_estimate_source"] as? String, advertised ? "probe" : nil)
            XCTAssertNil(serverRefusal(body))
        }
    }

    func testNeverModeIgnoresTheLearnedLimitUnlessTheCallerChose() {
        let never = PlaybackV3BufferingQualityRequest(
            baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: true, mode: .never)
        XCTAssertEqual(never.learnedLimit, PlaybackProtocolV3.LearnedLimit.ignore)
        XCTAssertNil(never.bandwidthEstimateKbps)
        XCTAssertNil(never.bandwidthEstimateSource)

        // Restore quality clears the limit whatever the mode.
        for mode in BufferingQualityMode.allCases {
            let restore = PlaybackV3BufferingQualityRequest(
                baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: true, mode: mode,
                learnedLimit: PlaybackProtocolV3.LearnedLimit.clear)
            XCTAssertEqual(restore.learnedLimit, PlaybackProtocolV3.LearnedLimit.clear, "\(mode)")
        }
        for mode in [BufferingQualityMode.ask, .always] {
            let request = PlaybackV3BufferingQualityRequest(
                baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: true, mode: mode)
            XCTAssertNil(request.learnedLimit, "the limit applies in \(mode)")
        }

        let oldServer = PlaybackV3BufferingQualityRequest(
            baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: false, mode: .never,
            learnedLimit: PlaybackProtocolV3.LearnedLimit.clear)
        XCTAssertNil(oldServer.learnedLimit)
        XCTAssertEqual(oldServer.clientFeatures, ApplePlaybackV3Capabilities.features)
    }

    /// A lowering reports the plan's throughput with `observed_rebuffer`;
    /// no other request may carry it.
    func testObservedThroughputRidesOnlyOnAnObservedRebuffer() throws {
        let cases: [(String?, Bool, Int?)] = [
            (observedRebuffer, true, 21_000),
            (PlaybackProtocolV3.BandwidthEstimateSource.probe, true, nil),
            (nil, true, nil),
            (observedRebuffer, false, nil),
        ]
        for (source, advertised, expected) in cases {
            let buffering = PlaybackV3BufferingQualityRequest(
                baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: advertised, mode: .always,
                bandwidthEstimateKbps: 44_100, bandwidthEstimateSource: source, observedThroughputKbps: 21_000)
            let body = try wireObject(APIv2PlaybackReplanBody(installationID: installation, request: replanRequest(buffering)))
            XCTAssertEqual(body["observed_throughput_kbps"] as? Int, expected, "\(source ?? "none"), \(advertised)")
            XCTAssertNil(serverRefusal(body))
        }
    }

    func testAnEstimateSourceIsNeverSentWithoutAnEstimate() throws {
        let buffering = PlaybackV3BufferingQualityRequest(
            baseFeatures: ApplePlaybackV3Capabilities.features, serverAdvertisesFeature: true, mode: .always,
            bandwidthEstimateSource: observedRebuffer)
        XCTAssertNil(buffering.bandwidthEstimateSource)
        let body = try wireObject(APIv2PlaybackReplanBody(installationID: installation, request: replanRequest(buffering)))
        XCTAssertNil(body["bandwidth_estimate_source"])
        XCTAssertNil(body["bandwidth_estimate_kbps"])
    }

    /// The published valid requests survive Apple's models and wire bodies
    /// with their buffering members intact.
    func testTheValidFixturesBufferingMembersRoundTrip() throws {
        let startFixture = try fixtureObject("buffering-start_request")
        let start = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3StartRequest.self, named: "buffering-start_request", bundleClass: Self.self)
        let startBody = try wireObject(APIv2PlaybackStartBody(start, installationID: installation))

        let replanFixture = try fixtureObject("buffering-replan_request")
        let replanFeatures = try XCTUnwrap(replanFixture["client_features"] as? [String])
        let buffering = PlaybackV3BufferingQualityRequest(
            baseFeatures: replanFeatures.filter { $0 != feature }, serverAdvertisesFeature: true, mode: .always,
            bandwidthEstimateKbps: replanFixture["bandwidth_estimate_kbps"] as? Int,
            bandwidthEstimateSource: replanFixture["bandwidth_estimate_source"] as? String,
            learnedLimit: replanFixture["learned_limit"] as? String)
        let replanBody = try wireObject(APIv2PlaybackReplanBody(installationID: installation, request: replanRequest(buffering)))

        for (fixture, body) in [(startFixture, startBody), (replanFixture, replanBody)] {
            for key in ["client_features", "bandwidth_estimate_kbps", "bandwidth_estimate_source"] {
                let expected = try XCTUnwrap(fixture[key] as? NSObject, key)
                XCTAssertEqual(body[key] as? NSObject, expected, key)
            }
            // Present on the start (`ignore`), absent on the lowering.
            XCTAssertEqual(body["learned_limit"] as? String, fixture["learned_limit"] as? String)
            XCTAssertNil(serverRefusal(body))
        }
        XCTAssertEqual(startFixture["learned_limit"] as? String, PlaybackProtocolV3.LearnedLimit.ignore)
    }

    /// The published invalid requests carry members the server refuses. Fed
    /// straight into Apple's request models, the wire bodies still drop them.
    func testTheEncoderCannotProduceTheInvalidFixturesShapes() throws {
        for name in ["buffering-without-feature-start_request", "buffering-source-without-estimate-start_request"] {
            XCTAssertNotNil(serverRefusal(try fixtureObject(name)), "\(name) is a refused shape")
            let request = try PlaybackV3FixtureTestSupport.decode(
                PlaybackV3StartRequest.self, named: name, bundleClass: Self.self)
            let body = try wireObject(APIv2PlaybackStartBody(request, installationID: installation))
            XCTAssertNil(serverRefusal(body), name)
        }
        for name in ["buffering-without-feature-replan_request", "buffering-source-without-estimate-replan_request"] {
            let fixture = try fixtureObject(name)
            XCTAssertNotNil(serverRefusal(fixture), "\(name) is a refused shape")
            let request = replanRequest(
                clientFeatures: try XCTUnwrap(fixture["client_features"] as? [String]),
                bandwidthEstimateKbps: fixture["bandwidth_estimate_kbps"] as? Int,
                bandwidthEstimateSource: fixture["bandwidth_estimate_source"] as? String,
                learnedLimit: fixture["learned_limit"] as? String)
            let body = try wireObject(APIv2PlaybackReplanBody(installationID: installation, request: request))
            XCTAssertNil(serverRefusal(body), name)
        }
        // A source without an estimate keeps the rest of what the feature allows.
        let request = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3StartRequest.self, named: "buffering-source-without-estimate-start_request", bundleClass: Self.self)
        let body = try wireObject(APIv2PlaybackStartBody(request, installationID: installation))
        XCTAssertEqual(body["learned_limit"] as? String, PlaybackProtocolV3.LearnedLimit.ignore)
        XCTAssertNil(body["bandwidth_estimate_source"])
    }

    // MARK: The plan's learned limit

    func testTheLearnedLimitDecodesOnBothSurfacesAndLabelsAuto() throws {
        let domain = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3DecisionResponse.self, named: "learned-limit-decision_response", bundleClass: Self.self)
        // A 5000 kbps limit lowered an Auto start to a 720p transcode.
        let expected = PlaybackV3BandwidthLimit(kbps: 5_000, source: observedRebuffer, expiresAt: "2030-01-07T23:55:00Z")
        XCTAssertEqual(domain.playbackPlan?.bandwidthLimit, expected)

        // The v2 surface spells file ids as opaque strings.
        var object = try fixtureObject("learned-limit-decision_response")
        var plan = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var source = try XCTUnwrap(plan["source"] as? [String: Any])
        source["media_file_id"] = "42"
        plan["source"] = source
        plan["requested_media_file_id"] = "42"
        plan["effective_media_file_id"] = "42"
        object["playback_plan"] = plan
        let limited = try XCTUnwrap(PlaybackV3FixtureTestSupport.v2Decision(object).playbackPlan)
        XCTAssertEqual(limited.bandwidthLimit, expected)

        let limitedAuto = try XCTUnwrap(ApplePlaybackQuality.playbackOptions(
            serverQualities: limited.availableQualities, bandwidthLimit: limited.bandwidthLimit
        ).first)
        XCTAssertEqual(limitedAuto, ApplePlaybackQuality.autoLimitedAfterBuffering)
        XCTAssertEqual(limitedAuto.id, ApplePlaybackQuality.autoId, "still the Auto row the menu selects")
        XCTAssertTrue(limitedAuto.isAuto)
        XCTAssertNotEqual(limitedAuto.label, ApplePlaybackQuality.auto.label)

        let unlimited = try XCTUnwrap(PlaybackV3FixtureTestSupport.v2Decision(bundleClass: Self.self).playbackPlan)
        XCTAssertNil(unlimited.bandwidthLimit)
        XCTAssertEqual(
            ApplePlaybackQuality.playbackOptions(serverQualities: unlimited.availableQualities,
                                                 bandwidthLimit: unlimited.bandwidthLimit).first,
            ApplePlaybackQuality.auto)
        XCTAssertEqual(ApplePlaybackQuality.playbackOptions(serverQualities: [], bandwidthLimit: expected),
                       [ApplePlaybackQuality.autoLimitedAfterBuffering])
    }

    // MARK: Connection endpoints

    /// The design's example, with every phase 2 member present.
    private static let connectionExample = #"""
    {
      "connection": "remote",
      "probe": { "kbps": 48000, "measured_at": "2026-10-17T19:02:11Z", "transport": "wifi" },
      "learned_limit": { "kbps": 44100, "observed_at": "2026-10-17T16:21:40Z", "expires_at": "2026-10-24T16:21:40Z" },
      "auto_budget_kbps": 35280
    }
    """#

    func testTheConnectionStateDecodesBothPhasesLeniently() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let full = try decoder.decode(APIv2PlaybackConnection.self, from: Data(Self.connectionExample.utf8))
        XCTAssertEqual(full.connection, "remote")
        XCTAssertEqual(full.learnedLimit?.kbps, 44_100)
        XCTAssertEqual(full.learnedLimit?.observedAt, ISO8601DateFormatter().date(from: "2026-10-17T16:21:40Z"))
        XCTAssertEqual(full.learnedLimit?.expiresAt, ISO8601DateFormatter().date(from: "2026-10-24T16:21:40Z"))
        XCTAssertEqual(full.probe?.kbps, 48_000)
        XCTAssertEqual(full.probe?.transport, "wifi")
        XCTAssertEqual(full.autoBudgetKbps, 35_280)

        // Phase 1: a nullable limit and no phase 2 members. Go also writes
        // fractional seconds.
        let phaseOne = try decoder.decode(APIv2PlaybackConnection.self, from: Data(
            #"{"connection":"local","learned_limit":{"kbps":2000,"observed_at":"2026-10-17T16:21:40.123456Z","expires_at":"2026-10-24T16:21:40.123456Z"}}"#.utf8))
        XCTAssertEqual(phaseOne.learnedLimit?.kbps, 2_000)
        XCTAssertNil(phaseOne.probe)
        XCTAssertNil(phaseOne.autoBudgetKbps)
        let none = try decoder.decode(APIv2PlaybackConnection.self, from: Data(
            #"{"connection":"provider:tailscale","learned_limit":null}"#.utf8))
        XCTAssertNil(none.learnedLimit)

        // A malformed optional member reads as absent.
        let odd = try decoder.decode(APIv2PlaybackConnection.self, from: Data(
            #"{"connection":"remote","probe":"soon","auto_budget_kbps":"35280","learned_limit":{"kbps":44100}}"#.utf8))
        XCTAssertNil(odd.probe)
        XCTAssertNil(odd.autoBudgetKbps)
        XCTAssertNil(odd.learnedLimit)
    }

    private func makeAPI() async throws -> (APIv2Client, APIv2TestStub, CapturedOrdinaryRequestAuth) {
        let name = "BufferingQualityContractTests.\(UUID().uuidString)"
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
        return (api, stub, try XCTUnwrap(captured))
    }

    func testTheConnectionEndpointsNameTheProfileAndDevice() async throws {
        let (api, stub, auth) = try await makeAPI()
        stub.reply(200, Self.connectionExample)
        let state = try await api.playbackConnection(auth: auth)
        XCTAssertEqual(state.learnedLimit?.kbps, 44_100)

        stub.reply(204, "")
        try await api.resetPlaybackLearnedLimit(auth: auth)

        XCTAssertEqual(stub.methods, ["GET", "DELETE"])
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/playback/connection", "/api/v2/playback/connection/learned-limit"])
        for request in stub.requests {
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
            XCTAssertEqual(request.header("x-silo-device-id"), AppleDeviceIdentity.current.id)
            XCTAssertNil(request.body.flatMap { $0.isEmpty ? nil : $0 }, "neither request has a body")
        }

        // Reset answers 204 only.
        stub.reply(200, "{}")
        do {
            try await api.resetPlaybackLearnedLimit(auth: auth)
            XCTFail("expected an invalid response")
        } catch PlaybackSequencedError.invalidResponse {}
    }

    func testTheResetIsItsOwnMutationAndNotASessionStop() {
        let reset = APIv2MutationCatalog.operation(method: "DELETE", path: "/api/v2/playback/connection/learned-limit")
        XCTAssertEqual(reset?.template, "/api/v2/playback/connection/learned-limit")
        XCTAssertEqual(reset?.retrySafety, .nonRetryable)
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/playback/connection", method: "GET"))
    }

    /// A speed-test result is sent once, as the contract marks it.
    func testAProbeResultIsANonRetryableMutation() {
        let report = APIv2MutationCatalog.operation(method: "POST", path: "/api/v2/playback/bandwidth-probe/results")
        XCTAssertEqual(report?.template, "/api/v2/playback/bandwidth-probe/results")
        XCTAssertEqual(report?.retrySafety, .nonRetryable)
        XCTAssertEqual(report?.replaysAfterRefresh, false)
    }

    // MARK: plan_summary

    func testAPlanSummaryEncodesAsThePublishedRouteEvent() throws {
        let fixture = try fixtureObject("plan-summary-route_event")
        // The event is a lowered plan's summary: the decision fixture's plan,
        // under the plan id the event names.
        var object = try fixtureObject("learned-limit-decision_response")
        var lowered = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        lowered["plan_id"] = try XCTUnwrap(fixture["plan_id"] as? String)
        object["playback_plan"] = lowered
        let decision = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self, from: JSONSerialization.data(withJSONObject: object))
        let plan = try XCTUnwrap(decision.playbackPlan)
        let prepared = PreparedPlaybackV3(
            playbackAttemptId: try XCTUnwrap(fixture["playback_attempt_id"] as? String),
            planAttemptId: try XCTUnwrap(fixture["plan_attempt_id"] as? String),
            planAttemptKey: try XCTUnwrap(fixture["plan_attempt_key"] as? String),
            outputContextId: fixture["output_context_id"] as? String,
            serverFeatures: [PlaybackProtocolV3.planSummaryFeature],
            plan: plan)
        XCTAssertTrue(prepared.advertisesPlanSummary)
        XCTAssertFalse(prepared.advertisesBufferingQuality)
        // The controller's own plan id never goes on the wire.
        let summary = BufferingQualityController.PlanSummary(
            planId: "local:summary", playedMs: 600_000, stallCount: 2, stallTotalMs: 8_000, stallLongestMs: 6_000,
            deliveredKbps: 8_000, mode: .always, action: .lowered, bandwidthEstimateKbps: nil,
            throughputKbps: 6_200)
        let event = PlaybackSessionBridge.planSummaryRouteEvent(
            summary, for: prepared, sessionId: try XCTUnwrap(fixture["session_id"] as? String))

        var body = try wireObject(APIv2PlaybackRouteEventBody(installationID: installation, eventID: "event", event: event))
        body.removeValue(forKey: "installation_id")
        body.removeValue(forKey: "event_id")
        // Schema-optional, and empty for a plan with no quirks.
        XCTAssertEqual(body.removeValue(forKey: "applied_quirk_ids") as? [String], [])
        XCTAssertEqual(body as NSDictionary, fixture as NSDictionary)

        let estimated = BufferingQualityController.PlanSummary(
            planId: "local:estimated", playedMs: 1, stallCount: 0, stallTotalMs: 0, stallLongestMs: 0,
            deliveredKbps: nil, mode: .never, action: .ignored, bandwidthEstimateKbps: 44_100)
        XCTAssertEqual(estimated.routeEventDiagnostics["bandwidth_estimate_kbps"], "44100")
        XCTAssertNil(estimated.routeEventDiagnostics["delivered_kbps"], "an unknown bitrate is left out")
    }
}
