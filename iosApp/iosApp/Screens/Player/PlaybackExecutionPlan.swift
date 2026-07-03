import Foundation

struct LoopbackSessionSpec {
    /// Base-layer color signaling for a Dolby Vision Profile 8 source.
    /// 8.1 = HDR10 base (PQ, brand `db1p`); 8.4 = HLG base (brand `db4h`).
    enum DVProfile8BaseLayer: Equatable {
        case hdr10
        case hlg
    }

    enum VideoMode: Equatable {
        case passthroughProfile5
        case convertProfile7To81
        case passthroughProfile8(DVProfile8BaseLayer)
        case passthroughHEVC
        case passthroughH264

        var sampleEntryCodec: String {
            switch self {
            case .passthroughProfile5:
                return "dvh1"
            case .convertProfile7To81:
                return "dvh1"
            case .passthroughProfile8:
                return "dvh1"
            case .passthroughHEVC:
                return "hvc1"
            case .passthroughH264:
                return "avc1"
            }
        }

        var logToken: String {
            switch self {
            case .passthroughProfile5:
                return "profile5_passthrough"
        case .convertProfile7To81:
                return "profile7_to81_base_layer"
            case .passthroughProfile8(.hdr10):
                return "profile8_1_passthrough"
            case .passthroughProfile8(.hlg):
                return "profile8_4_passthrough"
            case .passthroughHEVC:
                return "hevc_passthrough"
            case .passthroughH264:
                return "h264_passthrough"
            }
        }

        var isDolbyVision: Bool {
            switch self {
            case .passthroughProfile5, .convertProfile7To81, .passthroughProfile8:
                return true
            case .passthroughHEVC, .passthroughH264:
                return false
            }
        }
    }

    enum AudioOutputMode: Equatable {
        case copy
        case transcodeFLAC
        case requireFLAC
        case transcodeEC3
        case transcodeAC3
        case transcodeAAC

        var preferredCodecToken: String {
            switch self {
            case .copy:
                return ""
            case .transcodeFLAC, .requireFLAC:
                return "fLaC"
            case .transcodeEC3:
                return "ec-3"
            case .transcodeAC3:
                return "ac-3"
            case .transcodeAAC:
                return "mp4a.40.2"
            }
        }
    }

    struct SelectedAudio: Equatable {
        let trackIndex: Int
        let ffIndex: Int?
        let sourceCodec: String?
        let sourceChannelCount: Int?
        let sourceChannelLayout: String?
        let outputMode: AudioOutputMode
        let preservesAtmos: Bool
    }

    struct ManifestMetadata: Equatable {
        let advertisedDolbyVisionProfile: Int?
        let compatibilityBrand: String?
        let videoRange: String
        let mayClaimAtmos: Bool
    }

    let sourceURL: URL
    let headers: [String: String]
    let sourceStartTimeSeconds: Double
    let sourceBitrateBps: Double?
    let videoMode: VideoMode
    let sourceVideoFrameRate: Float?
    let selectedAudio: SelectedAudio
    let availableAudioTracks: [PlayerTrack]
    let manifestMetadata: ManifestMetadata
    let servingMode: LoopbackServingMode

    init(
        sourceURL: URL,
        headers: [String: String],
        sourceStartTimeSeconds: Double = 0,
        sourceBitrateBps: Double? = nil,
        videoMode: VideoMode,
        sourceVideoFrameRate: Float?,
        selectedAudio: SelectedAudio,
        availableAudioTracks: [PlayerTrack],
        manifestMetadata: ManifestMetadata,
        servingMode: LoopbackServingMode = .event
    ) {
        self.sourceURL = sourceURL
        self.headers = headers
        self.sourceStartTimeSeconds = sourceStartTimeSeconds.isFinite
            ? max(0, sourceStartTimeSeconds)
            : 0
        self.sourceBitrateBps = sourceBitrateBps
        self.videoMode = videoMode
        self.sourceVideoFrameRate = sourceVideoFrameRate
        self.selectedAudio = selectedAudio
        self.availableAudioTracks = availableAudioTracks
        self.manifestMetadata = manifestMetadata
        self.servingMode = servingMode
    }

    func reanchored(at mediaSeconds: Double) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: headers,
            sourceStartTimeSeconds: mediaSeconds,
            sourceBitrateBps: sourceBitrateBps,
            videoMode: videoMode,
            sourceVideoFrameRate: sourceVideoFrameRate,
            selectedAudio: selectedAudio,
            availableAudioTracks: availableAudioTracks,
            manifestMetadata: manifestMetadata,
            servingMode: servingMode
        )
    }
}

/// How the local loopback serves HLS to AVPlayer.
enum LoopbackServingMode: Equatable {
    /// Growing EVENT playlist cut at source keyframes; a seek outside the
    /// generated window tears the session down and reanchors on a fresh,
    /// zero-based timeline (legacy behavior).
    case event
    /// Static VOD playlist derived from a load-time segment plan: the full
    /// title is advertised up front, fragments are cut explicitly at plan
    /// boundaries, and producer restarts continue the session timeline
    /// (docs/tvos-player/2026-07-03-siloplayer-loopback-primary-plan.md).
    case vodPlan
}

extension LoopbackServingMode {
    /// Rollout gate. Stage 3 flipped the default ON after the living-room
    /// hardware pass (2026-07-03): an absent key serves VOD; an explicit
    /// `false` remains the kill switch back to the EVENT path.
    static let primaryGateKey = "player.apple.siloplayer_primary_enabled"

    static var gated: LoopbackServingMode {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: primaryGateKey) != nil else { return .vodPlan }
        return defaults.bool(forKey: primaryGateKey) ? .vodPlan : .event
    }
}

/// Minimal HTTP stream descriptor consumed by the load path. Produced at
/// the bridge/VM seam from `PlaybackSessionResponse` so the player layer
/// doesn't re-parse URLs and header maps on every route.
struct StreamRequest {
    let url: URL
    let headers: [String: String]
    let serverUrl: String
}

enum PlaybackRouteFamily: String, Equatable {
    case nativePlayer = "NativePlayer"
    case siloPlayer = "SiloPlayer"
    case compatibilityPlayer = "CompatibilityPlayer"

    var diagnosticsLabel: String { rawValue }
}

/// Identifies which playback engine will execute the plan. Produced at the
/// bridge/VM seam so route choice survives bootstrap as typed data rather
/// than being reconstructed from `session.playMethod` at the load path.
///
/// Replaces the older private `ApplePlayerRouteKind` with names that match
/// the delivery strategies described in the Apple Playback Engine Evolution
/// plan (`docs/plans/apple-playback-engine-evolution.md`).
enum PlaybackEngineKind: Equatable {
    /// Custom FFmpeg demux + VideoToolbox decode + AVSampleBufferDisplayLayer.
    /// Used for direct playback of exotic containers and codecs that
    /// AVFoundation cannot open natively (MKV, TS, M2TS, WebM, AVI).
    case playerCoreDirect
    /// AVPlayer consuming a server-produced HLS manifest. Near-term policy
    /// reserves this for explicit quality/bitrate-reduction playback rather
    /// than generic original-quality Apple normalization.
    case avPlayerHLS
    /// AVPlayer consuming a direct remote asset that already matches a narrow
    /// native Apple container/codec/subtitle allowlist.
    case avPlayerNativeDirect
    /// AVPlayer consuming locally-remuxed fragmented MP4 served via the
    /// in-process HLS loopback. Used when AVPlayer presentation is preferred
    /// but the original source container is not native-direct compatible.
    case siloPlayerLoopback

    var label: String {
        switch self {
        case .playerCoreDirect: return "playerCoreDirect"
        case .avPlayerHLS: return "avPlayerHLS"
        case .avPlayerNativeDirect: return "avPlayerNativeDirect"
        case .siloPlayerLoopback: return "siloPlayerLoopback"
        }
    }

    var routeFamily: PlaybackRouteFamily {
        switch self {
        case .playerCoreDirect:
            return .compatibilityPlayer
        case .avPlayerHLS, .avPlayerNativeDirect:
            return .nativePlayer
        case .siloPlayerLoopback:
            return .siloPlayer
        }
    }

    var appPlaybackLabel: String {
        switch self {
        case .playerCoreDirect:
            return "Compatibility Playback"
        case .avPlayerHLS:
            return "Server Stream"
        case .avPlayerNativeDirect:
            return "Direct"
        case .siloPlayerLoopback:
            return "Direct Stream"
        }
    }

    var routeCapabilities: ApplePlaybackRouteCapabilities {
        switch self {
        case .playerCoreDirect:
            return .playerCoreDirect
        case .avPlayerHLS:
            return .avPlayerHLS
        case .avPlayerNativeDirect:
            return .avPlayerNativeDirect
        case .siloPlayerLoopback:
            return .siloPlayerLoopback
        }
    }

    /// Capability profile advertised to the UI layer for this engine. The
    /// AVPlayer routes share the AVFoundation profile because the
    /// backend surface is identical once a stream is loaded.
    var capabilities: PlayerBackendCapabilities {
        routeCapabilities.backendCapabilities
    }
}

struct PlaybackSourceMetadata: Equatable {
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let subtitleCodecs: [String]
    let dolbyVisionProfile: Int?

    static let unknown = PlaybackSourceMetadata(
        container: nil,
        videoCodec: nil,
        audioCodec: nil,
        subtitleCodecs: [],
        dolbyVisionProfile: nil
    )
}

struct PlaybackNormalizationSummary: Equatable {
    let containerMode: String
    let videoMode: String
    let audioMode: String
    let subtitleMode: String

    static let none = PlaybackNormalizationSummary(
        containerMode: "none",
        videoMode: "none",
        audioMode: "none",
        subtitleMode: "none"
    )

    var logToken: String {
        "container=\(containerMode),video=\(videoMode),audio=\(audioMode),subtitle=\(subtitleMode)"
    }
}

struct PlaybackValidationClaims: Equatable {
    let localHDR: ApplePlaybackCapabilityState
    let tvOSDolbyVisionDisplay: ApplePlaybackCapabilityState
    let tvOSReceiverAtmos: ApplePlaybackCapabilityState
    let pictureInPicture: ApplePlaybackCapabilityState
    let externalPlayback: ApplePlaybackCapabilityState
    let citations: [String]

    static func from(routeCapabilities: ApplePlaybackRouteCapabilities) -> PlaybackValidationClaims {
        from(routeCapabilities: routeCapabilities, sourceMetadata: .unknown)
    }

    static func from(
        routeCapabilities: ApplePlaybackRouteCapabilities,
        sourceMetadata: PlaybackSourceMetadata
    ) -> PlaybackValidationClaims {
        let hasDolbyVision = sourceMetadata.dolbyVisionProfile != nil
        let hasHDRCandidate = hasDolbyVision || sourceMetadata.videoCodec == "hevc"
        let hasAtmosCandidate: Bool = {
            guard let audioCodec = sourceMetadata.audioCodec?.lowercased() else { return false }
            return audioCodec == "truehd" || audioCodec == "eac3" || audioCodec == "ec3" || audioCodec == "e-ac-3"
        }()
        return PlaybackValidationClaims(
            localHDR: hasHDRCandidate ? routeCapabilities.premiumClaims.localDeviceHDR.state : .unclaimed,
            tvOSDolbyVisionDisplay: hasDolbyVision ? routeCapabilities.premiumClaims.tvOSDolbyVisionDisplay.state : .unclaimed,
            tvOSReceiverAtmos: hasAtmosCandidate ? routeCapabilities.premiumClaims.tvOSReceiverAtmos.state : .unclaimed,
            pictureInPicture: routeCapabilities.pictureInPicture.state,
            externalPlayback: routeCapabilities.externalPlayback.state,
            citations: []
        )
    }

    var logToken: String {
        var tokens = [
            "hdr:\(localHDR.rawValue)",
            "dv:\(tvOSDolbyVisionDisplay.rawValue)",
            "atmos:\(tvOSReceiverAtmos.rawValue)",
            "pip:\(pictureInPicture.rawValue)",
            "external:\(externalPlayback.rawValue)"
        ]
        if !citations.isEmpty {
            tokens.append("citations:\(citations.joined(separator: "+"))")
        }
        return tokens.joined(separator: ",")
    }
}

/// Where the player should begin. Carried through bootstrap as typed data
/// so the load path does not infer "remux starts at zero" vs "transcode
/// starts at position" from the `playMethod` string.
enum PlaybackStartMode: Equatable {
    /// Begin at the top of a freshly generated HLS window. The server has
    /// already anchored the manifest to the requested stream origin, so the
    /// client seek target is always 0. This is the remux / codec-copy case.
    case startOfManifest
    /// Seek to an absolute position within the stream. Used by transcode HLS
    /// (seek inside a synthetic full-VOD manifest) and direct playback
    /// (seek inside the source file).
    case absolutePosition(Double)

    var seconds: Double {
        switch self {
        case .startOfManifest:
            return 0
        case .absolutePosition(let t):
            return t.isFinite ? t : 0
        }
    }
}

/// Typed execution plan produced at the bridge/VM seam and consumed by the
/// load path. Bundles the route decision, transport semantics, and stream
/// inputs so downstream code does not re-derive any of it from the lossy
/// `PlaybackSessionResponse` shape.
///
/// This is the Workstream 1 artifact from the Apple Playback Engine
/// Evolution plan. Subsequent workstreams extend the plan (native-direct
/// route, split capability contract) without changing its shape at the
/// call site.
struct PlaybackExecutionPlan {
    let delivery: PlaybackDeliveryStrategy
    let engine: PlaybackEngineKind
    let routeFamily: PlaybackRouteFamily
    let implementationRoute: String
    let appPlaybackLabel: String
    let startMode: PlaybackStartMode
    let streamRequest: StreamRequest
    let sourceStreamRequest: StreamRequest
    let loopbackSession: LoopbackSessionSpec?
    let capabilities: PlayerBackendCapabilities
    let routeCapabilities: ApplePlaybackRouteCapabilities
    let requirements: PlaybackRouteRequirements
    let sourceMetadata: PlaybackSourceMetadata
    let normalizationSummary: PlaybackNormalizationSummary
    let validationClaims: PlaybackValidationClaims
    /// Inputs to the route decision, retained on the plan so a single emit
    /// site can log the full decision trace instead of threading them
    /// through every consumer.
    let featureFlagEnabled: Bool
    let parityBlockers: [String]
    let decisionTrace: [String]
    let degradationWarnings: [String]
    let reason: String
    let playbackSessionId: String?

    init(
        delivery: PlaybackDeliveryStrategy,
        engine: PlaybackEngineKind,
        startMode: PlaybackStartMode,
        streamRequest: StreamRequest,
        sourceStreamRequest: StreamRequest? = nil,
        loopbackSession: LoopbackSessionSpec?,
        capabilities: PlayerBackendCapabilities,
        routeCapabilities: ApplePlaybackRouteCapabilities,
        requirements: PlaybackRouteRequirements,
        featureFlagEnabled: Bool,
        parityBlockers: [String],
        decisionTrace: [String],
        degradationWarnings: [String],
        reason: String,
        playbackSessionId: String? = nil,
        sourceMetadata: PlaybackSourceMetadata = .unknown,
        normalizationSummary: PlaybackNormalizationSummary = .none,
        validationClaims: PlaybackValidationClaims? = nil
    ) {
        self.delivery = delivery
        self.engine = engine
        self.routeFamily = engine.routeFamily
        self.implementationRoute = engine.label
        self.appPlaybackLabel = engine.appPlaybackLabel
        self.startMode = startMode
        self.streamRequest = streamRequest
        self.sourceStreamRequest = sourceStreamRequest ?? streamRequest
        self.loopbackSession = loopbackSession
        self.capabilities = capabilities
        self.routeCapabilities = routeCapabilities
        self.requirements = requirements
        self.sourceMetadata = sourceMetadata
        self.normalizationSummary = normalizationSummary
        self.validationClaims = validationClaims ?? PlaybackValidationClaims.from(
            routeCapabilities: routeCapabilities,
            sourceMetadata: sourceMetadata
        )
        self.featureFlagEnabled = featureFlagEnabled
        self.parityBlockers = parityBlockers
        self.decisionTrace = decisionTrace
        self.degradationWarnings = degradationWarnings
        self.reason = reason
        self.playbackSessionId = playbackSessionId
    }

    /// Build the fallback plan used when PlayerCore rejects a stream it
    /// cannot decode (currently Dolby Vision Profile 5). Keeps the
    /// "always-direct, always AVPlayer DV loopback, never gated" invariants
    /// in one place so `handleUnsupportedStream` doesn't reconstruct a plan
    /// by hand at the load path.
    static func dolbyVisionLoopback(
        streamRequest: StreamRequest,
        startTime: Double,
        rejectionReason: String,
        loopbackSession: LoopbackSessionSpec? = nil,
        routeRequirements: PlaybackRouteRequirements = .baseline,
        decisionTrace: [String] = [],
        playbackSessionId: String? = nil,
        sourceMetadata: PlaybackSourceMetadata = .unknown
    ) -> PlaybackExecutionPlan {
        let routeCapabilities = PlaybackEngineKind.siloPlayerLoopback.routeCapabilities
        let reason = rejectionReason == "dolbyVisionProfile5"
            ? "dolby_vision_profile5_loopback"
            : "playercore_rejected_\(rejectionReason)"
        return PlaybackExecutionPlan(
            delivery: .direct,
            engine: .siloPlayerLoopback,
            startMode: .absolutePosition(startTime),
            streamRequest: streamRequest,
            loopbackSession: loopbackSession,
            capabilities: PlaybackEngineKind.siloPlayerLoopback.capabilities,
            routeCapabilities: routeCapabilities,
            requirements: routeRequirements,
            featureFlagEnabled: true,
            parityBlockers: [],
            decisionTrace: decisionTrace + [reason],
            degradationWarnings: routeCapabilities.degradationNotes(for: routeRequirements),
            reason: reason,
            playbackSessionId: playbackSessionId,
            sourceMetadata: sourceMetadata,
            normalizationSummary: loopbackNormalizationSummary(
                loopbackSession: loopbackSession,
                sourceMetadata: sourceMetadata
            )
        )
    }

    /// Build the fallback plan used when PlayerCore's VideoToolbox path rejects
    /// HEVC HDR that is not known Dolby Vision P5. This still remuxes locally
    /// for AVPlayer, but keeps the manifest and display criteria as plain HEVC
    /// HDR rather than advertising Dolby Vision.
    static func hevcHDRLoopback(
        streamRequest: StreamRequest,
        startTime: Double,
        rejectionReason: String,
        loopbackSession: LoopbackSessionSpec?,
        routeRequirements: PlaybackRouteRequirements = .baseline,
        decisionTrace: [String] = [],
        playbackSessionId: String? = nil,
        sourceMetadata: PlaybackSourceMetadata = .unknown
    ) -> PlaybackExecutionPlan {
        let routeCapabilities = PlaybackEngineKind.siloPlayerLoopback.routeCapabilities
        let reason = "playercore_rejected_\(rejectionReason)_hevc_loopback"
        return PlaybackExecutionPlan(
            delivery: .direct,
            engine: .siloPlayerLoopback,
            startMode: .absolutePosition(startTime),
            streamRequest: streamRequest,
            loopbackSession: loopbackSession,
            capabilities: PlaybackEngineKind.siloPlayerLoopback.capabilities,
            routeCapabilities: routeCapabilities,
            requirements: routeRequirements,
            featureFlagEnabled: true,
            parityBlockers: [],
            decisionTrace: decisionTrace + [reason],
            degradationWarnings: routeCapabilities.degradationNotes(for: routeRequirements),
            reason: reason,
            playbackSessionId: playbackSessionId,
            sourceMetadata: sourceMetadata,
            normalizationSummary: loopbackNormalizationSummary(
                loopbackSession: loopbackSession,
                sourceMetadata: sourceMetadata
            )
        )
    }

    private static func loopbackNormalizationSummary(
        loopbackSession: LoopbackSessionSpec?,
        sourceMetadata: PlaybackSourceMetadata
    ) -> PlaybackNormalizationSummary {
        PlaybackNormalizationSummary(
            containerMode: "local_fmp4_hls",
            videoMode: loopbackSession?.videoMode.logToken ?? "loopback_unresolved",
            audioMode: loopbackSession.map { audioModeLogToken($0.selectedAudio.outputMode) }
                ?? "loopback_unresolved",
            subtitleMode: sourceMetadata.subtitleCodecs.isEmpty ? "none" : "extract_or_sidecar"
        )
    }

    private static func audioModeLogToken(_ mode: LoopbackSessionSpec.AudioOutputMode) -> String {
        switch mode {
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
