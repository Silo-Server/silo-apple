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

    /// The server's published v2 start decision
    /// (`Tests/Fixtures/APIv2/playback_start_opaque_ids.json`): the shape the
    /// client receives, with opaque string file ids and `/api/v2` media URLs.
    /// Its feature list is a subset; `header_authenticated_media_v1`, which
    /// the server always advertises and this client requires, is added the
    /// way the capability fixtures add it.
    static func v2DecisionObject(bundleClass: AnyClass) throws -> [String: Any] {
        let data = try APIv2FixtureTestSupport.data(named: "playback_start_opaque_ids", bundleClass: bundleClass)
        var object = try APIv2FixtureTestSupport.jsonObject(data)
        let features = object["server_features"] as? [String] ?? []
        object["server_features"] = features + [PlaybackProtocolV3.headerAuthenticatedMediaFeature]
        return object
    }

    /// Decodes a (possibly edited) v2 decision object the way the client does.
    static func v2Decision(_ object: [String: Any]) throws -> PlaybackV3DecisionResponse {
        try HTTPClient.makeJSONDecoder().decode(
            APIv2PlaybackDecision.self, from: JSONSerialization.data(withJSONObject: object)
        ).legacy()
    }

    static func v2Decision(bundleClass: AnyClass) throws -> PlaybackV3DecisionResponse {
        try v2Decision(v2DecisionObject(bundleClass: bundleClass))
    }

    /// A plan object taken from the v2 decision, decoded as the player's plan.
    static func v2Plan(_ object: [String: Any]) throws -> PlaybackV3Plan {
        try HTTPClient.makeJSONDecoder().decode(
            APIv2PlaybackPlan.self, from: JSONSerialization.data(withJSONObject: object)
        ).legacy()
    }
}
