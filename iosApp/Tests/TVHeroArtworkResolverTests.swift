import XCTest
@testable import Silo

final class TVHeroArtworkResolverTests: XCTestCase {
    private let poster = TVHeroArtwork(url: "https://example.test/poster.jpg", thumbhash: "poster")!
    private let sectionBackdrop = TVHeroArtwork(
        url: "https://example.test/section-backdrop.jpg",
        thumbhash: "section"
    )!
    private let detailBackdrop = TVHeroArtwork(
        url: "https://example.test/detail-backdrop.jpg",
        thumbhash: "detail"
    )!

    func testEpisodeDoesNotFlashPosterBeforeDetailBackdropLoads() {
        let artwork = TVHeroArtworkResolver.resolve(
            sectionBackdrop: nil,
            fallback: poster,
            prefersEnrichedBackdrop: true,
            canLoadEnrichment: true,
            enrichmentState: .loading,
            enrichedBackdrop: nil
        )

        XCTAssertNil(artwork)
    }

    func testEpisodeShowsDetailBackdropAsFirstArtwork() {
        let artwork = TVHeroArtworkResolver.resolve(
            sectionBackdrop: nil,
            fallback: poster,
            prefersEnrichedBackdrop: true,
            canLoadEnrichment: true,
            enrichmentState: .completed,
            enrichedBackdrop: detailBackdrop
        )

        XCTAssertEqual(artwork, detailBackdrop)
    }

    func testEpisodeFallsBackOnlyAfterDetailConfirmsNoBackdrop() {
        let artwork = TVHeroArtworkResolver.resolve(
            sectionBackdrop: nil,
            fallback: poster,
            prefersEnrichedBackdrop: true,
            canLoadEnrichment: true,
            enrichmentState: .completed,
            enrichedBackdrop: nil
        )

        XCTAssertEqual(artwork, poster)
    }

    func testNonEpisodeUsesSectionBackdropImmediately() {
        let artwork = TVHeroArtworkResolver.resolve(
            sectionBackdrop: sectionBackdrop,
            fallback: poster,
            prefersEnrichedBackdrop: false,
            canLoadEnrichment: true,
            enrichmentState: .loading,
            enrichedBackdrop: nil
        )

        XCTAssertEqual(artwork, sectionBackdrop)
    }

    func testCollectionWithoutDetailUsesPosterFallbackImmediately() {
        let artwork = TVHeroArtworkResolver.resolve(
            sectionBackdrop: nil,
            fallback: poster,
            prefersEnrichedBackdrop: true,
            canLoadEnrichment: false,
            enrichmentState: .notStarted,
            enrichedBackdrop: nil
        )

        XCTAssertEqual(artwork, poster)
    }

    func testFailedDetailLookupFallsBackInsteadOfStayingBlank() {
        let artwork = TVHeroArtworkResolver.resolve(
            sectionBackdrop: nil,
            fallback: poster,
            prefersEnrichedBackdrop: true,
            canLoadEnrichment: true,
            enrichmentState: .failed,
            enrichedBackdrop: nil
        )

        XCTAssertEqual(artwork, poster)
    }
}
