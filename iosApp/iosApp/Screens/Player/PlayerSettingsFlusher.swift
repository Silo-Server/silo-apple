//
//  PlayerSettingsFlusher.swift
//  Silo (iOS + tvOS + macOS)
//
//  Debounced writer for the player's device-scoped settings, speaking the
//  canonical settings API (`PUT`/`DELETE /api/v2/settings/values/{key}` at
//  scope `profile_device`).
//
//  Failure handling is the point of this type, not an afterthought. The
//  inline flusher this replaces dropped nothing on purpose but also retried
//  nothing: a write that failed mid-drain sat in the queue until the *next*
//  user edit happened to trigger another flush, so one server hiccup made a
//  setting look non-persistent until the user toggled something unrelated.
//
//  The writes are `natural_idempotent`: each one names the desired value of
//  one row, so sending it again converges instead of applying twice. There
//  is no mutation id. Owner decision D4 sets the rules: one pending value per
//  key (a newer edit replaces an older one), only that latest value is
//  retried, on a bounded backoff, while its (server, profile, device)
//  partition is still the active one. When the bound runs out the key is
//  *held*: it stays on this device and in the journal, is not sent again, and
//  the settings screens offer "Discard held change" (or a retry). A response
//  that proves retrying is pointless drops the op.
//
//  The debounce and the transient/permanent split match Android's
//  `ServerSettingsFlusher` (android-shared/.../common/settings/
//  ServerSettingsFlusher.kt): same 750 ms debounce, same retry schedule.
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
/// A protocol rather than a direct ``SiloAPI`` reference so the queueing,
/// debounce and retry behaviour can be exercised without a network. The scope
/// is baked in at `profile_device`, the only scope this client writes.
protocol PlayerSettingsTransport: AnyObject, Sendable {
    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse
    func putValue(key: SettingKey, value: SettingJSONValue, profileId: String?) async throws
    func deleteValue(key: SettingKey, profileId: String?) async throws
}

/// The production transport: the canonical endpoints on ``SiloAPI``.
final class SiloPlayerSettingsTransport: PlayerSettingsTransport {
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func effectiveValues(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(keys: keys)
    }

    func putValue(key: SettingKey, value: SettingJSONValue, profileId: String?) async throws {
        try await api.putValue(key: key, scope: .profileDevice, value: value, profileId: profileId)
    }

    func deleteValue(key: SettingKey, profileId: String?) async throws {
        try await api.deleteValue(key: key, scope: .profileDevice, profileId: profileId)
    }
}

/// One queued device-scoped write: the latest desired state of one key.
///
/// `Codable` because the queue outlives the process — see
/// ``PlayerSettingsWriteJournal``. Entries written by earlier builds also
/// carry a `mutationId`; it is ignored, because v2 writes are naturally
/// idempotent and replay nothing.
struct PendingSettingWrite: Equatable, Codable {
    enum Operation: Equatable, Codable {
        case set(SettingJSONValue)
        case delete
    }

    let operation: Operation

    /// The (server, profile, device) identity this operation belongs to.
    /// Nil is retained for in-memory/test journals with no scoped identity;
    /// the production journal binds older encoded entries to the scope whose
    /// storage partition they were loaded from.
    let scopeIdentifier: String?

    /// The profile captured with the journal partition. The production
    /// transport passes it explicitly so an async request cannot resolve its
    /// X-Profile-Id from a newer session after the user switches profiles.
    let profileId: String?

    /// Sends of this value that failed in a way a retry could fix. Past the
    /// retry policy's bound the write is held.
    var failedAttempts: Int

    /// Out of automatic retries: kept on this device and in the journal, but
    /// not sent again until the user retries it, replaces it with a new edit,
    /// or discards it.
    var isHeld: Bool

    init(
        operation: Operation,
        scopeIdentifier: String? = nil,
        profileId: String? = nil,
        failedAttempts: Int = 0,
        isHeld: Bool = false
    ) {
        self.operation = operation
        self.scopeIdentifier = scopeIdentifier
        self.profileId = profileId
        self.failedAttempts = failedAttempts
        self.isHeld = isHeld
    }

    private enum CodingKeys: String, CodingKey {
        case operation, scopeIdentifier, profileId, failedAttempts, isHeld
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decode(Operation.self, forKey: .operation)
        scopeIdentifier = try container.decodeIfPresent(String.self, forKey: .scopeIdentifier)
        profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        failedAttempts = try container.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0
        isHeld = try container.decodeIfPresent(Bool.self, forKey: .isHeld) ?? false
    }

    func bound(to scopeIdentifier: String?, profileId: String?) -> PendingSettingWrite {
        guard self.scopeIdentifier == nil || self.profileId == nil else { return self }
        return PendingSettingWrite(
            operation: operation,
            scopeIdentifier: self.scopeIdentifier ?? scopeIdentifier,
            profileId: self.profileId ?? profileId,
            failedAttempts: failedAttempts,
            isHeld: isHeld
        )
    }
}

/// Where the queue lives while the process is not running.
///
/// The debounce window is 750 ms of edits that exist only in memory, and the
/// process can end inside it: Cmd-Q on macOS terminates without waiting on a
/// detached flush, and a suspended iOS app killed from the switcher gets no
/// `willTerminate` at all. A lifecycle notification cannot close that hole
/// because it does not always arrive and never waits for a network round trip
/// — so the queue is written to disk as it is *enqueued*, and replayed by the
/// first flush after launch. `PlayerSettings.refreshFromServer` drains before
/// it adopts the server's answer, so a restored edit lands rather than being
/// overwritten by the stale value it was meant to replace.
protocol PlayerSettingsWriteJournal: AnyObject, Sendable {
    /// The partition currently addressed by load/save, when the journal is
    /// scope-aware. In-memory test journals use the default nil identity.
    var scopeIdentifier: String? { get }
    /// Profile addressed by the current partition. Older test journals have
    /// no profile identity and use the default nil value.
    var profileId: String? { get }
    func load() -> [SettingKey: PendingSettingWrite]
    func save(_ pending: [SettingKey: PendingSettingWrite])
    /// Remove one acknowledged operation from the partition it was captured
    /// from. Matching the operation prevents a late response from erasing a
    /// newer, different write to the same key; a newer write of the same
    /// value is already true on the server.
    func retire(_ key: SettingKey, matching write: PendingSettingWrite)
}

extension PlayerSettingsWriteJournal {
    var scopeIdentifier: String? { nil }
    var profileId: String? { nil }
}

/// The production journal: `UserDefaults`, partitioned by settings scope.
///
/// Partitioned because a queued op is addressed to one (server, profile,
/// device) triple. Replaying it after the user switched servers or profiles
/// would write the previous profile's choice onto the current one, so an entry
/// whose scope no longer matches is not loaded.
final class UserDefaultsSettingsWriteJournal: PlayerSettingsWriteJournal, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlayerSettingsFlusher"
    )

    private let defaults: UserDefaults
    private let profileProvider: @Sendable () -> String?
    private let scopeProvider: @Sendable () -> String?

    init(
        defaults: UserDefaults = .standard,
        profileProvider: @escaping @Sendable () -> String? = {
            AuthService.shared.profileId?.trimmingCharacters(in: .whitespacesAndNewlines)
        },
        scopeProvider: @escaping @Sendable () -> String? = { PlayerSettings.currentScopeIdentifier }
    ) {
        self.defaults = defaults
        self.profileProvider = profileProvider
        self.scopeProvider = scopeProvider
    }

    private func storageKey(for scopeIdentifier: String?) -> String? {
        scopeIdentifier.map { "player.pendingDeviceSettingWrites.\($0)" }
    }

    var scopeIdentifier: String? { scopeProvider() }
    var profileId: String? { profileProvider() }

    func load() -> [SettingKey: PendingSettingWrite] {
        let scopeIdentifier = scopeProvider()
        guard let storageKey = storageKey(for: scopeIdentifier),
              let data = defaults.data(forKey: storageKey) else {
            return [:]
        }
        do {
            let stored = try SettingsWireCoding.makeDecoder()
                .decode([String: PendingSettingWrite].self, from: data)
            // A key this build no longer knows is dropped rather than failing
            // the whole restore: the contract is additive, and one stale entry
            // must not strand every other queued edit.
            let profileId = profileProvider()
            return stored.reduce(into: [:]) { result, entry in
                if let key = SettingKey(rawValue: entry.key) {
                    result[key] = entry.value.bound(to: scopeIdentifier, profileId: profileId)
                }
            }
        } catch {
            Self.logger.warning("could not restore the pending settings queue: \(String(describing: error), privacy: .public)")
            defaults.removeObject(forKey: storageKey)
            return [:]
        }
    }

    func save(_ pending: [SettingKey: PendingSettingWrite]) {
        guard let storageKey = storageKey(for: scopeProvider()) else { return }
        guard !pending.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let encodable = Dictionary(uniqueKeysWithValues: pending.map { ($0.key.rawValue, $0.value) })
        guard let data = try? SettingsWireCoding.makeEncoder().encode(encodable) else {
            // Unreachable for a dictionary of contract values, and losing
            // durability is better than losing the in-memory queue.
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    func retire(_ key: SettingKey, matching write: PendingSettingWrite) {
        guard let storageKey = storageKey(for: write.scopeIdentifier),
              let data = defaults.data(forKey: storageKey) else {
            return
        }
        do {
            var stored = try SettingsWireCoding.makeDecoder()
                .decode([String: PendingSettingWrite].self, from: data)
            guard let persisted = stored[key.rawValue],
                  persisted.operation == write.operation else {
                return
            }
            stored.removeValue(forKey: key.rawValue)
            guard !stored.isEmpty else {
                defaults.removeObject(forKey: storageKey)
                return
            }
            guard let updated = try? SettingsWireCoding.makeEncoder().encode(stored) else {
                return
            }
            defaults.set(updated, forKey: storageKey)
        } catch {
            Self.logger.warning(
                "could not retire an acknowledged settings write: \(String(describing: error), privacy: .public)"
            )
        }
    }
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

    /// The automatic-retry schedule for a transient failure (D4's bound).
    ///
    /// Bounded on purpose: after `maximumAutomaticRetries` failed retries of a
    /// key's latest value the key is held rather than polled forever, so a
    /// server that is down for an hour is not hammered by every client's
    /// settings queue, and the user decides what happens to the change.
    typealias RetryPolicy = SettingWriteRetryPolicy

    /// What to do with an op after one attempt.
    private enum FlushOutcome {
        /// Applied, or already true. Drop it.
        case settled
        /// Refused in a way retrying cannot fix. Drop it and tell the
        /// settings screen once.
        case rejected
        /// The active partition changed before the request could be sent. Its
        /// original journal still owns it; do not retire an unattempted op.
        case leftInOriginalJournal
        /// Transient — keep the op and retry it on the backoff schedule, or
        /// hold it once the schedule is spent.
        case retryWithBackoff
        /// A precondition is not met yet (no profile selected, server predates
        /// the canonical API). Keep the op, but do not spin a timer against a
        /// condition only a user action or a reconnect can change.
        case retryOnNextTrigger
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlayerSettingsFlusher"
    )

    private let transport: PlayerSettingsTransport
    private let debounce: Duration
    private let retryPolicy: RetryPolicy
    private let journal: PlayerSettingsWriteJournal?

    private let lock = NSLock()
    /// The latest op per key for the active partition, held ones included.
    private var pending: [SettingKey: PendingSettingWrite] = [:]
    /// Ops a drain has taken out of `pending` but has not yet heard back on.
    /// Only the journal reads this — it has to describe them too, or a process
    /// death between the request leaving and its response arriving would lose a
    /// write that is in neither place.
    private var inFlight: [SettingKey: PendingSettingWrite] = [:]
    private var debounceTask: Task<Void, Never>?
    /// Bumped every time the debounce window is re-armed, so a waking timer can
    /// tell whether it is still the current one before it retires the
    /// registration in ``flushAfterDebounce(generation:)``.
    private var debounceGeneration: UInt64 = 0
    private var retryTask: Task<Void, Never>?
    /// Mirrors debounceGeneration for the retry timer: a waking task retires
    /// its own registration before it starts a drain.
    private var retryGeneration: UInt64 = 0
    /// Scope represented by the in-memory queue. A scope transition drops the
    /// local view and restores that partition's journal instead.
    private var activeJournalScope: String?
    private var isDraining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var heldKeysObserver: (@Sendable ([SettingKey]) -> Void)?
    private var reportedHeldKeys: [SettingKey] = []
    private var rejectionObserver: (@Sendable (SettingKey) -> Void)?

    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        transport: PlayerSettingsTransport,
        debounce: Duration = PlayerSettingsFlusher.defaultDebounce,
        retryPolicy: RetryPolicy = .default,
        journal: PlayerSettingsWriteJournal? = nil,
        flushesOnBackground: Bool = false
    ) {
        self.transport = transport
        self.debounce = debounce
        self.retryPolicy = retryPolicy
        self.journal = journal
        // Anything the last run left queued is replayed by the first flush;
        // anything it left held stays held.
        if let journal {
            activeJournalScope = journal.scopeIdentifier
            pending = journal.load()
        }
        if flushesOnBackground {
            observeLifecycle()
        }
    }

    convenience init() {
        // The app-wide instance is the one that must survive backgrounding and
        // termination; a test's instance opts out of both so a simulator
        // lifecycle notification cannot fire an unexpected flush mid-assertion
        // and nothing is written to the shared preferences domain.
        self.init(
            transport: SiloPlayerSettingsTransport(),
            journal: UserDefaultsSettingsWriteJournal(),
            flushesOnBackground: true
        )
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Send whatever is queued when the app leaves the foreground, and hold the
    /// process open long enough for it to land.
    ///
    /// Without this the debounce window is a data-loss hole: a user who flips a
    /// toggle and immediately swipes the app away has their change sitting in a
    /// timer that never fires. The old inline flusher had no window and so no
    /// such gap; adding the window means adding this.
    ///
    /// The notification alone is not enough, which is why the durable journal
    /// exists alongside it. On macOS the only lifecycle signal available before
    /// a Cmd-Q is `willResignActive`, and AppKit terminates without waiting on
    /// the flush it starts; on iOS a suspended app killed from the switcher is
    /// never told at all. Both paths therefore rely on the queue already being
    /// on disk. What these observers buy is the common case landing *now*
    /// rather than on next launch — and on iOS, a background-task assertion so
    /// the request is not suspended mid-flight.
    private func observeLifecycle() {
        #if canImport(UIKit)
        observe(UIApplication.didEnterBackgroundNotification)
        observe(UIApplication.willTerminateNotification)
        #elseif canImport(AppKit)
        observe(NSApplication.willResignActiveNotification)
        observe(NSApplication.willTerminateNotification)
        #endif
    }

    #if canImport(UIKit) || canImport(AppKit)
    private func observe(_ name: Notification.Name) {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self, self.hasSendableWrites else { return }
                Task { await self.flushHoldingTheProcessOpen() }
            }
        )
    }
    #endif

    /// Flush with whatever the platform offers to keep the process alive.
    ///
    /// On iOS a background-task assertion: without one the app can be suspended
    /// between the request leaving and its response arriving, and the write
    /// would then only land on the next launch's replay. ``flushNow()`` cannot
    /// throw and always returns once every op is acknowledged or has failed, so
    /// the assertion is always ended — one left open is a watchdog termination.
    private func flushHoldingTheProcessOpen() async {
        #if canImport(UIKit)
        let identifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "SiloSettingsFlush")
        }
        await flushNow()
        if identifier != .invalid {
            await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
        }
        #else
        await flushNow()
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

    /// Re-read the journal and adopt anything it still owes.
    ///
    /// `init` already does this, but the journal is partitioned by settings
    /// scope and the scope is not known until a server and profile are
    /// selected — which for the app-wide instance happens well after it is
    /// constructed. ``PlayerSettings/refreshFromServer()`` calls this on every
    /// launch, sign-in and profile switch so a queue persisted under a scope
    /// that only just became current is picked up rather than stranded.
    ///
    /// An op already queued in memory wins: it is at least as new as the disk
    /// copy.
    func restorePendingWrites() {
        guard let journal else { return }
        let scopeIdentifier = journal.scopeIdentifier
        let restored = journal.load()
        lock.lock()
        transitionScopeIfNeededLocked(to: scopeIdentifier)
        for (key, write) in restored where pending[key] == nil {
            // An in-flight write from the scope we just left must not block the
            // same key restored for the newly selected scope. Only a request
            // already draining for this exact partition supersedes its journal
            // copy.
            if let draining = inFlight[key], draining.scopeIdentifier == scopeIdentifier {
                continue
            }
            pending[key] = write
        }
        persistLocked()
        lock.unlock()
        publishHeldKeys()
    }

    /// Switch the in-memory view to another journal partition. The previous
    /// queue was persisted at enqueue time, so clearing it here does not lose
    /// anything; it prevents those operations from being sent with the newly
    /// selected profile's request headers.
    ///
    /// Caller must hold `lock`.
    private func transitionScopeIfNeededLocked(to scopeIdentifier: String?) {
        guard activeJournalScope != scopeIdentifier else { return }
        activeJournalScope = scopeIdentifier
        pending.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        debounceGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        retryGeneration &+= 1
    }

    /// True while anything is owed to the server, held changes included.
    var hasPendingWrites: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty || !inFlight.isEmpty || isDraining
    }

    /// True while a flush has something to send: held changes do not count.
    private var hasSendableWrites: Bool {
        lock.withLock { pending.values.contains { !$0.isHeld } || !inFlight.isEmpty || isDraining }
    }

    // MARK: - Held changes

    /// Keys whose latest change ran out of automatic retries, in player order.
    var heldKeys: [SettingKey] {
        lock.withLock { heldKeysLocked() }
    }

    /// Caller must hold `lock`.
    private func heldKeysLocked() -> [SettingKey] {
        Self.orderedKeys(in: pending.filter { $0.value.isHeld })
    }

    /// Called with ``heldKeys`` whenever that list changes, on no particular
    /// thread.
    func observeHeldKeys(_ observer: @escaping @Sendable ([SettingKey]) -> Void) {
        lock.withLock {
            heldKeysObserver = observer
            reportedHeldKeys = []
        }
        publishHeldKeys()
    }

    /// Called once for each change the server definitively refused, on no
    /// particular thread. The change has already been dropped.
    func observeRejections(_ observer: @escaping @Sendable (SettingKey) -> Void) {
        lock.withLock { rejectionObserver = observer }
    }

    /// Values this device has not yet got onto the server — queued, in flight
    /// or held — for the active partition. A refresh paints these over the
    /// server's answer, which does not have them yet. Clears are not listed:
    /// the value a clear exposes is only known once it lands.
    func unsettledValues() -> [SettingKey: SettingJSONValue] {
        lock.withLock {
            var values: [SettingKey: SettingJSONValue] = [:]
            for (key, write) in inFlight where write.scopeIdentifier == activeJournalScope {
                if case .set(let value) = write.operation { values[key] = value }
            }
            for (key, write) in pending {
                if case .set(let value) = write.operation {
                    values[key] = value
                } else {
                    values.removeValue(forKey: key)
                }
            }
            return values
        }
    }

    /// Keys with any change still owed to the server, clears included.
    var unsettledKeys: Set<SettingKey> {
        lock.withLock {
            Set(pending.keys).union(inFlight.filter { $0.value.scopeIdentifier == activeJournalScope }.keys)
        }
    }

    /// "Discard held change": forget every held change for the active
    /// partition, here and in the journal. Nothing is sent; the caller
    /// re-reads the server to repaint what it holds.
    func discardHeldChanges() {
        lock.withLock {
            pending = pending.filter { !$0.value.isHeld }
            persistLocked()
        }
        publishHeldKeys()
    }

    /// Send every held change again with a fresh retry budget, and wait for
    /// the attempt.
    func retryHeldChanges() async {
        lock.withLock {
            for (key, write) in pending where write.isHeld {
                pending[key] = PendingSettingWrite(
                    operation: write.operation,
                    scopeIdentifier: write.scopeIdentifier,
                    profileId: write.profileId
                )
            }
            persistLocked()
        }
        publishHeldKeys()
        await flushNow()
    }

    private func publishHeldKeys() {
        let (observer, keys) = lock.withLock { () -> ((@Sendable ([SettingKey]) -> Void)?, [SettingKey]) in
            let keys = heldKeysLocked()
            guard keys != reportedHeldKeys else { return (nil, keys) }
            reportedHeldKeys = keys
            return (heldKeysObserver, keys)
        }
        observer?(keys)
    }

    // MARK: - Queueing

    /// Queue one device-scoped write, restarting the debounce window.
    func enqueue(_ key: SettingKey, value: SettingJSONValue) {
        schedule(key) { existing, scopeIdentifier, profileId in
            // The identical value already queued is the same desired state, so
            // the pending op (and its retry count) stands. A held one does
            // not: setting it again is the user asking for another try.
            if case .set(let queued) = existing?.operation, queued == value, existing?.isHeld == false {
                return existing
            }
            return PendingSettingWrite(
                operation: .set(value),
                scopeIdentifier: scopeIdentifier,
                profileId: profileId
            )
        }
    }

    /// Queue clearing this device's value, so the setting inherits again.
    func enqueueDelete(_ key: SettingKey) {
        schedule(key) { existing, scopeIdentifier, profileId in
            if case .delete = existing?.operation, existing?.isHeld == false {
                return existing
            }
            return PendingSettingWrite(
                operation: .delete,
                scopeIdentifier: scopeIdentifier,
                profileId: profileId
            )
        }
    }

    private func schedule(
        _ key: SettingKey,
        _ next: (PendingSettingWrite?, String?, String?) -> PendingSettingWrite?
    ) {
        lock.lock()
        let scopeIdentifier = journal?.scopeIdentifier
        transitionScopeIfNeededLocked(to: scopeIdentifier)
        pending[key] = next(pending[key], scopeIdentifier, journal?.profileId)
        persistLocked()
        // The debounced drain below sends every queued op, so a pending retry
        // timer would only duplicate it.
        retryTask?.cancel()
        retryTask = nil
        retryGeneration &+= 1
        debounceTask?.cancel()
        debounceGeneration &+= 1
        let generation = debounceGeneration
        let interval = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.flushAfterDebounce(generation: generation)
        }
        lock.unlock()
        publishHeldKeys()
    }

    // MARK: - Draining

    /// The debounce timer's own way into a drain.
    ///
    /// Deliberately not ``flushNow()`` directly: that starts by cancelling
    /// `debounceTask`, and on this path `debounceTask` *is* the task executing
    /// the call, so it would cancel itself. Everything after that — the drain,
    /// the send, the `URLSession` round trip — would then run with
    /// `Task.isCancelled == true`, and `URLSession` reports its enclosing
    /// task's cancellation as `NSURLErrorCancelled`. Every debounced write
    /// would fail an attempt the request never survived, be classified as a
    /// transport failure, and only land on the first backoff retry a second
    /// later. Retiring this timer's own registration first makes the cancel in
    /// ``flushNow()`` a no-op.
    private func flushAfterDebounce(generation: UInt64) async {
        let isCurrent = lock.withLock {
            let isCurrent = debounceGeneration == generation
            if isCurrent {
                debounceTask = nil
            }
            return isCurrent
        }
        // A newer edit re-armed the window, or an explicit flush ran, while
        // this timer was waking. Either way this task has been cancelled and
        // whoever cancelled it owns the flush; going on would put the writes
        // back under a cancelled task, which is the whole failure this method
        // exists to avoid.
        guard isCurrent, !Task.isCancelled else { return }
        await flushNow()
    }

    /// Cancel any pending debounce, send every queued op that is not held,
    /// and return once each has been acknowledged or has failed.
    ///
    /// Re-entrant calls coalesce: a second caller waits for the drain already
    /// running rather than issuing the same writes twice.
    func flushNow() async {
        let claimed = lock.withLock {
            debounceTask?.cancel()
            debounceTask = nil
            retryTask?.cancel()
            retryTask = nil
            retryGeneration &+= 1
            return claimDrainLocked()
        }

        if claimed {
            await drain()
            return
        }

        await awaitDrainCompletion()

        // The drain we waited on re-reads the queue until it comes back empty,
        // so an op enqueued before this call was almost certainly included in
        // it. The exception is one enqueued in the instant that drain was
        // finishing, so take one more pass if anything is left. A duplicate
        // send would be harmless anyway: the write names a desired value.
        let needsAnotherPass = lock.withLock {
            pending.values.contains { !$0.isHeld } && claimDrainLocked()
        }
        if needsAnotherPass {
            await drain()
        }
    }

    /// Write the queue to the journal. Caller must hold `lock`.
    ///
    /// `alsoOwed` covers ops this drain has already failed and will re-queue
    /// when it finishes: they are momentarily in neither `pending` nor
    /// `inFlight`, and a process death in that window would drop them.
    private func persistLocked(alsoOwed: [SettingKey: PendingSettingWrite] = [:]) {
        guard let journal else { return }
        let scopeIdentifier = journal.scopeIdentifier
        var owed = pending.filter { $0.value.scopeIdentifier == scopeIdentifier }
        for (key, write) in inFlight
            where write.scopeIdentifier == scopeIdentifier && owed[key] == nil {
            owed[key] = write
        }
        for (key, write) in alsoOwed
            where write.scopeIdentifier == scopeIdentifier && owed[key] == nil {
            owed[key] = write
        }
        journal.save(owed)
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

    /// Preferred player order first, followed by any other queued contract
    /// key in deterministic raw-value order. The queue accepts SettingKey, so
    /// the preferred list must not become an accidental allowlist.
    private static func orderedKeys(
        in writes: [SettingKey: PendingSettingWrite]
    ) -> [SettingKey] {
        let preferred = SettingKey.playerDeviceSettings.filter { writes[$0] != nil }
        let preferredSet = Set(preferred)
        let remaining = writes.keys
            .filter { !preferredSet.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
        return preferred + remaining
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
        var rejected: [SettingKey] = []

        while true {
            let snapshot = lock.withLock {
                // Held ops stay where they are: they are owed, not sendable.
                let snapshot = pending.filter { !$0.value.isHeld }
                pending = pending.filter { $0.value.isHeld }
                // Moved, not dropped: the journal has to keep describing an op that
                // is out of `pending` but not yet acknowledged, or a process death
                // mid-request would lose it on both sides.
                inFlight = snapshot
                persistLocked()
                return snapshot
            }
            if snapshot.isEmpty { break }

            // A stable order so the two axes of the quality preset
            // (playback.preferred_quality and playback.max_bitrate_kbps) always
            // reach the server in the same sequence.
            for key in Self.orderedKeys(in: snapshot) {
                guard let write = snapshot[key] else { continue }
                let outcome = await send(key, write)
                lock.withLock {
                    if inFlight[key] == write {
                        inFlight.removeValue(forKey: key)
                    }
                    switch outcome {
                    case .settled, .rejected:
                        retryable.removeValue(forKey: key)
                        journal?.retire(key, matching: write)
                    case .leftInOriginalJournal:
                        retryable.removeValue(forKey: key)
                    case .retryWithBackoff:
                        var failed = write
                        failed.failedAttempts += 1
                        if failed.failedAttempts > retryPolicy.maximumAutomaticRetries {
                            failed.isHeld = true
                            log(key, "out of automatic retries", kept: true)
                        }
                        retryable[key] = failed
                    case .retryOnNextTrigger:
                        retryable[key] = write
                    }
                    // The failed ops are not in `pending` yet — they go back at the
                    // end of the drain — so the journal is the union of everything
                    // still owed.
                    persistLocked(alsoOwed: retryable)
                }
                if case .rejected = outcome {
                    rejected.append(key)
                }
            }
        }

        typealias Completion = ([CheckedContinuation<Void, Never>], (@Sendable (SettingKey) -> Void)?)
        let (resumed, rejectionObserver) = lock.withLock { () -> Completion in
            let currentScopeIdentifier = journal?.scopeIdentifier
            for (key, write) in retryable
                where write.scopeIdentifier == currentScopeIdentifier && pending[key] == nil {
                // A newer op enqueued during the drain wins over the failed one:
                // it is newer content.
                pending[key] = write
            }
            inFlight.removeAll()
            persistLocked()
            isDraining = false
            let resumed = waiters
            waiters.removeAll()

            // One timer for everything still retrying, paced by the op that
            // has failed least: an op further along its schedule is simply
            // sent a little early, which a desired-state write tolerates.
            // Ops waiting on a condition get no timer, and held ops wait for
            // the user.
            let retrying = retryable.compactMap { key, write -> Int? in
                guard pending[key] == write, !write.isHeld, write.failedAttempts > 0 else { return nil }
                return write.failedAttempts
            }
            if let attempt = retrying.min() {
                scheduleRetryLocked(attempt: attempt)
            }
            return (resumed, self.rejectionObserver)
        }

        for continuation in resumed {
            continuation.resume()
        }
        publishHeldKeys()
        for key in rejected {
            rejectionObserver?(key)
        }
    }

    /// Caller must hold `lock`.
    private func scheduleRetryLocked(attempt: Int) {
        let delay = retryPolicy.delay(forAttempt: attempt)
        retryTask?.cancel()
        retryGeneration &+= 1
        let generation = retryGeneration
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushAfterRetry(generation: generation)
        }
    }

    /// Retire a waking retry timer before it starts draining. Otherwise an
    /// overlapping explicit flush sees `retryTask` still pointing at the task
    /// executing the request and cancels that live URLSession operation.
    private func flushAfterRetry(generation: UInt64) async {
        let claimed = lock.withLock {
            let isCurrent = retryGeneration == generation
            if isCurrent {
                retryTask = nil
            }
            return isCurrent && claimDrainLocked()
        }
        guard claimed, !Task.isCancelled else { return }
        await drain()
    }

    // MARK: - Sending

    private func send(_ key: SettingKey, _ write: PendingSettingWrite) async -> FlushOutcome {
        if let journal, write.scopeIdentifier != journal.scopeIdentifier {
            log(
                key,
                "settings scope changed before send; owed by the original scope's journal",
                kept: true
            )
            return .leftInOriginalJournal
        }
        do {
            switch write.operation {
            case .set(let value):
                try await transport.putValue(key: key, value: value, profileId: write.profileId)
            case .delete:
                try await transport.deleteValue(key: key, profileId: write.profileId)
            }
            return .settled
        } catch let error as SettingsAPIError {
            return outcome(for: error, key: key, write: write)
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
        write: PendingSettingWrite
    ) -> FlushOutcome {
        if case .delete = write.operation {
            switch error {
            case .noValueAtScope:
                // Nothing stored at this scope, so the clear is already true: an
                // earlier attempt landed even if its response did not.
                return .settled
            case .serverUpgradeRequired:
                // A server with no canonical settings API cannot hold a row at
                // this scope. Locally resetting is therefore final; retaining
                // the DELETE would let it erase a future value after upgrade.
                log(key, "server predates canonical settings; reset locally", kept: false)
                return .settled
            default:
                break
            }
        }

        switch error.writeFailure {
        case .retry:
            // Retrying can help: the request never arrived, the server fell
            // over, throttled us, timed out, or the session token was mid
            // refresh.
            log(key, "transient failure: \(error)", kept: true)
            return .retryWithBackoff
        case .release:
            // The contract or the server refused the write, so sending the
            // same value would fail identically forever. Drop it — loudly,
            // because most of these are a client bug rather than a server
            // condition — and tell the settings screen once.
            log(key, "refused: \(error)", kept: false)
            return .rejected
        case .ownerChanged:
            // The write belongs to the owner that queued it. While that is
            // still the active partition it waits for the next trigger;
            // otherwise that partition's journal keeps it.
            if let journal, write.scopeIdentifier != journal.scopeIdentifier {
                log(key, "owner changed before the write landed; owed by its own partition", kept: true)
                return .leftInOriginalJournal
            }
            log(key, "owner changed before the write landed", kept: true)
            return .retryOnNextTrigger
        case .waitForCondition:
            // No profile selected yet, or the server does not serve the
            // canonical settings API. Only a user action or a reconnect fixes
            // that, so hold the user's choice rather than dropping it — but do
            // not spin a timer at it.
            log(key, "not sent: \(error)", kept: true)
            return .retryOnNextTrigger
        }
    }

    private func log(_ key: SettingKey, _ detail: String, kept: Bool) {
        let disposition = kept ? "kept" : "dropped"
        Self.logger.warning(
            "\(key.rawValue, privacy: .public): \(detail, privacy: .public); \(disposition, privacy: .public)"
        )
    }
}
