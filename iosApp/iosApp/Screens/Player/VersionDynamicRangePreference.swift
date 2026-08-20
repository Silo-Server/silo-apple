import Foundation

/// The dynamic-range tiebreak for automatic version selection.
///
/// Version ranking is resolution-first (see `DetailVersionSelection.score` and
/// `PlaybackSessionBridge.selectVersion`); this adds a small bonus that only
/// separates versions of the *same* resolution — a Dolby Vision file is
/// preferred over a plain HDR10 file when the display can actually present DV
/// and the user has left Dolby Vision on. The bonus is deliberately smaller
/// than one resolution step and smaller than every quality-preference term, so
/// it can never pull a lower-resolution file over a higher one or override the
/// user's quality cap — it is a tiebreak, not a new axis.
enum VersionDynamicRangePreference {
    /// The device/settings inputs the tiebreak reads. `current` probes the live
    /// display capability and the persisted Dolby Vision setting.
    struct Context: Equatable {
        var supportsDolbyVision: Bool
        var supportsHDR: Bool
        var dolbyVisionEnabled: Bool

        static var current: Context {
            let hdr = ApplePlaybackHDRAvailability.probe()
            return Context(
                supportsDolbyVision: hdr.supportsDolbyVision,
                supportsHDR: hdr.supportsHDR10 || hdr.supportsHLG,
                dolbyVisionEnabled: PlayerSettings.shared.dolbyVisionEnabled
            )
        }
    }

    /// `4` when the version is Dolby Vision and the display+setting can present
    /// it, `2` for any HDR presentation the display supports (including a DV
    /// file's HDR10 base layer when DV itself is unusable), `0` for SDR. Both
    /// non-zero values are below the resolution step (10) and every quality
    /// term, so they only ever break a same-resolution tie.
    static func bonus(for version: FileVersion, context: Context) -> Int {
        let isDolbyVision = ApplePlaybackRoutePlanner.dolbyVisionProfile(for: version) != nil
        if isDolbyVision, context.supportsDolbyVision, context.dolbyVisionEnabled {
            return 4
        }
        if version.hdr == true, context.supportsHDR {
            return 2
        }
        return 0
    }
}
