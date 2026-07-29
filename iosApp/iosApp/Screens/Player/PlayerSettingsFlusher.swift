//
//  PlayerSettingsFlusher.swift
//  Silo (iOS + tvOS + macOS)
//
//  Debounced writer for the player's device-scoped settings, speaking the
//  canonical settings API (`PUT`/`DELETE /api/v1/settings/values/{key}` at
//  scope `profile_device`).
//
//  Failure handling is the point of this type, not an afterthought. The
//  inline flusher this replaces dropped nothing on purpose but also retried
//  nothing: a write that failed mid-drain sat in the queue until the *next*
//  user edit happened to trigger another flush, so one server hiccup made a
//  setting look non-persistent until the user toggled something unrelated.
//  Here a transient failure is retried on a capped backoff carrying the SAME
//  mutation id — an idempotent replay rather than a second write — and only a
//  response that proves retrying is pointless drops the op.
//
//  Semantics deliberately match Android's `ServerSettingsFlusher`
//  (android-shared/.../common/settings/ServerSettingsFlusher.kt): same 750 ms
//  debounce, same "one mutation id per logical write, held across retries",
//  same transient/permanent split. A user with both clients should see a
//  setting land the same way on each.
//

import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The subset of the canonical settings API the player's settings need.
///
/// A protocol rather than a direct ``ContinuumAPI`` reference so the queueing,
/// debounce and retry behaviour can be exercised without a network. The scope
/// is baked in at `profile_device`, the only scope this client writes.
protocol PlayerSettingsTransport: AnyObject, Sendable {
    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse
    func putValue(key: SettingKey, value: SettingJSONValue, mutationId: String) async throws
    func deleteValue(key: SettingKey) async throws
}

/// The production transport: the canonical endpoints on ``ContinuumAPI``.
final class ContinuumPlayerSettingsTransport: PlayerSettingsTransport {
    private let api: ContinuumAPI

    init(api: ContinuumAPI = .shared) {
        self.api = api
    }

    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(keys: keys)
    }

    func putValue(key: SettingKey, value: SettingJSONValue, mutationId: String) async throws {
        _ = try await api.putValue(
            key: key,
            scope: .profileDevice,
            value: value,
            mutationId: mutationId
        )
    }

    func deleteValue(key: SettingKey) async throws {
        try await api.deleteValue(key: key, scope: .profileDevice)
    }
}

/// One queued device-scoped write.
struct PendingSettingWrite: Equatable {
    enum Operation: Equatable {
        case set(SettingJSONValue)
        case delete
    }

    let operation: Operation

    /// One id per logical write, held across every retry of that write.
    ///
    /// The server replays the receipt it recorded for a repeated id instead of
    /// applying the write again, so a retry after a dropped response cannot
    /// double-apply. Minting a fresh id per retry defeats that, and defeats the
    /// 409 that catches genuinely different content reusing an id.
    let mutationId: String
}

/// Queue + debounce + retry for the player's device-scoped settings.
///
/// `enqueue` is synchronous and lock-guarded rather than actor-isolated on
/// purpose: the setters call it from whatever context the UI is on, and two
/// rapid edits hopping to an actor could be delivered out of order, which for a
/// slider means the server keeps a value the user dragged *through* instead of
/// the one they stopped on. Ordering at the call site is the guarantee; only
/// the network drain is async.
final class PlayerSettingsFlusher: @unchecked Sendable {

    /// How long an op waits for the user to stop fiddling before it is sent.
    ///
    /// 750 ms matches Android. A slider drag or a held stepper emits a value
    /// per frame; without the window each intermediate value would be its own
    /// request.
    static let defaultDebounce: Duration = .milliseconds(750)

    /// The automatic-retry schedule for a transient failure.
    ///
    /// Bounded on purpose: after `maximumAutomaticRetries` the op stays queued
    /// but stops its own timer, so a server that is down for an hour is not
    /// polled forever by every client's settings queue. The next enqueue or
    /// ``flushNow()`` — app foreground, player exit, settings screen open —
    /// picks it up again with its mutation id intact.
    struct RetryPolicy: Sendable {
        var maximumAutomaticRetries: Int = 5
        var base: Duration = .seconds(1)
        var maximum: Duration = .seconds(60)

        static let `default` = RetryPolicy()

        func delay(forAttempt attempt: Int) -> Duration {
            let shift = min(max(attempt - 1, 0), 6)
            return min(base * (1 << shift), maximum)
        }
    }

    /// What to do with an op after one attempt.
    private enum FlushOutcome {
        /// Applied, or refused in a way retrying cannot fix. Drop it.
        case settled
        /// Transient — keep the op and retry it on the backoff schedule.
        case retryWithBackoff
        /// A precondition is not met yet (no profile selected, server predates
        /// the canonical API). Keep the op, but do not spin a timer against a
        /// condition only a user action or a reconnect can change.
        case retryOnNextTrigger
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlayerSettingsFlusher"
    )

    private let transport: PlayerSettingsTransport
    private let debounce: Duration
    private let retryPolicy: RetryPolicy

    private let lock = NSLock()
    private var pending: [SettingKey: PendingSettingWrite] = [:]
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0
    private var isDraining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var backgroundObserver: NSObjectProtocol?

    init(
        transport: PlayerSettingsTransport,
        debounce: Duration = PlayerSettingsFlusher.defaultDebounce,
        retryPolicy: RetryPolicy = .default,
        flushesOnBackground: Bool = false
    ) {
        self.transport = transport
        self.debounce = debounce
        self.retryPolicy = retryPolicy
        if flushesOnBackground {
            observeBackgrounding()
        }
    }

    convenience init() {
        // The app-wide instance is the one that must survive backgrounding;
        // a test's instance opts out so a simulator lifecycle notification
        // cannot fire an unexpected flush mid-assertion.
        self.init(transport: ContinuumPlayerSettingsTransport(), flushesOnBackground: true)
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    /// Send whatever is queued when the app leaves the foreground.
    ///
    /// Without this the debounce window is a data-loss hole: a user who flips a
    /// toggle and immediately swipes the app away has their change sitting in a
    /// timer that never fires, so the setting silently reverts on next launch.
    /// The old inline flusher had no window and so no such gap; adding the
    /// window means adding this.
    private func observeBackgrounding() {
        #if canImport(UIKit)
        let name = UIApplication.didEnterBackgroundNotification
        #elseif canImport(AppKit)
        let name = NSApplication.willResignActiveNotification
        #else
        return
        #endif
        #if canImport(UIKit) || canImport(AppKit)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.hasPendingWrites else { return }
            Task { await self.flushNow() }
        }
        #endif
    }

    /// Resolve every key this client syncs in one batched call.
    ///
    /// On the flusher rather than reached for directly so ``PlayerSettings``
    /// has one seam to fake in tests, and so the read and the writes cannot
    /// drift onto different transports.
    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        try await transport.effectiveValues(keys: keys)
    }

    /// Keys with an op still queued: one inside the debounce window, or one
    /// held back after a failure.
    var pendingKeys: [SettingKey] {
        lock.lock()
        defer { lock.unlock() }
        return SettingKey.playerDeviceSettings.filter { pending[$0] != nil }
    }

    var hasPendingWrites: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// The mutation id currently attached to this key's queued write, if any.
    /// Exposed so a test can prove a retry reuses it.
    func mutationId(for key: SettingKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pending[key]?.mutationId
    }

    // MARK: - Queueing

    /// Queue one device-scoped write, restarting the debounce window.
    func enqueue(_ key: SettingKey, value: SettingJSONValue) {
        schedule(key) { existing in
            // Re-enqueueing the identical value keeps the pending op *and* its
            // mutation id: it is the same logical write, and the server treats
            // a replayed id carrying identical content as already done.
            if case .set(let queued) = existing?.operation, queued == value {
                return existing
            }
            return PendingSettingWrite(operation: .set(value), mutationId: newSettingMutationId())
        }
    }

    /// Queue clearing this device's value, so the setting inherits again.
    func enqueueDelete(_ key: SettingKey) {
        schedule(key) { existing in
            if case .delete = existing?.operation {
                return existing
            }
            return PendingSettingWrite(operation: .delete, mutationId: newSettingMutationId())
        }
    }

    private func schedule(_ key: SettingKey, _ next: (PendingSettingWrite?) -> PendingSettingWrite?) {
        lock.lock()
        pending[key] = next(pending[key])
        // Fresh user activity re-arms the retry budget: whatever made the last
        // attempt fail may well be gone by now.
        retryAttempts = 0
        retryTask?.cancel()
        retryTask = nil
        debounceTask?.cancel()
        let interval = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.flushNow()
        }
        lock.unlock()
    }

    // MARK: - Draining

    /// Cancel any pending debounce, send every queued op, and return once each
    /// has been acknowledged or has failed.
    ///
    /// Re-entrant calls coalesce: a second caller waits for the drain already
    /// running rather than issuing the same writes twice.
    func flushNow() async {
        lock.lock()
        debounceTask?.cancel()
        debounceTask = nil
        retryTask?.cancel()
        retryTask = nil
        retryAttempts = 0
        let claimed = claimDrainLocked()
        lock.unlock()

        if claimed {
            await drain()
            return
        }

        await awaitDrainCompletion()

        // The drain we waited on re-reads the queue until it comes back empty,
        // so an op enqueued before this call was almost certainly included in
        // it. The exception is one enqueued in the instant that drain was
        // finishing, so take one more pass if anything is left. A duplicate
        // send would be harmless anyway: the mutation id makes it a replay.
        lock.lock()
        let needsAnotherPass = !pending.isEmpty && claimDrainLocked()
        lock.unlock()
        if needsAnotherPass {
            await drain()
        }
    }

    /// Caller must hold `lock`.
    private func claimDrainLocked() -> Bool {
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    private func awaitDrainCompletion() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard isDraining else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func drain() async {
        // Ops that failed during this drain. Held out of `pending` until the
        // loop finishes, or the loop would retry them immediately and spin.
        //
        // Only the latest outcome per key may live here: a later pass that
        // settles a newer op for the same key must evict the older failed
        // entry, or the re-queue below would resurrect a value the user has
        // already replaced. The `pending[key] == nil` guard below cannot catch
        // that — the very pass that sent the newer op already cleared it.
        var retryable: [SettingKey: PendingSettingWrite] = [:]
        var wantsBackoff = false

        while true {
            lock.lock()
            let snapshot = pending
            pending = [:]
            lock.unlock()
            if snapshot.isEmpty { break }

            // A stable order so the two axes of the quality preset
            // (playback.preferred_quality and playback.max_bitrate_kbps) always
            // reach the server in the same sequence.
            for key in SettingKey.playerDeviceSettings {
                guard let write = snapshot[key] else { continue }
                switch await send(key, write) {
                case .settled:
                    retryable.removeValue(forKey: key)
                case .retryWithBackoff:
                    retryable[key] = write
                    wantsBackoff = true
                case .retryOnNextTrigger:
                    retryable[key] = write
                }
            }
        }

        lock.lock()
        for (key, write) in retryable where pending[key] == nil {
            // A newer op enqueued during the drain wins over the failed one:
            // it is newer content, with its own id.
            pending[key] = write
        }
        isDraining = false
        let resumed = waiters
        waiters.removeAll()

        var scheduledAttempt: Int?
        if pending.isEmpty {
            retryAttempts = 0
        } else if wantsBackoff, retryAttempts < retryPolicy.maximumAutomaticRetries {
            retryAttempts += 1
            scheduledAttempt = retryAttempts
        }
        // Out of automatic retries, or nothing worth a timer: the ops stay
        // queued and the next enqueue or flushNow tries again with the same
        // mutation ids.
        if let scheduledAttempt {
            scheduleRetryLocked(attempt: scheduledAttempt)
        }
        lock.unlock()

        for continuation in resumed {
            continuation.resume()
        }
    }

    /// Caller must hold `lock`.
    private func scheduleRetryLocked(attempt: Int) {
        let delay = retryPolicy.delay(forAttempt: attempt)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.lock.lock()
            let claimed = self.claimDrainLocked()
            self.lock.unlock()
            if claimed {
                await self.drain()
            }
        }
    }

    // MARK: - Sending

    private func send(_ key: SettingKey, _ write: PendingSettingWrite) async -> FlushOutcome {
        do {
            switch write.operation {
            case .set(let value):
                try await transport.putValue(key: key, value: value, mutationId: write.mutationId)
            case .delete:
                try await transport.deleteValue(key: key)
            }
            return .settled
        } catch let error as SettingsAPIError {
            return outcome(for: error, key: key, operation: write.operation)
        } catch is CancellationError {
            // A cancelled flush must not lose the write: it goes back on the
            // queue and the next trigger replays it.
            return .retryOnNextTrigger
        } catch {
            log(key, "threw \(error)", kept: true)
            return .retryWithBackoff
        }
    }

    private func outcome(
        for error: SettingsAPIError,
        key: SettingKey,
        operation: PendingSettingWrite.Operation
    ) -> FlushOutcome {
        switch error {
        case .noValueAtScope:
            // Nothing stored at this scope, so the clear is already true: an
            // earlier attempt landed even if its response did not.
            if case .delete = operation { return .settled }
            log(key, "no value at scope", kept: false)
            return .settled

        case .profileRequired:
            // No profile selected yet. Only a user action fixes that, so hold
            // the user's choice rather than dropping it — but do not spin a
            // timer at it.
            log(key, "no profile selected", kept: true)
            return .retryOnNextTrigger

        case .serverUpgradeRequired:
            log(key, "server does not serve the canonical settings API", kept: true)
            return .retryOnNextTrigger

        case .unknownSetting, .clientLocalSetting, .scopeNotAllowed, .invalidValue, .mutationIdConflict:
            // The contract refused the write, so retrying would fail
            // identically forever. Drop it — loudly, because each of these is a
            // client bug rather than a server condition.
            log(key, "contract refused the write: \(error)", kept: false)
            return .settled

        case .server(let status, _, _):
            // Retrying can help: the request never arrived, the server fell
            // over, throttled us, timed out, or the session token was mid
            // refresh.
            let transient = status >= 500 || status == 408 || status == 429 || status == 401
            log(key, "server returned \(status)", kept: transient)
            return transient ? .retryWithBackoff : .settled

        case .transport(let description):
            log(key, "transport failure: \(description)", kept: true)
            return .retryWithBackoff
        }
    }

    private func log(_ key: SettingKey, _ detail: String, kept: Bool) {
        let disposition = kept ? "kept queued for retry" : "dropped"
        Self.logger.warning(
            "\(key.rawValue, privacy: .public): \(detail, privacy: .public); \(disposition, privacy: .public)"
        )
    }
}
