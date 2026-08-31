#if os(tvOS)
import SwiftUI

extension View {
    /// Shared scroll choreography for the tvOS detail pages (movie/episode,
    /// series, season). Apply to the detail page's vertical ScrollView.
    ///
    /// Season rows and the Series episode carousel need an explicit centered
    /// destination so their complete section remains visible after the focus
    /// engine's own minimal reveal.
    ///
    /// Any scroll we issue races the engine's own reveal, which is *deferred
    /// while d-pad input streams in* and can land late and clobber a single
    /// write. So both triggers re-assert their target across a window long
    /// enough to outlast the deferred reveal; every assert re-checks that the
    /// triggering row still owns focus so a stale one can never yank the page.
    ///
    /// Returning up to the Play / selector cluster restores the page-entry
    /// framing (hero pinned to the top) the same way.
    func detailFocusScroll(
        proxy: ScrollViewProxy,
        seasonRowFocused: Bool,
        actionRowFocused: Bool,
        episodeRailFocused: Bool = false,
        episodeSectionId: String,
        heroId: String,
        browseFocusKey: String? = nil,
        usesSinglePrimaryMovement: Bool = false,
        similarRailFocused: Bool = false,
        similarSectionId: String? = nil
    ) -> some View {
        modifier(
            DetailFocusScrollModifier(
                proxy: proxy,
                seasonRowFocused: seasonRowFocused,
                actionRowFocused: actionRowFocused,
                episodeRailFocused: episodeRailFocused,
                episodeSectionId: episodeSectionId,
                heroId: heroId,
                browseFocusKey: browseFocusKey,
                usesSinglePrimaryMovement: usesSinglePrimaryMovement,
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
    let episodeRailFocused: Bool
    let episodeSectionId: String
    let heroId: String
    let browseFocusKey: String?
    let usesSinglePrimaryMovement: Bool
    let similarRailFocused: Bool
    let similarSectionId: String?

    private enum Region {
        case seasonRow
        case actionRow
        case episodeRail
        case browse
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
    private static let browseScrollAnimation = Animation.smooth(
        duration: 1.0,
        extraBounce: 0
    )
    private static let primaryScrollAnimation = Animation.smooth(
        duration: 0.55,
        extraBounce: 0
    )

    /// Dense early asserts so motion starts immediately even when the first
    /// write is clobbered, then sparse late ones to outlast the engine's
    /// input-deferred reveal after rapid d-pad sequences.
    private static let assertDelays: [Double] = [0.02, 0.15, 0.45, 0.8, 1.1]
    /// Series hero controls share one fixed viewport. One immediate smooth
    /// write starts the motion, then a single late write outlasts tvOS's native
    /// reveal without repeatedly restarting the curve.
    private static let browseAssertDelays: [Double] = [0, 1.08]

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
            .onChange(of: episodeRailFocused) { _, focused in
                guard focused else { return }
                assertScroll(to: episodeSectionId, anchor: .center, while: .episodeRail)
            }
            .onChange(of: browseFocusKey) { _, focusKey in
                guard focusKey != nil else {
                    state.generation &+= 1
                    return
                }
                // The Series hero controls retain the page-entry framing until
                // the episode rail explicitly takes focus below.
                assertScroll(to: heroId, anchor: .top, while: .browse)
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
        if actionRowFocused { return .actionRow }
        if similarRailFocused { return .similarRail }
        if episodeRailFocused { return .episodeRail }
        if seasonRowFocused { return .seasonRow }
        if browseFocusKey != nil { return .browse }
        return nil
    }

    /// Series primary transitions use one coordinated animation. Legacy detail
    /// regions retain their defensive delayed assertions, and every delayed
    /// write re-checks that its triggering region still owns focus.
    private func assertScroll(to id: String, anchor: UnitPoint, while region: Region) {
        guard state.focusedRegion == region else { return }
        state.generation &+= 1

        if usesSinglePrimaryMovement,
           (region == .actionRow || region == .episodeRail) {
            withAnimation(Self.primaryScrollAnimation) {
                proxy.scrollTo(id, anchor: anchor)
            }
            return
        }

        let generation = state.generation
        let delays = region == .browse
            ? Self.browseAssertDelays
            : Self.assertDelays
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [state] in
                guard state.generation == generation,
                      state.focusedRegion == region else { return }
                if region == .browse {
                    withAnimation(Self.browseScrollAnimation) {
                        proxy.scrollTo(id, anchor: anchor)
                    }
                } else {
                    withAnimation(Self.scrollAnimation) {
                        proxy.scrollTo(id, anchor: anchor)
                    }
                }
            }
        }
    }
}
#endif
