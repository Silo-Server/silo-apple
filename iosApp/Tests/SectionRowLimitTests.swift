import Foundation
import XCTest
@testable import Silo

/// Home and library rows hold at most `SectionRowLimit.cards` cards, and only
/// a server that advertises `item_limit` is sent it.
final class SectionRowLimitTests: XCTestCase {
    private static let serverID = "rows-test"
    private static let sectionsPath = "/api/v2/home/sections"

    private static let sectionsJSON: String = {
        let items = (1...30).map { #"{"content_id":"movie:\#($0)","type":"movie","title":"Movie \#($0)"}"# }
        return #"{"sections":[{"id":"recent","section_type":"recently_added","title":"Recently Added","item_limit":100,"total_count":30,"items":[\#(items.joined(separator: ","))]}]}"#
    }()

    private static let unknownParameterJSON = #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed","status":422,"detail":"The request is invalid.","errors":[{"location":"query.item_limit","code":"unknown_parameter","detail":"unknown query parameter"}]}"#

    private func support() -> SectionItemLimitSupport {
        SectionItemLimitSupport(memory: .init(load: { _ in nil }, save: { _, _ in }))
    }

    private func client(stub: APIv2TestStub, support: SectionItemLimitSupport) async throws -> SiloAPI {
        let name = "SectionRowLimitTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: Self.serverID)
        await tokens.setServerUrl("https://rows.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens, sectionItemLimitSupport: support)
    }

    private func sectionReads(_ stub: APIv2TestStub) -> [StubURLProtocol.Request] {
        stub.requests.filter { $0.path == Self.sectionsPath }
    }

    func testAdvertisingServerIsAskedForShortRows() async throws {
        let stub = APIv2TestStub()
        let support = support()
        support.record(100, serverID: Self.serverID)
        let api = try await client(stub: stub, support: support)
        stub.reply(path: Self.sectionsPath, 200, Self.sectionsJSON)

        let read = try await api.homeSections()

        XCTAssertEqual(sectionReads(stub).map { $0.query["item_limit"] }, ["20"])
        XCTAssertEqual(read.sections.first?.items.count, 20)
        XCTAssertEqual(read.sections.first?.itemLimit, 20)
    }

    func testOtherServersGetNoParameterAndRowsStillStopAtTwenty() async throws {
        let stub = APIv2TestStub()
        let api = try await client(stub: stub, support: support())
        stub.reply(path: Self.sectionsPath, 200, Self.sectionsJSON)

        let read = try await api.homeSections()

        XCTAssertEqual(sectionReads(stub).count, 1)
        XCTAssertNil(sectionReads(stub).first?.query["item_limit"])
        XCTAssertEqual(read.sections.first?.items.map(\.contentId), (1...20).map { "movie:\($0)" })
        // The row's own count is the server's; the full page reports the rest.
        XCTAssertEqual(read.sections.first?.totalCount, 30)
    }

    /// A server downgraded after advertising the parameter still loads Home.
    func testRefusedParameterIsForgottenAndTheReadRepeatedWithout() async throws {
        let stub = APIv2TestStub()
        let support = support()
        support.record(100, serverID: Self.serverID)
        let api = try await client(stub: stub, support: support)
        stub.sequence(path: Self.sectionsPath, [
            .json(422, Self.unknownParameterJSON),
            .json(200, Self.sectionsJSON),
        ])

        let read = try await api.homeSections()

        XCTAssertEqual(sectionReads(stub).map { $0.query["item_limit"] }, ["20", nil])
        XCTAssertEqual(read.sections.first?.items.count, 20)
        XCTAssertNil(support.itemLimit(serverID: Self.serverID))
    }

    func testProbeRecordsTheAdvertisedMaximum() async throws {
        let stub = APIv2TestStub()
        let support = support()
        let api = try await client(stub: stub, support: support)
        stub.sequence(path: "/api/v2/home/capabilities", [
            .json(200, #"{"revision":"r1","state":"available","allowed":true,"section_item_limit_max":100}"#),
            .json(200, #"{"revision":"r2","state":"available","allowed":true}"#),
        ])

        await support.refresh(api: api)
        XCTAssertEqual(support.itemLimit(serverID: Self.serverID), 20)

        await support.refresh(api: api)
        XCTAssertNil(support.itemLimit(serverID: Self.serverID))
    }
}
