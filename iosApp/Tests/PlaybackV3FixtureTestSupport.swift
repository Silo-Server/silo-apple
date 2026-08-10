import Foundation
import XCTest

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
