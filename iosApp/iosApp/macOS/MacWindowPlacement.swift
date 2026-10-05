#if os(macOS)
import AppKit
import SwiftUI

/// Reopens the main window on the display it was last used on.
///
/// The window's frame is remembered as it moves. At launch it goes back to
/// that frame if a connected display still covers it; if that display is
/// gone, the window opens at the same size on the primary display instead.
struct MacWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacementView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PlacementView: NSView {
        private static let frameKey = "mac.window.lastFrame"
        private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }

            // After SwiftUI has finished placing the new window, so this
            // placement is the one that sticks.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.restoreFrame(of: window)
                self.trackFrame(of: window)
            }
        }

        private func restoreFrame(of window: NSWindow) {
            guard let saved = UserDefaults.standard.string(forKey: Self.frameKey) else { return }
            let frame = NSRectFromString(saved)
            // A window the system reopened in full screen keeps that frame.
            guard frame.width > 0, frame.height > 0,
                  !window.styleMask.contains(.fullScreen) else { return }

            let centre = NSPoint(x: frame.midX, y: frame.midY)
            if NSScreen.screens.contains(where: { $0.frame.contains(centre) }) {
                window.setFrame(frame, display: true)
            } else if let primary = NSScreen.screens.first?.visibleFrame {
                let size = NSSize(
                    width: min(frame.width, primary.width),
                    height: min(frame.height, primary.height)
                )
                let origin = NSPoint(
                    x: primary.midX - size.width / 2,
                    y: primary.midY - size.height / 2
                )
                window.setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }

        private func trackFrame(of window: NSWindow) {
            let names: [Notification.Name] = [
                NSWindow.didMoveNotification,
                // Covers zoom, tiling and programmatic resizes, which do not
                // end a live resize and may not move the origin.
                NSWindow.didResizeNotification,
                NSWindow.didChangeScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    // A full-screen window's frame is the whole display; keep
                    // the windowed frame it will return to.
                    guard let window, !window.styleMask.contains(.fullScreen) else { return }
                    UserDefaults.standard.set(
                        NSStringFromRect(window.frame),
                        forKey: Self.frameKey
                    )
                }
            }
        }
    }
}
#endif
