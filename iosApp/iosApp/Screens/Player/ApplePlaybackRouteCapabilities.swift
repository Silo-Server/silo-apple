import Foundation

enum ApplePlaybackCapabilityState: String, Equatable {
    case repoVerified
    case validationRequired
    case planned
    case unsupported
    case unclaimed

    var shortLabel: String {
        switch self {
        case .repoVerified:
            return "Repo-verified"
        case .validationRequired:
            return "Validation required"
        case .planned:
            return "Planned"
        case .unsupported:
            return "Unsupported"
        case .unclaimed:
            return "Unclaimed"
        }
    }
}

struct ApplePlaybackCapabilityEntry: Equatable {
    let state: ApplePlaybackCapabilityState
    let note: String
}

struct ApplePlaybackPremiumClaimSet: Equatable {
    let localDeviceHDR: ApplePlaybackCapabilityEntry
    let tvOSDolbyVisionDisplay: ApplePlaybackCapabilityEntry
    let tvOSReceiverAtmos: ApplePlaybackCapabilityEntry

    var summary: String {
        Self.summarize([
            localDeviceHDR.state,
            tvOSDolbyVisionDisplay.state,
            tvOSReceiverAtmos.state
        ]).shortLabel
    }

    private static func summarize(_ states: [ApplePlaybackCapabilityState]) -> ApplePlaybackCapabilityState {
        if states.contains(.validationRequired) { return .validationRequired }
        if states.contains(.planned) { return .planned }
        if states.contains(.unsupported) { return .unsupported }
        if states.contains(.unclaimed) { return .unclaimed }
        return .repoVerified
    }
}

struct PlaybackRouteRequirements: Equatable {
    let needsSecondarySubtitles: Bool
    /// Split per claim so a route where the user disabled Dolby Vision can
    /// drop the DV clause from warnings without touching the Atmos one.
    let needsValidatedDolbyVisionClaim: Bool
    let needsValidatedAtmosClaim: Bool

    var needsValidatedPremiumClaims: Bool {
        needsValidatedDolbyVisionClaim || needsValidatedAtmosClaim
    }

    static let baseline = PlaybackRouteRequirements(
        needsSecondarySubtitles: false,
        needsValidatedDolbyVisionClaim: false,
        needsValidatedAtmosClaim: false
    )

    var summaryTokens: [String] {
        var tokens: [String] = []
        if needsSecondarySubtitles { tokens.append("secondary_subtitles") }
        if needsValidatedPremiumClaims { tokens.append("premium_claim_validation") }
        return tokens
    }
}

struct PlayerRouteStatusRow: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

struct ApplePlaybackRouteCapabilities: Equatable {
    let routeLabel: String
    let backendCapabilities: PlayerBackendCapabilities
    let primaryAudioSelection: ApplePlaybackCapabilityEntry
    let primarySubtitleSelection: ApplePlaybackCapabilityEntry
    let sidecarPrimarySubtitles: ApplePlaybackCapabilityEntry
    let secondarySubtitles: ApplePlaybackCapabilityEntry
    let chapters: ApplePlaybackCapabilityEntry
    let subtitleDelay: ApplePlaybackCapabilityEntry
    let subtitleStyling: ApplePlaybackCapabilityEntry
    let audioDelay: ApplePlaybackCapabilityEntry
    let bufferedAheadReporting: ApplePlaybackCapabilityEntry
    let pictureInPicture: ApplePlaybackCapabilityEntry
    let externalPlayback: ApplePlaybackCapabilityEntry
    let nowPlayingIntegration: ApplePlaybackCapabilityEntry
    let tvOSRemoteOwnership: ApplePlaybackCapabilityEntry
    let premiumClaims: ApplePlaybackPremiumClaimSet

    var subtitleContractSummary: String {
        let summary = summarize([
            primarySubtitleSelection.state,
            sidecarPrimarySubtitles.state,
            secondarySubtitles.state
        ]).shortLabel
        if secondarySubtitles.state == .repoVerified,
           secondarySubtitles.note.localizedCaseInsensitiveContains("sidecar") {
            return "\(summary), secondary sidecar-only"
        }
        return summary
    }

    func degradationNotes(for requirements: PlaybackRouteRequirements) -> [String] {
        var notes: [String] = []

        switch (requirements.needsValidatedDolbyVisionClaim, requirements.needsValidatedAtmosClaim) {
        case (true, true):
            notes.append(
                "Premium Dolby Vision and Atmos claims still require output-path validation on \(routeLabel)."
            )
        case (true, false):
            notes.append(
                "Premium Dolby Vision claims still require output-path validation on \(routeLabel)."
            )
        case (false, true):
            notes.append(
                "Premium Atmos claims still require output-path validation on \(routeLabel)."
            )
        case (false, false):
            break
        }

        if requirements.needsSecondarySubtitles && secondarySubtitles.note.localizedCaseInsensitiveContains("sidecar") {
            notes.append(secondarySubtitles.note)
        }

        return notes
    }

    private func summarize(_ states: [ApplePlaybackCapabilityState]) -> ApplePlaybackCapabilityState {
        if states.contains(.validationRequired) { return .validationRequired }
        if states.contains(.planned) { return .planned }
        if states.contains(.unsupported) { return .unsupported }
        if states.contains(.unclaimed) { return .unclaimed }
        return .repoVerified
    }
}

extension ApplePlaybackRouteCapabilities {
    static let avPlayerHLS = ApplePlaybackRouteCapabilities(
        routeLabel: "Native Player HLS",
        backendCapabilities: .avFoundation,
        primaryAudioSelection: .init(
            state: .repoVerified,
            note: "AVFoundation media selection owns primary audio on HLS."
        ),
        primarySubtitleSelection: .init(
            state: .repoVerified,
            note: "AVFoundation media selection plus sidecar registration owns primary subtitles on HLS."
        ),
        sidecarPrimarySubtitles: .init(
            state: .repoVerified,
            note: "Primary sidecar subtitles are registered on Native Player HLS."
        ),
        secondarySubtitles: .init(
            state: .repoVerified,
            note: "Secondary subtitles on Native Player routes are currently limited to sidecar tracks."
        ),
        chapters: .init(
            state: .repoVerified,
            note: "Bridge-supplied chapters are published into the shared Native Player UI."
        ),
        subtitleDelay: .init(
            state: .repoVerified,
            note: "Silo-rendered sidecar subtitles honor subtitle delay on Native Player HLS."
        ),
        subtitleStyling: .init(
            state: .repoVerified,
            note: "Silo-rendered sidecar subtitles honor shared subtitle styling on Native Player HLS."
        ),
        audioDelay: .init(
            state: .unsupported,
            note: "Audio delay is not implemented on Native Player routes."
        ),
        bufferedAheadReporting: .init(
            state: .repoVerified,
            note: "Native Player publishes buffered-ahead state from loaded time ranges."
        ),
        pictureInPicture: .init(
            state: .validationRequired,
            note: "PiP is enabled on iOS Native Player HLS; Silo-rendered subtitles do not appear in the PiP window."
        ),
        externalPlayback: .init(
            state: .validationRequired,
            note: "Asset-conditional. AirPlay video hands the receiver the stream URL and nothing else: server-hosted direct assets are either header-authenticated (401 on the receiver) or rewritten to the on-device source proxy at 127.0.0.1, so external playback stays off for them. Offline downloads are fetchable and keep it, pending receiver validation."
        ),
        nowPlayingIntegration: .init(
            state: .repoVerified,
            note: "Now Playing and remote-command handling are shared across Native Player routes."
        ),
        tvOSRemoteOwnership: .init(
            state: .repoVerified,
            note: "Silo keeps the custom tvOS shell even on Native Player routes."
        ),
        premiumClaims: .init(
            localDeviceHDR: .init(
                state: .validationRequired,
                note: "Local HDR claims need recorded validation for this route."
            ),
            tvOSDolbyVisionDisplay: .init(
                state: .validationRequired,
                note: "tvOS Dolby Vision output claims need validated device-chain evidence."
            ),
            tvOSReceiverAtmos: .init(
                state: .validationRequired,
                note: "tvOS receiver Atmos claims need validated AVR evidence."
            )
        )
    )

    static let avPlayerNativeDirect = ApplePlaybackRouteCapabilities(
        routeLabel: "Native Player Direct",
        backendCapabilities: .avFoundation,
        primaryAudioSelection: .init(
            state: .repoVerified,
            note: "AVFoundation media selection owns primary audio on native-direct assets."
        ),
        primarySubtitleSelection: .init(
            state: .repoVerified,
            note: "Native-direct subtitle selection is allowed only for assets that match the Native Player allowlist; ASS/SSA text tracks are Silo-rendered through the extractor."
        ),
        sidecarPrimarySubtitles: .init(
            state: .repoVerified,
            note: "Primary sidecar subtitles remain available on Native Player Direct assets."
        ),
        secondarySubtitles: .init(
            state: .repoVerified,
            note: "Secondary subtitles on Native Player routes are currently limited to sidecar tracks."
        ),
        chapters: .init(
            state: .repoVerified,
            note: "Bridge-supplied chapters remain available on Native Player Direct assets."
        ),
        subtitleDelay: .init(
            state: .repoVerified,
            note: "Silo-rendered extracted and sidecar subtitles honor subtitle delay on Native Player Direct assets."
        ),
        subtitleStyling: .init(
            state: .repoVerified,
            note: "Silo-rendered extracted and sidecar subtitles honor shared subtitle styling on Native Player Direct assets."
        ),
        audioDelay: .init(
            state: .unsupported,
            note: "Audio delay is not implemented on Native Player Direct assets."
        ),
        bufferedAheadReporting: .init(
            state: .repoVerified,
            note: "Native Player publishes buffered-ahead state for native-direct assets."
        ),
        pictureInPicture: .init(
            state: .validationRequired,
            note: "PiP is enabled on iOS Native Player Direct assets; Silo-rendered subtitles do not appear in the PiP window."
        ),
        externalPlayback: .init(
            state: .unsupported,
            note: "AirPlay video hands the receiver the stream URL, which it fetches without the route's Authorization header, so the server answers 401. External playback and the route picker stay off here."
        ),
        nowPlayingIntegration: .init(
            state: .repoVerified,
            note: "Now Playing and remote-command handling are shared across Native Player routes."
        ),
        tvOSRemoteOwnership: .init(
            state: .repoVerified,
            note: "Silo keeps the custom tvOS shell even on Native Player Direct assets."
        ),
        premiumClaims: .init(
            localDeviceHDR: .init(
                state: .validationRequired,
                note: "HDR claims on native-direct assets still need output-path validation."
            ),
            tvOSDolbyVisionDisplay: .init(
                state: .validationRequired,
                note: "Dolby Vision claims on native-direct assets need validated device-chain evidence."
            ),
            tvOSReceiverAtmos: .init(
                state: .validationRequired,
                note: "Receiver Atmos claims on native-direct assets need validated AVR evidence."
            )
        )
    )

    static let siloPlayerLoopback = ApplePlaybackRouteCapabilities(
        routeLabel: "Direct Stream",
        backendCapabilities: .avFoundation,
        primaryAudioSelection: .init(
            state: .repoVerified,
            note: "AVFoundation media selection owns primary audio on SiloPlayer output."
        ),
        primarySubtitleSelection: .init(
            state: .repoVerified,
            note: "Primary subtitles remain available through AVFoundation plus sidecar registration."
        ),
        sidecarPrimarySubtitles: .init(
            state: .repoVerified,
            note: "Primary sidecar subtitles remain available on SiloPlayer output."
        ),
        secondarySubtitles: .init(
            state: .repoVerified,
            note: "Secondary subtitles on Native Player routes are currently limited to sidecar tracks."
        ),
        chapters: .init(
            state: .repoVerified,
            note: "Bridge-supplied chapters remain available on SiloPlayer output."
        ),
        subtitleDelay: .init(
            state: .repoVerified,
            note: "Silo-rendered sidecar subtitles honor subtitle delay on SiloPlayer output."
        ),
        subtitleStyling: .init(
            state: .repoVerified,
            note: "Silo-rendered sidecar subtitles honor shared subtitle styling on SiloPlayer output."
        ),
        audioDelay: .init(
            state: .unsupported,
            note: "Audio delay is not implemented on Native Player routes."
        ),
        bufferedAheadReporting: .init(
            state: .repoVerified,
            note: "AVPlayer publishes playable buffered-ahead state on SiloPlayer output."
        ),
        pictureInPicture: .init(
            state: .validationRequired,
            note: "PiP is enabled on iOS SiloPlayer output; Silo-rendered subtitles do not appear in the PiP window."
        ),
        externalPlayback: .init(
            state: .repoVerified,
            note: "AirPlay from iPhone to Apple TV is hardware-validated for SiloPlayer loopback delivery."
        ),
        nowPlayingIntegration: .init(
            state: .repoVerified,
            note: "Now Playing and remote-command handling are shared across Native Player routes."
        ),
        tvOSRemoteOwnership: .init(
            state: .repoVerified,
            note: "Silo keeps the custom tvOS shell even on the local loopback route."
        ),
        premiumClaims: .init(
            localDeviceHDR: .init(
                state: .validationRequired,
                note: "Local HDR and Dolby playback claims remain validation-gated."
            ),
            tvOSDolbyVisionDisplay: .init(
                state: .validationRequired,
                note: "tvOS Dolby Vision claims remain narrow and validation-gated."
            ),
            tvOSReceiverAtmos: .init(
                state: .validationRequired,
                note: "Receiver Atmos claims remain validation-gated."
            )
        )
    )

    static let macAVFoundation = ApplePlaybackRouteCapabilities(
        routeLabel: "Native Player (macOS)",
        backendCapabilities: .macAVFoundation,
        primaryAudioSelection: .init(
            state: .repoVerified,
            note: "Native Player owns primary audio selection on macOS."
        ),
        primarySubtitleSelection: .init(
            state: .repoVerified,
            note: "Native Player owns primary subtitle selection for supported macOS assets."
        ),
        sidecarPrimarySubtitles: .init(
            state: .repoVerified,
            note: "macOS registers and renders sidecar subtitles through the shared Silo subtitle session."
        ),
        secondarySubtitles: .init(
            state: .repoVerified,
            note: "macOS secondary subtitles are supported for sidecar tracks through the shared subtitle session."
        ),
        chapters: .init(
            state: .repoVerified,
            note: "Native Player publishes chapter metadata through the shared macOS UI."
        ),
        subtitleDelay: .init(
            state: .repoVerified,
            note: "macOS sidecar subtitles honor shared subtitle delay through the Silo overlay."
        ),
        subtitleStyling: .init(
            state: .repoVerified,
            note: "macOS sidecar subtitles honor shared subtitle styling through the Silo overlay."
        ),
        audioDelay: .init(
            state: .unsupported,
            note: "Audio delay is not implemented on Native Player for macOS."
        ),
        bufferedAheadReporting: .init(
            state: .repoVerified,
            note: "Native Player publishes buffered-ahead state on macOS."
        ),
        pictureInPicture: .init(
            state: .unclaimed,
            note: "macOS PiP is out of scope for this plan."
        ),
        externalPlayback: .init(
            state: .unclaimed,
            note: "macOS external playback is out of scope for this plan."
        ),
        nowPlayingIntegration: .init(
            state: .repoVerified,
            note: "Now Playing remains wired through the shared controller."
        ),
        tvOSRemoteOwnership: .init(
            state: .unsupported,
            note: "tvOS-specific remote ownership does not apply on macOS."
        ),
        premiumClaims: .init(
            localDeviceHDR: .init(
                state: .validationRequired,
                note: "macOS premium claims need a separate spec and validation pass."
            ),
            tvOSDolbyVisionDisplay: .init(
                state: .unsupported,
                note: "tvOS Dolby Vision claims do not apply on macOS."
            ),
            tvOSReceiverAtmos: .init(
                state: .unsupported,
                note: "tvOS receiver Atmos claims do not apply on macOS."
            )
        )
    )
}
