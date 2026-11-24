#if os(macOS)
import AppKit

extension BandwidthProbeScheduler {
    /// Treats Silo as in the background while it is hidden or every window it
    /// could play in is minimized or closed. Called once at launch; the
    /// scheduler lives as long as the app.
    func followMacVisibility() {
        for name in [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeMainNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMacVisibility() }
            }
        }
        // A closing window is still visible as this posts: check once it's gone.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateMacVisibility() }
        }
    }

    private func updateMacVisibility() {
        let app = NSApplication.shared
        setHidden(
            app.isHidden || app.windows.filter(\.canBecomeMain).allSatisfy { $0.isMiniaturized || !$0.isVisible }
        )
    }
}
#endif
