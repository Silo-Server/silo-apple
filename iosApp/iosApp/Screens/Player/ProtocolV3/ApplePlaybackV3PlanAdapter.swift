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
    case unsupportedRuntimeCorrection(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDelivery(let value):
            return "The server selected an unsupported V3 delivery: \(value)."
        case .invalidTransport(let value):
            return "The V3 playback transport is invalid: \(value)."
        case .unsupportedClientTransformation(let value):
            return "The V3 plan requires an unsupported client transformation: \(value)."
        case .unsupportedRuntimeCorrection(let value):
            return "The V3 plan requires an unsupported runtime correction: \(value)."
        }
    }
}

enum ApplePlaybackV3PlanAdapter {
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
        if let transformation = plan.transformations.first(where: { $0.executor == "client" }) {
            // Aether owns its internal normalization pipeline. The app no
            // longer exposes or executes named client recipes.
            throw ApplePlaybackV3PlanError.unsupportedClientTransformation(transformation.name)
        }
        if let correction = plan.runtimeCorrections.first {
            // Runtime correction tokens belonged to the removed Silo
            // playback implementation. Aether performs recovery internally.
            throw ApplePlaybackV3PlanError.unsupportedRuntimeCorrection(correction)
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
