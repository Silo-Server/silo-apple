import Foundation
import XCTest
@testable import Silo

final class HomeSectionsMutationTests: XCTestCase {
    private enum TestError: Error {
        case failed
    }

    @MainActor
    func testOnlyTopFeaturedSectionBecomesHeroAndLaterFeaturedSectionRemainsARow() throws {
        let item = try makeItem(contentId: "item")
        let viewModel = HomeViewModel()
        viewModel.sections = [
            makeSection(id: "featured-first", type: "custom", totalCount: 1, featured: true, items: [item]),
            makeSection(id: "featured-later", type: "custom", totalCount: 1, featured: true, items: [item]),
        ]

        XCTAssertEqual(viewModel.featuredSection?.id, "featured-first")
        XCTAssertEqual(viewModel.regularSections.map(\.id), ["featured-later"])
    }

    @MainActor
    func testFeaturedSectionBelowTopRowDoesNotBecomeHero() throws {
        let item = try makeItem(contentId: "item")
        let viewModel = HomeViewModel()
        viewModel.sections = [
            makeSection(id: "regular", type: "recently_added", totalCount: 1, items: [item]),
            makeSection(id: "featured-later", type: "custom", totalCount: 1, featured: true, items: [item]),
        ]

        XCTAssertNil(viewModel.featuredSection)
        XCTAssertEqual(viewModel.regularSections.map(\.id), ["regular", "featured-later"])
    }

    func testRemovesItemOnlyFromContinueWatchingSections() throws {
        let target = try makeItem(contentId: "target")
        let other = try makeItem(contentId: "other")
        let sections = [
            makeSection(id: "continue", type: "continue_watching", totalCount: 2, items: [target, other]),
            makeSection(id: "watchlist", type: "watchlist", totalCount: 1, items: [target]),
        ]

        let result = HomeSectionsMutation.removingContinueWatchingItem(
            contentId: target.contentId,
            from: sections
        )

        XCTAssertEqual(result[0].items.map(\.contentId), ["other"])
        XCTAssertEqual(result[0].totalCount, 1)
        XCTAssertEqual(result[1].items.map(\.contentId), ["target"])
        XCTAssertEqual(result[1].totalCount, 1)
    }

    func testLegacyInProgressSectionUsesSameRemovalSemantics() throws {
        let target = try makeItem(contentId: "target")
        let section = makeSection(id: "progress", type: "in_progress", totalCount: 1, items: [target])

        let result = HomeSectionsMutation.removingContinueWatchingItem(
            contentId: target.contentId,
            from: [section]
        )

        XCTAssertTrue(result[0].items.isEmpty)
        XCTAssertEqual(result[0].totalCount, 0)
    }

    func testTotalCountIsClampedAtZero() throws {
        let target = try makeItem(contentId: "target")
        let section = makeSection(id: "continue", type: "continue_watching", totalCount: 0, items: [target])

        let result = HomeSectionsMutation.removingContinueWatchingItem(
            contentId: target.contentId,
            from: [section]
        )

        XCTAssertEqual(result[0].totalCount, 0)
    }

    func testUnknownContentIdLeavesSectionUnchanged() throws {
        let item = try makeItem(contentId: "other")
        let section = makeSection(id: "continue", type: "continue_watching", totalCount: 1, items: [item])

        let result = HomeSectionsMutation.removingContinueWatchingItem(
            contentId: "missing",
            from: [section]
        )

        XCTAssertEqual(result[0].items, section.items)
        XCTAssertEqual(result[0].totalCount, section.totalCount)
    }

    func testCompletedItemIsRemovedFromPlaybackDrivenSections() throws {
        let target = try makeItem(contentId: "target")
        let other = try makeItem(contentId: "other")
        let sections = [
            makeSection(id: "continue", type: "continue_watching", totalCount: 2, items: [target, other]),
            makeSection(id: "next", type: "next_up", totalCount: 1, items: [target]),
            makeSection(id: "trending", type: "trending", totalCount: 1, items: [target]),
        ]

        let result = HomeSectionsMutation.removingCompletedItem(
            contentId: target.contentId,
            from: sections
        )

        XCTAssertEqual(result[0].items.map(\.contentId), ["other"])
        XCTAssertEqual(result[0].totalCount, 1)
        XCTAssertTrue(result[1].items.isEmpty)
        XCTAssertEqual(result[1].totalCount, 0)
        XCTAssertEqual(result[2].items.map(\.contentId), ["target"])
        XCTAssertEqual(result[2].totalCount, 1)
    }

    @MainActor
    func testSuccessfulDismissalUpdatesVisibleAndCachedSections() async throws {
        let target = try makeItem(contentId: "target")
        let other = try makeItem(contentId: "other")
        let sections = [
            makeSection(id: "continue", type: "continue_watching", totalCount: 2, items: [target, other]),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        var receivedContentId: String?
        var receivedProgressTimestamp: String?
        let viewModel = HomeViewModel(
            dismissContinueWatching: { contentId, progressUpdatedAt in
                receivedContentId = contentId
                receivedProgressTimestamp = progressUpdatedAt
            }
        )

        await viewModel.dismissContinueWatchingItem(target)

        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(receivedContentId, "target")
        XCTAssertEqual(receivedProgressTimestamp, target.progressUpdatedAt)
        XCTAssertEqual(viewModel.sections[0].items.map(\.contentId), ["other"])
        XCTAssertEqual(cached?.sections[0].items.map(\.contentId), ["other"])
        XCTAssertNil(viewModel.actionError)
    }

    @MainActor
    func testFailedDismissalPreservesStateAndSurfacesError() async throws {
        let target = try makeItem(contentId: "target")
        let sections = [
            makeSection(id: "continue", type: "continue_watching", totalCount: 1, items: [target]),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        let viewModel = HomeViewModel(
            dismissContinueWatching: { _, _ in
                throw TestError.failed
            }
        )

        await viewModel.dismissContinueWatchingItem(target)

        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(viewModel.sections[0].items.map(\.contentId), ["target"])
        XCTAssertEqual(cached?.sections[0].items.map(\.contentId), ["target"])
        XCTAssertNotNil(viewModel.actionError)
        XCTAssertTrue(viewModel.isShowingActionError)
    }

    @MainActor
    func testSuccessfulWatchedUpdateRemovesItemFromNextUpAndCache() async throws {
        let target = try makeItem(contentId: "target")
        let other = try makeItem(contentId: "other")
        let sections = [
            makeSection(id: "next", type: "next_up", totalCount: 2, items: [target, other]),
            makeSection(id: "trending", type: "trending", totalCount: 1, items: [target]),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        var receivedContentId: String?
        var receivedPlayed: Bool?
        let viewModel = HomeViewModel(
            setWatched: { contentId, played in
                receivedContentId = contentId
                receivedPlayed = played
            },
            fetchHomeSections: {
                // A reconciliation failure must not undo the committed local
                // update or require a manual pull-to-refresh.
                throw TestError.failed
            }
        )

        let succeeded = await viewModel.setWatched(target, played: true)

        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(receivedContentId, "target")
        XCTAssertEqual(receivedPlayed, true)
        XCTAssertEqual(viewModel.sections[0].items.map(\.contentId), ["other"])
        XCTAssertEqual(viewModel.sections[0].totalCount, 1)
        XCTAssertEqual(viewModel.sections[1].items.map(\.contentId), ["target"])
        XCTAssertEqual(cached?.sections[0].items.map(\.contentId), ["other"])
        XCTAssertEqual(cached?.sections[0].totalCount, 1)
        XCTAssertEqual(cached?.sections[1].items.map(\.contentId), ["target"])
        XCTAssertNil(viewModel.actionError)
    }

    @MainActor
    func testFailedWatchedUpdatePreservesStateAndSurfacesError() async throws {
        let target = try makeItem(contentId: "target")
        let sections = [
            makeSection(id: "next", type: "next_up", totalCount: 1, items: [target]),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        let viewModel = HomeViewModel(
            setWatched: { _, _ in
                throw TestError.failed
            }
        )

        let succeeded = await viewModel.setWatched(target, played: true)

        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(viewModel.sections[0].items.map(\.contentId), ["target"])
        XCTAssertEqual(cached?.sections[0].items.map(\.contentId), ["target"])
        XCTAssertNotNil(viewModel.actionError)
        XCTAssertTrue(viewModel.isShowingActionError)
    }

    private func makeItem(contentId: String) throws -> SectionItem {
        let json = """
        {
          "contentId": "\(contentId)",
          "type": "movie",
          "title": "Test Item",
          "progressUpdatedAt": "2026-07-10T12:00:00Z"
        }
        """
        return try JSONDecoder().decode(SectionItem.self, from: Data(json.utf8))
    }

    private func makeSection(
        id: String,
        type: String,
        totalCount: Int?,
        featured: Bool = false,
        items: [SectionItem]
    ) -> ResolvedSection {
        ResolvedSection(
            id: id,
            sectionType: type,
            title: id,
            featured: featured,
            itemLimit: nil,
            totalCount: totalCount,
            isCustom: false,
            customized: false,
            items: items
        )
    }
}
