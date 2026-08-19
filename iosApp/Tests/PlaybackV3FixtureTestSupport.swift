import Foundation
import XCTest
@testable import Silo

enum PlaybackV3FixtureTestSupport {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func fixtureURL(named name: String, bundleClass: AnyClass) throws -> URL {
        try XCTUnwrap(
            Bundle(for: bundleClass).url(forResource: name, withExtension: "json"),
            "Missing vendored Playback V3 fixture \(name).json"
        )
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        named name: String,
        bundleClass: AnyClass
    ) throws -> T {
        try decoder.decode(
            type,
            from: Data(contentsOf: fixtureURL(named: name, bundleClass: bundleClass))
        )
    }
}

/// Builds a planner execution plan from the fields the tests actually vary.
/// `selectedAudioTrackId`, `pendingAudioFfIndex` and
/// `selectedSecondarySubtitleTrackId` are `nil` at every call site.
func makeTestExecutionPlan(
    session: PlaybackSessionResponse,
    version: FileVersion,
    streamRequest: StreamRequest,
    routeRequirements: PlaybackRouteRequirements = .baseline,
    preferredAudioTrackIndex: Int? = nil,
    selectedPrimarySubtitleTrackId: Int64? = nil,
    dolbyVisionPolicy: DolbyVisionPolicy.Snapshot = .default
) -> PlaybackExecutionPlan {
    ApplePlaybackRoutePlanner().makeExecutionPlan(
        input: ApplePlaybackPlannerInput(
            session: session,
            selectedVersion: version,
            streamRequest: streamRequest,
            routeRequirements: routeRequirements,
            selectedAudioTrackId: nil,
            pendingAudioFfIndex: nil,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            selectedPrimarySubtitleTrackId: selectedPrimarySubtitleTrackId,
            selectedSecondarySubtitleTrackId: nil,
            dolbyVisionPolicy: dolbyVisionPolicy
        )
    )
}
