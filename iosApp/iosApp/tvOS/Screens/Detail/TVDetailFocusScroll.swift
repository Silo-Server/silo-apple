#if os(tvOS)
import SwiftUI

extension View {
    /// Detail-page scroll choreography. Apply to the detail page's vertical
    /// ScrollView. Returning focus to the hero action row pins the hero to the
    /// top; focusing a poster rail (recommendations, the box set row) centers
    /// its section so the heading stays visible. Each request re-checks focus
    /// before it fires, so a stale request cannot pull the page back.
    ///
    /// The action row re-asserts its target to outlast native reveals deferred
    /// by repeated d-pad input. Poster rail entry uses one scroll request:
    /// repeating an animated centering request can interrupt the reveal
    /// already in flight and cause a visible hitch.
    func detailFocusScroll(
        proxy: ScrollViewProxy,
        actionRowFocused: Bool,
        heroId: String,
        focusedPosterRailId: String? = nil
    ) -> some View {
        modifier(
            DetailFocusScrollModifier(
                proxy: proxy,
                actionRowFocused: actionRowFocused,
                heroId: heroId,
                focusedPosterRailId: focusedPosterRailId
            )
        )
    }
}

private struct DetailFocusScrollModifier: ViewModifier {
    let proxy: ScrollViewProxy
    let actionRowFocused: Bool
    let heroId: String
    /// Scroll ID of the poster rail section holding focus, if any.
    let focusedPosterRailId: String?

    private enum Region: Equatable {
        case actionRow
        case posterRail(String)
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
    /// Poster rail entry must not restart its animation with delayed
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
            .onChange(of: focusedPosterRailId) { _, id in
                guard let id else { return }
                // Native reveal occasionally pins a poster rail against the
                // very top edge and loses its section heading. Centering the
                // complete section keeps the heading and focus lift visible.
                assertScroll(to: id, anchor: .center, while: .posterRail(id))
            }
    }

    private var currentRegion: Region? {
        if actionRowFocused { return .actionRow }
        return focusedPosterRailId.map(Region.posterRail)
    }

    /// Re-assert the scroll target across the delay window. Every assert
    /// re-checks that the triggering region still owns focus (and that no
    /// newer trigger superseded it) so a stale assert can never yank the page
    /// after the user moves on.
    private func assertScroll(to id: String, anchor: UnitPoint, while region: Region) {
        state.generation &+= 1
        let generation = state.generation
        let delays = region == .actionRow ? Self.assertDelays : Self.singleAssertDelays
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
