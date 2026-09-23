import Foundation
import Nuke
import SwiftUI
import XCTest
@testable import Silo

final class ArtworkURLTests: XCTestCase {
    private let signedPath = "/api/v2/artwork/posters/a%2Fb%20c%252F.jpg?exp=123&sig=a%2Bb%2Fc%3D&key=1&key=2"

    func testSignedPathUsesOriginAndPreservesEncodedBytes() throws {
        let server = URL(string: "https://media.example:8443/silo/base?ignored=1#fragment")!
        let resolved = ArtworkURLResolver.resolve(signedPath, serverURL: server)
        XCTAssertEqual(resolved, "https://media.example:8443" + signedPath)
        XCTAssertEqual(URL(string: resolved)?.absoluteString, resolved)
        XCTAssertEqual(ArtworkURLResolver.resolve("/images/collection-templates/example.jpg", serverURL: server),
                       "https://media.example:8443/images/collection-templates/example.jpg")
    }

    func testAbsoluteS3AndOfflineURLsRemainUnchanged() {
        for value in ["https://bucket.example/a%2Fb.jpg?X-Amz-Signature=a%2Bz&x=1&x=2", "file:///cache/poster.jpg"] {
            XCTAssertEqual(ArtworkURLResolver.resolve(value, serverURL: URL(string: "https://media.example/base")), value)
        }
        XCTAssertEqual(ArtworkURLResolver.resolve(signedPath, serverURL: nil), signedPath)
    }

    func testArtworkDecodingLeavesOtherURLsUntouchedAndHandlesMissingFields() throws {
        struct Response: Codable {
            @ArtworkURL var posterUrl: String?
            @ArtworkURL var logoUrl: String?
            @RequiredArtworkURL var backdropUrl: String
            let downloadUrl: String
        }
        let json = #"{"poster_url":null,"backdrop_url":"/art/backdrop.jpg?sig=x%2By","download_url":"/api/v2/downloads/asset"}"#
        let value = try HTTPClient.makeJSONDecoder(artworkServerURL: URL(string: "https://a.example/base"))
            .decode(Response.self, from: Data(json.utf8))
        XCTAssertNil(value.posterUrl)
        XCTAssertNil(value.logoUrl)
        XCTAssertEqual(value.backdropUrl, "https://a.example/art/backdrop.jpg?sig=x%2By")
        XCTAssertEqual(value.downloadUrl, "/api/v2/downloads/asset")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let roundTrip = try HTTPClient.makeJSONDecoder().decode(Response.self, from: encoder.encode(value))
        XCTAssertEqual(roundTrip.backdropUrl, value.backdropUrl)
    }

    #if os(iOS)
    func testDownloadManifestRetainsAssetOwnershipPaths() throws {
        let json = #"{"download_id":"d1","content_id":"movie","type":"movie","title":"Movie","media_file_id":"7","artwork_urls":{"poster":"/downloads/d1/poster"},"chapters":[{"index":0,"start_seconds":0,"thumbnail_url":"/downloads/d1/chapter"}]}"#
        let manifest = try HTTPClient.makeJSONDecoder(artworkServerURL: URL(string: "https://a.example/base"))
            .decode(OfflineManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.artworkUrls?.poster, "/downloads/d1/poster")
        XCTAssertEqual(manifest.chapters?.first?.thumbnailUrl, "/downloads/d1/chapter")
    }
    #endif

    func testCatalogAndHomeArtworkKeepSupplyingServerAcrossSwitch() async throws {
        let stub = APIv2TestStub()
        let name = "ArtworkURLTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server-a")
        await tokens.setServerUrl("https://a.example/mount")
        await tokens.setProfileId("profile")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        let item = #"{"content_id":"movie","type":"movie","title":"Movie","poster_url":"\#(signedPath)"}"#
        stub.reply(200, #"{"items":[\#(item)],"page":{"has_more":false},"total":1,"total_exact":true,"window_cursor":"w"}"#)
        let first = try await api.catalogPage(query: .init(), operation: .get)
        let firstURL = try XCTUnwrap(first.value.items.first?.posterUrl)
        await tokens.switchActiveServer(serverId: "server-b")
        await tokens.setServerUrl("https://b.example/another-mount")
        await tokens.setProfileId("profile")
        let second = try await api.catalogPage(query: .init(), operation: .get)
        let secondURL = try XCTUnwrap(second.value.items.first?.posterUrl)
        XCTAssertEqual(firstURL, "https://a.example" + signedPath)
        XCTAssertEqual(secondURL, "https://b.example" + signedPath)
        // The visible renderer and all prefetchers receive these same strings;
        // Nuke's URL-based cache identity therefore includes the source server.
        let a = PosterImageCache.displayRequest(url: try XCTUnwrap(URL(string: firstURL)), pixelSize: CGSize(width: 300, height: 450))
        let b = PosterImageCache.displayRequest(url: try XCTUnwrap(URL(string: secondURL)), pixelSize: CGSize(width: 300, height: 450))
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertEqual(first.value.items.first?.posterUrl, firstURL)

        stub.reply(200, #"{"sections":[{"id":"cw","section_type":"continue_watching","title":"Continue Watching","items":[\#(item)]}]}"#)
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let home = try await api.homeSections(imageSize: nil, auth: XCTUnwrap(authValue))
        XCTAssertEqual(home.response.sections.first?.items.first?.posterUrl, secondURL)
        let legacy: SectionsResponse = try await http.get("/api/v1/home/sections")
        XCTAssertEqual(legacy.sections.first?.items.first?.posterUrl, secondURL)

        stub.reply(200, #"{"events":[{"date":"2026-09-16","items":[\#(item)]}]}"#)
        let calendar = try await api.calendar(start: "2026-09-16", end: "2026-09-17", filter: "everything", timezone: "UTC", auth: XCTUnwrap(authValue))
        XCTAssertEqual(calendar.events.first?.items.first?.posterUrl, secondURL)
    }

    @MainActor
    func testVisibleArtworkLoadsLocalAndDirectDeliveryWithSeparateCaches() async throws {
        let handler = StubURLProtocol.Handler()
        let red = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        }
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        }
        handler.route(StubURLProtocol.any) { request in
            .init(status: 200, headers: ["Content-Type": "image/png"],
                  body: request.url?.host == "a.example" ? red : blue)
        }
        let configuration = URLSessionConfiguration.ephemeral
        handler.install(into: configuration)
        var pipelineConfiguration = ImagePipeline.Configuration()
        pipelineConfiguration.dataLoader = DataLoader(configuration: configuration)
        pipelineConfiguration.imageCache = ImageCache()
        let pipeline = ImagePipeline(configuration: pipelineConfiguration)
        let previous = ImagePipeline.shared
        ImagePipeline.shared = pipeline
        defer { ImagePipeline.shared = previous }
        let urls = [
            ArtworkURLResolver.resolve(signedPath, serverURL: URL(string: "https://a.example/base")),
            ArtworkURLResolver.resolve(signedPath, serverURL: URL(string: "https://b.example/base")),
            "https://s3.example/poster.png?X-Amz-Signature=a%2Bb"
        ]
        for value in urls {
            let url = try XCTUnwrap(URL(string: value))
            // Exercise the same thumbnail request used by startup prefetch.
            _ = try await pipeline.image(for: PosterImageCache.cardWarmRequest(for: url))
            XCTAssertNotNil(pipeline.cache.cachedImage(for: PosterImageCache.cardWarmRequest(for: url)))
            let loaded = expectation(description: "Rendered " + (url.host ?? "artwork"))
            loaded.assertForOverFulfill = false
            let view = CachedAsyncImage(url: value, onImageLoaded: { loaded.fulfill() })
                .frame(width: 120, height: 180)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 240))
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            window.layoutIfNeeded()
            await fulfillment(of: [loaded], timeout: 5)
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "artwork-" + (url.host ?? "unknown")
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertEqual(Set(handler.requests.compactMap { $0.url?.host }), Set(["a.example", "b.example", "s3.example"]))
        XCTAssertTrue(handler.requests.allSatisfy { $0.header("Authorization") == nil })
    }

    func testCatalogIDsStayInOneURLPathSegment() throws {
        let id = "series/a?b#c%2F"
        let segment = try XCTUnwrap(CatalogPathSegment.encode(id))
        for path in ["/api/v2/catalog/series/\(segment)/seasons", "/api/v2/catalog/items/\(segment)"] {
            var components = try XCTUnwrap(URLComponents(string: "https://tv.example/mount"))
            components.percentEncodedPath += path
            let url = try XCTUnwrap(components.url)
            XCTAssertTrue(url.absoluteString.contains("series%2Fa%3Fb%23c%252F"))
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
        }
        for invalid in ["", ".", ".."] { XCTAssertNil(CatalogPathSegment.encode(invalid)) }
    }

    func testTopShelfHomeSeasonAndDetailArtwork() throws {
        let decoder = HTTPClient.makeJSONDecoder(artworkServerURL: URL(string: "https://tv.example/mount"))
        let sections = try decoder.decode(TopShelfSectionsResponse.self, from: Data(#"{"sections":[{"id":"cw","section_type":"continue_watching","title":"Continue Watching","items":[{"content_id":"episode","type":"episode","title":"Episode","poster_url":"/art/still.jpg?sig=a%2Bb"}]}]}"#.utf8))
        XCTAssertEqual(sections.sections.first?.items.first?.posterUrl, "https://tv.example/art/still.jpg?sig=a%2Bb")
        let seasons = try decoder.decode(TopShelfSeasonsResponse.self, from: Data(#"{"items":[{"season_number":1,"poster_url":"/art/season.jpg?sig=x%2Fy"}]}"#.utf8))
        XCTAssertEqual(seasons.seasons.first?.posterUrl, "https://tv.example/art/season.jpg?sig=x%2Fy")
        let detail = try decoder.decode(TopShelfItemDetail.self, from: Data(#"{"poster_url":"https://s3.example/poster.jpg?X-Amz-Signature=a%2Bb"}"#.utf8))
        XCTAssertEqual(detail.posterUrl, "https://s3.example/poster.jpg?X-Amz-Signature=a%2Bb")
    }

    func testDeliveryCapabilityOnIOSUsesV2RouteAndResets() async throws {
        let stub = APIv2TestStub()
        let name = "ArtworkCapabilityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.setServerUrl("https://a.example")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let probe = ImageSizeCapability(api: api, platformPrefersLargeImages: false)
        stub.reply(200, #"{"state":"available","revision":"r1","param":"image_size","sizes":["large"],"widths":{},"original_max_width_px":1920,"storage_backend":"local","delivery":"server"}"#)
        await probe.refresh()
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/images/capabilities")
        XCTAssertEqual(probe.capability?.storageBackend, "local")
        XCTAssertEqual(probe.capability?.delivery, "server")
        XCTAssertTrue(probe.requestQuery.isEmpty)
        XCTAssertEqual(ImageSizeSelection.queryEntries(capability: probe.capability, prefersLargeImages: true), ["image_size": "large"])
        probe.reset()
        XCTAssertNil(probe.capability)
        stub.reply(200, #"{"schema_version":1,"param":"image_size","sizes":["large"],"widths":{},"original_max_width_px":1920}"#)
        await probe.refresh()
        XCTAssertNil(probe.capability?.storageBackend)
        XCTAssertNil(probe.capability?.delivery)
        XCTAssertEqual(ImageSizeSelection.queryEntries(capability: probe.capability, prefersLargeImages: true), ["image_size": "large"])
    }
}
