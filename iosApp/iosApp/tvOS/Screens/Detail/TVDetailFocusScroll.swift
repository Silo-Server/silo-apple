#if os(tvOS)
import SwiftUI

extension View {
    /// Shared scroll choreography for the tvOS detail pages (movie/episode,
    /// series, season). Apply to the detail page's vertical ScrollView.
    ///
    /// Only multi-season pages need help: the short season chip row
    /// intercepts the down move, so the focus engine's minimal reveal scroll
    /// stops with the episode rail below the fold. Single-season pages never
    /// misframe — focus lands straight on the tall episode card and the
    /// engine's reveal produces the deep centered framing natively.
    ///
    /// Each focus transition produces at most one scroll. Repeated delayed
    /// `scrollTo` calls restart the animation while the focus engine is also
    /// revealing the focused control, which makes the page visibly stutter.
    /// Using the focused region as the task identity also cancels a pending
    /// request as soon as focus moves elsewhere.
    ///
    /// Returning up to the Play / Start Over / circle-button row restores the
    /// page-entry framing (hero pinned to the top) the same way.
    func detailFocusScroll(
        proxy: ScrollViewProxy,
        seasonRowFocused: Bool,
        actionRowFocused: Bool,
        episodeSectionId: String,
        heroId: String
    ) -> some View {
        modifier(
            DetailFocusScrollModifier(
                proxy: proxy,
                seasonRowFocused: seasonRowFocused,
                actionRowFocused: actionRowFocused,
                episodeSectionId: episodeSectionId,
                heroId: heroId
            )
        )
    }
}

private struct DetailFocusScrollModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let seasonRowFocused: Bool
    let actionRowFocused: Bool
    let episodeSectionId: String
    let heroId: String

    private enum Region: Equatable {
        case seasonRow
        case actionRow
    }

    /// A single non-bouncy curve follows the native reveal without continuing
    /// to move after focus has visually settled.
    private static let scrollAnimation = Animation.smooth(duration: 0.32, extraBounce: 0)

    func body(content: Content) -> some View {
        content
            .task(id: currentRegion) {
                guard let region = currentRegion else { return }

                // Let SwiftUI commit the new focused geometry before asking
                // the reader to frame it. This is one cooperative yield, not
                // a delayed corrective focus or a chain of scroll assertions.
                await Task.yield()
                guard !Task.isCancelled else { return }

                withAnimation(Self.scrollAnimation) {
                    switch region {
                    case .seasonRow:
                        proxy.scrollTo(episodeSectionId, anchor: .center)
                    case .actionRow:
                        proxy.scrollTo(heroId, anchor: .top)
                    }
                }
            }
    }

    private var currentRegion: Region? {
        if seasonRowFocused { return .seasonRow }
        if actionRowFocused { return .actionRow }
        return nil
    }
}
#endif
