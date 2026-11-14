import SwiftUI
import XCTest
@testable import Silo

#if os(iOS)
@MainActor
final class BrowseCollectionGridTests: XCTestCase {
    private static func titles(_ positions: Range<Int>) -> [BrowseItem] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return positions.map { position in
            let json = #"{"content_id":"movie:t\#(position)","type":"movie","title":"Title \#(position)","year":1999}"#
            return try! decoder.decode(BrowseItem.self, from: Data(json.utf8))
        }
    }

    /// Reads what the app's controls and cards read from the environment;
    /// drawing it without them stops the test.
    private struct EnvironmentProbe: View {
        @Environment(AppRouter.self) private var router
        @EnvironmentObject private var overlayStore: OverlayPrefsStore

        var body: some View {
            Text(verbatim: "Controls \(router.path.count) \(overlayStore.enabled)")
        }
    }

    private func collectionView(in view: UIView) -> UICollectionView? {
        (view as? UICollectionView) ?? view.subviews.lazy.compactMap { self.collectionView(in: $0) }.first
    }

    private func settle(_ window: UIWindow, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            if condition() || ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func shownPositions(_ collection: UICollectionView) -> [Int] {
        collection.indexPathsForVisibleItems.filter { $0.section == 1 }.map(\.item).sorted()
    }

    /// The grid as the Library tab shows it: under top chrome that reaches
    /// it as a safe-area inset, in title order with a letter index.
    func testAJumpLandsOnTheLetterAndTitlesArrivingAroundItMoveNothing() async throws {
        let total = 3000
        let pager = CatalogPositionPager(total: total) { start, limit in
            try await Task.sleep(for: .milliseconds(20))
            return Self.titles(start..<min(start + limit, total))
        }
        let commands = BrowseGridCommands()
        let chrome = PageChromeScrollState()
        let grid = BrowseCollectionGrid(
            items: Self.titles(0..<60),
            pager: pager,
            isLoading: false,
            hasMore: false,
            listIdentity: "library",
            forcesThreeColumnsOnPhone: true,
            trailingPadding: BrowseLetterIndex.reservedWidth,
            commands: commands,
            header: { AnyView(EnvironmentProbe().frame(height: 44)) },
            onItemTap: { _ in },
            onLoadMore: {},
            onRefresh: {}
        )
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 90) }
        .environment(chrome)
        .environment(AppRouter())
        .environmentObject(OverlayPrefsStore())

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: grid)
        window.isHidden = false
        defer { window.isHidden = true }

        var found: UICollectionView?
        try await settle(window) {
            found = self.collectionView(in: window)
            return found.map { !self.shownPositions($0).isEmpty } ?? false
        }
        let collection = try XCTUnwrap(found)
        XCTAssertEqual(collection.numberOfItems(inSection: 1), total, "the grid has a place for every title from the start")
        XCTAssertEqual(shownPositions(collection).first, 0)
        XCTAssertGreaterThanOrEqual(collection.adjustedContentInset.top, 90, "the page chrome insets the grid")
        XCTAssertEqual(collection.contentOffset.y, -collection.adjustedContentInset.top, accuracy: 0.5)
        XCTAssertEqual(chrome.offset, 0)

        commands.scroll(toPosition: 1501)
        try await settle(window) { self.shownPositions(collection).contains(1501) }
        let row = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 1501, section: 1))).frame
        XCTAssertEqual(
            row.minY - collection.contentOffset.y,
            collection.adjustedContentInset.top + SiloTheme.smallPadding,
            accuracy: 0.5,
            "the letter's row sits just under the page chrome"
        )
        XCTAssertEqual(chrome.offset, PageChromeGlass.fadeEnd)
        let landed = collection.contentOffset
        let size = collection.contentSize

        // The titles around the landing arrive, the ones above it included.
        try await settle(window) { pager.isLoaded(1400..<1700) }
        XCTAssertTrue(pager.isLoaded(1400..<1700))
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        XCTAssertEqual(collection.contentOffset, landed)
        XCTAssertEqual(collection.contentSize, size)
        XCTAssertTrue(shownPositions(collection).contains(1501))
    }

    func testColumnsFollowTheLibraryGridRules() {
        var inputs = BrowseGridLayoutInputs(horizontalSizeClass: .compact, verticalSizeClass: .regular)
        inputs.forcesThreeColumnsOnPhone = true
        inputs.posterSize = .large
        let phone = BrowseGridMetrics.resolve(containerWidth: 349, isPhone: true, inputs: inputs)
        XCTAssertEqual(phone.columnCount, 3, "a library stays three-up on iPhone at any card size")
        XCTAssertEqual(phone.cardWidth, min(SiloTheme.posterCardWidth, (349 - 16) / 3), accuracy: 0.01)

        inputs.isAccessibilitySize = true
        XCTAssertEqual(BrowseGridMetrics.resolve(containerWidth: 349, isPhone: true, inputs: inputs).columnCount, 2)

        let pad = BrowseGridMetrics.resolve(
            containerWidth: 1000,
            isPhone: false,
            inputs: BrowseGridLayoutInputs(horizontalSizeClass: .regular, verticalSizeClass: .regular)
        )
        XCTAssertEqual(pad.columnCount, 6)
        XCTAssertEqual(pad.cardWidth * 6 + pad.spacing * 5, 1000, accuracy: 0.01, "iPad cards fill the row")
    }
}
#endif

/// The Mac grid lays its posters out in one adaptive column; jumps and the
/// titles read above a jump need the number of cards it fits in a row.
final class CatalogGridColumnCountTests: XCTestCase {
    func testAnAdaptiveColumnCountsTheCardsThatFitTheWidth() {
        let adaptive = [GridItem(.adaptive(minimum: 120), spacing: 8)]
        XCTAssertEqual(CatalogGrid.laidOutColumnCount(adaptive, width: 1000), 7)
        XCTAssertEqual(CatalogGrid.laidOutColumnCount(adaptive, width: 100), 1)
        XCTAssertEqual(CatalogGrid.laidOutColumnCount(adaptive, width: 0), 1)
    }

    func testFixedColumnsCountThemselves() {
        let three = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        XCTAssertEqual(CatalogGrid.laidOutColumnCount(three, width: 1000), 3)
    }
}
