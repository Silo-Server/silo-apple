import AVFoundation
import Foundation

/// One source of truth for the active output's HDR eligibility and its change
/// notification. `eligibleForHDRPlayback` only reports whether HDR can be
/// presented; it does not identify individual HDR formats. AVPlayer owns
/// format negotiation for an eligible output.
enum AppleDisplayHDRProbe {
    /// Whether HDR can be presented at all.
    ///
    /// A plain class property, safe to read from any thread, so
    /// `PlaybackSessionBridge` can consult it straight from its actor without
    /// caching. The simulator has no real display pipeline, so it never
    /// claims HDR.
    static var isEligible: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return AVPlayer.eligibleForHDRPlayback
        #endif
    }

    /// Fires when `isEligible` changes — display connect/disconnect, mode
    /// changes, and resource changes all surface here.
    static var didChangeNotification: Notification.Name {
        AVPlayer.eligibleForHDRPlaybackDidChangeNotification
    }

    /// The output claim sent in the V3 capability snapshot. Format-specific
    /// fields stay false because the system does not expose them here.
    static func capabilities() -> PlaybackV3HDRCapabilities {
        return PlaybackV3HDRCapabilities(
            hdrPlaybackEligible: isEligible,
            // `eligibleForHDRPlayback` has no per-format breakdown. Do not
            // infer HDR10, HLG, or Dolby Vision support from it; the AVPlayer
            // route tells the server to delegate that decision to AVFoundation.
            hdr10: false,
            hdr10Plus: false,
            hlg: false,
            dolbyVisionProfiles: []
        )
    }
}
