import Foundation
import XCTest
@testable import Silo

final class DownloadRegistryV2Tests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try APIv2FixtureTestSupport.data(named: name, bundleClass: Self.self)
    }
    private func entry(id: String = "one", device: String = "device-one") throws -> APIv2DownloadEntry {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("download_status_event")) as? [String: Any])
        object["id"] = id
        object["device_id"] = device
        return try HTTPClient.makeJSONDecoder().decode(APIv2DownloadEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testRegistryCollectsAllPagesAndPreservesOpaqueCursor() async throws {
        var cursors: [String?] = []
        let rows = try await DownloadRegistryV2.collect(deviceID: "device-one") { cursor in
            cursors.append(cursor)
            return try APIv2DownloadPage(items: [entry(id: cursor == nil ? "one" : "two")],
                page: APIv2Page(nextCursor: cursor == nil ? "opaque+/=" : nil, hasMore: cursor == nil))
        }
        XCTAssertEqual(rows.map(\.id), ["one", "two"])
        XCTAssertEqual(rows.map(\.mediaFileId), [42, 42])
        XCTAssertEqual(cursors, [nil, "opaque+/="])
    }
    func testPartialFailureAndInvalidPagesNeverReturnARegistry() async throws {
        for mode in ["network", "duplicate", "foreign", "loop"] {
            var calls = 0
            do {
                _ = try await DownloadRegistryV2.collect(deviceID: "device-one") { _ in
                    calls += 1
                    if calls == 2 && mode == "network" { throw URLError(.networkConnectionLost) }
                    let row = try self.entry(id: mode == "duplicate" ? "one" : String(calls),
                        device: calls == 2 && mode == "foreign" ? "other" : "device-one")
                    return APIv2DownloadPage(items: [row], page: APIv2Page(nextCursor: "same", hasMore: true))
                }
                XCTFail(mode)
            } catch { XCTAssertEqual(calls, 2, mode) }
        }
    }
    func testEmptyRegistryAndCapabilityFixtures() async throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let page = try decoder.decode(APIv2DownloadPage.self, from: fixture("downloads_empty"))
        let rows = try await DownloadRegistryV2.collect(deviceID: "device-one") { _ in page }
        XCTAssertTrue(rows.isEmpty)
        let wire = try decoder.decode(APIv2DownloadCapability.self, from: fixture("download_capability"))
        let value = wire.localValue
        XCTAssertTrue(value.isUsable)
        XCTAssertEqual(value.proxyDelivery, false)
        XCTAssertEqual(value.orderedStatus, true)
        let restored = try JSONDecoder().decode(DownloadCapability.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("download_capability")) as? [String: Any])
        object["state"] = "future_state"
        let unknown = try decoder.decode(APIv2DownloadCapability.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(unknown.localValue.isUsable)
    }
    func testWireIDsAndRevisionAreCheckedBeforeLocalProjection() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("download_status_event")) as? [String: Any])
        let decoder = HTTPClient.makeJSONDecoder()
        for id in ["9007199254740993", "9223372036854775808", "01", "opaque"] {
            object["media_file_id"] = id
            let wire = try decoder.decode(APIv2DownloadEntry.self, from: JSONSerialization.data(withJSONObject: object))
            if id == "9007199254740993" { XCTAssertEqual(try ServerDownloadRow(v2: wire).mediaFileId, 9007199254740993) }
            else { XCTAssertThrowsError(try ServerDownloadRow(v2: wire)) }
        }
        object["media_file_id"] = 42
        XCTAssertThrowsError(try decoder.decode(APIv2DownloadEntry.self, from: JSONSerialization.data(withJSONObject: object)))
        object["media_file_id"] = "42"
        object["revision"] = 0
        let invalid = try decoder.decode(APIv2DownloadEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try ServerDownloadRow(v2: invalid))
    }
}
