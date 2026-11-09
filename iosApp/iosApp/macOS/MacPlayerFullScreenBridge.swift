#if os(macOS)
import AppKit
import SwiftUI

/// Full screen for the player window. Reports whether the window is in full
/// screen (once it has finished entering, and as soon as it starts leaving),
/// and hides the window toolbar there while `hidesToolbar` is set.
///
/// In full screen AppKit moves the title bar and toolbar into a separate strip
/// across the top of the screen. SwiftUI's toolbar visibility modifiers don't
/// reach it from the pushed player, so this hides the window's `NSToolbar`
/// directly and puts it back whenever full screen ends or the player goes.
struct MacPlayerFullScreenBridge: NSViewRepresentable {
    let hidesToolbar: Bool
    let onFullScreenChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> BridgeView { BridgeView(onFullScreenChange: onFullScreenChange) }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.onFullScreenChange = onFullScreenChange
        nsView.hidesToolbar = hidesToolbar
    }

    static func dismantleNSView(_ nsView: BridgeView, coordinator: ()) {
        nsView.restoreToolbar()
    }

    final class BridgeView: NSView {
        var onFullScreenChange: @MainActor (Bool) -> Void
        var hidesToolbar = false {
            didSet { if oldValue != hidesToolbar { applyToolbarVisibility() } }
        }
        private var observers: [NSObjectProtocol] = []
        private var isFullScreen = false

        init(onFullScreenChange: @escaping @MainActor (Bool) -> Void) {
            self.onFullScreenChange = onFullScreenChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { restoreToolbar() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setFullScreen(true) }
                },
                center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setFullScreen(false) }
                },
            ]
            // After SwiftUI finishes the update that placed this view.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.setFullScreen(window.styleMask.contains(.fullScreen))
            }
        }

        /// Puts the toolbar back for the pages behind the player.
        func restoreToolbar() {
            if let toolbar = window?.toolbar, !toolbar.isVisible {
                toolbar.isVisible = true
            }
        }

        private func setFullScreen(_ fullScreen: Bool) {
            isFullScreen = fullScreen
            applyToolbarVisibility()
            onFullScreenChange(fullScreen)
        }

        private func applyToolbarVisibility() {
            guard let toolbar = window?.toolbar else { return }
            let visible = !(isFullScreen && hidesToolbar)
            if toolbar.isVisible != visible {
                toolbar.isVisible = visible
            }
        }
    }
}
#endif
