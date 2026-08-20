//
//  LoopbackRecoveryStates.swift
//
//  The three value types the recovery owner threads on `RecoveryContext`:
//  the rebuild budget and the two item-death state machines. They live with the
//  policy that owns every instance and every mutation of them
//  (`RecoveryContext.rebuildBudget` / `.itemDeath` / `.itemDeathConfirmation`,
//  mutated only by `RecoveryPolicy` and `RecoveryDriver`); `AVPlayerBackend`
//  executes the actions they produce and reads none of their state.
//
//  All three are `Equatable` so `RecoveryContext` can synthesise its own
//  conformance, which is what a policy test compares two contexts with.
//

import Foundation

/// Session-scoped budget for full Silo loopback session rebuilds.
///
/// The starvation/exhaustion latch that guards a rebuild
/// (`RecoveryContext.PlayheadState.didEscalateStarvation`) is cleared *by* the
/// rebuild it guards, so on its own it bounds nothing across sessions: a title
/// that wedges the same way every time rebuilds forever. The budget is the
/// outer bound — once it is spent the recovery owner reports the failure and
/// the failure ladder owns the decision.
struct LoopbackRebuildBudget: Equatable {
    static let maximumRebuildsPerLoad = 2

    private(set) var used = 0

    var isExhausted: Bool { used >= Self.maximumRebuildsPerLoad }

    /// Spends one rebuild. Returns false when the budget is exhausted, in
    /// which case the caller must not rebuild.
    mutating func consume() -> Bool {
        guard !isExhausted else { return false }
        used += 1
        return true
    }

    mutating func reset() {
        used = 0
    }
}

struct LoopbackItemDeathRecoveryState: Equatable {
    enum Action: Equatable {
        case waitForConfirmation
        case reload(attempt: Int)
        case escalate
    }

    static let matchingPositionToleranceSeconds = 2.0
    static let evidenceRequired = 2
    static let maximumReloads = 1

    private var anchorPosition: Double?
    private var evidence = 0
    private var reloads = 0

    static func isItemDeath(statusCode: Int?, errorDescription: String) -> Bool {
        statusCode == -12889
            || statusCode == -15628
            || errorDescription.contains("-12889")
            || errorDescription.contains("No response for media file")
    }

    mutating func record(
        position: Double,
        evidenceWeight: Int,
        userPaused: Bool
    ) -> Action {
        guard !userPaused else { return .waitForConfirmation }
        let normalized = position.isFinite ? max(0, position) : 0
        if let anchorPosition,
           abs(anchorPosition - normalized) > Self.matchingPositionToleranceSeconds {
            evidence = 0
            reloads = 0
        }
        anchorPosition = normalized
        evidence += max(evidenceWeight, 1)
        guard evidence >= Self.evidenceRequired else { return .waitForConfirmation }
        evidence = 0
        return confirm(position: normalized, userPaused: userPaused)
    }

    mutating func confirm(position: Double, userPaused: Bool) -> Action {
        guard !userPaused else { return .waitForConfirmation }
        let normalized = position.isFinite ? max(0, position) : 0
        if let anchorPosition,
           abs(anchorPosition - normalized) > Self.matchingPositionToleranceSeconds {
            reloads = 0
        }
        anchorPosition = normalized
        evidence = 0
        guard reloads < Self.maximumReloads else { return .escalate }
        reloads += 1
        return .reload(attempt: reloads)
    }

    mutating func reset() {
        anchorPosition = nil
        evidence = 0
        reloads = 0
    }
}

/// Confirms AVFoundation's terminal-item failure mode without mistaking an
/// intentional pause for a dead item. A failed item can remain `.readyToPlay`
/// while AVPlayer parks at rate 0 / `.paused`, so item status alone is not a
/// useful health signal. The explicit play-intent latch is authoritative.
struct LoopbackItemDeathConfirmationState: Equatable {
    enum Trigger: String, Equatable {
        case failedToEnd = "failed_to_end"
        case unexpectedPause = "unexpected_pause"
    }

    enum TransportState: Equatable {
        case paused
        case waiting
        case playing
        case unknown
    }

    enum Action: Equatable {
        case none
        case reassertPlay
        case confirmed(trigger: Trigger)
    }

    static let confirmationSeconds = 3.0
    static let progressCancellationThresholdSeconds = 0.5

    private struct Candidate: Equatable {
        let trigger: Trigger
        let position: Double
        let startedAt: Double
    }

    private var candidate: Candidate?

    mutating func noteExplicitFailure(
        position: Double,
        now: Double,
        playbackEstablished: Bool,
        userPaused: Bool
    ) {
        guard playbackEstablished, !userPaused else {
            candidate = nil
            return
        }
        candidate = Candidate(
            trigger: .failedToEnd,
            position: normalized(position),
            startedAt: now
        )
    }

    mutating func evaluate(
        now: Double,
        position: Double,
        playbackEstablished: Bool,
        userPaused: Bool,
        transportState: TransportState,
        recoverySuppressed: Bool,
        mediaAvailableAhead: Bool
    ) -> Action {
        guard playbackEstablished, !userPaused, !recoverySuppressed else {
            candidate = nil
            return .none
        }

        let currentPosition = normalized(position)
        if let candidate {
            if abs(currentPosition - candidate.position)
                > Self.progressCancellationThresholdSeconds {
                self.candidate = nil
                return .none
            }
            if candidate.trigger == .unexpectedPause, transportState != .paused {
                self.candidate = nil
                return .none
            }
            guard now - candidate.startedAt >= Self.confirmationSeconds else {
                return .none
            }
            self.candidate = nil
            if candidate.trigger == .failedToEnd, transportState == .playing {
                return .none
            }
            return .confirmed(trigger: candidate.trigger)
        }

        guard transportState == .paused, mediaAvailableAhead else { return .none }
        candidate = Candidate(
            trigger: .unexpectedPause,
            position: currentPosition,
            startedAt: now
        )
        return .reassertPlay
    }

    mutating func resetCandidate() {
        candidate = nil
    }

    mutating func reset() {
        candidate = nil
    }

    private func normalized(_ position: Double) -> Double {
        position.isFinite ? max(0, position) : 0
    }
}
