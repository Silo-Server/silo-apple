#if os(macOS)
import AppKit

extension BandwidthProbeScheduler {
    /// Treats Silo as in the background while it is hidden or every window it
    /// could play in is minimized. Called once at launch; the scheduler lives
    /// as long as the app.
    func followMacVisibility() {
        for name in [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let app = NSApplication.shared
                    self?.setHidden(
                        app.isHidden || app.windows.filter(\.canBecomeMain).allSatisfy { $0.isMiniaturized || !$0.isVisible }
                    )
                }
            }
        }
    }
}
#endif
