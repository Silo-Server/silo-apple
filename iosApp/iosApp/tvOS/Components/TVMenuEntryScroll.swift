#if os(tvOS)
import SwiftUI

/// Reveal a page's entry controls before forwarding a top-menu focus request.
/// Keep the same scroll view and content state when the user reselects a page.
struct TVMenuEntryScroll: ViewModifier {
    let request: Int
    let onReady: (Int) -> Void

    @State private var position = ScrollPosition(edge: .top)
    @State private var lastRequest = 0
    @State private var pendingRequest: Int?
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
            .onChange(of: request, initial: true) { _, request in
                guard request > 0, request != lastRequest else { return }
                lastRequest = request
                pendingRequest = request
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
        guard let pending = pendingRequest else { return }
        // Wait for the layout that revealed the lazy entry row to commit.
        DispatchQueue.main.async {
            guard isAtTop, pendingRequest == pending else { return }
            pendingRequest = nil
            onReady(pending)
        }
    }
}
#endif
