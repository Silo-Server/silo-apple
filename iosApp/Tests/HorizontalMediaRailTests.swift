import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class HorizontalMediaRailTests: XCTestCase {
    private final class Frames {
        var cards: [String: CGRect] = [:]
    }

    private final class ScrollDelegate: NSObject, UIScrollViewDelegate {}

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func allScrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { allScrollViews(in: $0) }
    }

    private func makeWindow<Content: View>(_ content: Content) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        return window
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
    }

    private func items() throws -> [SectionItem] {
        try JSONDecoder().decode([SectionItem].self, from: Data(#"""
        [
          {"contentId":"fixture-movie","type":"movie","title":"A sample movie","year":2026,"positionSeconds":600,"durationSeconds":6000},
          {"contentId":"fixture-episode","type":"episode","title":"Another chapter","seriesTitle":"A sample series","seasonNumber":1,"episodeNumber":2}
        ]
        """#.utf8))
    }

    func testNativeBoundsAffectOnlyTheNearestRail() {
        let page = UIScrollView()
        page.alwaysBounceVertical = true
        let rail = UIScrollView()
        rail.alwaysBounceHorizontal = true
        rail.alwaysBounceVertical = true
        rail.decelerationRate = .fast
        rail.isPagingEnabled = true
        rail.contentSize = CGSize(width: 1800, height: 200)
        rail.contentOffset = CGPoint(x: 120, y: 0)
        let delegate = ScrollDelegate()
        rail.delegate = delegate
        let content = UIView()
        page.addSubview(rail)
        rail.addSubview(content)
        content.addSubview(PhoneMediaRailBoundsView())

        XCTAssertFalse(rail.bouncesHorizontally)
        XCTAssertFalse(rail.bouncesVertically)
        XCTAssertFalse(rail.alwaysBounceHorizontal)
        XCTAssertFalse(rail.alwaysBounceVertical)
        XCTAssertTrue(rail.isDirectionalLockEnabled)
        XCTAssertTrue(rail.isScrollEnabled)
        XCTAssertTrue(rail.isPagingEnabled)
        XCTAssertEqual(rail.decelerationRate, .fast)
        XCTAssertEqual(rail.contentOffset.x, 120)
        XCTAssertTrue(rail.delegate === delegate)
        XCTAssertTrue(page.bouncesVertically)
        XCTAssertTrue(page.alwaysBounceVertical)
        XCTAssertFalse(page.isDirectionalLockEnabled)
    }

    func testContinueWatchingKeepsEqualCardHeightsWithMissingProgress() async throws {
        let items = try items()
        XCTAssertNotNil(HomeFeedMeta.resumeCaption(for: items[0], locale: Locale(identifier: "en")))
        XCTAssertNil(HomeFeedMeta.resumeCaption(for: items[1], locale: Locale(identifier: "en")))
        for typeSize in [DynamicTypeSize.large, .accessibility1] {
            let frames = Frames()
            let content = HStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: 10) {
                ForEach(items) { item in
                    HomeStillCard(item: item, width: 170, opensResumeContext: true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("cards")) } action: {
                            frames.cards[item.contentId] = $0
                        }
                }
            }
            .coordinateSpace(name: "cards")
            .environment(AppRouter())
            .environmentObject(OverlayPrefsStore())
            .environment(\.dynamicTypeSize, typeSize)
            let window = makeWindow(content)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await settle(window)
            let movie = try XCTUnwrap(frames.cards[items[0].contentId])
            let episode = try XCTUnwrap(frames.cards[items[1].contentId])
            XCTAssertGreaterThan(movie.height, 100)
            XCTAssertEqual(movie.minY, episode.minY, accuracy: 0.5)
            XCTAssertEqual(movie.height, episode.height, accuracy: 0.5)
        }
    }

    func testOnlyContinueWatchingReservesAMissingResumeCaption() async throws {
        for item in try items() {
            let frames = Frames()
            let content = HStack(alignment: .top, spacing: 10) {
                HomeStillCard(item: item, width: 170)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("cards")) } action: {
                        frames.cards["ordinary"] = $0
                    }
                HomeStillCard(item: item, width: 170, opensResumeContext: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("cards")) } action: {
                        frames.cards["resume"] = $0
                    }
            }
            .coordinateSpace(name: "cards")
            .environment(AppRouter())
            .environmentObject(OverlayPrefsStore())
            let window = makeWindow(content)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await settle(window)
            let ordinary = try XCTUnwrap(frames.cards["ordinary"])
            let resume = try XCTUnwrap(frames.cards["resume"])
            if HomeFeedMeta.resumeCaption(for: item, locale: Locale(identifier: "en")) == nil {
                XCTAssertGreaterThan(resume.height, ordinary.height + 5,
                                     "Next Up must not reserve an invisible Continue Watching caption")
            } else {
                XCTAssertEqual(resume.height, ordinary.height, accuracy: 0.5,
                               "A visible progress caption must remain on either card")
            }
        }
    }

    @Observable
    fileprivate final class RowModel {
        var section: ResolvedSection
        init(_ section: ResolvedSection) { self.section = section }
    }

    fileprivate struct ObservedHomeRow: View {
        let model: RowModel
        var body: some View { HomeFeedRow(section: model.section) }
    }

    func testRemovingTheParkedCardKeepsTheRowInPlace() async throws {
        let cards = try (0..<8).map { index in
            try JSONDecoder().decode(SectionItem.self, from: Data(
                "{\"contentId\":\"fixture-resume-\(index)\",\"type\":\"movie\",\"title\":\"Sample \(index)\",\"positionSeconds\":600,\"durationSeconds\":6000}".utf8
            ))
        }
        let model = RowModel(ResolvedSection(
            id: "continue_watching", sectionType: "continue_watching", title: "Synthetic resume",
            featured: nil, itemLimit: nil, totalCount: nil, isCustom: nil, customized: nil, items: cards
        ))
        let window = makeWindow(ObservedHomeRow(model: model)
            .environment(AppRouter()).environmentObject(OverlayPrefsStore()))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(window)
        let rail = try XCTUnwrap(scrollViews(in: window).first)
        let start = -rail.adjustedContentInset.left

        // Park the row a few cards in through the drag callbacks SwiftUI
        // tracks, so the row's scroll position follows as it does for a swipe.
        rail.delegate?.scrollViewWillBeginDragging?(rail)
        rail.setContentOffset(CGPoint(x: start + rail.bounds.width * 2, y: 0), animated: false)
        rail.delegate?.scrollViewDidEndDragging?(rail, willDecelerate: false)
        try await settle(window)
        let parked = rail.contentOffset.x
        XCTAssertGreaterThan(parked, start + 1)

        // Remove every card that could be the parked one, one at a time, as
        // Home does after a dismissal; the row must never return to its start.
        for removed in cards.dropFirst(2).prefix(3) {
            model.section = model.section.replacingItems(
                model.section.items.filter { $0.contentId != removed.contentId }
            )
            try await settle(window)
            XCTAssertGreaterThan(rail.contentOffset.x, start + 1, "removing \(removed.contentId) reset the row")
        }
    }

    func testScrollAnchorSettlesOnTheNeighbourOfARemovedCard() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(HomeFeedRow.scrollAnchorId(keeping: "b", from: ids, to: ["a", "c", "d"]), "c")
        XCTAssertEqual(HomeFeedRow.scrollAnchorId(keeping: "d", from: ids, to: ["a", "b", "c"]), "c")
        XCTAssertEqual(HomeFeedRow.scrollAnchorId(keeping: "c", from: ids, to: ["a", "b", "c", "e"]), "c")
        // A refill that also drops the following card still lands nearby.
        XCTAssertEqual(HomeFeedRow.scrollAnchorId(keeping: "b", from: ids, to: ["a", "d", "e"]), "d")
        XCTAssertEqual(HomeFeedRow.scrollAnchorId(keeping: nil, from: ids, to: ["a", "c"]), "a")
    }

    func testHomeRowsKeepTheirBoundsAndPositionWhenRouterDetailStateChanges() async throws {
        let items = try items()
        let posters = try (0..<6).map { index in
            try JSONDecoder().decode(SectionItem.self, from: Data(
                "{\"contentId\":\"fixture-poster-\(index)\",\"type\":\"movie\",\"title\":\"Sample \(index)\"}".utf8
            ))
        }
        let rows = ["continue_watching", "trending"].map { kind in
            ResolvedSection(id: kind, sectionType: kind, title: "Synthetic \(kind)",
                            featured: nil, itemLimit: nil, totalCount: nil,
                            isCustom: nil, customized: nil,
                            items: kind == "continue_watching" ? items : posters)
        }
        let router = AppRouter()
        let window = makeWindow(ScrollView(.vertical) {
            VStack {
                ForEach(rows) { HomeFeedRow(section: $0) }
                Color.clear.frame(height: 1000)
            }
        }.environment(router).environmentObject(OverlayPrefsStore()))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(window)
        let page = try XCTUnwrap(scrollViews(in: window).first)
        let rails = allScrollViews(in: page).filter { $0 !== page }
        XCTAssertEqual(rails.count, 2)
        XCTAssertTrue(page.bouncesVertically)
        for rail in rails {
            XCTAssertFalse(rail.bouncesHorizontally)
            XCTAssertFalse(rail.bouncesVertically)
            XCTAssertTrue(rail.isScrollEnabled)
            XCTAssertTrue(rail.isDirectionalLockEnabled)
            XCTAssertEqual(rail.contentOffset.x, -rail.adjustedContentInset.left, accuracy: 1)
        }
        let posterRail = try XCTUnwrap(rails.max(by: { $0.contentSize.width < $1.contentSize.width }))
        for offset in [-posterRail.adjustedContentInset.left, 142 - posterRail.adjustedContentInset.left] {
            posterRail.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            try await settle(window)
            let before = posterRail.contentOffset.x
            router.presentItemDetail(contentId: posters[4].contentId)
            try await settle(window)
            XCTAssertEqual(posterRail.contentOffset.x, before, accuracy: 1)
            router.dismissItemDetail()
            try await settle(window)
            XCTAssertEqual(posterRail.contentOffset.x, before, accuracy: 1)
            XCTAssertFalse(posterRail.bouncesHorizontally)
            XCTAssertTrue(page.bouncesVertically)
        }
    }
}
