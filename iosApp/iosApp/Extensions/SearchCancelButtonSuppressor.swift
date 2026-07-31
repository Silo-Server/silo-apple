#if os(iOS)
import SwiftUI
import UIKit

/// Hides the search bar's Cancel button (an "✕" pill on iOS 26) so the search
/// field's own clear button stays the single way to empty the query and the
/// navigation bar's back button stays the single way to leave the screen.
///
/// SwiftUI exposes no modifier for this, so the representable walks the
/// responder chain to the hosting controller and turns the button off on the
/// `UISearchController` that `.searchable` installed. Pair it with
/// `.searchPresentationToolbarBehavior(.avoidHidingContent)`, which keeps the
/// back button on screen while the field is focused.
struct SearchCancelButtonSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = SuppressorView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class SuppressorView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // The search controller is attached during the same layout pass
            // that installs this view, so apply on the next runloop turn.
            DispatchQueue.main.async { [weak self] in
                self?.suppressCancelButton()
            }
        }

        private func suppressCancelButton() {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = (current as? UIViewController)?.navigationItem.searchController {
                    controller.automaticallyShowsCancelButton = false
                    controller.searchBar.setShowsCancelButton(false, animated: false)
                    return
                }
                responder = current.next
            }
        }
    }
}
#endif
