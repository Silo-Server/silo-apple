import XCTest
@testable import Silo

@MainActor
final class ArtworkLookaheadTests: XCTestCase {
    private func item(_ id: String, type: String = "movie", poster: Bool = true) throws -> SectionItem {
        let posterField = poster ? ",\"posterUrl\":\"file:///lookahead/\(id).jpg\"" : ""
        return try JSONDecoder().decode(SectionItem.self, from: Data(
            "{\"contentId\":\"\(id)\",\"type\":\"\(type)\",\"title\":\"\(id)\"\(posterField)}".utf8
        ))
    }

    private func section(_ type: String, _ items: [SectionItem]) -> ResolvedSection {
        ResolvedSection(id: type, sectionType: type, title: type, featured: nil, itemLimit: nil,
                        totalCount: nil, isCustom: nil, customized: nil, items: items)
    }

    func testRowShapeFollowsTheSectionContent() throws {
        let movie = try item("m1")
        let episode = try item("e1", type: "episode")
        let audiobook = try item("a1", type: "audiobook")

        XCTAssertEqual(SectionRow.layout(for: section("next_up", [movie])), .thumbnail)
        XCTAssertEqual(SectionRow.layout(for: section("continue_watching", [episode])), .thumbnail)
        XCTAssertEqual(SectionRow.layout(for: section("trending", [audiobook])), .square)
        XCTAssertEqual(SectionRow.layout(for: section("trending", [audiobook, movie])), .poster)
        #if os(tvOS)
        // Skyline keeps resume rows as stills even when they hold only movies.
        XCTAssertEqual(SectionRow.layout(for: section("continue_watching", [movie])), .thumbnail)
        #else
        XCTAssertEqual(SectionRow.layout(for: section("continue_watching", [movie])), .poster)
        #endif
    }

    /// The lookahead decodes the cards after the one shown, at the size the
    /// card draws, so the card later paints from that decode.
    func testWarmsTheNextCardsAtTheSizeTheCardDraws() throws {
        let items = try (0..<(ArtworkLookahead.cardsAhead + 4)).map { try item("look-\($0)") }
        let cardWidth: CGFloat = 176
        let drawn = try XCTUnwrap(PosterImageCache.decodePixelSize(
            forPointSize: MediaCard.artworkSize(cardWidthOverride: cardWidth, aspect: .poster),
            scale: PosterImageCache.displayScale
        ))

        ArtworkLookahead.warmCards(after: 1, in: items) {
            MediaRow.cardArtwork(for: $0, layout: .poster, cardWidth: cardWidth)
        }

        let warmed = items.indices.filter { index in
            ArtworkVariants.shared.sizes(for: URL(string: items[index].posterUrl!)!).contains(drawn)
        }
        XCTAssertEqual(warmed, Array(2...(1 + ArtworkLookahead.cardsAhead)))
    }

    func testWarmingPastTheLastCardDoesNothing() throws {
        let items = try [item("end-0"), item("end-1", poster: false)]
        ArtworkLookahead.warmCards(after: 1, in: items) {
            MediaRow.cardArtwork(for: $0, layout: .poster, cardWidth: nil)
        }
        ArtworkLookahead.warmCards(after: 0, in: items) {
            MediaRow.cardArtwork(for: $0, layout: .poster, cardWidth: nil)
        }
        XCTAssertTrue(ArtworkVariants.shared.sizes(for: URL(string: items[0].posterUrl!)!).isEmpty)
    }
}
