import XCTest
import Foundation
@testable import Silo

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
          { "id": 7, "name": "Podcasts", "type": "podcasts" }
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try! decoder.decode(LibrariesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.libraries.map(\.id), [1, 2, 3])
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
        XCTAssertEqual(response.sections[0].items.map(\.contentId), ["m1", "a1"])
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
