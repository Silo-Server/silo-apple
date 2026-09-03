import Foundation
import XCTest
@testable import Silo

final class HomeSectionsMutationTests: XCTestCase {
    private enum TestError: Error {
        case failed
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
    func testNextUpCardDismissesOnNextUpSurfaceAndClearsBothRows() async throws {
        // A Next Up episode merged into Continue Watching has a series but no
        // progress row. It must not be sent to the continue_watching surface
        // with a fabricated timestamp, which the server would never match.
        let target = try makeItem(contentId: "target", progressUpdatedAt: nil, seriesId: "series-1")
        let other = try makeItem(contentId: "other")
        let sections = [
            makeSection(id: "continue", type: "continue_watching", totalCount: 2, items: [target, other]),
            makeSection(id: "next", type: "next_up", totalCount: 1, items: [target]),
            makeSection(id: "trending", type: "trending", totalCount: 1, items: [target]),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        var continueWatchingCalls = 0
        var receivedContentId: String?
        var receivedSeriesId: String?
        let viewModel = HomeViewModel(
            dismissContinueWatching: { _, _ in
                continueWatchingCalls += 1
            },
            dismissNextUp: { contentId, seriesId in
                receivedContentId = contentId
                receivedSeriesId = seriesId
            }
        )

        await viewModel.dismissContinueWatchingItem(target)

        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(continueWatchingCalls, 0)
        XCTAssertEqual(receivedContentId, "target")
        XCTAssertEqual(receivedSeriesId, "series-1")
        XCTAssertEqual(viewModel.sections.map { $0.items.map(\.contentId) }, [["other"], [], ["target"]])
        XCTAssertEqual(cached?.sections.map { $0.items.map(\.contentId) }, [["other"], [], ["target"]])
        XCTAssertNil(viewModel.actionError)
    }

    @MainActor
    func testCardWithoutProgressOrSeriesIsLeftInPlace() async throws {
        let target = try makeItem(contentId: "target", progressUpdatedAt: nil, seriesId: nil)
        let sections = [
            makeSection(id: "continue", type: "continue_watching", totalCount: 1, items: [target]),
        ]
        ResponseCache.shared.set(SectionsResponse(sections: sections), for: CacheKey.homeSections)
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        let viewModel = HomeViewModel(
            dismissContinueWatching: { _, _ in XCTFail("unexpected continue_watching dismissal") },
            dismissNextUp: { _, _ in XCTFail("unexpected next_up dismissal") }
        )

        await viewModel.dismissContinueWatchingItem(target)

        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(viewModel.sections[0].items.map(\.contentId), ["target"])
        XCTAssertEqual(cached?.sections[0].items.map(\.contentId), ["target"])
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

    @MainActor
    func testPlaybackWriteRefreshReloadsResumeAndSuccessorWithoutManualRefresh() async throws {
        for (contentId, position) in [("episode-one", 450), ("episode-two", 30)] {
            let oldItem = try makeItem(contentId: "episode-one")
            let stale = SectionsResponse(sections: [makeSection(
                id: "continue", type: "continue_watching", totalCount: 1, items: [oldItem]
            )])
            let updated = try JSONDecoder().decode(SectionItem.self, from: Data(
                "{\"contentId\":\"\(contentId)\",\"type\":\"episode\",\"title\":\"Synthetic episode\",\"positionSeconds\":\(position),\"durationSeconds\":1200}".utf8
            ))
            let fresh = SectionsResponse(sections: [makeSection(
                id: "continue", type: "continue_watching", totalCount: 1, items: [updated]
            )])
            ResponseCache.shared.set(stale, for: CacheKey.homeSections)
            let model = HomeViewModel(fetchHomeSections: { fresh })
            let refresh = StartupContentPrefetcher.homeRefreshAfterPlaybackWrite()
            let received = expectation(description: "Home refresh after \(contentId) progress write")
            let observer = NotificationCenter.default.addObserver(
                forName: .homeSectionsShouldRefresh, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
                    XCTAssertNil(cached, "Invalidate stale cache before notifying the visible Home view")
                    Task { @MainActor in
                        await model.loadSections()
                        received.fulfill()
                    }
                }
            }
            defer {
                NotificationCenter.default.removeObserver(observer)
                ResponseCache.shared.remove(CacheKey.homeSections)
            }
            // Capturing the completion must not refresh before the write.
            XCTAssertEqual(model.sections.first?.items.first?.contentId, "episode-one")
            XCTAssertNotNil(ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self))
            refresh()
            await fulfillment(of: [received], timeout: 2)
            XCTAssertEqual(model.sections.first?.items.first?.contentId, contentId)
            XCTAssertEqual(model.sections.first?.items.first?.positionSeconds, Double(position))
        }
    }

    @MainActor
    func testLatePlaybackWriteCannotInvalidateAnotherProfileHome() throws {
        let refresh = StartupContentPrefetcher.homeRefreshAfterPlaybackWrite()
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        let current = SectionsResponse(sections: [makeSection(
            id: "new-profile", type: "continue_watching", totalCount: 1,
            items: [try makeItem(contentId: "new-profile-item")]
        )])
        ResponseCache.shared.set(current, for: CacheKey.homeSections)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .homeSectionsShouldRefresh, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { notifications += 1 } }
        defer {
            NotificationCenter.default.removeObserver(observer)
            ResponseCache.shared.remove(CacheKey.homeSections)
        }
        refresh()
        XCTAssertEqual(notifications, 0)
        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        XCTAssertEqual(cached?.sections.first?.items.first?.contentId, "new-profile-item")
    }

    private func makeItem(
        contentId: String,
        progressUpdatedAt: String? = "2026-07-10T12:00:00Z",
        seriesId: String? = nil
    ) throws -> SectionItem {
        var fields: [String: Any] = [
            "contentId": contentId,
            "type": "movie",
            "title": "Test Item",
        ]
        if let progressUpdatedAt {
            fields["progressUpdatedAt"] = progressUpdatedAt
        }
        if let seriesId {
            fields["seriesId"] = seriesId
        }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(SectionItem.self, from: data)
    }

    private func makeSection(
        id: String,
        type: String,
        totalCount: Int?,
        items: [SectionItem]
    ) -> ResolvedSection {
        ResolvedSection(
            id: id,
            sectionType: type,
            title: id,
            featured: false,
            itemLimit: nil,
            totalCount: totalCount,
            isCustom: false,
            customized: false,
            items: items
        )
    }
}
