#if os(tvOS)
import Foundation
import Observation

/// Device-local debug switches for the Apple TV client. Unlike
/// `AppNavPreferences` these are not profile-scoped: a debugging aid
/// applies to the device being debugged, not the signed-in user.
@Observable
final class TVDebugSettings {
    static let shared = TVDebugSettings()

    /// Whether the d-pad focus-destination overlay is drawn on screen
    /// (see `TVFocusDebugOverlay`).
    private(set) var showFocusTargets: Bool

    @ObservationIgnored private let defaults: SharedDefaults

    private static let showFocusTargetsKey = "skyline.debug.showFocusTargets"

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
        // Launch-arg override (same convention as -debugPlay) so the
        // overlay can be exercised on screens that precede sign-in.
        self.showFocusTargets = defaults.bool(forKey: Self.showFocusTargetsKey)
            || CommandLine.arguments.contains("-debugFocusTargets")
    }

    func setShowFocusTargets(_ value: Bool) {
        showFocusTargets = value
        defaults.set(value, forKey: Self.showFocusTargetsKey)
    }
}
#endif
