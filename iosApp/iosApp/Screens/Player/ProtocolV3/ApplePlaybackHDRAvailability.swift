import AVFoundation

/// Output-path HDR evidence used only for Protocol V3 capability reporting.
/// Aether owns display-criteria programming and media routing.
struct ApplePlaybackHDRAvailability: Equatable {
    let hdrPlaybackEligible: Bool
    let supportsHDR10: Bool
    let supportsHLG: Bool
    let supportsDolbyVision: Bool

    var supportsAnyHDRMode: Bool {
        supportsHDR10 || supportsHLG || supportsDolbyVision
    }

    static func probe() -> ApplePlaybackHDRAvailability {
        #if os(macOS)
        let eligible = AVPlayer.eligibleForHDRPlayback
        return ApplePlaybackHDRAvailability(
            hdrPlaybackEligible: eligible,
            supportsHDR10: eligible,
            supportsHLG: eligible,
            supportsDolbyVision: false
        )
        #else
        let modes = AVPlayer.availableHDRModes
        return ApplePlaybackHDRAvailability(
            hdrPlaybackEligible: AVPlayer.eligibleForHDRPlayback,
            supportsHDR10: modes.contains(.hdr10),
            supportsHLG: modes.contains(.hlg),
            supportsDolbyVision: modes.contains(.dolbyVision)
        )
        #endif
    }
}

/// Conservative device/output facts shared by diagnostics and download
/// capability reporting. This does not select or configure a playback route.
struct ApplePlaybackDisplayCapabilities: Equatable {
    let hdrPlaybackEligible: Bool
    let supportsDolbyVision: Bool
    let supportsHDR10: Bool
    let supportsHLG: Bool
    let supportsAtmos: Bool
    let maxResolution: ResolutionHint?
    let supportsTenBit: Bool

    enum ResolutionHint: String, Equatable {
        case sd
        case hd
        case fullHD
        case uhd4K
    }

    static func probe() -> ApplePlaybackDisplayCapabilities {
        let hdrAvailability = ApplePlaybackHDRAvailability.probe()
        var supportsAtmos = false
        #if !os(macOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        supportsAtmos = outputs.contains { $0.isSpatialAudioEnabled }
        #endif
        return ApplePlaybackDisplayCapabilities(
            hdrPlaybackEligible: hdrAvailability.hdrPlaybackEligible,
            supportsDolbyVision: hdrAvailability.supportsDolbyVision,
            supportsHDR10: hdrAvailability.supportsHDR10,
            supportsHLG: hdrAvailability.supportsHLG,
            supportsAtmos: supportsAtmos,
            maxResolution: nil,
            supportsTenBit: hdrAvailability.supportsAnyHDRMode
        )
    }
}
