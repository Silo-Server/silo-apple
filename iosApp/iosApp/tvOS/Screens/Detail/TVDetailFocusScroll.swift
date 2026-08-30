#if os(tvOS)
import Observation
import SwiftUI

/// Scroll-synchronous visual state for the detail canvas. The owning detail
/// view deliberately passes this reference without reading `progress` in its
/// body, so frame-by-frame scroll updates invalidate only the small visual
/// leaves that consume it instead of rebuilding the complete focus graph.
@Observable
final class TVDetailScrollVisualState {
    var progress: CGFloat = 0
}

extension View {
    /// Shared scroll choreography for the tvOS detail pages (movie/episode,
    /// series, season). Apply to the detail page's vertical ScrollView.
    ///
    /// The season pills and cards are one browser region. Entering either one
    /// uses the focus engine's native reveal, producing one coherent hero →
    /// episode transition even on pages without a season-pill row.
    ///
    /// Each focus transition produces at most one scroll. Repeated delayed
    /// `scrollTo` calls restart the animation while the focus engine is also
    /// revealing the focused control, which makes the page visibly stutter.
    /// Using the focused region as the task identity also cancels a pending
    /// request as soon as focus moves elsewhere.
    ///
    /// Returning up to the Play / Start Over / circle-button row restores the
    /// page-entry framing (hero pinned to the top) the same way.
    ///
    func detailFocusScroll(
        proxy: ScrollViewProxy,
        episodeBrowserFocused: Bool,
        heroControlsFocused: Bool,
        episodeSectionId: String,
        heroId: String
    ) -> some View {
        modifier(
            DetailFocusScrollModifier(
                proxy: proxy,
                episodeBrowserFocused: episodeBrowserFocused,
                heroControlsFocused: heroControlsFocused,
                episodeSectionId: episodeSectionId,
                heroId: heroId
            )
        )
    }
}

private struct DetailFocusScrollModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let episodeBrowserFocused: Bool
    let heroControlsFocused: Bool
    let episodeSectionId: String
    let heroId: String

    private enum Destination: Equatable {
        case episodeBrowser
        case hero
    }

    private struct ScrollRequest: Equatable {
        let destination: Destination
        let generation: Int
    }

    /// Remembers the canvas destination across the focus engine's transient
    /// `item -> nil -> item` handoff. Without this, horizontal movement within
    /// a row replays the same vertical `scrollTo` and nudges the page.
    @State private var settledDestination: Destination?

    /// A single non-bouncy curve follows the native reveal without continuing
    /// to move after focus has visually settled.
    private static let scrollAnimation = Animation.smooth(duration: 0.44, extraBounce: 0)

    func body(content: Content) -> some View {
        content
            .task(id: currentRequest) {
                guard let request = currentRequest else {
                    // Focus commonly passes through nil between controls in
                    // the same destination. Preserve the latch so Play →
                    // Version cannot replay the hero scroll and nudge the
                    // canvas. A real browser ↔ hero transition still changes
                    // the destination and therefore issues the required
                    // request without relying on a nil reset.
                    return
                }
                guard request.destination != settledDestination else { return }

                // Let SwiftUI commit the new focused geometry before asking
                // the reader to frame it. This is one cooperative yield, not
                // a delayed corrective focus or a chain of scroll assertions.
                await Task.yield()
                guard !Task.isCancelled else { return }

                TVDetailFocusDiagnostics.record(
                    "detail.scroll.request",
                    target: request.destination == .hero ? "hero" : "episodeBrowser",
                    action: request.destination == .hero ? "scrollTo" : "nativeReveal",
                    state: "generation=\(request.generation)",
                    essential: true
                )
                settledDestination = request.destination
                switch request.destination {
                case .episodeBrowser:
                    // The focus engine already reveals the newly focused
                    // Season pill or episode card at its preferred safe-area
                    // position. Forcing the section to `.top` competes with
                    // that placement; the next horizontal move then corrects
                    // the canvas by roughly one focus-margin.
                    break
                case .hero:
                    withAnimation(Self.scrollAnimation) {
                        proxy.scrollTo(heroId, anchor: .top)
                    }
                }
            }
    }

    private var currentRequest: ScrollRequest? {
        if episodeBrowserFocused {
            return ScrollRequest(destination: .episodeBrowser, generation: 0)
        }
        if heroControlsFocused {
            return ScrollRequest(destination: .hero, generation: 0)
        }
        return nil
    }
}
#endif
