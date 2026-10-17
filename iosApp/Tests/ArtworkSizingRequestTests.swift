import Foundation
import XCTest
@testable import Silo

/// Each image-bearing read through `SiloAPI` asks for the widths of the
/// screen that draws it, against the vendored capability fixture (a server
/// that takes per-slot widths) at 2×.
final class ArtworkSizingRequestTests: XCTestCase {
    private static let fixture = "get_image_capabilities_ok"
    private let sectionsJSON = #"{"sections":[{"id":"cw","section_type":"continue_watching","title":"Continue Watching","items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}]}]}"#

    /// A probed capability on `display`, answering with the fixture, or with
    /// the fixture minus `slot_width_params` for a server that predates them.
    /// It asks for large images on such a server, as tvOS does.
    private func capability(display: ArtworkDisplay = .assumed, slotWidths: Bool = true) async throws -> ImageSizeCapability {
        var response = try APIv2FixtureTestSupport.decode(
            ImageSizeCapabilityResponse.self, named: Self.fixture, bundleClass: Self.self
        )
        if !slotWidths { response.slotWidthParams = nil }
        let capability = ImageSizeCapability(platformPrefersLargeImages: true, display: { display }) { response }
        await capability.refresh()
        return capability
    }

    private func client(stub: APIv2TestStub, capability: ImageSizeCapability) async throws -> SiloAPI {
        let name = "ArtworkSizingRequestTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "artwork-test")
        await tokens.setServerUrl("https://artwork.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens, imageSizeCapability: capability)
    }

    private func sent(_ stub: APIv2TestStub, path: String) throws -> [String: String] {
        try XCTUnwrap(stub.requests.last(where: { $0.path == path }), path).query
    }

    /// Home, For You and detail ask for the same hero backdrop and logo, so
    /// the detail an item opens into reuses the hero image already cached.
    func testHeroReadsAskForTheSameHeroWidths() async throws {
        let stub = APIv2TestStub()
        let capability = try await capability()
        let api = try await client(stub: stub, capability: capability)
        let detail = try XCTUnwrap(String(data: APIv2FixtureTestSupport.data(named: "get_catalog_item_ok", bundleClass: Self.self), encoding: .utf8))
        stub.reply(path: "/api/v2/home/sections", 200, sectionsJSON)
        stub.reply(path: "/api/v2/recommendations/discover", 200, #"{"items":[]}"#)
        stub.reply(path: "/api/v2/catalog/items/movie:heat-1995", 200, detail)

        _ = try await api.homeSections()
        _ = try await api.recommendationsDiscover()
        _ = try await api.itemDetail(contentId: "movie:heat-1995")

        let home = try sent(stub, path: "/api/v2/home/sections")
        let forYou = try sent(stub, path: "/api/v2/recommendations/discover")
        let item = try sent(stub, path: "/api/v2/catalog/items/movie:heat-1995")
        XCTAssertEqual(home, capability.requestQuery(for: .home))
        XCTAssertEqual(forYou, capability.requestQuery(for: .shelves))
        XCTAssertEqual(item, capability.requestQuery(for: .detail))
        #if os(tvOS)
        XCTAssertEqual(forYou, home)
        for slot in ["backdrop_width", "logo_width"] {
            XCTAssertEqual(item[slot], home[slot], slot)
        }
        #endif
    }

    func testRailsAskForTheirOwnSlots() async throws {
        let stub = APIv2TestStub()
        let capability = try await capability()
        let api = try await client(stub: stub, capability: capability)
        let episodesPath = "/api/v2/catalog/series/series:one/seasons/1/episodes"
        let similarPath = "/api/v2/recommendations/similar/movie:heat"
        stub.reply(path: episodesPath, 200, #"{"items":[]}"#)
        stub.reply(path: similarPath, 200, #"{"items":[]}"#)

        _ = try await api.episodes(seriesId: "series:one", seasonNumber: 1)
        _ = try await api.recommendationsSimilar(contentId: "movie:heat")

        XCTAssertEqual(try sent(stub, path: episodesPath), capability.requestQuery(for: .episodes))
        var similar = try sent(stub, path: similarPath)
        XCTAssertEqual(similar.removeValue(forKey: "limit"), "12")
        XCTAssertEqual(similar, capability.requestQuery(for: .similar))
    }

    /// A server without per-slot widths answers `422` to any width parameter,
    /// and to any size on a recommendation read. For You and similar go bare,
    /// as they always have; the other reads keep tvOS's `image_size=large`.
    func testServerWithoutSlotWidthsGetsTodaysRequests() async throws {
        let stub = APIv2TestStub()
        let api = try await client(stub: stub, capability: try await capability(slotWidths: false))
        let detail = try XCTUnwrap(String(data: APIv2FixtureTestSupport.data(named: "get_catalog_item_ok", bundleClass: Self.self), encoding: .utf8))
        let episodesPath = "/api/v2/catalog/series/series:one/seasons/1/episodes"
        let similarPath = "/api/v2/recommendations/similar/movie:heat"
        stub.reply(path: "/api/v2/home/sections", 200, sectionsJSON)
        stub.reply(path: "/api/v2/recommendations/discover", 200, #"{"items":[]}"#)
        stub.reply(path: "/api/v2/catalog/items/movie:heat-1995", 200, detail)
        stub.reply(path: episodesPath, 200, #"{"items":[]}"#)
        stub.reply(path: similarPath, 200, #"{"items":[]}"#)

        _ = try await api.homeSections()
        _ = try await api.recommendationsDiscover()
        _ = try await api.itemDetail(contentId: "movie:heat-1995")
        _ = try await api.episodes(seriesId: "series:one", seasonNumber: 1)
        _ = try await api.recommendationsSimilar(contentId: "movie:heat")

        XCTAssertEqual(try sent(stub, path: "/api/v2/home/sections"), ["image_size": "large"])
        XCTAssertEqual(try sent(stub, path: "/api/v2/catalog/items/movie:heat-1995"), ["image_size": "large"])
        XCTAssertEqual(try sent(stub, path: episodesPath), ["image_size": "large"])
        XCTAssertEqual(try sent(stub, path: "/api/v2/recommendations/discover"), [:])
        XCTAssertEqual(try sent(stub, path: similarPath), ["limit": "12"])
        for request in stub.requests {
            XCTAssertFalse(request.query.keys.contains { $0.hasSuffix("_width") }, request.path)
        }
    }

    /// Catalog pages carry their widths in the query and in the continuation,
    /// so every page of one list resolves artwork the same way.
    func testCatalogPagesKeepTheirWidthsAcrossPages() async throws {
        let stub = APIv2TestStub()
        let capability = try await capability()
        let api = try await client(stub: stub, capability: capability)
        stub.sequence(path: "/api/v2/catalog", [
            .json(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":0,"total_exact":true}"#),
            .json(200, #"{"items":[],"page":{"has_more":false},"total":0,"total_exact":true}"#),
        ])

        let first = try await api.catalogPage(APIv2CatalogQuery())
        _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))

        let expected = capability.requestQuery(for: .cards)
        let pages = stub.requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertEqual(pages.count, 2)
        for page in pages {
            XCTAssertEqual(page.query.filter { expected.keys.contains($0.key) }, expected)
        }
    }

    #if os(iOS)
    /// iPhone 17 Pro Max, portrait: the detail hero is 440 × 519 pt, so a
    /// 16:9 backdrop needs 924 pt; the episode rail's 240 pt stills are 720 px.
    func testIPhoneWidthsFollowItsLayout() async throws {
        let capability = try await capability(display: ArtworkDisplay(scale: 3, screenSize: CGSize(width: 956, height: 440)))
        XCTAssertEqual(capability.requestQuery(for: .detail),
                       ["backdrop_width": "2772", "logo_width": "1152", "photo_width": "228"])
        XCTAssertEqual(capability.requestQuery(for: .episodes), ["still_width": "720"])
        XCTAssertEqual(capability.requestQuery(for: .home), ["poster_width": "396", "backdrop_width": "720"])
    }

    /// 13-inch iPad in landscape: the split detail hero is the full window
    /// high (1032 pt), so a 16:9 backdrop needs 1835 pt.
    func testIPadWidthsFollowItsLayout() async throws {
        let capability = try await capability(
            display: ArtworkDisplay(scale: 2, screenSize: CGSize(width: 1376, height: 1032), isPad: true)
        )
        XCTAssertEqual(capability.requestQuery(for: .detail),
                       ["backdrop_width": "3670", "logo_width": "860", "photo_width": "152"])
        XCTAssertEqual(capability.requestQuery(for: .cards), ["poster_width": "432"])
        XCTAssertEqual(capability.requestQuery(for: .episodes), ["still_width": "480"])
    }
    #endif

    #if os(tvOS)
    /// The issue's Apple TV 4K table.
    func testAppleTV4KWidths() async throws {
        let capability = try await capability()
        XCTAssertEqual(ArtworkSurface.tvHeroBackdropWidth, 1344)
        XCTAssertEqual(capability.requestQuery(for: .home),
                       ["image_size": "medium", "backdrop_width": "2688", "logo_width": "1760"])
        XCTAssertEqual(capability.requestQuery(for: .shelves), capability.requestQuery(for: .home))
        XCTAssertEqual(capability.requestQuery(for: .detail),
                       ["poster_width": "920", "backdrop_width": "2688", "logo_width": "1760", "photo_width": "400"])
        XCTAssertEqual(capability.requestQuery(for: .episodes), ["still_width": "720"])
        // Cards seed the detail hero with their backdrop, so they ask for the hero's.
        XCTAssertEqual(capability.requestQuery(for: .similar), ["poster_width": "440", "backdrop_width": "2688"])
        XCTAssertEqual(capability.requestQuery(for: .cards), ["poster_width": "520", "backdrop_width": "2688"])
        XCTAssertEqual(capability.requestQuery(for: .lists), ["poster_width": "352", "backdrop_width": "2688"])
        XCTAssertTrue(capability.requestQuery(for: .watch).isEmpty)
    }
    #endif
}
