import Foundation
import XCTest
@testable import Silo

/// Pins the transport's 401 refresh-and-resend allowlist
/// (`APIv2MutationCatalog`) to the server contract's `x-silo-retry-safety`
/// annotations, vendored as `Fixtures/APIv2RetrySafety/apiv2-retry-safety.json`.
final class APIv2RetrySafetyTests: XCTestCase {
    private struct ContractOperation: Decodable {
        let method: String
        let path: String
        let retrySafety: String

        enum CodingKeys: String, CodingKey {
            case method
            case path
            case retrySafety = "retry_safety"
        }
    }

    private func contract() throws -> [ContractOperation] {
        let data = try APIv2FixtureTestSupport.data(named: "apiv2-retry-safety", bundleClass: Self.self)
        return try JSONDecoder().decode([ContractOperation].self, from: data)
    }

    /// A concrete request path for a template: every `{...}` segment becomes `p1`.
    private func concretePath(_ template: String) -> String {
        "/" + template.split(separator: "/")
            .map { $0.hasPrefix("{") && $0.hasSuffix("}") ? "p1" : String($0) }
            .joined(separator: "/")
    }

    private let clientSingleDispatch: [(method: String, template: String)] = [
        ("POST", "/api/v2/playback/sessions/{session_id}/control/ws-ticket"),
        ("POST", "/api/v2/playback/{session_id}/replan"),
        ("POST", "/api/v2/catalog/items/{id}/translate-description"),
        ("POST", "/api/v2/devices/push/apple"),
    ]

    // MARK: Contract

    func testCatalogMatchesVendoredContract() throws {
        let contract = try contract()
        XCTAssertFalse(contract.isEmpty)
        var classes: [String: APIv2RetrySafety] = [:]
        for entry in contract {
            classes["\(entry.method) \(entry.path)"] = try XCTUnwrap(
                APIv2RetrySafety(rawValue: entry.retrySafety),
                "unknown x-silo-retry-safety class \(entry.retrySafety) on \(entry.method) \(entry.path)"
            )
        }
        var seen: Set<String> = []
        for operation in APIv2MutationCatalog.operations {
            let key = "\(operation.method) \(operation.template)"
            XCTAssertTrue(seen.insert(key).inserted, "\(key) is in the catalog twice")
            guard let expected = classes[key] else {
                XCTFail("\(key) is not an annotated operation in the vendored contract")
                continue
            }
            XCTAssertEqual(operation.retrySafety, expected, "\(key) disagrees with the contract")
        }
    }

    func testEveryNonRetryableContractOperationIsSentOnce() throws {
        let nonRetryable = try contract().filter { $0.retrySafety == APIv2RetrySafety.nonRetryable.rawValue }
        XCTAssertFalse(nonRetryable.isEmpty)
        for entry in nonRetryable {
            XCTAssertFalse(
                HTTPClient.shouldAttemptRefresh(path: concretePath(entry.path), method: entry.method),
                "\(entry.method) \(entry.path) is non_retryable but would be refreshed and re-sent"
            )
        }
    }

    // MARK: Catalog

    func testEveryReplayAllowedCatalogOperationIsReplayed() {
        let replayed = APIv2MutationCatalog.operations.filter(\.replaysAfterRefresh)
        XCTAssertFalse(replayed.isEmpty)
        for operation in replayed {
            XCTAssertTrue(
                HTTPClient.shouldAttemptRefresh(path: concretePath(operation.template), method: operation.method),
                "\(operation.method) \(operation.template) should refresh and re-send after a 401"
            )
        }
    }

    func testClientSingleDispatchOperationsAreSentOnce() throws {
        for (method, template) in clientSingleDispatch {
            let operation = try XCTUnwrap(
                APIv2MutationCatalog.operation(method: method, path: concretePath(template)),
                "\(method) \(template) is missing from the catalog"
            )
            XCTAssertEqual(operation.template, template)
            XCTAssertNotEqual(operation.retrySafety, .nonRetryable, "the contract allows replaying \(template)")
            XCTAssertFalse(
                HTTPClient.shouldAttemptRefresh(path: concretePath(template), method: method),
                "\(method) \(template) is kept single-dispatch"
            )
        }
    }

    func testUnknownMutationIsNotReplayed() {
        XCTAssertFalse(HTTPClient.shouldAttemptRefresh(path: "/api/v2/not-a-route", method: "POST"))
        // One segment more than `PUT /api/v2/settings/values/{key}`.
        XCTAssertFalse(HTTPClient.shouldAttemptRefresh(path: "/api/v2/settings/values/a/b", method: "PUT"))
        // A known template under a method the catalog does not list for it.
        XCTAssertFalse(HTTPClient.shouldAttemptRefresh(path: "/api/v2/auth/logout", method: "DELETE"))
    }

    func testGetIsReplayed() {
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/requests", method: "GET"))
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/collections", method: "HEAD"))
    }

    func testPublicAuthPathIsNeverReplayed() {
        XCTAssertFalse(HTTPClient.shouldAttemptRefresh(path: "/api/v2/auth/refresh", method: "POST"))
        XCTAssertFalse(HTTPClient.shouldAttemptRefresh(path: "/api/v2/auth/login", method: "POST"))
    }

    func testMatchingIsCaseInsensitiveOnMethodAndIgnoresTheQuery() {
        XCTAssertTrue(HTTPClient.shouldAttemptRefresh(path: "/api/v2/playback/s1/progress", method: "post"))
        XCTAssertEqual(
            APIv2MutationCatalog.operation(method: "PUT", path: "/api/v2/settings/values/theme?scope=device")?.template,
            "/api/v2/settings/values/{key}"
        )
    }

    // MARK: Matching

    func testMostLiteralTemplateWins() {
        let templated = APIv2MutationOperation("POST", "/api/v2/x/{id}", .naturalIdempotent)
        let literal = APIv2MutationOperation("POST", "/api/v2/x/sync", .nonRetryable)
        for candidates in [[templated, literal], [literal, templated]] {
            XCTAssertEqual(APIv2MutationCatalog.operation(method: "POST", path: "/api/v2/x/sync", in: candidates), literal)
            XCTAssertEqual(APIv2MutationCatalog.operation(method: "POST", path: "/api/v2/x/abc", in: candidates), templated)
        }
    }
}
