#if os(tvOS)
import SwiftUI

extension View {
    /// Detail-page scroll choreography. Apply to the detail page's vertical
    /// ScrollView. Returning focus to the hero action row pins the hero to the
    /// top; focusing the recommendations rail centers its section so the
    /// heading stays visible. Each request re-checks focus before it fires, so
    /// a stale request cannot pull the page back.
    ///
    /// The action row re-asserts its target to outlast native reveals deferred
    /// by repeated d-pad input. Recommendation entry uses one scroll request:
    /// repeating an animated centering request can interrupt the reveal
    /// already in flight and cause a visible hitch.
    func detailFocusScroll(
        proxy: ScrollViewProxy,
        actionRowFocused: Bool,
        heroId: String,
        similarRailFocused: Bool = false,
        similarSectionId: String? = nil
    ) -> some View {
        modifier(
            DetailFocusScrollModifier(
                proxy: proxy,
                actionRowFocused: actionRowFocused,
                heroId: heroId,
                similarRailFocused: similarRailFocused,
                similarSectionId: similarSectionId
            )
        )
    }
}

private struct DetailFocusScrollModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let actionRowFocused: Bool
    let heroId: String
    let similarRailFocused: Bool
    let similarSectionId: String?

    private enum Region {
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
    /// Recommendation entry must not restart its animation with delayed
    /// corrections, including while moving laterally within the rail.
    private static let singleAssertDelays: [Double] = [0]

    func body(content: Content) -> some View {
        // Mirror focus into the shared state on every render so in-flight
        // asserts observe focus moves that happen mid-window.
        state.focusedRegion = currentRegion
        return content
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
        if actionRowFocused { return .actionRow }
        if similarRailFocused { return .similarRail }
        return nil
    }

    /// Re-assert the scroll target across the delay window. Every assert
    /// re-checks that the triggering region still owns focus (and that no
    /// newer trigger superseded it) so a stale assert can never yank the page
    /// after the user moves on.
    private func assertScroll(to id: String, anchor: UnitPoint, while region: Region) {
        state.generation &+= 1
        let generation = state.generation
        let delays = region == .similarRail ? Self.singleAssertDelays : Self.assertDelays
        for delay in delays {
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
