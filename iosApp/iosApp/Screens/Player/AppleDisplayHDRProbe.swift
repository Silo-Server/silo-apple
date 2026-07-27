import AVFoundation
import Foundation

/// The active output's HDR state. Presentation only — an HDR source stays
/// playable when HDR is not being presented, because the client tone maps.
enum AppleDisplayHDRProbe {
    /// Whether HDR can be presented right now. Live — drops on display changes,
    /// Low Power Mode, and resource pressure. Drives presentation (EDR, tvOS
    /// display criteria) and Dolby Vision Profile 5, never playability.
    static var isEligible: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return AVPlayer.eligibleForHDRPlayback
        #endif
    }

    static var didChangeNotification: Notification.Name {
        AVPlayer.eligibleForHDRPlaybackDidChangeNotification
    }

    /// Per format: can this client be handed such a source and render it
    /// correctly? Not "is the display showing this format" — answering with
    /// that forces needless transcodes.
    static func capabilities() -> PlaybackV3HDRCapabilities {
        return PlaybackV3HDRCapabilities(
            hdr10: true,
            // No dynamic metadata, but the HDR10 base renders correctly.
            hdr10Plus: true,
            hlg: true,
            dolbyVisionProfiles: dolbyVisionProfiles
        )
    }

    /// 7 and 8 carry an HDR10/HLG base layer to fall back on, so they hold
    /// without HDR presentation; Profile 5 has none and renders as wrong colors.
    /// Listing 7 also tells the server this client resolves the enhancement
    /// layer itself.
    private static var dolbyVisionProfiles: [Int] {
        isEligible ? [5, 7, 8] : [7, 8]
    }
}
