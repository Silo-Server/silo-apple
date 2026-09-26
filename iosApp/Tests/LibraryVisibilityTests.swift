import XCTest
import Foundation
@testable import Silo

final class LibraryVisibilityTests: XCTestCase {
    func testLibrariesResponseOnlyIncludesSupportedAppleLibraryTypes() {
        let libraries = [
            (1, "Movies", "movies"),
            (2, "Series", "series"),
            (3, "Audiobooks", "audiobooks"),
            (4, "Music", "music"),
            (5, "Ebooks", "ebooks"),
            (6, "Comics", "comics"),
            (7, "Podcasts", "podcasts"),
            (8, "Mixed Media", "mixed"),
        ].map { Library(id: $0.0, name: $0.1, type: $0.2, sortOrder: nil, posterUrl: nil) }

        let response = LibrariesResponse(libraries: libraries)

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
