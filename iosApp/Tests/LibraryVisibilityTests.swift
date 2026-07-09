import XCTest
import Foundation

// Shared by SiloTests and SiloTVTests. Keep assertions limited to symbols that
// exist in both app targets, typically shared networking/model code.
#if os(tvOS)
@testable import SiloTV
#else
@testable import Silo
#endif

final class LibraryVisibilityTests: XCTestCase {
    func testLibrariesResponseOnlyIncludesSupportedAppleLibraryTypes() {
        let json = """
        [
          { "id": 1, "name": "Movies", "type": "movies" },
          { "id": 2, "name": "Series", "type": "series" },
          { "id": 3, "name": "Audiobooks", "type": "audiobooks" },
          { "id": 4, "name": "Music", "type": "music" },
          { "id": 5, "name": "Ebooks", "type": "ebooks" },
          { "id": 6, "name": "Comics", "type": "comics" },
          { "id": 7, "name": "Podcasts", "type": "podcasts" },
          { "id": 8, "name": "Mixed Media", "type": "mixed" }
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try! decoder.decode(LibrariesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.libraries.map(\.id), [1, 2, 3, 8])
    }

    func testLibraryVisibilityUsesExplicitAudiobookLibraryTypesOnly() {
        XCTAssertTrue(SiloMediaType.isSupportedLibrary("audiobook"))
        XCTAssertTrue(SiloMediaType.isSupportedLibrary("audiobooks"))
        XCTAssertFalse(SiloMediaType.isSupportedLibrary("book"))
        XCTAssertFalse(SiloMediaType.isSupportedLibrary("books"))
    }

    func testSectionsResponseStripsItemsFromHiddenLibraryTypes() {
        let json = """
        {
          "sections": [
            {
              "id": "continue",
              "section_type": "continue_watching",
              "title": "Continue Watching",
              "items": [
                { "content_id": "m1", "type": "movie", "title": "A Movie" },
                { "content_id": "e1", "type": "ebook", "title": "An Ebook" },
                { "content_id": "ep1", "type": "episode", "title": "An Episode" },
                { "content_id": "c1", "type": "comic", "title": "A Comic" },
                { "content_id": "mu1", "type": "music", "title": "An Album" },
                { "content_id": "a1", "type": "audiobook", "title": "An Audiobook" }
              ]
            },
            {
              "id": "manga-recent",
              "section_type": "recently_added",
              "title": "Recently Added Manga",
              "items": [
                { "content_id": "g1", "type": "manga", "title": "A Manga" }
              ]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try! decoder.decode(SectionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sections.map(\.id), ["continue", "manga-recent"])
        XCTAssertEqual(response.sections[0].items.map(\.contentId), ["m1", "ep1", "a1"])
        XCTAssertTrue(response.sections[1].items.isEmpty)
    }

    func testSectionsResponseDecodesServerCardImageStyleAndLandscapeArtwork() throws {
        let json = """
        {
          "sections": [
            {
              "id": "editorial",
              "section_type": "recently_added",
              "title": "Editorial",
              "card_image_style": "landscape",
              "items": [
                {
                  "content_id": "m1",
                  "type": "movie",
                  "title": "A Movie",
                  "landscape_card_url": "/images/m1-landscape.webp",
                  "landscape_card_thumbhash": "landscape-thumb",
                  "backdrop_url": "/images/m1-backdrop.webp",
                  "backdrop_thumbhash": "backdrop-thumb"
                }
              ]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(SectionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sections[0].cardImageStyle, .landscape)
        XCTAssertEqual(response.sections[0].items[0].landscapeCardUrl, "/images/m1-landscape.webp")
        XCTAssertEqual(response.sections[0].items[0].landscapeCardThumbhash, "landscape-thumb")
    }

    func testSectionsResponseDefaultsMissingOrUnknownCardImageStyleToAuto() throws {
        let json = """
        {
          "sections": [
            { "id": "missing", "section_type": "recent", "title": "Missing", "items": [] },
            {
              "id": "unknown",
              "section_type": "recent",
              "title": "Unknown",
              "card_image_style": "banner",
              "items": []
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(SectionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sections.map(\.cardImageStyle), [.auto, .auto])
    }

    func testLandscapeRowsPreferStoredCardButStillOverlayBackdropFallback() {
        XCTAssertEqual(
            LandscapeRowArtwork.imageUrl(
                cardUrl: "/images/stored-landscape.webp",
                backdropUrl: "/images/backdrop.webp"
            ),
            "/images/stored-landscape.webp"
        )
        XCTAssertEqual(
            LandscapeRowArtwork.imageUrl(
                cardUrl: nil,
                backdropUrl: "/images/backdrop.webp"
            ),
            "/images/backdrop.webp"
        )
        XCTAssertNil(
            LandscapeRowArtwork.thumbhash(
                cardThumbhash: "",
                backdropThumbhash: nil
            )
        )

        XCTAssertFalse(LandscapeRowArtwork.showsTitleOverlay(cardUrl: "/images/stored-landscape.webp"))
        XCTAssertTrue(LandscapeRowArtwork.showsTitleOverlay(cardUrl: nil))
        XCTAssertTrue(LandscapeRowArtwork.showsTitleOverlay(cardUrl: ""))
    }

    func testLandscapeCardOverlaysKeepBottomBadgesInTheCardCorner() {
        let landscape = CardOverlays.layoutInsets(for: .bottomLeft, variant: .landscapeCard)
        XCTAssertEqual(landscape.leading, 8)
        XCTAssertEqual(landscape.bottom, 8)

        let wide = CardOverlays.layoutInsets(for: .bottomLeft, variant: .wide)
        XCTAssertEqual(wide.leading, 8)
        XCTAssertEqual(wide.bottom, 24)
    }

    func testLiveCardOverlaysDoNotReserveSpaceForEmptyLabels() throws {
        let definition = try XCTUnwrap(OverlayRegistry.def(for: .showStatus))
        let prefs = OverlaySchema.buildDefaults()
        let preset = OverlayPresets.preset(prefs.preset)
        var data = OverlayData()

        data.showStatus = " \n "
        XCTAssertNil(OverlayBadgeRenderState.resolve(
            def: definition,
            data: data,
            prefs: prefs,
            preset: preset
        ))

        data.showStatus = "Continuing"
        XCTAssertEqual(
            OverlayBadgeRenderState.resolve(
                def: definition,
                data: data,
                prefs: prefs,
                preset: preset
            )?.label,
            "Continuing"
        )
    }

    func testSectionsResponseMemberwiseInitAlsoStripsUnsupportedItems() throws {
        let itemJson = """
        { "content_id": "e1", "type": "ebook", "title": "An Ebook" }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(SectionItem.self, from: Data(itemJson.utf8))

        let response = SectionsResponse(sections: [
            ResolvedSection(
                id: "discover_0_similar",
                sectionType: "similar",
                title: "Because You Watched",
                featured: false,
                itemLimit: 1,
                totalCount: 1,
                isCustom: false,
                customized: false,
                items: [item]
            )
        ])

        XCTAssertTrue(response.sections[0].items.isEmpty)
    }
}
