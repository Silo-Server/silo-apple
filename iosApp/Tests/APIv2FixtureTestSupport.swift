import Foundation
import XCTest
@testable import Silo

/// Loads the vendored API v2 fixtures (Tests/Fixtures/APIv2) and decodes them
/// with the production decoder — never a test-only lenient one.
enum APIv2FixtureTestSupport {
    struct IndexEntry: Decodable {
        struct Request: Decodable {
            let method: String
            let path: String
            let headers: [String: String]?
            let body: String?
        }

        let name: String
        let operationId: String?
        let scenario: String
        let request: Request
        let expectedStatus: Int
        let responseHeaders: [String: String]
        let responseMediaType: String
        let schema: String
        let bodyFile: String
    }

    private struct Index: Decodable {
        let fixtures: [IndexEntry]
    }

    static var decoder: JSONDecoder { HTTPClient.makeJSONDecoder() }

    static func fixtureURL(named name: String, bundleClass: AnyClass) throws -> URL {
        try XCTUnwrap(
            Bundle(for: bundleClass).url(forResource: name, withExtension: "json"),
            "Missing vendored API v2 fixture \(name).json"
        )
    }

    static func data(named name: String, bundleClass: AnyClass) throws -> Data {
        try Data(contentsOf: fixtureURL(named: name, bundleClass: bundleClass))
    }

    static func index(bundleClass: AnyClass) throws -> [IndexEntry] {
        // The index is metadata about the fixtures, not server output, but it
        // is also snake_case and the production decoder reads it fine.
        try decoder.decode(Index.self, from: data(named: "index", bundleClass: bundleClass)).fixtures
    }

    static func entry(named name: String, bundleClass: AnyClass) throws -> IndexEntry {
        try XCTUnwrap(
            index(bundleClass: bundleClass).first { $0.name == name },
            "index.json has no entry named \(name)"
        )
    }

    static func decode<T: Decodable>(_ type: T.Type, named name: String, bundleClass: AnyClass) throws -> T {
        try decoder.decode(type, from: data(named: name, bundleClass: bundleClass))
    }

    /// Re-serializes a fixture body after applying `mutate` to its top-level
    /// object, for the unknown-member and unknown-enum probes.
    static func mutatedBody(
        named name: String,
        bundleClass: AnyClass,
        mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data(named: name, bundleClass: bundleClass)) as? [String: Any]
        )
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
