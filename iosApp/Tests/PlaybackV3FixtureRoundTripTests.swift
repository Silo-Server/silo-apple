import Foundation
import XCTest
@testable import Silo

/// Stage-0 characterization: every vendored Playback V3 fixture is readable,
/// and every fixture that has a production model survives a full
/// decode → encode → decode round trip through the app's own coding strategy.
///
/// The existing fixture tests assert individual fields. None of them proves
/// the models are *symmetric*: a key the app decodes but re-encodes under a
/// different name would pass a field assertion and still send the server
/// something it cannot read. Replans and route events are built from decoded
/// plans, so that asymmetry would only surface on the wire.
final class PlaybackV3FixtureRoundTripTests: XCTestCase {

    private static let allFixtures = [
        "attempt_keys",
        "capability_response",
        "conformance_matrix",
        "decision_response",
        "error_response",
        "replan_request",
        "route_event",
        "start_request",
        "subtitle_inventory"
    ]

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    // MARK: - Every fixture is present and is valid JSON

    func testEveryVendoredFixtureIsPresentAndParses() throws {
        for name in Self.allFixtures {
            let url = try PlaybackV3FixtureTestSupport.fixtureURL(
                named: name,
                bundleClass: Self.self
            )
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            XCTAssertTrue(
                object is [String: Any] || object is [[String: Any]],
                "\(name).json must be a JSON object or array of objects"
            )
        }
    }

    // MARK: - Round trips through the production models

    private func roundTrip<T: Codable & Equatable>(
        _ type: T.Type,
        named name: String
    ) throws -> T {
        let first = try PlaybackV3FixtureTestSupport.decode(
            type,
            named: name,
            bundleClass: Self.self
        )
        let reencoded = try encoder.encode(first)
        let second = try PlaybackV3FixtureTestSupport.decoder.decode(type, from: reencoded)
        XCTAssertEqual(first, second, "\(name) did not survive a round trip")
        return second
    }

    func testDecisionResponseRoundTrips() throws {
        let decision = try roundTrip(PlaybackV3DecisionResponse.self, named: "decision_response")
        let plan = try XCTUnwrap(decision.playbackPlan)

        // The round trip must preserve the fields the client echoes verbatim.
        XCTAssertEqual(plan.planAttemptKey, "v3:f0144c47fa349e3e")
        XCTAssertEqual(plan.delivery, "original_http")
        XCTAssertEqual(plan.subtitle.inventory.map(\.combinedIndex), [0, 1, 2, 3, 4])

        // And a plan re-decoded from its own encoding still validates.
        guard case .playable = decision.validatedForApple() else {
            return XCTFail("the golden decision must validate as playable")
        }
    }

    func testCapabilityAndStartRequestRoundTrip() throws {
        let capability = try roundTrip(
            PlaybackV3CapabilityResponse.self,
            named: "capability_response"
        )
        XCTAssertTrue(PlaybackSessionBridge.supportsNeutralProtocolV3(capability))

        let start = try roundTrip(PlaybackV3StartRequest.self, named: "start_request")
        XCTAssertEqual(start.protocolVersion, PlaybackProtocolV3.version)
        XCTAssertEqual(start.clientCapabilities.videoEvidence, PlaybackProtocolV3.Evidence.exact)
    }

    /// Every fixture the app has a production model for decodes into it, so a
    /// re-vendor that changes a shape fails here rather than on the wire.
    /// Two are excluded on purpose and pinned separately below: `route_event`
    /// (the sample is narrower than `PlaybackV3RouteEvent`) and `replan_request`
    /// (the server omits `local_mutations` when empty). The remaining three are
    /// server-side scenario documents with no Apple model at all.
    func testEveryFixtureWithAProductionModelDecodesIntoIt() throws {
        _ = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3CapabilityResponse.self,
            named: "capability_response",
            bundleClass: Self.self
        )
        _ = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3DecisionResponse.self,
            named: "decision_response",
            bundleClass: Self.self
        )
        _ = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3StartRequest.self,
            named: "start_request",
            bundleClass: Self.self
        )
    }

    /// PIN: `local_mutations` is `omitempty` on the server, so its generated
    /// replan sample omits the key, while `PlaybackV3ReplanRequest` declares it
    /// non-optional. Apple only ever *encodes* this type, so the asymmetry is
    /// benign — but it is the reason the fixture is not in the decode sweep
    /// above, and a model that starts decoding replans must close it first.
    func testReplanRequestFixtureOmitsLocalMutations() throws {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "replan_request",
            bundleClass: Self.self
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertNil(object["local_mutations"])
        XCTAssertEqual(object["plan_attempt_key"] as? String, "v3:f0144c47fa349e3e")
        XCTAssertThrowsError(
            try PlaybackV3FixtureTestSupport.decode(
                PlaybackV3ReplanRequest.self,
                named: "replan_request",
                bundleClass: Self.self
            )
        )

        // The request Apple actually builds always carries the key, so the
        // encoder side of the contract round-trips.
        let decoded = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3ReplanRequest.self,
            from: try JSONSerialization.data(
                withJSONObject: object.merging(["local_mutations": []]) { _, new in new }
            )
        )
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(
            try PlaybackV3FixtureTestSupport.decoder.decode(
                PlaybackV3ReplanRequest.self,
                from: reencoded
            ),
            decoded
        )
    }

    // MARK: - Fixtures with no production model

    /// `error_response` is the 426 upgrade envelope. Apple has no model for it
    /// (it is read as an opaque HTTP error), so the contract that matters is
    /// the envelope shape itself.
    func testErrorEnvelopeShape() throws {
        struct Envelope: Codable, Equatable {
            let error: String
            let message: String
        }
        let envelope = try roundTrip(Envelope.self, named: "error_response")
        XCTAssertEqual(envelope.error, "client_upgrade_required")
        XCTAssertFalse(envelope.message.isEmpty)
    }

    /// `attempt_keys` is a server-side conformance vector list, not a wire
    /// message: there is no Apple model to round-trip. What Apple must honour
    /// is that the key is opaque and echoed verbatim.
    func testAttemptKeyVectorsAreOpaqueAndSelfConsistent() throws {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "attempt_keys",
            bundleClass: Self.self
        )
        let vectors = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        )
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let key = try XCTUnwrap(vector["server_plan_attempt_key"] as? String)
            XCTAssertTrue(key.hasPrefix("v3:"), key)
            XCTAssertEqual(vector["replan_echo"] as? String, key)
            XCTAssertEqual(vector["attempted_plan_keys"] as? [String], [key])
        }
    }

    // MARK: - route_event: the client model is wider than the fixture

    /// PIN: current state of the vendored fixtures. The server's route-event
    /// sample carries only the fields it actually sends; `PlaybackV3RouteEvent`
    /// additionally declares `applied_quirk_ids` (and three optionals) as part
    /// of its own contract, so the sample is not decodable into the model as
    /// vendored. Re-vendoring is tracked as protocol drift — this pins which
    /// keys the two sides disagree on so the fix is checkable.
    func testRouteEventFixtureIsNarrowerThanTheAppleModel() throws {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "route_event",
            bundleClass: Self.self
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )

        // What the fixture does carry — the correlation identity Apple echoes.
        XCTAssertEqual(object["protocol_version"] as? Int, PlaybackProtocolV3.version)
        XCTAssertEqual(object["event"] as? String, "first_frame")
        XCTAssertEqual(object["plan_attempt_key"] as? String, "v3:f0144c47fa349e3e")
        XCTAssertEqual(object["output_context_id"] as? String, "7")

        // What it does not.
        for key in [
            "failure_classification",
            "fallback_reason",
            "applied_quirk_ids",
            "quirk_registry_revision"
        ] {
            XCTAssertNil(object[key], "\(key) unexpectedly present — re-vendor the fixture")
        }
    }

    /// The model Apple actually sends does round-trip, so the encoder side of
    /// the contract is sound even while the fixture lags.
    func testRouteEventModelRoundTrips() throws {
        let event = PlaybackV3RouteEvent(
            protocolVersion: PlaybackProtocolV3.version,
            playbackAttemptId: "attempt-golden-0001",
            sessionId: "11111111-1111-4111-8111-111111111111",
            planId: "plan:478677870860e5e5108c18bff749b34b",
            planAttemptId: "plan-attempt-golden-0001",
            planAttemptKey: "v3:f0144c47fa349e3e",
            event: "first_frame",
            failureClassification: nil,
            fallbackReason: nil,
            appliedQuirkIds: [],
            quirkRegistryRevision: nil,
            outputContextId: "7",
            diagnostics: ["first_frame_ms": "412"]
        )
        let encoded = try encoder.encode(event)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["plan_attempt_key"] as? String, "v3:f0144c47fa349e3e")
        XCTAssertEqual(object["output_context_id"] as? String, "7")
        XCTAssertNil(object["engine"], "route events must not name an Apple engine")

        let decoded = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3RouteEvent.self,
            from: encoded
        )
        XCTAssertEqual(decoded, event)
    }

    // MARK: - subtitle_inventory

    /// The inventory fixture is a server-side scenario document rather than a
    /// wire message; its contract for Apple is that combined ordinals are
    /// dense and gap-free, which is what subtitle identity translation relies
    /// on end to end.
    func testSubtitleInventoryOrdinalsAreDenseAndGapFree() throws {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "subtitle_inventory",
            bundleClass: Self.self
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let inventory = try XCTUnwrap(object["inventory"] as? [[String: Any]])
        let ordinals = inventory.compactMap { $0["combined_index"] as? Int }

        XCTAssertEqual(ordinals.count, inventory.count)
        XCTAssertEqual(ordinals, Array(0..<inventory.count))
    }
}
