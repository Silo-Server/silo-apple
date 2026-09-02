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
        browseFocusKey: String? = nil,
        browseHoldRequest: Int = 0,
        browseRestoreRequest: Int = 0,
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
                browseFocusKey: browseFocusKey,
                browseHoldRequest: browseHoldRequest,
                browseRestoreRequest: browseRestoreRequest,
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
    let browseFocusKey: String?
    let browseHoldRequest: Int
    let browseRestoreRequest: Int
    let similarRailFocused: Bool
    let similarSectionId: String?

    private enum Region {
        case seasonRow
        case actionRow
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
        duration: 0.55,
        extraBounce: 0
    )

    /// Dense early asserts so motion starts immediately even when the first
    /// write is clobbered, then sparse late ones to outlast the engine's
    /// input-deferred reveal after rapid d-pad sequences.
    private static let assertDelays: [Double] = [0.02, 0.15, 0.45, 0.8, 1.1]
    /// Series row-to-row moves share one fixed viewport. A single write owns
    /// entry into that viewport; a delayed duplicate can fire after a later
    /// focus move and is visible as a page bounce.
    private static let browseAssertDelays: [Double] = [0]

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
            .onChange(of: browseFocusKey) { _, focusKey in
                guard focusKey != nil else {
                    state.generation &+= 1
                    return
                }
                // Series browsing is a fixed first-viewport experience: the
                // logo and artwork remain the visual anchor while cards move
                // horizontally beneath the focused carousel slot.
                if browseRestoreRequest > 0 {
                    restoreBrowseScroll(to: heroId, anchor: .top)
                } else {
                    assertScroll(to: heroId, anchor: .top, while: .browse)
                }
            }
            .onChange(of: browseHoldRequest) { _, request in
                guard request > 0, browseFocusKey != nil else { return }
                // A Season -> Episodes move is already at the approved main
                // framing. Hold that exact offset through tvOS's short native
                // reveal window instead of letting it pan down and correcting
                // back afterward.
                holdScroll(to: heroId, anchor: .top, while: .browse)
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
        if seasonRowFocused { return .seasonRow }
        if browseFocusKey != nil { return .browse }
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

    /// Re-apply the current browse anchor for the few frames in which tvOS
    /// performs its automatic focus reveal. These writes deliberately carry
    /// no animation: the viewport is already correct, so animating a return
    /// would create the very dip/rebound this hold is preventing.
    private func holdScroll(to id: String, anchor: UnitPoint, while region: Region) {
        state.generation &+= 1
        let generation = state.generation

        // Ten frames at 60 Hz cover the native row-to-row reveal. The Series
        // page explicitly releases this lock before focusing Cast, so these
        // corrections never compete with its first deliberate page scroll.
        for frame in 0...9 {
            let delay = Double(frame) / 60
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [state] in
                guard state.generation == generation,
                      state.focusedRegion == region else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            }
        }
    }

    /// Returning from a lower supporting rail is the only animated entry into
    /// the fixed Series viewport. Final position ownership is handled by the
    /// outer scroll view's idle phase rather than delayed correction timers.
    private func restoreBrowseScroll(to id: String, anchor: UnitPoint) {
        state.generation &+= 1
        let generation = state.generation

        DispatchQueue.main.async { [state] in
            guard state.generation == generation,
                  state.focusedRegion == .browse else { return }
            withAnimation(Self.browseScrollAnimation) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }
}
#endif
