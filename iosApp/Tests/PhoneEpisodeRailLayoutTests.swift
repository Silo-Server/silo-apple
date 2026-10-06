#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class PhoneEpisodeRailLayoutTests: XCTestCase {
    func testTrailingMarginLetsLastCardReachLeadingEdge() {
        // 390pt iPhone rail, 16pt leading margin, 240pt cards.
        XCTAssertEqual(
            PhoneEpisodeRailLayout.selectingTrailingMargin(railWidth: 390, leadingMargin: 16, cardWidth: 240),
            134
        )
    }

    func testTrailingMarginNeverDropsBelowLeadingMargin() {
        XCTAssertEqual(
            PhoneEpisodeRailLayout.selectingTrailingMargin(railWidth: 0, leadingMargin: 16, cardWidth: 240),
            16
        )
        XCTAssertEqual(
            PhoneEpisodeRailLayout.selectingTrailingMargin(railWidth: 260, leadingMargin: 16, cardWidth: 240),
            16
        )
    }

    /// The rail must scroll far enough for the last of five episodes to sit
    /// where the first one starts, or swiping can never select it.
    func testSelectingRailScrollsLastEpisodeIntoTheLeadingSlot() async throws {
        guard HorizontalMediaRailLayout.isPhone else {
            throw XCTSkip("The leading-snap rail is iPhone-only")
        }
        let episodes = (1...5).map(episode)
        let rail = PhoneEpisodeRail(episodes: episodes, onSelect: { _ in }, selectsCenteredEpisode: true)
            .environment(AppRouter())
            .environmentObject(OverlayPrefsStore())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: rail)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        let cardStep = 240 * UICustomizationPreferences.shared.cardPresentation.posterSize.scale + 14
        let needed = CGFloat(episodes.count - 1) * cardStep - 0.5
        // The trailing margin follows the measured rail width, so wait for
        // the layout pass that applies it.
        var range: CGFloat = 0
        for _ in 0..<40 {
            window.layoutIfNeeded()
            if let scrollView = firstScrollView(in: window) {
                let minOffset = -scrollView.adjustedContentInset.left
                let maxOffset = scrollView.contentSize.width + scrollView.adjustedContentInset.right
                    - scrollView.bounds.width
                range = maxOffset - minOffset
                if range >= needed { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(range, needed)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    private func episode(_ number: Int) -> EpisodeListItem {
        EpisodeListItem(
            contentId: "episode-\(number)",
            seasonNumber: 1,
            episodeNumber: number,
            title: "Episode \(number)",
            overview: nil,
            airDate: nil,
            runtime: 50,
            imdbId: nil,
            tmdbId: nil,
            tvdbId: nil,
            stillUrl: nil,
            stillThumbhash: nil,
            userData: nil,
            files: nil
        )
    }
}
#endif
