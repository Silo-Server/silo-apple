import Foundation
import Synchronization

/// The watch state a detail page's Play tap resumes from.
///
/// A detail page's item and episode list are snapshots from when the page
/// loaded. Another device can move the position while the page stays open,
/// so a Play tap re-reads the server's watch state and both the resume
/// prompt and the player start use that answer. The page's snapshot is only
/// the fallback when the server can't answer (offline, error, or slow).
enum DetailResumeState: Equatable {
    /// The server's current watch state; nil means it has none for the item.
    case refreshed(LeafItemUserData?)
    /// The server read was skipped, failed, or timed out.
    case unavailable

    /// How long a Play tap waits for the server before falling back to the
    /// page's snapshot, so a stalled request can't leave the tap unanswered.
    static let defaultTimeout: Duration = .seconds(3)

    /// The position to offer and resume from, or nil to play without a
    /// resume prompt. Fresh server state wins over the page snapshot, even
    /// when the server reports no progress at all.
    func resumePosition(cached: LeafItemUserData?) -> Double? {
        let userData: LeafItemUserData?
        switch self {
        case .refreshed(let fresh): userData = fresh
        case .unavailable: userData = cached
        }
        return PlaybackResumePoint.position(
            userData?.positionSeconds,
            duration: userData?.durationSeconds
        )
    }

    /// Runs `fetch`, mapping a thrown error, a fetch slower than `timeout`,
    /// or the caller's cancellation to `.unavailable`.
    ///
    /// The fetch runs in its own task and is cancelled, not awaited, once
    /// the answer is decided. A task group would join it on exit, so a fetch
    /// parked where cancellation can't reach (such as a shared token-refresh
    /// flight) would hold the tap past the timeout.
    static func load(
        timeout: Duration = defaultTimeout,
        fetch: @escaping @Sendable () async throws -> LeafItemUserData?
    ) async -> DetailResumeState {
        let answer = FirstAnswer()
        let fetchTask = Task {
            do {
                answer.settle(.refreshed(try await fetch()))
            } catch {
                answer.settle(.unavailable)
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            answer.settle(.unavailable)
        }
        let state = await withTaskCancellationHandler {
            await withCheckedContinuation { answer.wait($0) }
        } onCancel: {
            answer.settle(.unavailable)
        }
        fetchTask.cancel()
        timeoutTask.cancel()
        return state
    }
}

/// The first of the fetch, the timeout, and cancellation to settle decides
/// `DetailResumeState.load`'s answer; later ones are ignored.
private final class FirstAnswer: Sendable {
    private enum Slot {
        case waiting(CheckedContinuation<DetailResumeState, Never>?)
        case settled(DetailResumeState)
    }

    private let slot = Mutex<Slot>(.waiting(nil))

    func wait(_ continuation: CheckedContinuation<DetailResumeState, Never>) {
        let settled = slot.withLock { slot -> DetailResumeState? in
            if case .settled(let state) = slot { return state }
            slot = .waiting(continuation)
            return nil
        }
        if let settled { continuation.resume(returning: settled) }
    }

    func settle(_ state: DetailResumeState) {
        let waiter = slot.withLock { slot -> CheckedContinuation<DetailResumeState, Never>? in
            guard case .waiting(let waiter) = slot else { return nil }
            slot = .settled(state)
            return waiter
        }
        waiter?.resume(returning: state)
    }
}
