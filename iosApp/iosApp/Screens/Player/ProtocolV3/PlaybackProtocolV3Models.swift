import Foundation

enum PlaybackProtocolV3 {
    static let version = 3
    static let planFeature = "playback_plan_v3"
    /// Server-only compatibility marker for the neutral V3 contract. Unlike
    /// `playback_plan_v3`, this guarantees opaque server-minted attempt keys
    /// and distinct intent replan operations.
    static let neutralContractFeature = "neutral_playback_v3_contract_v1"
    static let clientTransformFeature = "client_video_transformations_v1"
    static let routeDiagnosticsFeature = "playback_route_diagnostics"
    static let deviceQuirksFeature = "device_quirks_v1"
    static let seekReanchorFeature = "seek_reanchor_v1"
    /// The `output_change` intent replan exists. Per §6 an intent operation
    /// keeps the previous route eligible; `failure_recovery` would instead
    /// exclude the current plan key and force a route the device never rejected.
    static let outputChangeFeature = "output_change_v1"
    static let directStreamResumeFeature = "direct_stream_resume_v1"
    /// API-local media URLs carry no signed credential. The client attaches
    /// its current Authorization header to the source and every derived media
    /// or subtitle request.
    static let headerAuthenticatedMediaFeature = "header_authenticated_media_v1"
    /// Opt-in, only meaningful alongside `header_authenticated_media_v1`: the
    /// plan may hand back absolute, still credential-free media URLs on a
    /// server-designated proxy origin, and the client attaches the same bearer
    /// there that it sends the API. Unlike header auth this is optional — a
    /// server that does not advertise it simply keeps every byte API-local.
    static let authorizedMediaOriginsFeature = "authorized_media_origins_v1"
    /// The server may validate bounded `hardware: false` decode entries for
    /// original delivery. Older servers ignore the opt-in and keep their
    /// hardware-only strict-tier behavior.
    static let softwareVideoDecodeFeature = "software_video_decode_v1"
    static let planSourceDurationFeature = "plan_source_duration_v1"
    /// The plan names the `available_qualities` entry it delivers in
    /// `active_quality`, so an absent field means "no entry" rather than "a
    /// server that predates the field". API v2 only.
    static let planActiveQualityFeature = "plan_active_quality_v1"
    /// Scoped to `original_http`: the Aether executor accepts the declared
    /// source dynamic range and resolves HDR/Dolby Vision presentation against
    /// the live output after delivery. It is not a promise that packaged
    /// server streams can present the same range natively.
    static let clientManagedDynamicRangeClaim = "client_managed_dynamic_range_v1"
    /// Scoped to `original_http`: after probing the complete source, Aether
    /// maps the plan's selected audio ordinal to its concrete stream id.
    static let embeddedSubtitlesFeature = "embedded_subtitles_v1"
    static let clientSelectedAudioTrackClaim = "client_selected_audio_track_v1"
    /// Native v2 only. The server accepts `bandwidth_estimate_source` and
    /// `learned_limit` on a start or replan whose `client_features` names it,
    /// and records and applies learned bandwidth limits only for such requests.
    /// See ``PlaybackV3BufferingQualityRequest``.
    static let bufferingQualityFeature = "buffering_quality_v1"
    /// Native v2 only. The server accepts the `plan_summary` route event.
    static let planSummaryFeature = "playback_plan_summary_v1"
    /// Capability only. The server advertises `bandwidth_probe_url`, takes
    /// probe results, and adds `probe` and `auto_budget_kbps` to the
    /// connection endpoint. See ``BandwidthProbeScheduler``.
    static let connectionSpeedFeature = "connection_speed_v1"

    /// Where a request's `bandwidth_estimate_kbps` came from.
    enum BandwidthEstimateSource {
        static let probe = "probe"
        /// The step-down estimate after repeated rebuffering. The server keeps
        /// it as this device's learned limit on the current connection.
        static let observedRebuffer = "observed_rebuffer"
    }

    /// What a request asks the server to do with the learned limit. Absent,
    /// the limit applies to Auto.
    enum LearnedLimit {
        /// Plan without the limit and keep it stored.
        static let ignore = "ignore"
        /// Delete the limit for this connection, then plan without it.
        static let clear = "clear"
    }

    enum RouteEvent {
        /// Sent when a plan stops being the playing plan; see
        /// ``BufferingQualityController/PlanSummary/routeEventDiagnostics``.
        static let planSummary = "plan_summary"
    }

    /// Delivery classes are the unit a client negotiates in
    /// `client_playback_context.deliveries`. They are deliberately coarser than
    /// the four plan-level `delivery` outcomes the server reports back: the
    /// server folds `server_remux_hls` and `server_transcode_hls` onto `hls`,
    /// and `server_remux_progressive` onto `progressive`.
    enum DeliveryClass {
        static let originalHTTP = "original_http"
        static let progressive = "progressive"
        static let hls = "hls"
    }

    enum PlanDelivery {
        static let originalHTTP = "original_http"
        static let remuxProgressive = "server_remux_progressive"
        static let remuxHLS = "server_remux_hls"
        static let transcodeHLS = "server_transcode_hls"

        static let supported: Set<String> = [
            originalHTTP, remuxProgressive, remuxHLS, transcodeHLS
        ]
    }

    /// What the plan asks the client to do with the selected subtitle.
    enum SubtitleMode {
        static let off = "off"
        static let render = "render"
        /// Server-transcoded cues the client still renders itself. Only the
        /// artifact's format differs from `render`.
        static let convert = "convert"
        static let burnIn = "burn_in"

        /// Modes whose artifact the client mounts and renders locally. Every
        /// gate that arms a local subtitle selection must accept all of them:
        /// a gate that only knows `render` turns a mounted artifact into an
        /// explicit Off while the picker still shows the row selected.
        static let locallyRendered: Set<String> = [render, convert]
    }

    /// How much the client actually knows about its own decoders. The server
    /// gates direct/copy routes on this: `exact` and `platformAttested` are
    /// matched against `video_decode` entries, `declared` only against the flat
    /// codec list.
    enum Evidence {
        static let exact = "exact"
        static let platformAttested = "platform_attested"
        static let declared = "declared"
    }

    /// Why the client is asking for a new plan. `failureRecovery` is the
    /// server's default when the field is absent; the three intent operations
    /// carry no `failure`.
    enum ReplanOperation {
        static let failureRecovery = "failure_recovery"
        static let seekReanchor = "seek_reanchor"
        static let trackChange = "track_change"
        static let qualityChange = "quality_change"
        /// The active display/output capabilities changed. Nothing failed, so
        /// §6 keeps the previous route eligible: neither attempted-key history
        /// nor the failed-plan exclusion applies. The server rejects this
        /// operation outright if it carries a `failure`.
        static let outputChange = "output_change"
    }
}

struct PlaybackV3HDRCapabilities: Codable, Equatable {
    let hdr10: Bool
    let hdr10Plus: Bool
    let hlg: Bool
    let dolbyVisionProfiles: [Int]

    /// The coarse `capabilities.hdr` flag the protocol also carries. Derived
    /// rather than declared so the two can never disagree.
    var claimsAnyHDR: Bool {
        hdr10 || hdr10Plus || hlg || !dolbyVisionProfiles.isEmpty
    }
}

struct PlaybackV3AudioPassthroughEntry: Codable, Equatable {
    let codec: String
    let channelCounts: [Int]
    let layouts: [String]
}

struct PlaybackV3AudioPassthrough: Codable, Equatable {
    let passthroughCodecs: [String]
    let spatializerEnabled: Bool
    let maxChannels: Int
    let entries: [PlaybackV3AudioPassthroughEntry]
}

struct PlaybackV3VideoDecodeCapability: Codable, Equatable, Sendable {
    let codec: String
    let decoderName: String?
    let profiles: [String]
    let levels: [Int]
    let bitDepths: [Int]
    let maxWidth: Int
    let maxHeight: Int
    let maxFrameRate: Double
    let maxBitrateKbps: Int
    let hardware: Bool
}

extension AppleDecodeCapabilities {
    /// The neutral decoder facts above adapted once into the Protocol V3 wire
    /// model. Keeping this adapter beside the model lets shared capability code
    /// compile in extensions that do not carry the playback protocol.
    static func playbackV3VideoDecodeAttestation() -> [PlaybackV3VideoDecodeCapability] {
        videoDecodeAttestation().map { capability in
            PlaybackV3VideoDecodeCapability(
                codec: capability.codec,
                decoderName: capability.decoderName,
                profiles: capability.profiles,
                levels: capability.levels,
                bitDepths: capability.bitDepths,
                maxWidth: capability.maxWidth,
                maxHeight: capability.maxHeight,
                maxFrameRate: capability.maxFrameRate,
                maxBitrateKbps: capability.maxBitrateKbps,
                hardware: capability.hardware
            )
        }
    }
}

struct PlaybackV3CodecCapabilities: Codable, Equatable {
    /// How this client knows what it can decode. Online iOS and Apple TV 4K playback
    /// uses `declared` for the pinned Aether/FFmpeg manifest and lets Aether
    /// probe the exact stream at load time. Persistent downloads and the
    /// conservative Apple surfaces retain bounded `platform_attested` entries.
    let videoEvidence: String
    let audioEvidence: String
    let codecsVideo: [String]
    let codecsVideoHardware: [String]
    let codecsAudio: [String]
    let containers: [String]
    let maxResolution: String?
    let hdr: Bool
    let hdrDetails: PlaybackV3HDRCapabilities?
    let audioPassthrough: PlaybackV3AudioPassthrough?
    let videoDecode: [PlaybackV3VideoDecodeCapability]
}

struct PlaybackV3DeviceContext: Codable, Equatable {
    let platform: String
    let osVersion: String?
    let manufacturer: String?
    let model: String?
    /// Free-form platform-specific detail. Bounded by the server at 16 entries
    /// with keys and values of at most 128 characters each.
    let platformDetails: [String: String]
}

struct PlaybackV3OutputContext: Codable, Equatable {
    let hdrDetails: PlaybackV3HDRCapabilities?
    let audioPassthrough: PlaybackV3AudioPassthrough?
    let currentSink: String?
    let sinkType: String?
    /// Opaque token identifying the current output route. The server only ever
    /// compares it for equality, so any stable platform-native identity works.
    let outputContextId: String?
}

struct PlaybackV3NativeEmbeddedSubtitleCapability: Codable, Equatable {
    let container: String
    let codecs: [String]
    let trackIdentity: String
    let assStyling: Bool
    let fontAttachments: Bool
}

struct PlaybackV3DeliverySubtitleCapabilities: Codable, Equatable {
    var nativeEmbedded: [PlaybackV3NativeEmbeddedSubtitleCapability]? = nil
    let embeddedText: Bool
    let sidecarText: Bool
    let assStyling: Bool
    let embeddedBitmap: Bool
    let sidecarBitmap: Bool
    let fontAttachments: Bool
}

struct PlaybackV3Transformation: Codable, Equatable {
    let name: String
    let executor: String
    let recipeVersion: String
    let validatedClaims: [String]
}

struct PlaybackV3DeliveryCapability: Codable, Equatable {
    let enabled: Bool
    let supportedOnDevice: Bool
    let failureReason: String?
    let containers: [String]
    let videoCodecs: [String]
    let audioDecodeCodecs: [String]
    let audioPassthroughCodecs: [String]
    let maxChannels: Int?
    let hdrDetails: PlaybackV3HDRCapabilities?
    let subtitles: PlaybackV3DeliverySubtitleCapabilities
    let features: [String]
    let authHeaderRefresh: Bool
    let validatedClaims: [String]
    let transformations: [PlaybackV3Transformation]
}

struct PlaybackV3ClientContext: Codable, Equatable {
    let protocolVersion: Int
    let formFactor: String
    let appVersion: String
    /// `CFBundleVersion`. Optional so older/foreign contexts still decode.
    let appBuild: String?
    /// `dev` / `sideload` / `release`.
    let appChannel: String?
    let device: PlaybackV3DeviceContext
    let output: PlaybackV3OutputContext
    /// Keyed by delivery class, never by an engine name.
    let deliveries: [String: PlaybackV3DeliveryCapability]
}

struct PlaybackV3StartRequest: Codable, Equatable {
    let protocolVersion: Int
    let clientFeatures: [String]
    let fileId: Int
    let profileId: String
    let playbackAttemptId: String
    let qualityPreference: String
    let subtitleFidelityPreference: String
    /// `client` keeps session-local progress reporting active while leaving
    /// durable resume/history ownership to the client (audiobook timeline).
    /// Omission is the normal server-owned policy.
    let progressPersistence: String?
    let startPosition: Double?
    let audioTrackId: String?
    let audioTrackIndex: Int?
    let subtitleTrackId: String?
    let subtitleTrackIndex: Int?
    let metered: Bool
    let bandwidthEstimateKbps: Int?
    let bandwidthCapKbps: Int?
    let clientCapabilities: PlaybackV3CodecCapabilities
    let clientPlaybackContext: PlaybackV3ClientContext
    /// Room playback keeps one source timeline across all participant plans.
    var allowAlternateVersions: Bool? = nil
    /// `buffering_quality_v1` members, taken from a
    /// ``PlaybackV3BufferingQualityRequest``. The wire body sends them only
    /// alongside the feature.
    var bandwidthEstimateSource: String? = nil
    var learnedLimit: String? = nil
}

struct PlaybackV3TrackIdentity: Codable, Equatable {
    let id: String
    let index: Int?
}

struct PlaybackV3SelectedTracks: Codable, Equatable {
    let audio: PlaybackV3TrackIdentity?
    let subtitle: PlaybackV3TrackIdentity?
}

struct PlaybackV3Failure: Codable, Equatable {
    let classification: String
    let message: String?
    let decoderName: String?
}

struct PlaybackV3ReplanRequest: Codable, Equatable {
    let protocolVersion: Int
    let clientFeatures: [String]
    let operation: String
    let playbackAttemptId: String
    let replanRequestId: String
    let failedPlanId: String
    let planAttemptId: String
    /// The key the server minted for the plan being replaced, echoed verbatim.
    /// Clients never compute one.
    let planAttemptKey: String
    let attemptedPlanKeys: [String]
    let attemptCount: Int
    let qualityPreference: String
    let positionSeconds: Double
    let metered: Bool
    let bandwidthEstimateKbps: Int?
    let bandwidthCapKbps: Int?
    let selectedTracks: PlaybackV3SelectedTracks
    /// Absent for intent operations (`track_change`, `quality_change`) and
    /// `seek_reanchor`, which describe desired state rather than a failure.
    let failure: PlaybackV3Failure?
    /// Client-side state the server should fold into the next attempt key, so
    /// a locally-mutated route does not collide with the plan it replaced.
    let localMutations: [String]
    let clientCapabilities: PlaybackV3CodecCapabilities
    let clientPlaybackContext: PlaybackV3ClientContext
    /// `buffering_quality_v1` members, as on ``PlaybackV3StartRequest``.
    var bandwidthEstimateSource: String? = nil
    var learnedLimit: String? = nil
    /// The playing plan's throughput so far, sent only with
    /// `observed_rebuffer` (``PlaybackV3BufferingQualityRequest``).
    var observedThroughputKbps: Int? = nil
}

/// The client features and buffering-quality members of one start or replan.
///
/// The server refuses `bandwidth_estimate_source`, `learned_limit` and
/// `observed_throughput_kbps` unless `client_features` names
/// `buffering_quality_v1`, refuses a source without
/// `bandwidth_estimate_kbps`, and a throughput without the
/// `observed_rebuffer` source. Requests take these values from here, and the
/// v2 wire bodies apply ``permittedMembers`` again when they encode, so no
/// refused shape can be sent.
struct PlaybackV3BufferingQualityRequest: Equatable, Sendable {
    let clientFeatures: [String]
    let bandwidthEstimateKbps: Int?
    let bandwidthEstimateSource: String?
    let learnedLimit: String?
    /// What the playing plan received so far, measured as its
    /// `plan_summary` `throughput_kbps`. The server plans a lowering with the
    /// lower of this and the estimate.
    let observedThroughputKbps: Int?

    /// - Parameters:
    ///   - serverAdvertisesFeature: whether the server advertises
    ///     `buffering_quality_v1`. Without it the estimate is still sent, and
    ///     the two members are dropped.
    ///   - mode: the effective `playback.buffering_quality_mode`. In `never`
    ///     a request carries `learned_limit: "ignore"`, so a limit another
    ///     profile on this device learned does not lower its plans.
    ///   - learnedLimit: an explicit choice, which wins over the mode (Restore
    ///     quality sends `clear`).
    init(
        baseFeatures: [String],
        serverAdvertisesFeature: Bool,
        mode: BufferingQualityMode,
        bandwidthEstimateKbps: Int? = nil,
        bandwidthEstimateSource: String? = nil,
        learnedLimit: String? = nil,
        observedThroughputKbps: Int? = nil
    ) {
        let features = serverAdvertisesFeature && !baseFeatures.contains(PlaybackProtocolV3.bufferingQualityFeature)
            ? baseFeatures + [PlaybackProtocolV3.bufferingQualityFeature]
            : baseFeatures
        let permitted = Self.permittedMembers(
            clientFeatures: features,
            bandwidthEstimateKbps: bandwidthEstimateKbps,
            bandwidthEstimateSource: bandwidthEstimateSource,
            learnedLimit: learnedLimit ?? (mode == .never ? PlaybackProtocolV3.LearnedLimit.ignore : nil),
            observedThroughputKbps: observedThroughputKbps
        )
        clientFeatures = features
        self.bandwidthEstimateKbps = bandwidthEstimateKbps
        self.bandwidthEstimateSource = permitted.bandwidthEstimateSource
        self.learnedLimit = permitted.learnedLimit
        self.observedThroughputKbps = permitted.observedThroughputKbps
    }

    /// The members a request may carry: none without the feature in
    /// `clientFeatures`, no source without an estimate, and no throughput
    /// without the `observed_rebuffer` source.
    static func permittedMembers(
        clientFeatures: [String],
        bandwidthEstimateKbps: Int?,
        bandwidthEstimateSource: String?,
        learnedLimit: String?,
        observedThroughputKbps: Int? = nil
    ) -> (bandwidthEstimateSource: String?, learnedLimit: String?, observedThroughputKbps: Int?) {
        guard clientFeatures.contains(PlaybackProtocolV3.bufferingQualityFeature) else { return (nil, nil, nil) }
        let source = bandwidthEstimateKbps == nil ? nil : bandwidthEstimateSource
        let observed = source == PlaybackProtocolV3.BandwidthEstimateSource.observedRebuffer
            ? observedThroughputKbps
            : nil
        return (source, learnedLimit, observed)
    }
}

extension PlaybackV3ReplanRequest {
    /// This request with only the buffering-quality members the server accepts.
    var withPermittedBufferingQualityMembers: PlaybackV3ReplanRequest {
        var request = self
        (request.bandwidthEstimateSource, request.learnedLimit, request.observedThroughputKbps) =
            PlaybackV3BufferingQualityRequest.permittedMembers(
                clientFeatures: clientFeatures,
                bandwidthEstimateKbps: bandwidthEstimateKbps,
                bandwidthEstimateSource: bandwidthEstimateSource,
                learnedLimit: learnedLimit,
                observedThroughputKbps: observedThroughputKbps
            )
        return request
    }
}

struct PlaybackV3RouteEvent: Codable, Equatable {
    let protocolVersion: Int
    let playbackAttemptId: String
    let sessionId: String?
    let planId: String?
    let planAttemptId: String?
    let planAttemptKey: String?
    let event: String
    let failureClassification: String?
    let fallbackReason: String?
    let appliedQuirkIds: [String]
    let quirkRegistryRevision: String?
    let outputContextId: String?
    let diagnostics: [String: String]
}

/// What one plan did while it was the playing plan, as the `plan_summary`
/// route event carries it: sent when the plan is replaced, stopped or fails,
/// and only to a server that advertises `playback_plan_summary_v1`.
extension BufferingQualityController.PlanSummary {
    /// The event's diagnostics. Every value is a string, and an unknown
    /// estimate or bitrate is left out rather than sent as zero.
    var routeEventDiagnostics: [String: String] {
        var values = [
            "played_ms": String(max(0, playedMs)),
            "stall_count": String(max(0, stallCount)),
            "stall_total_ms": String(max(0, stallTotalMs)),
            "stall_longest_ms": String(max(0, stallLongestMs)),
            "buffering_mode": mode.wireValue,
            "buffering_action": action.rawValue,
        ]
        values["delivered_kbps"] = deliveredKbps.map(String.init)
        values["bandwidth_estimate_kbps"] = bandwidthEstimateKbps.map(String.init)
        values["throughput_kbps"] = throughputKbps.map(String.init)
        return values
    }
}

struct PlaybackV3Stream: Codable, Equatable {
    let url: String
    let `protocol`: String
    let container: String?
    let mimeType: String?
    let headers: [String: String]
    let headerRefresh: String
    let headerRefreshUrl: String?
}

struct PlaybackV3Timeline: Codable, Equatable {
    let sourceStartSeconds: Double
    let streamOriginSeconds: Double
    let playerStartSeconds: Double
    let timelineOffsetSeconds: Double
    let seekWindowStartSeconds: Double?
    let seekWindowEndSeconds: Double?
    let canSeekAnywhere: Bool
    let seekRestoration: String
}

struct PlaybackV3EffectiveRecipe: Codable, Equatable {
    let videoCodec: String?
    let audioCodec: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrateKbps: Int?
    let dynamicRange: String?
    let audioChannels: Int?
    let audioLayout: String?
}

struct PlaybackV3SourceDescriptor: Codable, Equatable {
    let mediaFileId: Int
    /// Full runtime of the source, or nil when the server does not know it.
    ///
    /// Optional so a server predating the field still decodes: every
    /// non-Optional property here is a required key, and a `keyNotFound`
    /// would fail the whole plan.
    ///
    /// This is the whole file, never `total - sourceStartSeconds` and never
    /// adjusted by `timelineOffsetSeconds`. Do not substitute the player's
    /// reported duration: on an HLS copy remux that is the window produced so
    /// far, not the runtime.
    let durationSeconds: Double?
    let container: String?
    let videoCodec: String?
    let videoProfile: String?
    let videoLevel: Int?
    let bitDepth: Int?
    let colorRange: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let bitrateKbps: Int?
    let dynamicRange: String?
    let hdr10Plus: Bool
    let dolbyVisionProfile: Int?
    let dvBlCompatId: Int?
    let dvEnhancementLayer: String
    let audioCodec: String?
    let audioChannels: Int?
    let audioLayout: String?
    let videoCopyUnsafe: Bool?
}

struct PlaybackV3VideoClaims: Codable, Equatable {
    let hdr10: Bool
    let hdr10Plus: Bool
    let hlg: Bool
    let dolbyVision: Bool
    let dolbyVisionReason: String?
}

struct PlaybackV3AudioClaims: Codable, Equatable {
    let codec: String?
    let passthrough: Bool
    let atmosPreserved: Bool
    let dtsVariant: String?
    let reason: String?
}

struct PlaybackV3SubtitleClaims: Codable, Equatable {
    let assStylingPreserved: Bool
    let bitmapOverlay: Bool
    let bitmapSidecar: Bool
    let reason: String?
}

struct PlaybackV3ValidationClaims: Codable, Equatable {
    let video: PlaybackV3VideoClaims
    let audio: PlaybackV3AudioClaims
    let subtitles: PlaybackV3SubtitleClaims
}

struct PlaybackV3SubtitleArtifact: Codable, Equatable {
    let url: String
    let mimeType: String
    let format: String
    let timingOriginSeconds: Double
}

/// One selectable subtitle track, as the server sees it.
///
/// `combinedIndex` is a dense server-assigned ordinal over embedded, external
/// and downloaded tracks together. It is not an index into any client-side
/// array.
struct PlaybackV3SubtitleInventoryItem: Codable, Equatable {
    let trackId: String
    let combinedIndex: Int
    let source: String
    let codec: String?
    let language: String?
    let label: String?
    let forced: Bool
    let `default`: Bool
    let hearingImpaired: Bool
    let delivery: String
    let url: String?
    let fontBundleUrl: String?
    /// Names the track to the subtitle sync operations; present on external
    /// and downloaded SRT, WebVTT, ASS, and SSA tracks. Opaque, and stable
    /// across sessions and inventory order.
    var syncKey: String? = nil
}

struct PlaybackV3EmbeddedSubtitle: Codable, Equatable {
    let streamIndex: Int
}

struct PlaybackV3SubtitleDecision: Codable, Equatable {
    let mode: String
    let trackId: String?
    let artifact: PlaybackV3SubtitleArtifact?
    var embedded: PlaybackV3EmbeddedSubtitle? = nil
    /// Authoritative list of every subtitle track for this plan. Select a track
    /// by echoing an entry's `trackId` or `combinedIndex` — never by counting
    /// tracks, summing arrays, or taking max(index) + 1.
    let inventory: [PlaybackV3SubtitleInventoryItem]
}

struct PlaybackV3AppliedQuirk: Codable, Equatable {
    let id: String
    let registryRevision: String
    let action: String
    let reason: String?
}

struct PlaybackV3DegradationWarning: Codable, Equatable {
    let code: String
    let message: String
}

struct PlaybackV3AvailableQuality: Codable, Equatable {
    let label: String
    /// Optional server-owned presentation label for compound quality rungs.
    let displayName: String?
    /// Audio-only quality rungs have no meaningful video height.
    let height: Int?
    let bitrateKbps: Int
    let preservesSource: Bool
}

struct PlaybackV3Plan: Codable, Equatable {
    let protocolVersion: Int
    let planId: String
    let sessionId: String?
    let expiresAt: String?
    let delivery: String
    /// Server-minted identity for this attempt. Echo it on replan and route
    /// events; the client never computes one.
    let planAttemptKey: String
    let stream: PlaybackV3Stream
    let timeline: PlaybackV3Timeline
    let selectedTracks: PlaybackV3SelectedTracks
    let effectiveRecipe: PlaybackV3EffectiveRecipe
    let claims: PlaybackV3ValidationClaims
    let subtitle: PlaybackV3SubtitleDecision
    let transformations: [PlaybackV3Transformation]
    let appliedQuirks: [PlaybackV3AppliedQuirk]
    let runtimeCorrections: [String]
    let degradationWarnings: [PlaybackV3DegradationWarning]
    let decisionReason: String
    let requestedMediaFileId: Int
    let effectiveMediaFileId: Int
    let source: PlaybackV3SourceDescriptor
    let subtitleFidelityPolicy: String
    /// Quality rungs the server will honour for a `quality_change` replan.
    let availableQualities: [PlaybackV3AvailableQuality]
    /// Present only when this device's learned limit lowered the plan.
    var bandwidthLimit: PlaybackV3BandwidthLimit? = nil
    /// The `availableQualities` label this plan delivers, when the server
    /// advertises `plan_active_quality_v1`; nil when it delivers none.
    var activeQuality: String? = nil
}

/// `playback_plan.bandwidth_limit`: the learned limit Auto planned under,
/// after repeated rebuffering on this device and connection.
struct PlaybackV3BandwidthLimit: Codable, Equatable, Sendable {
    let kbps: Int
    /// Always `observed_rebuffer` today.
    let source: String
    /// RFC 3339.
    let expiresAt: String
}

extension PlaybackV3Plan {
    /// The one inventory row this plan's subtitle decision names.
    ///
    /// Every consumer that needs "which row is selected" resolves it here so
    /// the picker, the load spec, the renewal intent and the session
    /// projection cannot disagree with each other. The order matches the
    /// shared Android resolver (`resolvedSelectedSubtitleIndex`):
    /// `selected_tracks.subtitle.index` is authoritative, then its stable
    /// `id`. The trailing `subtitle.track_id` match is Apple-only and last:
    /// it is the transitional shape this client already accepted and must
    /// keep accepting, but it never outranks the neutral identity.
    ///
    /// `subtitle.mode` is deliberately not consulted. A caller that must
    /// distinguish "off" from "selected but not locally rendered" — the
    /// picker — applies that gate itself.
    var selectedSubtitleInventoryItem: PlaybackV3SubtitleInventoryItem? {
        if let index = selectedTracks.subtitle?.index,
           let byIndex = subtitle.inventory.first(where: { $0.combinedIndex == index }) {
            return byIndex
        }
        if let id = selectedTracks.subtitle?.id,
           let byIdentity = subtitle.inventory.first(where: { $0.trackId == id }) {
            return byIdentity
        }
        if let trackId = subtitle.trackId {
            return subtitle.inventory.first { $0.trackId == trackId }
        }
        return nil
    }

    /// The selected combined ordinal, falling back to the wire index when the
    /// inventory names no row for it (a transitional plan can still be
    /// executable without publishing the row).
    var selectedSubtitleCombinedIndex: Int? {
        selectedSubtitleInventoryItem?.combinedIndex ?? selectedTracks.subtitle?.index
    }
}

struct PlaybackV3Terminal: Codable, Equatable {
    let reason: String
    let message: String
    let retryable: Bool
}

struct PlaybackV3DecisionResponse: Codable, Equatable {
    let protocolVersion: Int?
    let serverFeatures: [String]
    let outcome: String?
    let sessionId: String?
    let playbackPlan: PlaybackV3Plan?
    let terminal: PlaybackV3Terminal?
}

enum PlaybackV3DecisionValidation: Equatable {
    case playable(plan: PlaybackV3Plan, sessionId: String)
    case terminal(PlaybackV3Terminal)
    case incompatible(allocatedSessionId: String?)
}

extension PlaybackV3DecisionResponse {
    func validatedForApple() -> PlaybackV3DecisionValidation {
        guard protocolVersion == PlaybackProtocolV3.version,
              serverFeatures.contains(PlaybackProtocolV3.planFeature) else {
            return .incompatible(allocatedSessionId: sessionId)
        }
        if outcome == "adaptation_unavailable" {
            return .terminal(terminal ?? PlaybackV3Terminal(
                reason: "invalid_terminal_response",
                message: "The server could not produce a playable Apple route.",
                retryable: false
            ))
        }
        guard outcome == "playable",
              let plan = playbackPlan,
              plan.protocolVersion == PlaybackProtocolV3.version,
              let sessionId = plan.sessionId ?? sessionId,
              !sessionId.isEmpty,
              !plan.planId.isEmpty,
              !plan.stream.url.isEmpty,
              ["none", "session"].contains(plan.stream.headerRefresh) else {
            return .incompatible(allocatedSessionId: sessionId)
        }
        guard PlaybackProtocolV3.PlanDelivery.supported.contains(plan.delivery) else {
            return .incompatible(allocatedSessionId: sessionId)
        }
        return .playable(plan: plan, sessionId: sessionId)
    }
}
