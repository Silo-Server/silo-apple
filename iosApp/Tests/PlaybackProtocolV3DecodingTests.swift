import Foundation
import XCTest
@testable import Silo

/// Wire-tolerance and wire-strictness tests for the V3 decision response.
///
/// Every case here starts from the vendored server decision fixture and edits a
/// parsed copy in memory — the fixture on disk stays byte-for-byte identical to
/// silo-server, which is the only way it can keep working as a cross-repo
/// conformance gate.
final class PlaybackProtocolV3DecodingTests: XCTestCase {
    private enum TestFailure: Error {
        case decisionWasNotPlayable
    }

    // MARK: - Optional bitrate_kbps

    func testOriginalRungWithoutBitrateStillDecodes() throws {
        // Only `label` and `preserves_source` are required on the wire, and the
        // Original rung copies the source's probed bitrate — a source whose
        // bitrate the server could not determine omits the key entirely.
        let plan = try playablePlan(
            try replacingQualityRungs(
                with: [["label": "original", "height": 1_080, "preserves_source": true]]
            )
        )
        XCTAssertNil(plan.availableQualities.first?.bitrateKbps)

        let options = ApplePlaybackQuality.playbackOptions(
            serverQualities: plan.availableQualities,
            fallbackVersion: nil
        )
        XCTAssertEqual(options.map(\.id), ["auto", "original"])
        XCTAssertEqual(options.map(\.bitrateKbps), [0, 0])
        XCTAssertEqual(options.last?.label, "Original")
    }

    func testAudioOnlyRungWithoutHeightOrBitrateDecodes() throws {
        let plan = try playablePlan(
            try replacingQualityRungs(
                with: [["label": "audio_high", "preserves_source": false]]
            )
        )
        let rung = try XCTUnwrap(plan.availableQualities.first)
        XCTAssertNil(rung.height)
        XCTAssertNil(rung.bitrateKbps)

        let options = ApplePlaybackQuality.playbackOptions(
            serverQualities: plan.availableQualities,
            fallbackVersion: nil
        )
        XCTAssertEqual(options.map(\.id), ["auto", "audio_high"])
        XCTAssertEqual(options.last?.resolution, "")
        XCTAssertEqual(options.last?.bitrateKbps, 0)
    }

    func testRungWithHeightAndBitratePresentDecodes() throws {
        let plan = try playablePlan(try decisionObject())
        let rung = try XCTUnwrap(plan.availableQualities.first)
        XCTAssertEqual(rung.label, "original")
        XCTAssertEqual(rung.height, 1_080)
        XCTAssertEqual(rung.bitrateKbps, 8_000)
    }

    // MARK: - Transformation descriptors

    func testAdvertisedRecipeVersionAndClaimsValidate() throws {
        let descriptor = try XCTUnwrap(
            ApplePlaybackV3Capabilities.clientTransformationDescriptor(named: "client_dv7_to_dv81")
        )
        let plan = try playablePlan(
            try replacingTransformations(with: [wireTransformation(descriptor)])
        )
        XCTAssertNoThrow(try ApplePlaybackV3PlanAdapter.validate(plan))
    }

    func testFutureRecipeVersionIsRejected() throws {
        let descriptor = try XCTUnwrap(
            ApplePlaybackV3Capabilities.clientTransformationDescriptor(named: "client_dv7_to_dv81")
        )
        var transformation = wireTransformation(descriptor)
        transformation["recipe_version"] = "2"
        let plan = try playablePlan(try replacingTransformations(with: [transformation]))

        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(plan)) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .unsupportedClientTransformation("client_dv7_to_dv81 recipe version 2")
            )
        }
    }

    func testUnadvertisedValidatedClaimIsRejected() throws {
        let descriptor = try XCTUnwrap(
            ApplePlaybackV3Capabilities.clientTransformationDescriptor(named: "client_dv7_to_hdr10")
        )
        var transformation = wireTransformation(descriptor)
        transformation["validated_claims"] = descriptor.validatedClaims + ["chroma_upsampled"]
        let plan = try playablePlan(try replacingTransformations(with: [transformation]))

        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(plan)) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .unsupportedClientTransformation("client_dv7_to_hdr10 claim chroma_upsampled")
            )
        }
    }

    func testAdvertisedTransformationsComeFromTheDescriptorRegistry() {
        XCTAssertFalse(ApplePlaybackV3Capabilities.clientTransformationDescriptors.isEmpty)
        let advertised = ApplePlaybackV3Capabilities.snapshot()
            .context
            .deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]?
            .transformations ?? []
        for transformation in advertised {
            XCTAssertEqual(
                transformation,
                ApplePlaybackV3Capabilities.clientTransformationDescriptor(named: transformation.name)
            )
        }
    }

    // MARK: - Retired feature token

    func testOriginalDeliveryNoLongerAdvertisesPlayerCore() throws {
        let original = try XCTUnwrap(
            ApplePlaybackV3Capabilities.snapshot()
                .context
                .deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertFalse(original.features.contains("apple_playercore"))
        XCTAssertEqual(
            original.features,
            ["apple_native_direct", "apple_local_loopback", "client_audio_track_selection_v1"]
        )
    }

    // MARK: - Fixture editing helpers

    private func decisionObject() throws -> [String: Any] {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func replacingQualityRungs(with rungs: [[String: Any]]) throws -> [String: Any] {
        try mutatingPlan { $0["available_qualities"] = rungs }
    }

    private func replacingTransformations(
        with transformations: [[String: Any]]
    ) throws -> [String: Any] {
        try mutatingPlan { $0["transformations"] = transformations }
    }

    private func mutatingPlan(_ mutate: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var decision = try decisionObject()
        var plan = try XCTUnwrap(decision["playback_plan"] as? [String: Any])
        mutate(&plan)
        decision["playback_plan"] = plan
        return decision
    }

    private func wireTransformation(_ descriptor: PlaybackV3Transformation) -> [String: Any] {
        [
            "name": descriptor.name,
            "executor": descriptor.executor,
            "recipe_version": descriptor.recipeVersion,
            "validated_claims": descriptor.validatedClaims
        ]
    }

    private func playablePlan(
        _ decision: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlaybackV3Plan {
        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: decision)
        )
        guard case .playable(let plan, _) = response.validatedForApple() else {
            XCTFail("Expected the edited decision fixture to stay playable", file: file, line: line)
            throw TestFailure.decisionWasNotPlayable
        }
        return plan
    }
}
