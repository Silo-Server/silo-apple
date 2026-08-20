import Foundation

struct PreparedPlaybackV3: Equatable {
    let playbackAttemptId: String
    let planAttemptId: String
    let planAttemptKey: String
    let outputContextId: String?
    let serverFeatures: [String]
    let plan: PlaybackV3Plan
}

enum ApplePlaybackV3PlanError: LocalizedError, Equatable {
    case unsupportedDelivery(String)
    case invalidTransport(String)
    case unsupportedClientTransformation(String)
    case invalidClientTransformation(String)
    case unsupportedRuntimeCorrection(String)
    case localVideoDecodeUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedDelivery(let value):
            return "The server selected an unsupported V3 delivery: \(value)."
        case .invalidTransport(let value):
            return "The V3 playback transport is invalid: \(value)."
        case .unsupportedClientTransformation(let value):
            return "The V3 plan requires an unsupported client transformation: \(value)."
        case .invalidClientTransformation(let value):
            return "The V3 client transformation cannot be executed as planned: \(value)."
        case .unsupportedRuntimeCorrection(let value):
            return "The V3 plan requires an unsupported runtime correction: \(value)."
        case .localVideoDecodeUnavailable:
            return "This H.264 High 10 source exceeds the validated local software-decoder limits."
        }
    }
}

enum ApplePlaybackV3PlanAdapter {
    private static let clientTransformations = ["client_dv7_to_dv81", "client_dv7_to_hdr10"]
    private static let runtimeCorrections = [
        "client_dv8_hdr10plus_sanitizer_v1",
        "client_post_resume_video_recovery_v1",
        "client_surface_recovery_v1"
    ]

    static func validate(_ plan: PlaybackV3Plan) throws {
        guard PlaybackProtocolV3.PlanDelivery.supported.contains(plan.delivery) else {
            throw ApplePlaybackV3PlanError.unsupportedDelivery(plan.delivery)
        }
        guard !plan.stream.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlaybackV3PlanError.invalidTransport("empty stream URL")
        }
        guard ["none", "session"].contains(plan.stream.headerRefresh) else {
            throw ApplePlaybackV3PlanError.invalidTransport(
                "unsupported header refresh mode \(plan.stream.headerRefresh)"
            )
        }
        if plan.stream.protocol == "hls" {
            guard plan.delivery == "server_remux_hls" || plan.delivery == "server_transcode_hls" else {
                throw ApplePlaybackV3PlanError.invalidTransport("HLS protocol/delivery mismatch")
            }
        } else if plan.stream.protocol == "http_progressive" {
            guard plan.delivery == "original_http" || plan.delivery == "server_remux_progressive" else {
                throw ApplePlaybackV3PlanError.invalidTransport("progressive protocol/delivery mismatch")
            }
        } else {
            throw ApplePlaybackV3PlanError.invalidTransport("unsupported protocol \(plan.stream.protocol)")
        }
        if let unsupported = plan.transformations.first(where: {
            $0.executor == "client" && !clientTransformations.contains($0.name)
        }) {
            throw ApplePlaybackV3PlanError.unsupportedClientTransformation(unsupported.name)
        }
        let selectedClientTransformations = plan.transformations.filter { $0.executor == "client" }
        if selectedClientTransformations.count > 1 {
            throw ApplePlaybackV3PlanError.invalidClientTransformation(
                "multiple mutually exclusive client transformations"
            )
        }
        if !selectedClientTransformations.isEmpty && plan.delivery != "original_http" {
            throw ApplePlaybackV3PlanError.invalidClientTransformation(
                "client transformations require the original_http delivery"
            )
        }
        if let unsupported = plan.runtimeCorrections.first(where: { !runtimeCorrections.contains($0) }) {
            throw ApplePlaybackV3PlanError.unsupportedRuntimeCorrection(unsupported)
        }
    }

    static func playbackSession(
        plan: PlaybackV3Plan,
        sessionId: String,
        selectedVersion: FileVersion,
        serverFeatures: [String]
    ) -> PlaybackSessionResponse {
        var subtitleUrls = plan.subtitle.inventory.compactMap { item -> SubtitleUrl? in
            guard item.delivery == "sidecar",
                  let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else {
                return nil
            }
            return SubtitleUrl(
                index: item.combinedIndex,
                language: item.language,
                codec: item.codec,
                label: item.label,
                source: item.source,
                forced: item.forced,
                default: item.default,
                hearingImpaired: item.hearingImpaired,
                fontBundleUrl: item.fontBundleUrl,
                url: url
            )
        }
        // Inventory is authoritative in the neutral contract. Keep a narrow
        // fallback for a selected sidecar artifact so an otherwise executable
        // plan does not lose its active subtitle if a transitional server
        // omitted that one inventory URL.
        if let artifact = plan.subtitle.artifact,
           let selectedIndex = plan.selectedTracks.subtitle?.index,
           !subtitleUrls.contains(where: { $0.index == selectedIndex }) {
            let selected = plan.selectedTracks.subtitle?.index.flatMap {
                subtitleTrack(atServerCombinedIndex: $0, in: selectedVersion)
            }
            subtitleUrls.append(SubtitleUrl(
                index: selectedIndex,
                language: selected?.language,
                codec: artifact.format,
                label: selected?.title,
                source: selected.map { $0.external == true ? "external" : "embedded" } ?? "protocol_v3",
                forced: selected?.forced,
                default: selected?.isDefault,
                hearingImpaired: selected?.hearingImpaired,
                fontBundleUrl: nil,
                url: artifact.url
            ))
        }
        let durationSeconds: Double?
        if serverFeatures.contains(PlaybackProtocolV3.planSourceDurationFeature) {
            // Presence of the feature makes nil authoritative: the server
            // knows the field but could not determine this source's runtime.
            durationSeconds = plan.source.durationSeconds
        } else {
            // Transitional servers predate the field, so the catalog value is
            // still the only duration evidence available.
            durationSeconds = plan.source.durationSeconds ?? selectedVersion.duration
        }
        return PlaybackSessionResponse(
            sessionId: sessionId,
            userId: nil,
            profileId: nil,
            mediaFileId: plan.effectiveMediaFileId,
            playMethod: deliveryStrategy(plan.delivery).name,
            position: max(0, plan.timeline.playerStartSeconds),
            isPaused: false,
            streamUrl: plan.stream.url,
            audioTrackIndex: plan.selectedTracks.audio?.index,
            durationSeconds: durationSeconds,
            timelineOffsetSeconds: max(0, plan.timeline.timelineOffsetSeconds),
            subtitleUrls: subtitleUrls,
            playbackInfo: PlaybackInfo(
                streamType: plan.stream.protocol,
                transcodeAudio: plan.transformations.contains { $0.name == "audio_to_aac" },
                videoCodec: plan.effectiveRecipe.videoCodec,
                audioCodec: plan.effectiveRecipe.audioCodec
            )
        )
    }

    /// V3 subtitle identities are external-first combined ordinals. Apple’s
    /// embedded picker carries FFmpeg stream indices instead, and watch detail
    /// lists embedded tracks before external tracks, so the wire identity must
    /// be translated rather than copied.
    static func serverCombinedSubtitleIndex(
        ffmpegStreamIndex: Int,
        in version: FileVersion
    ) -> Int? {
        guard ffmpegStreamIndex >= 0 else { return nil }
        let tracks = version.subtitleTracks ?? []
        let externalCount = tracks.filter { $0.external == true }.count
        let embedded = tracks.filter { $0.external != true }
        guard let embeddedOrdinal = embedded.firstIndex(where: {
            $0.index == ffmpegStreamIndex
        }) else {
            return nil
        }
        return externalCount + embeddedOrdinal
    }

    static func serverCombinedSubtitleIndex(
        for playerTrack: PlayerTrack,
        in version: FileVersion
    ) -> Int? {
        if playerTrack.isExternal {
            return playerTrack.srcId.flatMap { $0 >= 0 ? $0 : nil }
        }
        guard let ffmpegStreamIndex = playerTrack.ffIndex else { return nil }
        return serverCombinedSubtitleIndex(
            ffmpegStreamIndex: ffmpegStreamIndex,
            in: version
        )
    }

    static func ffmpegSubtitleStreamIndex(
        serverCombinedIndex: Int,
        in version: FileVersion
    ) -> Int? {
        guard serverCombinedIndex >= 0 else { return nil }
        let tracks = version.subtitleTracks ?? []
        let externalCount = tracks.filter { $0.external == true }.count
        let embedded = tracks.filter { $0.external != true }
        let embeddedOrdinal = serverCombinedIndex - externalCount
        guard embedded.indices.contains(embeddedOrdinal) else { return nil }
        return embedded[embeddedOrdinal].index
    }

    static func makeExecutionPlan(
        v3: PreparedPlaybackV3,
        basePlan: PlaybackExecutionPlan,
        streamRequest: StreamRequest,
        routeRequirements: PlaybackRouteRequirements,
        supportsH264High10SoftwareDecode: Bool =
            ApplePlaybackV3Capabilities.supportsValidatedH264High10DeviceClass()
    ) throws -> PlaybackExecutionPlan {
        try validate(v3.plan)
        let plan = v3.plan
        let delivery = deliveryStrategy(plan.delivery)
        var engine: PlaybackEngineKind
        var loopbackSession: LoopbackSessionSpec?
        switch plan.delivery {
        case "original_http":
            // The V3 direct slot describes delivery, while the existing Apple
            // planner chooses the concrete local executor for that source.
            // The source descriptor is authoritative for the granted plan and
            // can be more complete than the catalog item used by the legacy
            // planner. High 10 must never fall back to AVPlayer when catalog
            // video tracks are absent or stale.
            if requiresSoftwareH264Decode(plan.source) {
                guard AppleH264High10SoftwareDecodePolicy.supports(
                    high10SourceFacts(plan.source),
                    deviceSupported: supportsH264High10SoftwareDecode
                ) else {
                    throw ApplePlaybackV3PlanError.localVideoDecodeUnavailable
                }
                engine = .playerCoreDirect
                loopbackSession = nil
            } else {
                engine = basePlan.engine
                loopbackSession = basePlan.loopbackSession
            }
        case "server_remux_progressive":
            engine = .avPlayerNativeDirect
            loopbackSession = nil
        case "server_remux_hls", "server_transcode_hls":
            engine = .avPlayerHLS
            loopbackSession = nil
        default:
            throw ApplePlaybackV3PlanError.unsupportedDelivery(plan.delivery)
        }

        if let transformation = plan.transformations.first(where: { $0.executor == "client" }) {
            guard let baseLoopbackSession = basePlan.loopbackSession else {
                throw ApplePlaybackV3PlanError.invalidClientTransformation(
                    "\(transformation.name) requires the Apple loopback executor"
                )
            }
            engine = .siloPlayerLoopback
            loopbackSession = forcedLoopbackSession(
                baseLoopbackSession,
                transformation: transformation.name
            )
        }

        let routeCapabilities = engine.routeCapabilities
        let sourceMetadata = PlaybackSourceMetadata(
            container: plan.source.container,
            videoCodec: plan.source.videoCodec,
            audioCodec: plan.source.audioCodec,
            subtitleCodecs: basePlan.sourceMetadata.subtitleCodecs,
            dolbyVisionProfile: plan.source.dolbyVisionProfile,
            // Prefer the server's probed source fact. Catalog metadata remains
            // the compatibility fallback for plans that omit color_range.
            colorRange: plan.source.colorRange ?? basePlan.sourceMetadata.colorRange,
            frameRate: plan.source.frameRate,
            bitrateKbps: plan.source.bitrateKbps
        )
        let transformationTokens = plan.transformations.map {
            "v3_transform_\($0.executor)_\($0.name)_\($0.recipeVersion)"
        }
        let quirkTokens = plan.appliedQuirks.map { "v3_quirk_\($0.registryRevision)_\($0.id)" }
        let correctionTokens = plan.runtimeCorrections.map { "v3_runtime_correction_\($0)" }
        let warnings = plan.degradationWarnings.map { "\($0.code): \($0.message)" }
        let normalization = PlaybackNormalizationSummary(
            containerMode: plan.delivery == "original_http" ? basePlan.normalizationSummary.containerMode : plan.delivery,
            videoMode: plan.effectiveRecipe.videoCodec ?? "copy",
            audioMode: plan.effectiveRecipe.audioCodec
                ?? (plan.source.audioCodec == nil ? "none" : "copy"),
            subtitleMode: plan.subtitle.mode
        )

        return PlaybackExecutionPlan(
            delivery: delivery,
            engine: engine,
            startMode: .absolutePosition(max(0, plan.timeline.playerStartSeconds)),
            streamRequest: streamRequest,
            sourceStreamRequest: streamRequest,
            loopbackSession: engine == .siloPlayerLoopback ? loopbackSession : nil,
            capabilities: routeCapabilities.backendCapabilities,
            routeCapabilities: routeCapabilities,
            requirements: routeRequirements,
            featureFlagEnabled: true,
            parityBlockers: routeCapabilities.blockingReasons(for: routeRequirements),
            decisionTrace: basePlan.decisionTrace + [
                "protocol_v3", "v3_plan_\(plan.planId)", "v3_delivery_\(plan.delivery)"
            ] + transformationTokens + quirkTokens + correctionTokens,
            degradationWarnings: warnings + routeCapabilities.degradationNotes(for: routeRequirements),
            reason: "v3_\(plan.decisionReason)",
            playbackSessionId: plan.sessionId,
            wireDelivery: plan.delivery,
            serverFeatures: v3.serverFeatures,
            sourceMetadata: sourceMetadata,
            normalizationSummary: normalization
        )
    }

    private static func requiresSoftwareH264Decode(
        _ source: PlaybackV3SourceDescriptor
    ) -> Bool {
        AppleH264High10SoftwareDecodePolicy.requiresSoftwareDecode(
            codec: source.videoCodec,
            bitDepth: source.bitDepth,
            profile: source.videoProfile
        )
    }

    private static func high10SourceFacts(
        _ source: PlaybackV3SourceDescriptor
    ) -> AppleH264High10SourceFacts {
        AppleH264High10SourceFacts(
            codec: source.videoCodec,
            profile: source.videoProfile,
            level: source.videoLevel,
            bitDepth: source.bitDepth,
            width: source.width,
            height: source.height,
            frameRate: source.frameRate,
            bitrateKbps: source.bitrateKbps
        )
    }

    private static func forcedLoopbackSession(
        _ base: LoopbackSessionSpec,
        transformation: String
    ) -> LoopbackSessionSpec {
        let videoMode: LoopbackSessionSpec.VideoMode
        let manifestMetadata: LoopbackSessionSpec.ManifestMetadata
        switch transformation {
        case "client_dv7_to_dv81":
            videoMode = .convertProfile7To81
            manifestMetadata = LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: 8,
                compatibilityBrand: "db1p",
                videoRange: "PQ",
                mayClaimAtmos: base.manifestMetadata.mayClaimAtmos
            )
        default:
            videoMode = .passthroughHEVC
            manifestMetadata = LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "PQ",
                mayClaimAtmos: base.manifestMetadata.mayClaimAtmos
            )
        }
        return LoopbackSessionSpec(
            sourceURL: base.sourceURL,
            headers: base.headers,
            sourceStartTimeSeconds: base.sourceStartTimeSeconds,
            sourceBitrateBps: base.sourceBitrateBps,
            videoMode: videoMode,
            sourceVideoFrameRate: base.sourceVideoFrameRate,
            selectedAudio: base.selectedAudio,
            availableAudioTracks: base.availableAudioTracks,
            manifestMetadata: manifestMetadata,
            servingMode: base.servingMode
        )
    }

    private static func subtitleTrack(
        atServerCombinedIndex index: Int,
        in version: FileVersion
    ) -> SubtitleTrack? {
        guard index >= 0 else { return nil }
        let tracks = version.subtitleTracks ?? []
        let external = tracks.filter { $0.external == true }
        let embedded = tracks.filter { $0.external != true }
        let combined = external + embedded
        guard combined.indices.contains(index) else { return nil }
        return combined[index]
    }

    private static func deliveryStrategy(_ value: String) -> PlaybackDeliveryStrategy {
        switch value {
        case "server_remux_hls", "server_remux_progressive":
            return .remux
        case "server_transcode_hls":
            return .transcode
        default:
            return .direct
        }
    }
}
