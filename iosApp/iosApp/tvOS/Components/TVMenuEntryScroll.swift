/// Tracks a single entry request across delayed scroll and layout callbacks.
/// Returning to the menu cancels the request; only a new selection can rearm it.
struct TVMenuEntryFocusState {
    private var lastRequest = 0
    private(set) var pendingRequest: Int?

    mutating func receive(_ request: Int, menuOwnsFocus: Bool) -> Bool {
        guard request > 0, request != lastRequest else { return false }
        lastRequest = request
        pendingRequest = menuOwnsFocus ? nil : request
        return pendingRequest != nil
    }

    mutating func cancel() {
        pendingRequest = nil
    }

    mutating func consume(_ request: Int) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        return true
    }
}

#if os(tvOS)
import SwiftUI

/// Reveal a page's entry controls before forwarding a top-menu focus request.
/// Keep the same scroll view and content state when the user reselects a page.
struct TVMenuEntryScroll: ViewModifier {
    let request: Int
    let isTopMenuFocused: Bool
    let onReady: (Int) -> Void

    @State private var position = ScrollPosition(edge: .top)
    @State private var focusState = TVMenuEntryFocusState()
    @State private var isAtTop = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top <= 1
            } action: { _, atTop in
                isAtTop = atTop
                if atTop { forwardPendingRequest() }
            }
            .onChange(of: isTopMenuFocused) { _, menuOwnsFocus in
                if menuOwnsFocus { focusState.cancel() }
            }
            .onDisappear { focusState.cancel() }
            .onChange(of: request, initial: true) { _, request in
                guard focusState.receive(request, menuOwnsFocus: isTopMenuFocused) else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    position.scrollTo(edge: .top)
                }
                // Already at the top produces no geometry change.
                if isAtTop { forwardPendingRequest() }
            }
    }

    private func forwardPendingRequest() {
        guard let pending = focusState.pendingRequest else { return }
        // Wait for the layout that revealed the lazy entry row to commit.
        DispatchQueue.main.async {
            guard isAtTop, focusState.consume(pending) else { return }
            onReady(pending)
        }
    }
}
#endif
