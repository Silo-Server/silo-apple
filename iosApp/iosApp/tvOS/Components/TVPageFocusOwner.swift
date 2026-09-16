#if os(tvOS)
import SwiftUI

/// Makes an inert placeholder — an empty state, or a loading state with
/// nothing to focus yet — the focus owner for its page.
///
/// tvOS has no pointer and no Tab key, so a page that renders no focusable
/// view leaves the focus engine with nothing focused. The remote stops
/// responding, and Menu/Back never reaches the shell's `onExitCommand`
/// either, because exit commands travel up the *focused* responder chain.
/// The app then reads as hard-frozen with force quit as the only way out.
/// Any placeholder that can be a whole page's content therefore has to hold
/// focus itself.
///
/// This is the native focus graph model from `docs/tvos-focus.md`: one real
/// focus target, seeded by the shell's content hand-down token, with Up handed
/// back to the top menu at the page boundary.
struct TVPageFocusOwner: ViewModifier {
    /// The shell's content focus hand-down token (`contentFocusRequest`).
    let focusRequest: Int
    /// True while the top menu owns focus. The placeholder must never pull
    /// focus out of the bar — a load finishing empty while the user is up in
    /// the menu is the common case.
    let isTopMenuFocused: Bool
    let accessibilityLabel: String
    /// Up at the page's top boundary returns focus to the top menu.
    let onMoveUp: (() -> Void)?

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            // The placeholder is not actionable, so the system focus effect
            // would only draw a halo around static text.
            .focusEffectDisabled()
            .accessibilityLabel(accessibilityLabel)
            .onMoveCommand { direction in
                guard direction == .up else { return }
                onMoveUp?()
            }
            // Runs on appear as well as on each new request, which is the
            // path that matters most: the usual way into this state is a load
            // finishing empty, which swaps the placeholder in without the
            // shell issuing a new hand-down.
            .task(id: focusRequest) {
                guard !isTopMenuFocused else { return }
                // Let the outgoing content's focus teardown commit first. A
                // claim made in the same transaction loses to the engine's own
                // repair from the resigning view.
                await Task.yield()
                guard !isTopMenuFocused else { return }
                isFocused = true
            }
    }
}

extension View {
    /// Make this placeholder its page's focus owner. See `TVPageFocusOwner`.
    func tvPageFocusOwner(
        focusRequest: Int,
        isTopMenuFocused: Bool,
        accessibilityLabel: String,
        onMoveUp: (() -> Void)?
    ) -> some View {
        modifier(
            TVPageFocusOwner(
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                accessibilityLabel: accessibilityLabel,
                onMoveUp: onMoveUp
            )
        )
    }
}
#endif
