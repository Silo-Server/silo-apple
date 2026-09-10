import Foundation

/// Single-owner handoff for one cancellation-shielded request outcome.
///
/// Exactly one of the caller and the shielded request itself takes the result,
/// never both — otherwise a cancelled start could return a session *and* delete
/// it. A lock rather than an actor because `withTaskCancellationHandler`'s
/// cancellation handler is synchronous and cannot `await`.
final class PlaybackCancellationShieldGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var bufferedOutcome: Result<Value, Error>?
    private var callerSettled = false

    /// Suspends the caller until the outcome arrives, or resumes it immediately
    /// when the outcome (or a cancellation) already landed.
    func attachCaller(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let bufferedOutcome {
            self.bufferedOutcome = nil
            lock.unlock()
            continuation.resume(with: bufferedOutcome)
            return
        }
        if callerSettled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns `true` when the caller took the outcome, `false` when it gave up
    /// first and the shielded request now owns the cleanup.
    func deliver(_ outcome: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !callerSettled else {
            lock.unlock()
            return false
        }
        callerSettled = true
        guard let waiting = continuation else {
            // The caller has not suspended yet; `attachCaller` collects this.
            bufferedOutcome = outcome
            lock.unlock()
            return true
        }
        continuation = nil
        lock.unlock()
        waiting.resume(with: outcome)
        return true
    }

    /// The caller was cancelled. It stops waiting now; the request keeps going.
    func abandon() {
        lock.lock()
        guard !callerSettled else {
            lock.unlock()
            return
        }
        callerSettled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
    }
}

enum PlaybackCancellationShield {
    /// Runs a server-allocating request so caller-side cancellation cannot
    /// orphan what it allocated.
    ///
    /// `URLSession` aborts on task cancellation, and `POST /playback/start` has
    /// no idempotent retract: a request cancelled after it reached the server
    /// leaves a session nothing on the client will ever stop. So the request
    /// runs in an unstructured child that does not inherit cancellation — an
    /// `async let` or task-group child would inherit it and reintroduce exactly
    /// that abort. The caller still observes its own cancellation and throws
    /// promptly, because the autoplay start timeout has to fire on time; the
    /// child then reclaims the result the caller never saw.
    static func run<Value>(
        operation: @escaping @Sendable () async throws -> Value,
        reclaim: @escaping @Sendable (Value) async -> Void
    ) async throws -> Value {
        let gate = PlaybackCancellationShieldGate<Value>()
        Task {
            let outcome: Result<Value, Error>
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            // Only the abandoned path reclaims, so there is one owner and no
            // duplicate retirement.
            guard !gate.deliver(outcome), case .success(let value) = outcome else { return }
            await reclaim(value)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.attachCaller(continuation)
            }
        } onCancel: {
            gate.abandon()
        }
    }
}
