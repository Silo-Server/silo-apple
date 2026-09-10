import Foundation

/// Everything a replan request needs that can be derived without touching the
/// network, the device, or the bridge's mutable state.
struct PlaybackReplanRequestPlan: Equatable {
    let operation: String
    let isSeekReanchor: Bool
    /// A user intent (track/quality/output change) restarts the bounded route
    /// ladder instead of advancing it.
    let invalidatesIntent: Bool
    /// The response is required to describe the same route as the current plan.
    let preservesRoute: Bool
    let usesV2: Bool
    let attemptedPlanKeys: [String]
    let attemptCount: Int
    let selectedTracks: PlaybackV3SelectedTracks
    let clientQualityId: String
    let usesServerQualityPreference: Bool
    let qualityPreference: String
    let bandwidthCapKbps: Int?
    let position: Double
    /// The route event announcing that this replan was requested.
    let eventName: String
}

/// The pure classification step of a Protocol V3 replan: it maps the failure or
/// intent, the server's advertised capability, the attempt counters, and the
/// route ladder onto one of three answers, with no I/O and no bridge state.
enum PlaybackReplanDecision: Equatable {
    /// The active server cannot serve this operation at all, so the caller
    /// silently declines instead of reporting a failure.
    case unsupported
    /// The local ladder is exhausted before a request is worth sending.
    case terminal(PlaybackV3TerminalFailure)
    case request(PlaybackReplanRequestPlan)

    /// The client-side ceiling on one attempt's bounded route ladder.
    static let attemptCeiling = 8

    static func classify(
        active: ActiveProtocolV3,
        classification: String,
        requestedOperation: String?,
        usesV2: Bool,
        position: Double,
        qualityPreference: String?,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?
    ) -> PlaybackReplanDecision {
        // The intent mapping depends on what the server advertised for this
        // attempt, so it cannot be resolved by the caller ahead of time.
        let operation = requestedOperation ?? replanOperation(
            forClassification: classification,
            serverFeatures: active.serverFeatures
        )
        guard active.attemptCount < attemptCeiling else {
            return .terminal(PlaybackV3TerminalFailure(
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder.",
                retryable: false
            ))
        }

        let isIntent = operation == PlaybackProtocolV3.ReplanOperation.trackChange
            || operation == PlaybackProtocolV3.ReplanOperation.qualityChange
            || operation == PlaybackProtocolV3.ReplanOperation.outputChange
        let invalidatesIntent = isIntent || classification == "output_route_changed"
        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        let preservesRoute = isSeekReanchor
            || isV2SameRouteRecovery(operation: operation, usesV2: usesV2)
        if isSeekReanchor,
           !active.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            return .unsupported
        }
        let attemptedKeys = preservesRoute
            ? active.attemptedPlanKeys
            : invalidatesIntent
            ? []
            : Array(Set(active.attemptedPlanKeys + [active.planAttemptKey])).sorted()

        let selectedFileId = active.plan.effectiveMediaFileId
        let selectedAudio = (preservesRoute ? nil : audioTrackIndex).flatMap { index in
            trackIdentity(fileId: selectedFileId, kind: "audio", index: index)
        } ?? active.plan.selectedTracks.audio
        let selectedSubtitle: PlaybackV3TrackIdentity? = {
            if preservesRoute { return active.plan.selectedTracks.subtitle }
            if classification == "subtitle_track_changed" {
                return subtitleTrackIndex.flatMap { index in
                    trackIdentity(fileId: selectedFileId, kind: "subtitle", index: index)
                }
            }
            return active.plan.selectedTracks.subtitle
        }()

        let qualitySelection = qualityPreference.map {
            ApplePlaybackQuality.protocolV3Selection(
                requestedQualityId: $0,
                availableQualities: active.plan.availableQualities
            )
        }
        let clientQualityId = qualitySelection?.clientQualityId ?? active.clientQualityId
        let usesServerQualityPreference = qualitySelection?.isServerOwned
            ?? active.usesServerQualityPreference

        return .request(PlaybackReplanRequestPlan(
            operation: operation,
            isSeekReanchor: isSeekReanchor,
            invalidatesIntent: invalidatesIntent,
            preservesRoute: preservesRoute,
            usesV2: usesV2,
            attemptedPlanKeys: attemptedKeys,
            attemptCount: invalidatesIntent ? 1 : active.attemptCount,
            selectedTracks: PlaybackV3SelectedTracks(
                audio: selectedAudio,
                subtitle: selectedSubtitle
            ),
            clientQualityId: clientQualityId,
            usesServerQualityPreference: usesServerQualityPreference,
            qualityPreference: qualitySelection?.serverPreference
                ?? (usesServerQualityPreference
                    ? clientQualityId
                    : PlaybackContentSelection.protocolV3QualityPreference(clientQualityId)),
            bandwidthCapKbps: qualitySelection.map(\.bandwidthCapKbps) ?? active.bandwidthCapKbps,
            position: position.isFinite ? max(0, position) : 0,
            eventName: isSeekReanchor
                ? "seek_reanchor_requested"
                : (invalidatesIntent ? "plan_invalidated" : "plan_failed")
        ))
    }

    private static func trackIdentity(
        fileId: Int,
        kind: String,
        index: Int
    ) -> PlaybackV3TrackIdentity? {
        guard index >= 0 else { return nil }
        return PlaybackV3TrackIdentity(
            id: PlaybackContentSelection.protocolV3TrackId(
                fileId: fileId,
                kind: kind,
                index: index
            ),
            index: index
        )
    }

    // MARK: - Protocol mapping

    /// Maps a local failure/intent classification onto the protocol's replan
    /// operation. A user-initiated track or quality change is an intent, not a
    /// failure, and carries no `failure` block.
    ///
    /// An output-route change is an intent too: the device never rejected the
    /// plan, the display it was chosen for did. §6 gives `output_change`
    /// exactly that meaning — it keeps the previous route eligible, where
    /// `failure_recovery` excludes the current plan key and so forces a
    /// different route even when the new sink can still play it.
    ///
    /// That operation only exists on a server advertising `output_change_v1`;
    /// an older one rejects it as an invalid operation, so the historical
    /// failure-recovery spelling remains the fallback there. Omitting
    /// `serverFeatures` means exactly that older server.
    static func replanOperation(
        forClassification classification: String,
        serverFeatures: [String] = []
    ) -> String {
        switch classification {
        case "audio_track_changed", "subtitle_track_changed":
            return PlaybackProtocolV3.ReplanOperation.trackChange
        case "quality_changed":
            return PlaybackProtocolV3.ReplanOperation.qualityChange
        case "output_route_changed"
            where serverFeatures.contains(PlaybackProtocolV3.outputChangeFeature):
            return PlaybackProtocolV3.ReplanOperation.outputChange
        default:
            return PlaybackProtocolV3.ReplanOperation.failureRecovery
        }
    }

    static func replanFailure(
        operation: String,
        classification: String,
        message: String
    ) -> PlaybackV3Failure? {
        switch operation {
        case PlaybackProtocolV3.ReplanOperation.trackChange,
             PlaybackProtocolV3.ReplanOperation.qualityChange,
             // The server rejects an `output_change` that carries a failure:
             // "output_change must not include failure".
             PlaybackProtocolV3.ReplanOperation.outputChange,
             PlaybackProtocolV3.ReplanOperation.seekReanchor:
            return nil
        default:
            return PlaybackV3Failure(
                classification: classification,
                message: String(message.prefix(512)),
                decoderName: nil
            )
        }
    }

    static func isV2SameRouteRecovery(operation: String, usesV2: Bool) -> Bool {
        usesV2 && [PlaybackProtocolV3.ReplanOperation.failureRecovery,
                   PlaybackProtocolV3.ReplanOperation.seekFailureRecovery,
                   PlaybackProtocolV3.ReplanOperation.seekReanchor].contains(operation)
    }

    static func replanPreservesAttempt(operation: String, usesV2: Bool,
        currentSessionID: String, nextSessionID: String,
        current: PlaybackV3Plan, next: PlaybackV3Plan,
        attemptedKeys: [String], responseFeatures: [String]) throws -> Bool {
        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        let v2SameRoute = isV2SameRouteRecovery(operation: operation, usesV2: usesV2)
        let preservesRoute = isSeekReanchor || v2SameRoute
        guard preservesRoute || !attemptedKeys.contains(next.planAttemptKey) else {
            throw PlaybackV3TerminalFailure(reason: "replan_loop_detected",
                message: "The server returned a protocol V3 plan that already failed on this output route.", retryable: false)
        }
        if preservesRoute {
            guard currentSessionID == nextSessionID,
                  (v2SameRoute || responseFeatures.contains(PlaybackProtocolV3.seekReanchorFeature)),
                  (!v2SameRoute || (next.planId == current.planId
                    && next.effectiveMediaFileId == current.effectiveMediaFileId
                    && next.requestedMediaFileId == current.requestedMediaFileId
                    && next.source == current.source
                    && next.stream.protocol == current.stream.protocol
                    && next.stream.container == current.stream.container)),
                  next.planAttemptKey == current.planAttemptKey,
                  next.delivery == current.delivery,
                  next.effectiveRecipe == current.effectiveRecipe,
                  next.selectedTracks == current.selectedTracks,
                  next.transformations == current.transformations,
                  next.appliedQuirks == current.appliedQuirks,
                  next.runtimeCorrections == current.runtimeCorrections else {
                throw PlaybackV3TerminalFailure(reason: "invalid_seek_reanchor_response",
                    message: "The server changed the route or playback intent during a V3 seek re-anchor.", retryable: false)
            }
        }
        return preservesRoute
    }
}
