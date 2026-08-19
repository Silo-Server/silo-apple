//
//  RecoveryDriver.swift
//
//  Stage 2 wave 2b — the ONE runtime caller of `RecoveryPolicy.decide`.
//
//  Before this wave a recovery decision could be taken in nine places (six
//  in-route ladders inside `AVPlayerBackend`, `handlePlaybackError`, the
//  origin-outage ride-through and the two session renewals in
//  `PlayerViewModel`), coordinated by a two-owner handshake. Wave 1B lifted
//  every constant and every rung into the pure `RecoveryPolicy`; this class is
//  the only thing that feeds it. One driver exists per `PlaybackEngineSession`,
//  i.e. per `LoadID`, which is what makes the context — and therefore every
//  latch, budget and rolling window that used to live as a mutable field on the
//  backend or the view model — load-scoped without a generation counter.
//
//  The driver decides nothing. It threads the context, mirrors a handful of
//  live inputs the policy cannot read for itself (`note…`), and reproduces the
//  *decision-point* log lines the ladders emitted where they decided, so a
//  console capture reads exactly as it did before. Execution belongs to
//  `AVPlayerBackend.perform(_:)` (in-route actions) and to `PlayerViewModel`
//  (session/transport actions).
//

import Foundation
import OSLog

/// Isolation mirrors the code it replaces (and `LocalHLSHost` from wave 2a):
/// a plain `final class`, because every ladder it absorbed was entered from a
/// nonisolated context — the backend's notification observers, its `RunLoop`
/// timers and the view model, none of which are actor isolated. Every caller
/// still drives it from the main queue, exactly as the ladders were driven.
final class RecoveryDriver {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "RecoveryDriver"
    )

    /// Reason key for the origin-outage ride-through — the string
    /// `AVPlayerBackend.originOutageRecoverySuspensionReason` carried.
    static let originOutageSuspensionReason = "origin_outage"
    /// Reason key for a view-model-owned server replan — the string
    /// `AVPlayerBackend.serverReplanRecoverySuspensionReason` carried.
    static let serverReplanSuspensionReason = "server_replan"

    /// The load's recovery state. Readable so the shell can *report* on a
    /// decision it did not take (the "ignoring playback error while server
    /// outage recovery is active" log line, the "Reconnected" notice's
    /// once-per-outage gate); never mutated from outside.
    private(set) var context: RecoveryContext

    /// Fired whenever `suspendedReasons` changes, so the backend's periodic
    /// `[CMP-AVP] loopback playhead state` telemetry can keep printing its
    /// `suspended=[…]` suffix. Diagnostics only — the latch itself is
    /// `context.suspendedReasons` and nothing else reads this.
    var onSuspensionChanged: ((Set<String>) -> Void)?

    /// The trigger that armed the item-death confirmation candidate, latched so
    /// the confirmed-path log lines can name it exactly as
    /// `performLoopbackItemDeathRecoveryAction` did. `noteExplicitFailure` arms
    /// `.failedToEnd`; the confirmation state arms `.unexpectedPause` exactly
    /// when it answers `.reassertPlay`.
    private var lastItemDeathTrigger = LoopbackItemDeathConfirmationState.Trigger.failedToEnd.rawValue

    init(route: PlaybackEngineKind) {
        context = .initial(route: route)
    }

    // MARK: - Decide

    /// The single recovery decision point. Everything else in the player either
    /// produces a `RecoveryObservation` or executes a `RecoveryAction`.
    @discardableResult
    func observe(_ observation: RecoveryObservation, now: Date = Date()) -> RecoveryAction? {
        let before = context
        let (action, next) = RecoveryPolicy.decide(observation, context: context, now: now)
        context = next
        if case .reassertPlay = action {
            lastItemDeathTrigger = LoopbackItemDeathConfirmationState.Trigger.unexpectedPause.rawValue
        }
        if case let .itemFailedToEnd(_, userPaused) = observation, !userPaused {
            lastItemDeathTrigger = LoopbackItemDeathConfirmationState.Trigger.failedToEnd.rawValue
        }
        logDecision(observation, action: action, before: before, now: now)
        return action
    }

    // MARK: - Suspension (the retired `setRecoverySuspended` handshake)

    /// Suspends (or resumes) every in-route recovery rung for one owner.
    /// Reference-counted by `reason`, exactly as the backend's latch was, so
    /// one owner clearing its reason does not release another owner's hold.
    func setSuspended(_ suspended: Bool, reason: String) {
        let changed = suspended
            ? context.suspendedReasons.insert(reason).inserted
            : (context.suspendedReasons.remove(reason) != nil)
        guard changed else { return }
        cmpLog(
            "[CMP-OUTAGE] recovery suspension \(suspended ? "on" : "off") reason=\(reason) "
            + "held=[\(context.suspendedReasons.sorted().joined(separator: ","))]"
        )
        onSuspensionChanged?(context.suspendedReasons)
    }

    /// Adopts another driver's live holds.
    ///
    /// The latch used to live on `AVPlayerBackend`, so it travelled with the
    /// backend *instance*: a same-engine replan reuses that instance, and the
    /// hold `attemptProtocolV3Replan` took before the round trip stayed on it
    /// until the replan's `defer`. Making the latch load-scoped would otherwise
    /// drop it the moment the replacement session adopts the backend, so the
    /// replacement inherits it and the same `defer` releases it.
    func adoptSuspensions(_ reasons: Set<String>) {
        for reason in reasons.sorted() {
            setSuspended(true, reason: reason)
        }
    }

    // MARK: - Live inputs the policy cannot read for itself

    func note(userPaused: Bool) {
        context.userPaused = userPaused
    }

    func note(playbackEstablished: Bool) {
        context.playbackEstablished = playbackEstablished
    }

    func note(mediaTimelineOffset: Double) {
        context.mediaTimelineOffset = mediaTimelineOffset
    }

    /// Refreshes the transport sample the notification-driven rungs read.
    ///
    /// `RecoveryPolicy` is pure, but the shared reanchor rung, the auto-resume
    /// rung and the item-death rung read the live player at the moment their
    /// notification fires rather than off the 1 Hz tick. The engine session
    /// therefore pulls a fresh sample from the backend immediately before every
    /// `observe`, which is what keeps those rungs reading the same values they
    /// read when they lived inside `AVPlayerBackend`.
    func note(playheadSample: PlayheadSample) {
        context.playhead.lastSample = playheadSample
    }

    /// The view-model-side preconditions of the failure ladder and the two
    /// renewals. Refreshed immediately before the observations that consume
    /// them, for the same reason `note(playheadSample:)` exists.
    func note(
        isProtocolV3Active: Bool,
        isReplanInFlight: Bool,
        hasWatchDetail: Bool,
        canRenewSourceInBackground: Bool,
        canAutoRecoverInterruption: Bool,
        canBuildLoopbackFallback: Bool,
        nearEnd: RecoveryContext.NearEndInputs?
    ) {
        context.isProtocolV3Active = isProtocolV3Active
        context.isReplanInFlight = isReplanInFlight
        context.hasWatchDetail = hasWatchDetail
        context.canRenewSourceInBackground = canRenewSourceInBackground
        context.canAutoRecoverInterruption = canAutoRecoverInterruption
        context.canBuildLoopbackFallback = canBuildLoopbackFallback
        context.nearEnd = nearEnd
    }

    // MARK: - Startup ladder arming

    /// `armLoopbackStartupWatchdogIfNeeded`'s state half: the backstop clock,
    /// the progress clock and the served-request baseline. The ladder's stage
    /// lives here from now on.
    func armStartupLadder(startedAt: Date, servedRequests: UInt64) {
        context.startup = RecoveryContext.StartupState(
            stage: .initial,
            startedAt: startedAt,
            lastProgressAt: startedAt,
            lastRequestCount: servedRequests
        )
    }

    /// A new engine load began on the same session (a reanchor, a rebuild, or
    /// the deferred `playlist_unchanged` recovery consumed by `play()`).
    ///
    /// Resets exactly what `AVPlayerBackend.load(strategy:)` and the
    /// `teardownMediaPipeline` it opens with reset — the advance tracker, the
    /// reanchor cooldown, the edge watch, the file-loaded edge and both
    /// item-death states. The reanchor retry budget (count / window /
    /// escalation latch) deliberately survives a reanchor and only resets on
    /// window expiry, so it is not touched here; neither is the rebuild budget,
    /// which only a new load resets.
    func noteEngineLoadStarted() {
        context.playbackEstablished = false
        context.playhead.lastAdvancePosition = nil
        context.playhead.stationarySince = nil
        context.playhead.lastStallRecoveryAt = nil
        context.playhead.lastSample = nil
        context.edge = nil
        // B:4312-4313 `teardownMediaPipeline`.
        context.itemDeath.reset()
        context.itemDeathConfirmation.reset()
    }

    // MARK: - Renewal outcomes

    /// The silent renewal succeeded: clear both single-flights and the
    /// transient budget (`attemptBackgroundSessionRenewal`'s success tail).
    func noteBackgroundRenewalSucceeded() {
        context.backgroundRenewalInFlight = false
        context.freshRenewalInFlight = false
        context.backgroundRenewalTransientFailures = 0
    }

    /// A silent renewal failed transiently. Returns whether the transient
    /// budget is now spent, i.e. whether the caller must escalate through
    /// `noteBackgroundRenewalExhausted()` — the limit lives in `RecoveryPolicy`
    /// and is read nowhere else.
    func noteBackgroundRenewalTransientFailure() -> Bool {
        context.backgroundRenewalInFlight = false
        context.backgroundRenewalTransientFailures += 1
        return context.backgroundRenewalTransientFailures
            >= RecoveryPolicy.backgroundRenewalTransientFailureLimit
    }

    /// A silent renewal failed in a way that escalates at once
    /// (`failBackgroundRenewal`). Puts the context in the state the policy's
    /// `.sessionMissing` arm reads as "the silent path is spent", so re-emitting
    /// the observation lands on the visible renewal with the
    /// `_bg_renewal_failed` suffix.
    func noteBackgroundRenewalExhausted() {
        context.backgroundRenewalInFlight = false
        context.backgroundRenewalTransientFailures =
            RecoveryPolicy.backgroundRenewalTransientFailureLimit
    }

    // MARK: - Visible server-outage recovery

    /// Drops the visible recovery's single-flight without deciding anything.
    ///
    /// The slot is the policy's form of `activeServerOutageRecoverySessionId`,
    /// which the failure ladder and the end-of-file gate read and which
    /// `clearServerOutageRecoveryState()` cleared alongside the task that owned
    /// the wait. It is also what an executor that bails on a load-state gate
    /// (end-of-file reached) has to give back, because legacy never latched it
    /// on that path.
    func clearServerOutageRecovery() {
        context.serverOutageRecovery = nil
    }

    // MARK: - Decision telemetry
    //
    // Each line below is the one the rung printed at the point it decided,
    // reproduced verbatim. They live here because this is now that point.

    private func logDecision(
        _ observation: RecoveryObservation,
        action: RecoveryAction?,
        before: RecoveryContext,
        now: Date
    ) {
        guard let action else {
            logNonAction(observation, before: before)
            return
        }
        switch action {
        case .reassertPlay:
            guard let sample = context.playhead.lastSample else { return }
            cmpLog(
                "[CMP-AVP] unexpected AVPlayer pause; reasserting play pos=\(sample.position) bufAhead=\(sample.bufferedAhead) generatedAhead=\(sample.generatedAhead)"
            )

        case .nudgeStartup:
            cmpLog("[CMP-AVP] startup watchdog stage=nudge trigger=\(startupTrigger(for: observation))")

        case .reloadStartupItem:
            cmpLog("[CMP-AVP] startup watchdog stage=reload trigger=\(startupTrigger(for: observation))")

        case let .reanchor(_, reason) where reason == "vod_stall_nudge":
            logPlayheadWatchdogTrigger(observation, before: before, now: now)

        case let .reloadItem(atMediaSeconds, reason):
            if reason == "vod_stall" {
                logPlayheadWatchdogTrigger(observation, before: before, now: now)
            } else {
                logItemDeathReload(observation, reason: reason, atMediaSeconds: atMediaSeconds)
            }

        case let .rebuildLocalSession(_, reason):
            logRebuild(observation, reason: reason, before: before, now: now)

        case .reanchor, .restartProducer, .deferUntilPlay, .resumePlayback,
             .treatAsNaturalEnd, .requestServerReplan, .switchRoute,
             .renewSourceInBackground, .renewSessionFresh, .rideThroughOutage,
             .endOutageRideThrough, .recoverFromServerOutage, .waitForServerReady,
             .autoRecoverInterruption, .fail:
            // Executed elsewhere and logged there, exactly as before.
            break
        }
    }

    /// The one rung whose "no action" outcome had a log line of its own:
    /// item-death evidence that has not reached the confirmation threshold
    /// (`performLoopbackItemDeathRecoveryAction`'s `.waitForConfirmation`).
    private func logNonAction(_ observation: RecoveryObservation, before: RecoveryContext) {
        guard case let .itemDeathEvidence(statusCode, description, _, position, userPaused) = observation,
              before.playbackEstablished,
              before.route == .siloPlayerLoopback,
              !before.isRecoverySuspended,
              LoopbackItemDeathRecoveryState.isItemDeath(
                statusCode: statusCode,
                errorDescription: description
              ) else { return }
        cmpLog(
            "[CMP-AVP] loopback item-death evidence waiting trigger=\(evidenceTrigger(statusCode)) status=\(statusCode ?? 0) userPaused=\(userPaused ? 1 : 0) pos=\(position) error=\(description)"
        )
    }

    private func logItemDeathReload(
        _ observation: RecoveryObservation,
        reason: String,
        atMediaSeconds: Double
    ) {
        // `reason` is `item_death_<trigger>_<attempt>` — the two values the
        // legacy line names, so they are read back out of it rather than
        // re-derived.
        let body = reason.dropFirst("item_death_".count)
        guard let separator = body.lastIndex(of: "_") else { return }
        let trigger = String(body[body.startIndex..<separator])
        let attempt = String(body[body.index(after: separator)...])
        let (statusCode, position) = itemDeathEvidenceFields(observation, fallback: atMediaSeconds)
        cmpLog(
            "[CMP-AVP] loopback item-death confirmed; reloading item trigger=\(trigger) status=\(statusCode) attempt=\(attempt) pos=\(position)"
        )
    }

    private func logRebuild(
        _ observation: RecoveryObservation,
        reason: String,
        before: RecoveryContext,
        now: Date
    ) {
        switch reason {
        case "loopback_item_death":
            let (statusCode, position) = itemDeathEvidenceFields(observation, fallback: 0)
            let trigger: String
            if case let .itemDeathEvidence(code, _, _, _, _) = observation {
                trigger = evidenceTrigger(code)
            } else {
                trigger = lastItemDeathTrigger
            }
            cmpLog(
                "[CMP-AVP] loopback item-death repeated at same position; rebuilding Silo loopback trigger=\(trigger) status=\(statusCode) pos=\(position)"
            )
        case "loopback_starvation":
            cmpLog(
                "[CMP-AVP] loopback starvation: playhead frozen \(Int(stationaryFor(before: before, now: now)))s with empty buffer and no segment serves; rebuilding Silo loopback"
            )
        case "playhead_watchdog":
            guard let sample = context.playhead.lastSample else { return }
            let reanchors = before.playhead.reanchorCount
            let stationary = stationaryFor(before: before, now: now)
            Self.logger.error(
                "[CMP-AVP] local loopback playhead_watchdog exhausted reanchors=\(reanchors, privacy: .public) pos=\(sample.position, privacy: .public) stationaryFor=\(stationary, privacy: .public); rebuilding Silo loopback"
            )
        default:
            break
        }
    }

    private func logPlayheadWatchdogTrigger(
        _ observation: RecoveryObservation,
        before: RecoveryContext,
        now: Date
    ) {
        // Only the 1 Hz tick's reanchor rung printed this; the seek-deadline
        // and outage-kick entries into the same recipe never did.
        guard case let .playheadTick(sample) = observation else { return }
        let attempt = context.playhead.reanchorCount
        let stationary = stationaryFor(before: before, now: now)
        Self.logger.error(
            "[CMP-AVP] local loopback playhead_watchdog trigger attempt=\(attempt, privacy: .public) pos=\(sample.position, privacy: .public) tc=\(Self.label(for: sample.timeControl), privacy: .public) bufAhead=\(sample.bufferedAhead, privacy: .public) generatedAhead=\(sample.generatedAhead, privacy: .public) stationaryFor=\(stationary, privacy: .public)"
        )
    }

    /// The tick's `stationaryFor` local: measured against the advance mark the
    /// *decision* saw, which the rungs never move.
    private func stationaryFor(before: RecoveryContext, now: Date) -> Double {
        context.playhead.stationarySince.map { now.timeIntervalSince($0) }
            ?? before.playhead.stationarySince.map { now.timeIntervalSince($0) }
            ?? 0
    }

    private func itemDeathEvidenceFields(
        _ observation: RecoveryObservation,
        fallback: Double
    ) -> (String, Double) {
        switch observation {
        case let .itemDeathEvidence(statusCode, _, _, position, _):
            return ("\(statusCode ?? 0)", position)
        case let .playheadTick(sample):
            // `loopbackPlayheadWatchdogTick` passed `statusCode: nil`.
            return ("0", sample.position)
        default:
            return ("0", fallback)
        }
    }

    /// `handleLoopbackItemDeathEvidence`'s `trigger` argument: the error log
    /// carries a status code, the failed-to-end tail does not.
    private func evidenceTrigger(_ statusCode: Int?) -> String {
        statusCode == nil ? "failed_to_end" : "error_log"
    }

    /// `escalateLoopbackStartupRecovery(trigger:)`'s argument: the 1 Hz tick's
    /// fetch-freeze verdict, or the item error log's `-15628` loader-poison
    /// signature.
    private func startupTrigger(for observation: RecoveryObservation) -> String {
        if case .itemDeathEvidence = observation { return "errorLog_-15628" }
        return "fetches_frozen"
    }

    private static func label(for timeControl: PlayheadSample.TimeControl) -> String {
        switch timeControl {
        case .paused: return "paused"
        case .waiting: return "waiting"
        case .playing: return "playing"
        case .unknown: return "unknown"
        }
    }
}
