#if os(tvOS)
import SwiftUI
import UIKit

/// Resolves the nearest scroll-view ancestor of a marker inside its content.
struct TVDetailScrollViewResolver: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfNeeded()
    }

    final class ResolverView: UIView {
        var onResolve: ((UIScrollView) -> Void)?
        private weak var resolvedScrollView: UIScrollView?
        private var resolutionScheduled = false

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolveIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfNeeded()
        }

        func resolveIfNeeded() {
            if let resolvedScrollView {
                onResolve?(resolvedScrollView)
                return
            }
            guard !resolutionScheduled else { return }
            resolutionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resolutionScheduled = false
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? UIScrollView {
                        self.resolvedScrollView = scrollView
                        self.onResolve?(scrollView)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

#endif
