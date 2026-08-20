import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The HDR modes tvOS/macOS reports for the current playback output path.
///
/// This is deliberately separate from codec decode support: AVPlayer's HDR
/// availability reflects the device plus the connected display/HDMI chain,
/// which is the evidence the protocol-v3 server uses when deciding whether a
/// Dolby Vision source can stay source-preserving.
struct ApplePlaybackHDRAvailability: Equatable {
    let hdrPlaybackEligible: Bool
    let supportsHDR10: Bool
    let supportsHLG: Bool
    let supportsDolbyVision: Bool

    var supportsAnyHDRMode: Bool {
        supportsHDR10 || supportsHLG || supportsDolbyVision
    }

    static func probe() -> ApplePlaybackHDRAvailability {
        #if targetEnvironment(simulator)
        return ApplePlaybackHDRAvailability(
            hdrPlaybackEligible: false,
            supportsHDR10: false,
            supportsHLG: false,
            supportsDolbyVision: false
        )
        #elseif os(macOS)
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

/// Snapshot of the device's playback output capabilities at plan time.
/// Plumbed into `ApplePlaybackPlannerInput` so the planner can stop
/// over-promising HDR / Dolby Vision purely from source metadata. Today
/// the planner consumes the snapshot for trace + degradation warnings;
/// future iterations can use it to actually gate route eligibility.
///
/// The probe is conservative: any field defaults to `false` / `nil` when
/// it cannot be determined. "Unknown" never reads as "supported".
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

    static let unknown = ApplePlaybackDisplayCapabilities(
        hdrPlaybackEligible: false,
        supportsDolbyVision: false,
        supportsHDR10: false,
        supportsHLG: false,
        supportsAtmos: false,
        maxResolution: nil,
        supportsTenBit: false
    )

    /// Best-effort capability snapshot from the host. AVAudioSession's
    /// current route gives us spatial-audio capability on iOS/tvOS;
    /// AVPlayer gives the HDR modes available through the current display
    /// chain. Where a value cannot be obtained, the field stays at its
    /// conservative default rather than being optimistically populated.
    static func probe() -> ApplePlaybackDisplayCapabilities {
        let hdrAvailability = ApplePlaybackHDRAvailability.probe()
        var supportsAtmos = false
        #if !os(macOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if #available(iOS 15.0, tvOS 15.0, *) {
            supportsAtmos = outputs.contains { $0.isSpatialAudioEnabled }
        }
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

struct ApplePlaybackPlannerInput {
    let session: PlaybackSessionResponse
    let selectedVersion: FileVersion
    let streamRequest: StreamRequest
    let routeRequirements: PlaybackRouteRequirements
    let selectedAudioTrackId: Int64?
    let pendingAudioFfIndex: Int?
    let preferredAudioTrackIndex: Int?
    let selectedPrimarySubtitleTrackId: Int64?
    let selectedSecondarySubtitleTrackId: Int64?
    let hlsRouteFeatureEnabled: Bool
    /// Stage 2 rollout gate: lifts the loopback startup-unreliable blockers
    /// and serves eligible sources through the VOD plan mode.
    let siloPlayerPrimaryEnabled: Bool
    /// Snapshot of the user's Dolby Vision settings, captured at plan time.
    let dolbyVisionPolicy: DolbyVisionPolicy.Snapshot
    /// Captured at plan-creation time so route choice and degradation
    /// warnings can reflect the actual output, not just source metadata.
    /// Defaults to `.unknown` (conservative no-knowledge state) so older
    /// callers continue to compile while the probe wires in.
    let displayCapabilities: ApplePlaybackDisplayCapabilities

    init(
        session: PlaybackSessionResponse,
        selectedVersion: FileVersion,
        streamRequest: StreamRequest,
        routeRequirements: PlaybackRouteRequirements,
        selectedAudioTrackId: Int64?,
        pendingAudioFfIndex: Int?,
        preferredAudioTrackIndex: Int?,
        selectedPrimarySubtitleTrackId: Int64?,
        selectedSecondarySubtitleTrackId: Int64?,
        hlsRouteFeatureEnabled: Bool,
        siloPlayerPrimaryEnabled: Bool = false,
        dolbyVisionPolicy: DolbyVisionPolicy.Snapshot,
        displayCapabilities: ApplePlaybackDisplayCapabilities = .unknown
    ) {
        self.session = session
        self.selectedVersion = selectedVersion
        self.streamRequest = streamRequest
        self.routeRequirements = routeRequirements
        self.selectedAudioTrackId = selectedAudioTrackId
        self.pendingAudioFfIndex = pendingAudioFfIndex
        self.preferredAudioTrackIndex = preferredAudioTrackIndex
        self.selectedPrimarySubtitleTrackId = selectedPrimarySubtitleTrackId
        self.selectedSecondarySubtitleTrackId = selectedSecondarySubtitleTrackId
        self.hlsRouteFeatureEnabled = hlsRouteFeatureEnabled
        self.siloPlayerPrimaryEnabled = siloPlayerPrimaryEnabled
        self.dolbyVisionPolicy = dolbyVisionPolicy
        self.displayCapabilities = displayCapabilities
    }
}

struct ApplePlaybackRoutePlanner {
    private static let nativeDirectContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let nativeDirectVideoCodecs: Set<String> = ["h264", "hevc"]
    private static let nativeDirectAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3"]
    private static let nativeDirectSubtitleCodecs: Set<String> = [
        "ass", "ssa", "mov_text", "tx3g", "wvtt", "webvtt"
    ]
    private static let siloSourceContainers: Set<String> = ["mkv", "matroska", "ts", "m2ts", "mts", "mpegts"]
    private static let siloVideoCodecs: Set<String> = ["h264", "hevc"]
    private static let siloTextSubtitleCodecs: Set<String> = [
        "ass", "ssa", "srt", "subrip", "webvtt", "mov_text", "tx3g"
    ]
    /// Canonical bitmap-subtitle codec identifiers (PGS/DVD/DVB/VobSub).
    /// Bitmap subs have no text representation, so they can't be AI-translated
    /// (`SubtitleTranslateMenu` reads this to offer "Transcribe" instead) and
    /// gate routing here. Exposed `static` so callers share one source of truth.
    static let siloBitmapSubtitleCodecs: Set<String> = [
        "pgs", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "vobsub"
    ]
    /// Bitmap codecs the SiloPlayer route renders client-side: the AVPlayer
    /// subtitle extractor decodes them into RGBA cue images for the overlay,
    /// so they no longer force the compatibility (burn-in transcode) route.
    /// DVB stays out — its broadcast region/CLUT model is unvalidated here.
    static let siloClientRenderedBitmapSubtitleCodecs: Set<String> = [
        "pgs", "hdmv_pgs_subtitle", "dvd_subtitle", "vobsub"
    ]

    func makeExecutionPlan(input: ApplePlaybackPlannerInput) -> PlaybackExecutionPlan {
        let session = input.session
        let selectedVersion = input.selectedVersion
        let delivery = PlaybackDeliveryStrategy(playMethod: session.playMethod)
        let sourceMetadata = Self.sourceMetadata(for: selectedVersion, session: session)
        let directDolbyVisionProfile = sourceMetadata.dolbyVisionProfile
        let directDvProfile8BaseLayer = Self.dvProfile8BaseLayer(for: selectedVersion, sourceMetadata: sourceMetadata)
        let directDolbyVisionResolution = directDolbyVisionProfile.map {
            DolbyVisionPolicy.resolution(forProfile: $0, snapshot: input.dolbyVisionPolicy)
        }
        var directLoopbackVideoMode: LoopbackSessionSpec.VideoMode? = switch directDolbyVisionProfile {
        case 5:
            .passthroughProfile5
        case 7:
            directDolbyVisionResolution == .dolbyVision
                ? .convertProfile7To81
                : .passthroughHEVC
        case 8:
            directDolbyVisionResolution == .dolbyVision
                ? .passthroughProfile8(directDvProfile8BaseLayer)
                : .passthroughHEVC
        default:
            nil
        }
        var directLoopbackSession: LoopbackSessionSpec? = nil

        let engine: PlaybackEngineKind
        let featureFlagEnabled: Bool
        let parityBlockers: [String]
        let routeCapabilities: ApplePlaybackRouteCapabilities
        let decisionTrace: [String]
        let degradationWarnings: [String]
        let reason: String

        switch delivery {
        case .direct:
            featureFlagEnabled = true
            let directAssessment = Self.assessNativeDirectRoute(
                selectedVersion: selectedVersion,
                session: session,
                requirements: input.routeRequirements
            )
            let siloAssessment = Self.assessSiloRoute(
                selectedVersion: selectedVersion,
                session: session,
                nativeAssessment: directAssessment,
                sourceMetadata: sourceMetadata,
                requirements: input.routeRequirements,
                selectedAudioTrackId: input.selectedAudioTrackId,
                pendingAudioFfIndex: input.pendingAudioFfIndex,
                preferredAudioTrackIndex: input.preferredAudioTrackIndex,
                selectedPrimarySubtitleTrackId: input.selectedPrimarySubtitleTrackId,
                selectedSecondarySubtitleTrackId: input.selectedSecondarySubtitleTrackId,
                siloPlayerPrimaryEnabled: input.siloPlayerPrimaryEnabled
            )
            if directLoopbackVideoMode == nil, let mode = siloAssessment.videoMode {
                directLoopbackVideoMode = mode
            }
            directLoopbackSession = directLoopbackVideoMode.flatMap { videoMode in
                Self.makeLoopbackSessionSpec(
                    for: selectedVersion,
                    selectedAudioTrackIndex: session.audioTrackIndex,
                    selectedAudioTrackId: input.selectedAudioTrackId,
                    pendingAudioFfIndex: input.pendingAudioFfIndex,
                    preferredAudioTrackIndex: input.preferredAudioTrackIndex,
                    streamRequest: input.streamRequest,
                    videoMode: videoMode,
                    videoRange: Self.videoRange(for: videoMode, source: selectedVersion),
                    sourceStartTimeSeconds: session.position,
                    servingMode: input.siloPlayerPrimaryEnabled ? .vodPlan : .event
                )
            }
            let requiresSoftwareH264 = Self.requiresSoftwareH264Decode(
                for: selectedVersion,
                fallbackCodec: session.playbackInfo?.videoCodec
            )
            if requiresSoftwareH264 {
                directLoopbackSession = nil
                engine = .playerCoreDirect
                parityBlockers = []
                routeCapabilities = .playerCoreDirect
                reason = "h264_high10_software_decode"
            } else if let directDolbyVisionProfile, let directDolbyVisionResolution,
               [5, 7, 8].contains(directDolbyVisionProfile), directLoopbackSession != nil {
                engine = .siloPlayerLoopback
                parityBlockers = []
                routeCapabilities = .siloPlayerLoopback
                reason = Self.dolbyVisionRouteToken(
                    profile: directDolbyVisionProfile,
                    resolution: directDolbyVisionResolution,
                    profile8BaseLayer: directDvProfile8BaseLayer,
                    vocabulary: .reason
                )
            } else if directAssessment.isEligible {
                engine = .avPlayerNativeDirect
                parityBlockers = []
                routeCapabilities = .avPlayerNativeDirect
                reason = "native_direct_asset"
            } else if siloAssessment.isEligible, directLoopbackSession != nil {
                engine = .siloPlayerLoopback
                parityBlockers = []
                routeCapabilities = .siloPlayerLoopback
                reason = siloAssessment.reason
            } else {
                #if os(macOS)
                engine = .playerCoreDirect
                parityBlockers = directAssessment.blockers + siloAssessment.blockers.map { "silo_\($0)" }
                routeCapabilities = .playerCoreDirect
                reason = "macos_direct_blocked"
                #else
                engine = .playerCoreDirect
                var blockers = directAssessment.blockers + siloAssessment.blockers.map { "silo_\($0)" }
                if (directDolbyVisionProfile == 5
                    || directDolbyVisionProfile == 7
                    || directDolbyVisionProfile == 8
                    || siloAssessment.isEligible),
                   directLoopbackSession == nil {
                    blockers.append("silo_loopback_session_unresolved")
                }
                parityBlockers = blockers
                routeCapabilities = .playerCoreDirect
                reason = directAssessment.blockers.isEmpty
                    ? "direct_play_uses_coremedia"
                    : "native_direct_blocked"
                #endif
            }
            var trace = input.routeRequirements.summaryTokens
            if let directDolbyVisionProfile {
                trace.append("dolby_vision_profile_\(directDolbyVisionProfile)")
            }
            if let directDolbyVisionProfile, let directDolbyVisionResolution,
               [5, 7, 8].contains(directDolbyVisionProfile) {
                trace.append(Self.dolbyVisionRouteToken(
                    profile: directDolbyVisionProfile,
                    resolution: directDolbyVisionResolution,
                    profile8BaseLayer: directDvProfile8BaseLayer,
                    vocabulary: .trace
                ))
            } else if siloAssessment.isEligible, engine == .siloPlayerLoopback {
                trace.append("\(siloAssessment.reason)_selected")
            }
            let fallbackOrderToken: String = switch engine {
            case .avPlayerNativeDirect:
                "fallback_order_native_silo_compatibility"
            case .siloPlayerLoopback:
                "fallback_order_silo_compatibility"
            case .playerCoreDirect:
                "fallback_order_compatibility_only"
            case .avPlayerHLS:
                "fallback_order_hls_controlled_retry"
            }
            decisionTrace = trace + directAssessment.trace + siloAssessment.trace + [fallbackOrderToken]
            degradationWarnings = routeCapabilities.degradationNotes(for: input.routeRequirements)
                + siloAssessment.degradations
        case .remux, .transcode:
            let flagOn = input.hlsRouteFeatureEnabled
            featureFlagEnabled = flagOn
            parityBlockers = flagOn ? [] : ["feature_flag_off"]
            engine = flagOn ? .avPlayerHLS : .playerCoreDirect
            routeCapabilities = flagOn ? .avPlayerHLS : .playerCoreDirect
            decisionTrace = input.routeRequirements.summaryTokens + [
                "delivery_\(delivery.name)",
                flagOn ? "avplayer_hls_enabled" : "avplayer_hls_disabled",
                flagOn ? "fallback_order_hls_controlled_retry" : "fallback_order_compatibility_only"
            ]
            degradationWarnings = routeCapabilities.degradationNotes(for: input.routeRequirements)
            reason = flagOn ? "apple_hls_route_enabled" : "parity_gate_blocked"
        }

        let startMode: PlaybackStartMode
        switch session.playMethod.lowercased() {
        case "remux":
            startMode = .startOfManifest
        default:
            startMode = .absolutePosition(session.position)
        }

        let capabilityBlockers = routeCapabilities.blockingReasons(for: input.routeRequirements)
        let allBlockers = parityBlockers + capabilityBlockers

        return PlaybackExecutionPlan(
            delivery: delivery,
            engine: engine,
            startMode: startMode,
            streamRequest: input.streamRequest,
            loopbackSession: engine == .siloPlayerLoopback ? directLoopbackSession : nil,
            capabilities: routeCapabilities.backendCapabilities,
            routeCapabilities: routeCapabilities,
            requirements: input.routeRequirements,
            featureFlagEnabled: featureFlagEnabled,
            parityBlockers: allBlockers,
            decisionTrace: decisionTrace + allBlockers.map { "blocker_\($0)" },
            degradationWarnings: degradationWarnings,
            reason: reason,
            playbackSessionId: session.sessionId,
            sourceMetadata: sourceMetadata,
            normalizationSummary: Self.normalizationSummary(
                engine: engine,
                delivery: delivery,
                loopbackSession: directLoopbackSession,
                sourceMetadata: sourceMetadata
            )
        )
    }

    static func makeRouteRequirements(
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        dolbyVisionPolicy: DolbyVisionPolicy.Snapshot
    ) -> PlaybackRouteRequirements {
        let hasPrimaryAudioSelection = !(selectedVersion.audioTracks ?? []).isEmpty
        let hasEmbeddedSubtitles = (selectedVersion.subtitleTracks ?? []).contains { !($0.external ?? false) }
        let hasSidecarSubtitles = !(session.subtitleUrls ?? []).isEmpty
        let hasChapters = !Self.chapterInfoList(from: selectedVersion).isEmpty
        // The source's DV claim only needs output-path validation when the
        // resolved route still presents Dolby Vision — a "Dolby Vision off"
        // fallback plays plain HDR10 and must not surface DV-claim warnings.
        let claimsDolbyVision = Self.versionHasDolbyVision(selectedVersion)
            && DolbyVisionPolicy.claimsDolbyVisionOutput(
                DolbyVisionPolicy.resolution(
                    forProfile: Self.dolbyVisionProfile(for: selectedVersion) ?? 0,
                    snapshot: dolbyVisionPolicy
                )
            )

        return PlaybackRouteRequirements(
            needsPrimaryAudioSelection: hasPrimaryAudioSelection,
            needsPrimarySubtitleSelection: hasEmbeddedSubtitles || hasSidecarSubtitles,
            needsSidecarPrimarySubtitles: hasSidecarSubtitles,
            needsSecondarySubtitles: hasSidecarSubtitles,
            needsChapters: hasChapters,
            needsNowPlayingIntegration: true,
            keepsPictureInPictureDisabledUntilValidated: false,
            keepsExternalPlaybackDisabledUntilValidated: false,
            needsValidatedDolbyVisionClaim: claimsDolbyVision,
            needsValidatedAtmosClaim: Self.versionHasPotentialAtmos(selectedVersion)
        )
    }

    static func makeLoopbackSessionSpec(
        for version: FileVersion,
        selectedAudioTrackIndex: Int?,
        selectedAudioTrackId: Int64?,
        pendingAudioFfIndex: Int?,
        preferredAudioTrackIndex: Int?,
        streamRequest: StreamRequest,
        videoMode: LoopbackSessionSpec.VideoMode,
        videoRange: String = "PQ",
        sourceStartTimeSeconds: Double = 0,
        servingMode: LoopbackServingMode = .event
    ) -> LoopbackSessionSpec? {
        let tracks = normalizedLoopbackAudioTracks(
            for: version,
            selectedAudioTrackId: selectedAudioTrackId,
            pendingAudioFfIndex: pendingAudioFfIndex,
            preferredAudioTrackIndex: preferredAudioTrackIndex
        )
        let selectedTrack = tracks.first(where: { $0.srcId == selectedAudioTrackIndex })
            ?? resolveLoopbackSelectedAudioTrack(
                from: tracks,
                selectedAudioTrackId: selectedAudioTrackId,
                pendingAudioFfIndex: pendingAudioFfIndex,
                preferredAudioTrackIndex: preferredAudioTrackIndex
            )
        let selectedAudio: LoopbackSessionSpec.SelectedAudio
        if tracks.isEmpty {
            selectedAudio = .absent
        } else {
            guard let selectedTrack,
                  let selectedTrackIndex = selectedTrack.srcId ?? selectedAudioTrackIndex else {
                return nil
            }
            let outputMode = loopbackAudioOutputMode(for: selectedTrack)
            let preservesAtmos = outputMode == .copy && loopbackAudioPreservesAtmos(for: selectedTrack)
            selectedAudio = LoopbackSessionSpec.SelectedAudio(
                trackIndex: selectedTrackIndex,
                ffIndex: selectedTrack.ffIndex,
                sourceCodec: selectedTrack.codec,
                sourceChannelCount: selectedTrack.audioChannelCount,
                sourceChannelLayout: selectedTrack.audioChannelsLayout,
                outputMode: outputMode,
                preservesAtmos: preservesAtmos
            )
        }
        let advertisedProfile: Int? = switch videoMode {
        case .passthroughProfile5:
            5
        case .convertProfile7To81:
            8
        case .passthroughProfile8:
            8
        case .passthroughHEVC, .passthroughH264:
            nil
        }
        let compatibilityBrand: String? = switch videoMode {
        case .passthroughProfile5:
            nil
        case .convertProfile7To81:
            "db1p"
        case .passthroughProfile8(.hdr10):
            "db1p"
        case .passthroughProfile8(.sdr):
            "db2g"
        case .passthroughProfile8(.hlg):
            "db4h"
        case .passthroughHEVC, .passthroughH264:
            nil
        }

        return LoopbackSessionSpec(
            sourceURL: streamRequest.url,
            headers: streamRequest.headers,
            sourceStartTimeSeconds: sourceStartTimeSeconds.isFinite
                ? max(0, sourceStartTimeSeconds)
                : 0,
            sourceBitrateBps: version.bitrate.map { Double($0) * 1_000 },
            videoMode: videoMode,
            sourceVideoFrameRate: loopbackSourceFrameRate(for: version),
            selectedAudio: selectedAudio,
            availableAudioTracks: tracks,
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: advertisedProfile,
                compatibilityBrand: compatibilityBrand,
                videoRange: videoRange,
                mayClaimAtmos: selectedAudio.preservesAtmos
            ),
            servingMode: servingMode
        )
    }
}

private struct NativeDirectAssessment {
    let isEligible: Bool
    let blockers: [String]
    let trace: [String]
}

private struct SiloRouteAssessment {
    let isEligible: Bool
    let videoMode: LoopbackSessionSpec.VideoMode?
    let blockers: [String]
    let trace: [String]
    let degradations: [String]
    let reason: String
}

extension ApplePlaybackRoutePlanner {
    static func requiresSoftwareH264Decode(
        for version: FileVersion,
        fallbackCodec: String? = nil
    ) -> Bool {
        let sourceCodec = version.videoTracks?.first?.codec ?? version.codecVideo ?? fallbackCodec
        let codec = sourceCodec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard codec == "h264" || codec == "avc" || codec == "avc1" else { return false }
        guard let track = version.videoTracks?.first else { return false }
        if let bitDepth = track.bitDepth, bitDepth > 8 { return true }
        let profile = track.profile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return profile == "high 10" || profile == "high10" || profile == "high 10 intra"
    }

    static func hevcLoopbackVideoRange(for version: FileVersion) -> String {
        videoRange(for: .passthroughHEVC, source: version)
    }

    static func unambiguousColorRange(for version: FileVersion) -> String? {
        guard let tracks = version.videoTracks, tracks.count == 1 else { return nil }
        return tracks[0].colorRange
    }

    /// Decide which base layer a Dolby Vision Profile 8 source carries:
    /// HDR10 (8.1, brand `db1p`), SDR (8.2, brand `db2g`), or HLG (8.4,
    /// brand `db4h`). Defaults to HDR10 — by far the more common variant —
    /// when signaling is missing or ambiguous. The decode-side counterpart is
    /// `DVProfile8BaseLayer.init(dolbyVisionCompatibilityID:)`, which reads
    /// the same distinction out of the parsed configuration record; the two
    /// have to agree, so both are pinned together in
    /// `HDRDisplayCriteriaPolicyTests`.
    static func dvProfile8BaseLayer(
        for version: FileVersion,
        sourceMetadata: PlaybackSourceMetadata
    ) -> LoopbackSessionSpec.DVProfile8BaseLayer {
        switch transferKind(for: version) {
        case "HLG": return .hlg
        case "SDR": return .sdr
        default: return .hdr10
        }
    }
}

private extension ApplePlaybackRoutePlanner {
    static func assessNativeDirectRoute(
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        requirements: PlaybackRouteRequirements
    ) -> NativeDirectAssessment {
        var blockers: [String] = []
        var trace: [String] = ["delivery_direct"]

        let container = normalizedContainer(for: selectedVersion)
        trace.append("container_\(container ?? "unknown")")
        if let container {
            if !nativeDirectContainers.contains(container) {
                blockers.append("container_not_allowlisted")
            }
        } else {
            blockers.append("container_unknown")
        }

        let videoCodec = normalizedVideoCodec(selectedVersion.codecVideo ?? session.playbackInfo?.videoCodec)
        trace.append("video_\(videoCodec ?? "unknown")")
        if let videoCodec {
            if !nativeDirectVideoCodecs.contains(videoCodec) {
                blockers.append("video_codec_not_allowlisted")
            }
            if requiresSoftwareH264Decode(
                for: selectedVersion,
                fallbackCodec: session.playbackInfo?.videoCodec
            ) {
                blockers.append("video_profile_requires_software_decode")
                trace.append("video_h264_high10_software")
            }
        } else {
            blockers.append("video_codec_unknown")
        }

        let audioCodec = normalizedAudioCodec(selectedVersion.codecAudio ?? session.playbackInfo?.audioCodec)
        trace.append("audio_\(audioCodec ?? "unknown")")
        if let audioCodec {
            if !nativeDirectAudioCodecs.contains(audioCodec) {
                blockers.append("audio_codec_not_allowlisted")
            }
        } else {
            blockers.append("audio_codec_unknown")
        }

        let unsupportedSubtitleCodecs = unsupportedEmbeddedSubtitleCodecs(for: selectedVersion)
        if !unsupportedSubtitleCodecs.isEmpty {
            blockers.append("embedded_subtitles_require_compatibility")
            trace.append("embedded_subtitles_\(unsupportedSubtitleCodecs.joined(separator: "_"))")
        }

        let capabilityBlockers = PlaybackEngineKind.avPlayerNativeDirect.routeCapabilities
            .blockingReasons(for: requirements)
        blockers.append(contentsOf: capabilityBlockers)

        return NativeDirectAssessment(
            isEligible: blockers.isEmpty,
            blockers: blockers,
            trace: trace
        )
    }

    static func assessSiloRoute(
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        nativeAssessment: NativeDirectAssessment,
        sourceMetadata: PlaybackSourceMetadata,
        requirements: PlaybackRouteRequirements,
        selectedAudioTrackId: Int64?,
        pendingAudioFfIndex: Int?,
        preferredAudioTrackIndex: Int?,
        selectedPrimarySubtitleTrackId: Int64?,
        selectedSecondarySubtitleTrackId: Int64?,
        siloPlayerPrimaryEnabled: Bool = false
    ) -> SiloRouteAssessment {
        var blockers: [String] = []
        var trace: [String] = ["silo_assessment"]
        var degradations: [String] = []

        guard sourceMetadata.dolbyVisionProfile == nil else {
            return SiloRouteAssessment(
                isEligible: true,
                videoMode: nil,
                blockers: [],
                trace: trace + ["silo_dv_profile_owned_by_dv_policy"],
                degradations: [],
                reason: "dolby_vision_loopback"
            )
        }

        guard nativeAssessment.blockers.contains("container_not_allowlisted")
                || nativeAssessment.blockers.contains("audio_codec_not_allowlisted")
                || nativeAssessment.blockers.contains("embedded_subtitles_require_compatibility") else {
            return SiloRouteAssessment(
                isEligible: false,
                videoMode: nil,
                blockers: ["no_normalization_needed"],
                trace: trace + ["silo_not_needed"],
                degradations: [],
                reason: "silo_not_needed"
            )
        }

        guard let container = sourceMetadata.container else {
            blockers.append("container_unknown")
            return blockedSilo(blockers: blockers, trace: trace, degradations: degradations)
        }
        trace.append("silo_container_\(container)")
        if !siloSourceContainers.contains(container), !nativeDirectContainers.contains(container) {
            blockers.append("container_not_normalizable")
        }

        guard let videoCodec = sourceMetadata.videoCodec else {
            blockers.append("video_codec_unknown")
            return blockedSilo(blockers: blockers, trace: trace, degradations: degradations)
        }
        trace.append("silo_video_\(videoCodec)")
        guard siloVideoCodecs.contains(videoCodec) else {
            blockers.append("video_not_copyable")
            return blockedSilo(blockers: blockers, trace: trace, degradations: degradations)
        }

        let mandatoryEmbeddedSubtitleCodecs = selectedOrMandatoryEmbeddedSubtitleCodecs(
            for: selectedVersion,
            selectedPrimarySubtitleTrackId: selectedPrimarySubtitleTrackId,
            selectedSecondarySubtitleTrackId: selectedSecondarySubtitleTrackId
        )
        let bitmapSubtitleCodecs = mandatoryEmbeddedSubtitleCodecs.filter { siloBitmapSubtitleCodecs.contains($0) }
        let blockedBitmapSubtitleCodecs = bitmapSubtitleCodecs.filter {
            !siloClientRenderedBitmapSubtitleCodecs.contains($0)
        }
        if !blockedBitmapSubtitleCodecs.isEmpty {
            blockers.append("bitmap_subtitles_require_compatibility")
            trace.append("silo_bitmap_subtitles_\(blockedBitmapSubtitleCodecs.joined(separator: "_"))")
        }
        let clientRenderedBitmapSubtitleCodecs = bitmapSubtitleCodecs.filter {
            siloClientRenderedBitmapSubtitleCodecs.contains($0)
        }
        if !clientRenderedBitmapSubtitleCodecs.isEmpty {
            trace.append(
                "silo_bitmap_subtitles_client_rendered_\(clientRenderedBitmapSubtitleCodecs.joined(separator: "_"))"
            )
        }
        let nonTextSubtitleCodecs = mandatoryEmbeddedSubtitleCodecs.filter {
            !siloTextSubtitleCodecs.contains($0) && !siloBitmapSubtitleCodecs.contains($0)
        }
        if !nonTextSubtitleCodecs.isEmpty {
            blockers.append("embedded_subtitle_codec_unknown")
            trace.append("silo_unknown_subtitles_\(nonTextSubtitleCodecs.joined(separator: "_"))")
        }
        if !mandatoryEmbeddedSubtitleCodecs.isEmpty, blockers.isEmpty {
            trace.append("silo_subtitles_extract_or_register")
        }

        let audioMode = normalizedLoopbackAudioTracks(
            for: selectedVersion,
            selectedAudioTrackId: selectedAudioTrackId,
            pendingAudioFfIndex: pendingAudioFfIndex,
            preferredAudioTrackIndex: preferredAudioTrackIndex
        ).first(where: { $0.isSelected }).map(loopbackAudioOutputMode)
        if audioMode == .transcodeAAC || audioMode == .transcodeAC3 || audioMode == .transcodeEC3 {
            degradations.append("Loopback audio may use an explicit lossy fallback.")
        }

        if !PlaybackEngineKind.siloPlayerLoopback.routeCapabilities
            .blockingReasons(for: requirements).isEmpty {
            blockers.append(contentsOf: PlaybackEngineKind.siloPlayerLoopback.routeCapabilities
                .blockingReasons(for: requirements))
        }

        guard blockers.isEmpty else {
            return blockedSilo(blockers: blockers, trace: trace, degradations: degradations)
        }

        let mode: LoopbackSessionSpec.VideoMode = videoCodec == "hevc"
            ? .passthroughHEVC
            : .passthroughH264
        let reason: String
        if nativeAssessment.blockers.contains("audio_codec_not_allowlisted") {
            reason = "\(videoCodec)_audio_normalization_loopback"
        } else if nativeAssessment.blockers.contains("embedded_subtitles_require_compatibility") {
            reason = "\(videoCodec)_subtitle_normalization_loopback"
        } else {
            reason = "\(videoCodec)_container_loopback"
        }
        if mode == .passthroughH264, !siloPlayerPrimaryEnabled {
            // The EVENT loopback writer fragments H.264 at source keyframes.
            // Long-GOP MKVs can show one frame, then stall while AVPlayer waits
            // on sparse fMP4/HLS fragments. The VOD serving mode (Stage 2 gate)
            // removes the growing-playlist startup dependency — the full title
            // is advertised at load and AVPlayer buffers against it.
            return blockedSilo(
                blockers: ["h264_loopback_startup_unreliable"],
                trace: trace + ["silo_reason_\(reason)", "silo_h264_loopback_disabled"],
                degradations: degradations
            )
        }
        if mode == .passthroughHEVC,
           (Self.transferKind(for: selectedVersion) ?? "SDR") == "SDR",
           !siloPlayerPrimaryEnabled {
            // Plain SDR HEVC has the same long-fragment startup risk without a
            // Dolby Vision/HDR video presentation claim that requires AVPlayer
            // ownership; lifted by the same VOD gate as H.264 above.
            return blockedSilo(
                blockers: ["hevc_sdr_loopback_startup_unreliable"],
                trace: trace + ["silo_reason_\(reason)", "silo_hevc_sdr_loopback_disabled"],
                degradations: degradations
            )
        }
        if siloPlayerPrimaryEnabled {
            trace.append("silo_vod_gate_open")
        }
        return SiloRouteAssessment(
            isEligible: true,
            videoMode: mode,
            blockers: [],
            trace: trace + ["silo_eligible", "silo_reason_\(reason)"],
            degradations: degradations,
            reason: reason
        )
    }

    static func blockedSilo(
        blockers: [String],
        trace: [String],
        degradations: [String]
    ) -> SiloRouteAssessment {
        SiloRouteAssessment(
            isEligible: false,
            videoMode: nil,
            blockers: blockers,
            trace: trace + blockers.map { "silo_blocker_\($0)" },
            degradations: degradations,
            reason: "silo_blocked"
        )
    }

    static func sourceMetadata(
        for version: FileVersion,
        session: PlaybackSessionResponse
    ) -> PlaybackSourceMetadata {
        let videoTrack = version.videoTracks?.first
        return PlaybackSourceMetadata(
            container: normalizedContainer(for: version),
            videoCodec: normalizedVideoCodec(version.codecVideo ?? session.playbackInfo?.videoCodec),
            audioCodec: normalizedAudioCodec(version.codecAudio ?? session.playbackInfo?.audioCodec),
            subtitleCodecs: embeddedSubtitleCodecs(for: version),
            dolbyVisionProfile: dolbyVisionProfile(for: version),
            colorRange: unambiguousColorRange(for: version),
            frameRate: parseLoopbackFrameRate(videoTrack?.frameRate).map(Double.init),
            bitrateKbps: videoTrack?.bitrate ?? version.bitrate
        )
    }

    static func normalizationSummary(
        engine: PlaybackEngineKind,
        delivery: PlaybackDeliveryStrategy,
        loopbackSession: LoopbackSessionSpec?,
        sourceMetadata: PlaybackSourceMetadata
    ) -> PlaybackNormalizationSummary {
        switch engine {
        case .avPlayerHLS:
            return PlaybackNormalizationSummary(
                containerMode: delivery.name,
                videoMode: "server_output",
                audioMode: "server_output",
                subtitleMode: "server_or_sidecar"
            )
        case .siloPlayerLoopback:
            return PlaybackNormalizationSummary(
                containerMode: "local_fmp4_hls",
                videoMode: loopbackSession?.videoMode.logToken ?? "loopback_unresolved",
                audioMode: loopbackSession.map {
                    $0.selectedAudio.isPresent
                        ? $0.selectedAudio.outputMode.logToken
                        : "none"
                } ?? "loopback_unresolved",
                subtitleMode: sourceMetadata.subtitleCodecs.isEmpty ? "none" : "extract_or_sidecar"
            )
        case .avPlayerNativeDirect:
            return .none
        case .playerCoreDirect:
            return PlaybackNormalizationSummary(
                containerMode: "none",
                videoMode: "compatibility_decode",
                audioMode: "compatibility_decode",
                subtitleMode: "compatibility_render"
            )
        }
    }

    static func videoRange(
        for videoMode: LoopbackSessionSpec.VideoMode,
        source: FileVersion? = nil
    ) -> String {
        switch videoMode {
        case .passthroughProfile5, .convertProfile7To81:
            return "PQ"
        case .passthroughProfile8(.hdr10):
            return "PQ"
        case .passthroughProfile8(.sdr):
            return "SDR"
        case .passthroughProfile8(.hlg):
            return "HLG"
        case .passthroughHEVC:
            // Unknown transfer resolves to SDR, not PQ: the master playlist
            // carrying this token is never served to AVPlayer (playback
            // starts from the media playlist), so its only behavioral
            // consumer is the HDR display-criteria policy — and forcing an
            // HDR10 HDMI mode switch for content we can't verify as HDR is
            // strictly worse than skipping the criteria write.
            return source.flatMap(transferKind(for:)) ?? "SDR"
        case .passthroughH264:
            return "SDR"
        }
    }

    /// Map a video track's `color_transfer` (FFmpeg AVCOL_TRC name) to the
    /// HLS `VIDEO-RANGE` token. Prefers `color_transfer` over the higher-level
    /// `video_range` because the latter says "DolbyVision" for both PQ-base
    /// (8.1) and HLG-base (8.4) sources, which would conflate them.
    static func transferKind(for version: FileVersion) -> String? {
        guard let track = (version.videoTracks ?? []).first else { return nil }
        switch normalizedToken(track.colorTransfer) {
        case "smpte2084", "pq", "smpte-st-2084", "smptest2084":
            return "PQ"
        case "arib-std-b67", "hlg":
            return "HLG"
        case "bt709", "bt-709", "bt470bg", "smpte170m", "smpte240m":
            return "SDR"
        default:
            break
        }
        switch normalizedToken(track.videoRange) {
        case "hdr10", "hdr10plus", "hdr10+", "hdr": return "PQ"
        case "hlg": return "HLG"
        case "sdr": return "SDR"
        // "dolbyvision" is intentionally not handled here — without
        // color_transfer we can't tell PQ-base (8.1) from HLG-base (8.4).
        default: return nil
        }
    }

    static func normalizedContainer(for version: FileVersion) -> String? {
        if let raw = normalizedToken(version.container) {
            if raw == "quicktime" { return "mov" }
            return raw
        }

        guard let fileName = version.fileName else { return nil }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    static func normalizedVideoCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "h264", "h.264", "avc", "avc1":
            return "h264"
        case "hevc", "h265", "h.265", "hvc1", "hev1":
            return "hevc"
        default:
            return normalizedToken(raw)
        }
    }

    static func normalizedAudioCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "aac", "mp4a":
            return "aac"
        case "ac3":
            return "ac3"
        case "eac3", "ec3", "ec-3", "e-ac-3":
            return "eac3"
        case "truehd", "true-hd", "dolbytruehd", "mlp", "mlpa":
            return "truehd"
        case "alac":
            return "alac"
        case "mp3":
            return "mp3"
        default:
            return normalizedToken(raw)
        }
    }

    static func normalizedSubtitleCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "mov_text", "tx3g":
            return "mov_text"
        case "wvtt", "webvtt", "web_vtt":
            return "webvtt"
        case "hdmv_pgs_subtitle":
            return "hdmv_pgs_subtitle"
        default:
            return normalizedToken(raw)
        }
    }

    static func unsupportedEmbeddedSubtitleCodecs(for version: FileVersion) -> [String] {
        embeddedSubtitleCodecs(for: version).filter { !nativeDirectSubtitleCodecs.contains($0) }
    }

    static func embeddedSubtitleCodecs(for version: FileVersion) -> [String] {
        (version.subtitleTracks ?? [])
            .filter { !($0.external ?? false) }
            .map { track in normalizedSubtitleCodec(track.codec) ?? "unknown" }
    }

    static func selectedOrMandatoryEmbeddedSubtitleCodecs(
        for version: FileVersion,
        selectedPrimarySubtitleTrackId: Int64?,
        selectedSecondarySubtitleTrackId: Int64?
    ) -> [String] {
        let embedded = (version.subtitleTracks ?? []).filter { !($0.external ?? false) }
        let selectedStreamIndexes = [selectedPrimarySubtitleTrackId, selectedSecondarySubtitleTrackId]
            .compactMap { trackId -> Int? in
                guard let trackId else { return nil }
                if SubtitleTrackIdSpace.isSidecar(trackId) { return nil }
                if SubtitleTrackIdSpace.isAVPlayerEmbedded(trackId) {
                    return Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
                }
                if trackId >= 20_000 {
                    return Int(trackId - 20_000)
                }
                return Int(trackId)
            }
        let selected = embedded.filter { track in
            guard let index = track.index else { return false }
            return selectedStreamIndexes.contains(index)
        }
        let mandatory = embedded.filter { ($0.forced ?? false) || ($0.isDefault ?? false) }
        let candidates = selected.isEmpty ? mandatory : selected
        return candidates.map { normalizedSubtitleCodec($0.codec) ?? "unknown" }
    }

    /// The two token vocabularies the plan carries for a DV loopback route:
    /// the `reason` string (matched by `humanReadableRouteReason`) and the
    /// decision-trace entry. Deriving both from one mapping keeps them from
    /// drifting as profiles or policy resolutions are added.
    enum DolbyVisionTokenVocabulary {
        case reason
        case trace
    }

    static func dolbyVisionRouteToken(
        profile: Int,
        resolution: DolbyVisionPolicy.Resolution,
        profile8BaseLayer: LoopbackSessionSpec.DVProfile8BaseLayer,
        vocabulary: DolbyVisionTokenVocabulary
    ) -> String {
        // Profile 5 never resolves to `.dolbyVisionDisabled` (no compatible
        // base layer), so the disabled tokens can lead unconditionally.
        if resolution == .dolbyVisionDisabled {
            return vocabulary == .reason
                ? "dolby_vision_disabled_base_layer_loopback"
                : "dolby_vision_disabled_base_layer_selected"
        }
        switch (profile, vocabulary) {
        case (5, .reason):
            return "dolby_vision_profile5_loopback"
        case (5, .trace):
            return "profile5_loopback_selected"
        case (7, .reason):
            return resolution == .profile7HDR10Fallback
                ? "dolby_vision_profile7_hdr10_fallback_loopback"
                : "dolby_vision_profile7_to81_base_layer_loopback"
        case (7, .trace):
            return resolution == .profile7HDR10Fallback
                ? "profile7_hdr10_fallback_selected"
                : "profile7_to81_base_layer_loopback_selected"
        case (_, .reason):
            return profile8BaseLayer == .hlg
                ? "dolby_vision_profile84_passthrough_loopback"
                : "dolby_vision_profile81_passthrough_loopback"
        case (_, .trace):
            return profile8BaseLayer == .hlg
                ? "profile84_passthrough_loopback_selected"
                : "profile81_passthrough_loopback_selected"
        }
    }

    static func versionHasDolbyVision(_ version: FileVersion) -> Bool {
        (version.videoTracks ?? []).contains { track in
            normalizedToken(track.dolbyVision) != nil
        }
    }

    static func dolbyVisionProfile(for version: FileVersion) -> Int? {
        (version.videoTracks ?? []).compactMap { track in
            dolbyVisionProfile(from: track.dolbyVision)
        }.first
    }

    static func dolbyVisionProfile(from raw: String?) -> Int? {
        guard let token = normalizedToken(raw) else { return nil }

        if let profile = Int(token), profile > 0 {
            return profile
        }

        let pattern = #"(?:profile|dvhe|dvh1|dvav|dva1|dvvp|p)\D*([0-9]{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = regex.firstMatch(in: token, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: token),
              let profile = Int(token[captureRange]),
              profile > 0 else {
            return nil
        }

        return profile
    }

    static func versionHasPotentialAtmos(_ version: FileVersion) -> Bool {
        (version.audioTracks ?? []).contains { track in
            let codec = normalizedToken(track.codec)
            let title = normalizedToken(track.title)
            return codec == "truehd"
                || codec == "e-ac-3"
                || codec == "eac3"
                || title?.localizedCaseInsensitiveContains("atmos") == true
        }
    }

    static func chapterInfoList(from version: FileVersion) -> [PlayerChapterInfo] {
        (version.chapters ?? [])
            .filter { chapter in
                chapter.startSeconds.isFinite && chapter.startSeconds >= 0
            }
            .sorted { lhs, rhs in
                if lhs.startSeconds == rhs.startSeconds {
                    return lhs.index < rhs.index
                }
                return lhs.startSeconds < rhs.startSeconds
            }
            .map { chapter in
                PlayerChapterInfo(
                    index: chapter.index,
                    title: chapter.title,
                    time: chapter.startSeconds
                )
            }
    }

    static func makeLoopbackAudioTracks(for version: FileVersion) -> [PlayerTrack] {
        (version.audioTracks ?? []).enumerated().map { audioTrackIndex, track in
            PlayerTrack(audioTrack: track, offset: audioTrackIndex)
        }
    }

    static func normalizedLoopbackAudioTracks(
        for version: FileVersion,
        selectedAudioTrackId: Int64?,
        pendingAudioFfIndex: Int?,
        preferredAudioTrackIndex: Int?
    ) -> [PlayerTrack] {
        let sourceTracks = makeLoopbackAudioTracks(for: version)
        guard !sourceTracks.isEmpty else { return [] }
        let selectedFfIndex = resolveLoopbackSelectedAudioTrack(
            from: sourceTracks,
            selectedAudioTrackId: selectedAudioTrackId,
            pendingAudioFfIndex: pendingAudioFfIndex,
            preferredAudioTrackIndex: preferredAudioTrackIndex
        )?.ffIndex
        return sourceTracks.map { track in
            PlayerTrack(
                trackId: track.trackId,
                kind: track.kind,
                title: track.title,
                lang: track.lang,
                codec: track.codec,
                audioChannelsLayout: track.audioChannelsLayout,
                audioChannelCount: track.audioChannelCount,
                bitrate: track.bitrate,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isVisualImpaired: track.isVisualImpaired,
                isExternal: track.isExternal,
                isSelected: track.ffIndex == selectedFfIndex,
                ffIndex: track.ffIndex,
                srcId: track.srcId
            )
        }
    }

    static func resolveLoopbackSelectedAudioTrack(
        from tracks: [PlayerTrack],
        selectedAudioTrackId: Int64?,
        pendingAudioFfIndex: Int?,
        preferredAudioTrackIndex: Int?
    ) -> PlayerTrack? {
        if let selectedAudioTrackId,
           let track = tracks.first(where: { $0.trackId == selectedAudioTrackId }) {
            return track
        }
        if let pendingAudioFfIndex,
           let track = tracks.first(where: { audioSelectionIndex(for: $0) == pendingAudioFfIndex }) {
            return track
        }
        if let preferredAudioTrackIndex,
           let track = tracks.first(where: { audioSelectionIndex(for: $0) == preferredAudioTrackIndex }) {
            return track
        }
        if let track = tracks.first(where: { $0.isDefault }) {
            return track
        }
        return tracks.first
    }

    static func audioSelectionIndex(for track: PlayerTrack) -> Int? {
        track.srcId ?? track.ffIndex
    }

    static func loopbackAudioOutputMode(for track: PlayerTrack) -> LoopbackSessionSpec.AudioOutputMode {
        switch normalizedToken(track.codec)?.replacingOccurrences(of: "-", with: "") {
        case "aac", "ac3", "eac3":
            return .copy
        case "truehd", "dolbytruehd":
            return .requireFLAC
        case "mlp", "mlpa":
            return .requireFLAC
        default:
            if let channelCount = track.audioChannelCount, channelCount > 2 {
                return .transcodeFLAC
            }
            return .transcodeAAC
        }
    }

    static func loopbackAudioPreservesAtmos(for track: PlayerTrack) -> Bool {
        guard normalizedToken(track.codec)?.replacingOccurrences(of: "-", with: "") == "eac3" else {
            return false
        }
        let titleToken = normalizedToken(track.title)
        return titleToken?.contains("atmos") == true || titleToken?.contains("joc") == true
    }

    static func loopbackSourceFrameRate(for version: FileVersion) -> Float? {
        (version.videoTracks ?? [])
            .compactMap { parseLoopbackFrameRate($0.frameRate) }
            .first
    }

    static func parseLoopbackFrameRate(_ raw: String?) -> Float? {
        guard let token = normalizedToken(raw) else { return nil }
        if token.contains("/") {
            let parts = token.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let numerator = Float(parts[0]),
                  let denominator = Float(parts[1]),
                  numerator > 0,
                  denominator > 0 else {
                return nil
            }
            return numerator / denominator
        }

        guard let value = Float(token), value > 0 else {
            return nil
        }
        return value
    }

    static func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token.isEmpty ? nil : token
    }
}

private extension LoopbackSessionSpec.AudioOutputMode {
    var logToken: String {
        switch self {
        case .copy:
            return "copy"
        case .transcodeFLAC:
            return "transcode_flac"
        case .requireFLAC:
            return "require_flac"
        case .transcodeEC3:
            return "transcode_ec3"
        case .transcodeAC3:
            return "transcode_ac3"
        case .transcodeAAC:
            return "transcode_aac"
        }
    }
}

private extension PlayerTrack {
    init(audioTrack: AudioTrack, offset: Int) {
        self.init(
            trackId: Int64(10_000 + offset),
            kind: .audio,
            title: audioTrack.title,
            lang: audioTrack.language,
            codec: audioTrack.codec,
            audioChannelsLayout: audioTrack.channelLayout,
            audioChannelCount: audioTrack.channels,
            bitrate: audioTrack.bitrate.map(Int64.init),
            isDefault: audioTrack.isDefault ?? false,
            isForced: false,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: audioTrack.index,
            srcId: offset
        )
    }
}
