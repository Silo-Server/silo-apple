#if os(tvOS) && DEBUG
import Foundation

/// Debug switches for the Apple TV client, set by launch arguments.
enum TVDebugSettings {
    /// Draws the d-pad focus-destination overlay (see `TVFocusDebugOverlay`)
    /// when launched with `-debugFocusTargets` (same convention as
    /// `-debugPlay`), so it also works on screens that precede sign-in.
    static let showFocusTargets = CommandLine.arguments.contains("-debugFocusTargets")
}
#endif
