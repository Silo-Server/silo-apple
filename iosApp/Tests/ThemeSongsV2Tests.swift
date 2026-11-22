import Foundation
import XCTest
@testable import Silo

/// Local theme music over API v2 (`docs/catalog-api.md`, "Local theme songs,
/// V2" in silo-server), decoded from the vendored server fixtures.
final class ThemeSongsV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func api(server: String = "https://silo.example/base") async throws -> SiloAPI {
        let name = "ThemeSongsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl(server)
        await tokens.setProfileId("profile-one")
        return SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
    }

    private func fixture(_ name: String, setting members: [String: Any] = [:]) -> String {
        APIv2FixtureTestSupport.text(named: name, bundleClass: Self.self, setting: members)
    }

    private func detail(setting members: [String: Any] = [:]) throws -> ItemDetail {
        let body = try APIv2FixtureTestSupport.mutatedBody(named: "get_catalog_item_ok", bundleClass: Self.self) {
            $0.merge(members) { $1 }
        }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: body)
        return try ItemDetail(catalog: wire)
    }

    func testItemDetailCarriesTheServerResolvedThemeSet() throws {
        let themes = try XCTUnwrap(detail().themes)
        XCTAssertEqual(themes.ownerId, "movie:heat-1995")
        XCTAssertEqual(themes.items.map { $0.id }, ["7"])
        XCTAssertEqual(themes.items.first?.title, "Opening")
        XCTAssertEqual(themes.items.first?.durationSeconds, 60)
        XCTAssertEqual(themes.items.first?.container, "mp3")
    }

    func testItemDetailWithoutThemesStillProjects() throws {
        // The server omits `themes` when its optional lookup fails.
        let body = try APIv2FixtureTestSupport.mutatedBody(named: "get_catalog_item_ok", bundleClass: Self.self) {
            $0.removeValue(forKey: "themes")
        }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: body)
        XCTAssertNil(try ItemDetail(catalog: wire).themes)
    }

    // MARK: Capability

    func testCapabilityReportsAvailabilityFromTheServerDocument() async throws {
        stub.reply(200, fixture("theme_songs_capability"))
        let api = try await api()

        let capability = try await api.themeSongsCapability()

        XCTAssertEqual(stub.requests.last?.method, "GET")
        XCTAssertEqual(stub.requests.last?.path, "/base/api/v2/catalog/themes/capabilities")
        XCTAssertEqual(stub.requests.last?.header("x-profile-id"), "profile-one")
        XCTAssertTrue(capability.isAvailable)
        XCTAssertTrue(capability.transcode ?? false)
    }

    func testCapabilityIsUnavailableWhenRefusedOrUnconfigured() async throws {
        let api = try await api()
        stub.reply(200, fixture("theme_songs_capability", setting: ["allowed": false]))
        let refused = try await api.themeSongsCapability()
        XCTAssertFalse(refused.isAvailable)
        stub.reply(200, fixture("theme_songs_capability", setting: ["state": "unconfigured"]))
        let unconfigured = try await api.themeSongsCapability()
        XCTAssertFalse(unconfigured.isAvailable)
    }

    // MARK: Playback grant

    func testGrantNamesOwnerAndThemeAndListsWhatAVFoundationDecodes() async throws {
        stub.reply(200, fixture("theme_songs_playback"))
        let api = try await api()

        _ = try await api.themePlayback(ownerId: "movie:heat-1995", themeId: "7")

        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/base/api/v2/catalog/items/movie:heat-1995/themes/7/playback")
        XCTAssertEqual(sent.header("x-profile-id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.body)) as? [String: Any])
        let formats = try XCTUnwrap(body["accepted_formats"] as? [[String: String]])
        let pairs = Set(formats.map { "\($0["container"] ?? "")/\($0["audio_codec"] ?? "")" })
        // AAC in MP4 is what the server converts everything else to.
        XCTAssertTrue(pairs.contains("mp4/aac"))
        XCTAssertTrue(pairs.contains("mp3/mp3"))
        // AVFoundation has no Ogg demuxer, so Vorbis and Opus themes must be converted.
        XCTAssertFalse(pairs.contains { $0.hasPrefix("ogg/") || $0.hasPrefix("opus/") })
    }

    func testRelativeGrantURLResolvesAgainstTheServerAndOriginalAudioLoops() async throws {
        stub.reply(200, fixture("theme_songs_playback"))
        let api = try await api()

        let grant = try await api.themePlayback(ownerId: "movie:heat-1995", themeId: "7")

        XCTAssertEqual(grant.url.absoluteString,
                       "https://silo.example/base/api/v2/catalog/items/movie:heat-1995/themes/7/audio?token=fixture-theme-grant")
        XCTAssertFalse(grant.isConverted)
    }

    func testProxyGrantURLIsKeptAndConvertedDeliveryIsReported() async throws {
        stub.reply(200, fixture("theme_songs_playback_converted",
                                setting: ["url": "https://proxy.example/theme/7?token=abc"]))
        let api = try await api()

        let grant = try await api.themePlayback(ownerId: "movie:heat-1995", themeId: "7")

        XCTAssertEqual(grant.url.absoluteString, "https://proxy.example/theme/7?token=abc")
        XCTAssertTrue(grant.isConverted)
    }

    func testGrantRefusalsThrow() async throws {
        let api = try await api()
        for name in ["theme_songs_playback_not_acceptable", "theme_songs_playback_unauthorized"] {
            let status = try APIv2FixtureTestSupport.entry(named: name, bundleClass: Self.self).expectedStatus
            stub.reply(status, fixture(name))
            do {
                _ = try await api.themePlayback(ownerId: "movie:heat-1995", themeId: "7")
                XCTFail("\(name) must not yield a grant")
            } catch {}
        }
    }

    func testGrantNeverPrintsItsSignedURL() async throws {
        stub.reply(200, fixture("theme_songs_playback"))
        let api = try await api()

        let grant = try await api.themePlayback(ownerId: "movie:heat-1995", themeId: "7")

        for text in [String(describing: grant), String(reflecting: grant), "\(grant)"] {
            XCTAssertFalse(text.contains("fixture-theme-grant"), text)
        }
    }
}
