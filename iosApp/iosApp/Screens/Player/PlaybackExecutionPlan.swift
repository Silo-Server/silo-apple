import Foundation

struct LoopbackSessionSpec {
    /// Base-layer color signaling for a Dolby Vision Profile 8 source.
    /// 8.1 = HDR10 base (PQ, brand `db1p`); 8.2 = SDR base (Rec.709, brand
    /// `db2g`); 8.4 = HLG base (brand `db4h`).
    enum DVProfile8BaseLayer: Equatable {
        case hdr10
        case hlg
        case sdr

        /// The base layer a `dvcC`/`dvvC` compatibility ID names: 2 is
        /// Profile 8.2's SDR base, 4 is Profile 8.4's HLG base, and
        /// everything else (1 = HDR10, 0 = none) resolves to the PQ default.
        /// Shared with `ApplePlaybackRoutePlanner.dvProfile8BaseLayer`, which
        /// decides the same thing from server metadata before decode.
        init(dolbyVisionCompatibilityID: Int?) {
            switch dolbyVisionCompatibilityID {
            case 2: self = .sdr
            case 4: self = .hlg
            default: self = .hdr10
            }
        }
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
            case .passthroughProfile8(.sdr):
                return "profile8_2_passthrough"
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

        /// True when a (typically lossy) source track is re-encoded to
        /// lossless FLAC, which can raise the served bitrate above the
        /// source container average.
        var bridgesToLosslessFLAC: Bool {
            self == .transcodeFLAC || self == .requireFLAC
        }

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

    /// How the loopback writer produces the VIDEO track. Deliberately a
    /// sibling of `VideoMode` rather than more cases on it: `VideoMode` is the
    /// Dolby-Vision / sample-entry decision and is switched exhaustively in a
    /// dozen places, while this answers the orthogonal "copy the source
    /// bitstream or re-encode it" question. Mirrors `AudioOutputMode`.
    enum VideoOutputMode: Equatable {
        /// Today's remux. The only value for Dolby Vision, HEVC, and H.264.
        case copy
        /// FFmpeg software decode → `hevc_videotoolbox` encode.
        case transcodeHEVC
        /// Same pipeline through `h264_videotoolbox`; the fallback when the
        /// HEVC encoder cannot be opened on this device.
        case transcodeH264
        /// AV1 remuxed as-is because the device has hardware AV1 decode.
        case passthroughAV1

        var isBridged: Bool {
            self == .transcodeHEVC || self == .transcodeH264
        }

        /// Sample entry fourcc the muxer must write when this mode decides it.
        /// `.copy` returns nil and defers to `VideoMode.sampleEntryCodec`,
        /// which owns the Dolby Vision `dvh1` distinction.
        var sampleEntryCodec: String? {
            switch self {
            case .copy:
                return nil
            case .transcodeHEVC:
                return "hvc1"
            case .transcodeH264:
                return "avc1"
            case .passthroughAV1:
                return "av01"
            }
        }

        var logToken: String {
            switch self {
            case .copy:
                return "copy"
            case .transcodeHEVC:
                return "bridge_hevc"
            case .transcodeH264:
                return "bridge_h264"
            case .passthroughAV1:
                return "av1_passthrough"
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

        static let absent = SelectedAudio(
            trackIndex: -1,
            ffIndex: nil,
            sourceCodec: nil,
            sourceChannelCount: nil,
            sourceChannelLayout: nil,
            outputMode: .copy,
            preservesAtmos: false
        )

        var isPresent: Bool {
            if let ffIndex {
                return ffIndex >= 0
            }
            return trackIndex >= 0
        }
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
    /// Whether the writer copies the source video bitstream or bridges it
    /// through decode + VideoToolbox encode. Defaults to `.copy` so every
    /// pre-existing construction site keeps today's behavior.
    let videoOutputMode: VideoOutputMode
    /// Source video dimensions when the planner knows them. Consumed by the
    /// bridge's bitrate ladder; nil leaves the ladder on the decoded frame's
    /// own dimensions.
    let sourceVideoWidth: Int?
    let sourceVideoHeight: Int?
    /// The `hvcC` / `avcC` record the FIRST bridged producer of this player
    /// item published. AVPlayer fetches `EXT-X-MAP` once per item, so a
    /// restarted producer must install the original parameter sets rather
    /// than whatever its own fresh encoder session synthesizes; the writer
    /// also asserts the two match and fails the session if they do not.
    let bridgedVideoParameterSets: Data?
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
        videoOutputMode: VideoOutputMode = .copy,
        sourceVideoWidth: Int? = nil,
        sourceVideoHeight: Int? = nil,
        bridgedVideoParameterSets: Data? = nil,
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
        self.videoOutputMode = videoOutputMode
        self.sourceVideoWidth = sourceVideoWidth
        self.sourceVideoHeight = sourceVideoHeight
        self.bridgedVideoParameterSets = bridgedVideoParameterSets
        self.sourceVideoFrameRate = sourceVideoFrameRate
        self.selectedAudio = selectedAudio
        self.availableAudioTracks = Self.markSelectedAudioTrack(
            in: availableAudioTracks,
            selectedAudio: selectedAudio
        )
        self.manifestMetadata = manifestMetadata
        self.servingMode = servingMode
    }

    /// Diagnostics token for the video normalization actually performed. A
    /// bridged or AV1-passthrough session's `videoMode` only describes the
    /// sample entry, so reporting it alone would read as a plain remux.
    var videoNormalizationLogToken: String {
        videoOutputMode == .copy ? videoMode.logToken : videoOutputMode.logToken
    }

    /// The selected mux input is authoritative. The planner can resolve it
    /// from a server-provided audio ordinal after the inventory was initially
    /// marked from local preferences; publishing those stale flags makes the
    /// view model "correct" an already-correct selection and rebuild the
    /// loopback item immediately after its first frame.
    private static func markSelectedAudioTrack(
        in tracks: [PlayerTrack],
        selectedAudio: SelectedAudio
    ) -> [PlayerTrack] {
        guard selectedAudio.isPresent else { return tracks }
        let selectedTrack = tracks.first(where: { $0.srcId == selectedAudio.trackIndex })
            ?? selectedAudio.ffIndex.flatMap { ffIndex in
                tracks.first(where: { $0.ffIndex == ffIndex })
            }
        guard let selectedTrack else { return tracks }

        return tracks.map { track in
            let isSelected = track.trackId == selectedTrack.trackId
            guard track.isSelected != isSelected else { return track }
            return PlayerTrack(
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
                isSelected: isSelected,
                ffIndex: track.ffIndex,
                srcId: track.srcId
            )
        }
    }

    func reanchored(at mediaSeconds: Double) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: headers,
            sourceStartTimeSeconds: mediaSeconds,
            sourceBitrateBps: sourceBitrateBps,
            videoMode: videoMode,
            videoOutputMode: videoOutputMode,
            sourceVideoWidth: sourceVideoWidth,
            sourceVideoHeight: sourceVideoHeight,
            bridgedVideoParameterSets: bridgedVideoParameterSets,
            sourceVideoFrameRate: sourceVideoFrameRate,
            selectedAudio: selectedAudio,
            availableAudioTracks: availableAudioTracks,
            manifestMetadata: manifestMetadata,
            servingMode: servingMode
        )
    }

    /// Pins the parameter sets a restarted bridged producer must reproduce.
    /// Called once per player item, from the backend's
    /// `onBridgedVideoParameterSetsResolved` handler.
    func carryingBridgedVideoParameterSets(_ data: Data) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: headers,
            sourceStartTimeSeconds: sourceStartTimeSeconds,
            sourceBitrateBps: sourceBitrateBps,
            videoMode: videoMode,
            videoOutputMode: videoOutputMode,
            sourceVideoWidth: sourceVideoWidth,
            sourceVideoHeight: sourceVideoHeight,
            bridgedVideoParameterSets: data,
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

    var diagnosticsLabel: String { rawValue }

    /// User-facing family name for the player HUD (the raw value is a
    /// diagnostics token that reads as jargon on screen).
    var displayLabel: String {
        switch self {
        case .nativePlayer: return "Native Player"
        case .siloPlayer: return "SiloPlayer"
        }
    }
}

/// Identifies which playback engine will execute the plan. Produced at the
/// bridge/VM seam so route choice survives bootstrap as typed data rather
/// than being reconstructed from `session.playMethod` at the load path.
///
/// Replaces the older private `ApplePlayerRouteKind` with names that match
/// the delivery strategies described in the Apple Playback Engine Evolution
/// plan (`docs/plans/apple-playback-engine-evolution.md`).
enum PlaybackEngineKind: Equatable {
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
        case .avPlayerHLS: return "avPlayerHLS"
        case .avPlayerNativeDirect: return "avPlayerNativeDirect"
        case .siloPlayerLoopback: return "siloPlayerLoopback"
        }
    }

    var routeFamily: PlaybackRouteFamily {
        switch self {
        case .avPlayerHLS, .avPlayerNativeDirect:
            return .nativePlayer
        case .siloPlayerLoopback:
            return .siloPlayer
        }
    }

    var appPlaybackLabel: String {
        switch self {
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
    let colorRange: String?

    static let unknown = PlaybackSourceMetadata(
        container: nil,
        videoCodec: nil,
        audioCodec: nil,
        subtitleCodecs: [],
        dolbyVisionProfile: nil,
        colorRange: nil
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
    /// Server wire delivery token. Legacy direct plans predate the V3 token
    /// but are equivalent to `original_http`.
    let wireDelivery: String?
    let serverFeatures: [String]
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

    var supportsDirectStreamResume: Bool {
        delivery == .direct
            && wireDelivery == "original_http"
            && serverFeatures.contains(PlaybackProtocolV3.directStreamResumeFeature)
    }

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
        wireDelivery: String? = nil,
        serverFeatures: [String] = [],
        sourceMetadata: PlaybackSourceMetadata = .unknown,
        normalizationSummary: PlaybackNormalizationSummary = .none,
        validationClaims: PlaybackValidationClaims? = nil
    ) {
        self.delivery = delivery
        self.wireDelivery = wireDelivery ?? (delivery == .direct ? "original_http" : nil)
        self.serverFeatures = serverFeatures
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
}
