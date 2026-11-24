#if os(macOS)
import AppKit
import SwiftUI

/// The back gestures a menu item can't carry: ⌘← and the mouse's back
/// button, alongside Go > Back (⌘[). Only events for this view's window
/// count, so each window steps back through its own pages.
///
/// ⌘← stays with a text field that is editing (it moves to the start of the
/// line there) and with the player (previous chapter). The mouse's back
/// button closes the player like any other page.
struct MacBackNavigationMonitor: NSViewRepresentable {
    let isPlayerOnScreen: Bool
    let canGoBack: Bool
    let goBack: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isPlayerOnScreen = isPlayerOnScreen
        nsView.canGoBack = canGoBack
        nsView.goBack = goBack
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var isPlayerOnScreen = false
        var canGoBack = false
        var goBack: () -> Void = {}
        private var monitor: MacLocalEventMonitor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = MacLocalEventMonitor(matching: [.keyDown, .otherMouseUp]) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func stopMonitoring() {
            monitor?.stop()
            monitor = nil
        }

        /// True when the event went back a page and is used up.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, canGoBack else { return false }
            switch event.type {
            case .otherMouseUp:
                guard event.buttonNumber == MacBackGesture.mouseBackButton else { return false }
            case .keyDown:
                guard MacBackGesture.isCommandLeftArrow(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                ), !isPlayerOnScreen, !(window.firstResponder is NSText) else { return false }
            default:
                return false
            }
            goBack()
            return true
        }
    }
}

enum MacBackGesture {
    /// The "back" side button on a mouse that has one.
    static let mouseBackButton = 3
    static let leftArrowKeyCode: UInt16 = 123

    /// ⌘← with no other modifier. Arrow keys carry the function and numeric
    /// pad flags, which don't count.
    static func isCommandLeftArrow(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == leftArrowKeyCode
            && modifiers.intersection([.command, .control, .option, .shift]) == .command
    }
}
#endif
