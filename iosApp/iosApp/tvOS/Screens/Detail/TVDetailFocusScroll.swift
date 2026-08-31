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
    /// Any scroll we issue races the engine's own reveal, which is *deferred
    /// while d-pad input streams in* and can land late and clobber a single
    /// write. So both triggers re-assert their target across a window long
    /// enough to outlast the deferred reveal; every assert re-checks that the
    /// triggering row still owns focus so a stale one can never yank the page.
    ///
    /// Returning up to the Play / Start Over / circle-button row restores the
    /// page-entry framing (hero pinned to the top) the same way.
    func detailFocusScroll(
        proxy: ScrollViewProxy,
        seasonRowFocused: Bool,
        actionRowFocused: Bool,
        episodeSectionId: String,
        heroId: String,
        similarRailFocused: Bool = false,
        similarSectionId: String? = nil
    ) -> some View {
        modifier(
            DetailFocusScrollModifier(
                proxy: proxy,
                seasonRowFocused: seasonRowFocused,
                actionRowFocused: actionRowFocused,
                episodeSectionId: episodeSectionId,
                heroId: heroId,
                similarRailFocused: similarRailFocused,
                similarSectionId: similarSectionId
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
    let similarRailFocused: Bool
    let similarSectionId: String?

    private enum Region {
        case seasonRow
        case actionRow
        case similarRail
    }

    /// Live mirror of the focus state plus a generation counter, shared with
    /// the scheduled scroll closures. A class so those escaping closures read
    /// the *current* values at fire time instead of stale captured copies —
    /// that's what lets a pending assert bail out once the user has moved on.
    private final class AssertState {
        var generation = 0
        var focusedRegion: Region?
    }

    @State private var state = AssertState()

    /// Match the pace of the focus engine's own reveal scrolls; the theme's
    /// 0.2s `normalDuration` read as an abrupt snap next to them.
    private static let scrollAnimation = Animation.easeInOut(duration: 0.45)

    /// Dense early asserts so motion starts immediately even when the first
    /// write is clobbered, then sparse late ones to outlast the engine's
    /// input-deferred reveal after rapid d-pad sequences.
    private static let assertDelays: [Double] = [0.02, 0.15, 0.45, 0.8, 1.1]

    func body(content: Content) -> some View {
        // Mirror focus into the shared state on every render so in-flight
        // asserts observe focus moves that happen mid-window.
        state.focusedRegion = currentRegion
        return content
            .onChange(of: seasonRowFocused) { _, focused in
                guard focused else { return }
                assertScroll(to: episodeSectionId, anchor: .center, while: .seasonRow)
            }
            .onChange(of: actionRowFocused) { _, focused in
                guard focused else { return }
                assertScroll(to: heroId, anchor: .top, while: .actionRow)
            }
            .onChange(of: similarRailFocused) { _, focused in
                guard focused, let similarSectionId else { return }
                // Native reveal occasionally pins a poster rail against the
                // very top edge and loses its section heading. Centering the
                // complete section keeps the heading and focus lift visible.
                assertScroll(to: similarSectionId, anchor: .center, while: .similarRail)
            }
    }

    private var currentRegion: Region? {
        if seasonRowFocused { return .seasonRow }
        if actionRowFocused { return .actionRow }
        if similarRailFocused { return .similarRail }
        return nil
    }

    /// Re-assert the scroll target across the delay window. Every assert
    /// re-checks that the triggering region still owns focus (and that no
    /// newer trigger superseded it) so a stale assert can never yank the page
    /// after the user moves on. Asserts are idempotent — same target, so
    /// whichever one lands last just holds the position.
    private func assertScroll(to id: String, anchor: UnitPoint, while region: Region) {
        state.generation &+= 1
        let generation = state.generation
        for delay in Self.assertDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [state] in
                guard state.generation == generation,
                      state.focusedRegion == region else { return }
                withAnimation(Self.scrollAnimation) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            }
        }
    }
}
#endif
