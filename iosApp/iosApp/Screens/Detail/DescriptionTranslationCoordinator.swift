import Foundation

/// Drives one on-view "translate this description" run at a time.
///
/// The server has no job-status endpoint for description translation: you
/// `POST /api/v2/catalog/items/{id}/translate-description` and then observe completion by
/// re-reading whatever shows the text until it no longer reports a pending
/// language (the localized overview lands within seconds). This coordinator
/// owns that POST-then-poll loop, its bounded schedule, and the `idle /
/// translating / failed` UI state. The caller supplies the read (`fetch`) and
/// publishes it (`apply`), so the same loop serves an item detail, a season's
/// episode list, and a hero card.
///
/// Automatic runs start once per item and language (``Key``); an explicit
/// ``translate(_:fetch:apply:)`` may run again after a failure. One in-flight
/// run at a time; ``cancel()`` on disappear.
@MainActor
@Observable
final class DescriptionTranslationCoordinator {
    /// The item a job translates and the language it translates into: always
    /// the `pending_translation_language` the server reported.
    struct Key: Hashable, Sendable {
        let contentId: String
        let targetLanguage: String
    }

    enum Phase: Equatable {
        case idle
        case translating
        case failed
    }

    private(set) var phase: Phase = .idle
    /// The item and language of the current or most recent run.
    private(set) var key: Key?

    /// Re-read schedule. The overview typically lands within the first
    /// passes; the tail covers a slow translation. The sum (~45 s) is the cap
    /// after which the run gives up and reports `.failed`, as web does.
    nonisolated static let defaultSchedule: [Duration] = [1, 2, 2, 3, 3, 4, 5, 5, 5, 5, 5, 5].map { .seconds($0) }

    private let api: SiloAI
    private let schedule: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeRunID: UUID?
    /// Keys an automatic run already started for, so a re-appearing view or a
    /// re-read that still reports the language does not start another job.
    @ObservationIgnored private var automaticKeys: Set<Key> = []

    init(
        api: SiloAI = .shared,
        schedule: [Duration] = DescriptionTranslationCoordinator.defaultSchedule,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.schedule = schedule
        self.sleep = sleep
    }

    var isRunning: Bool { task != nil }

    func isTranslating(_ key: Key) -> Bool {
        phase == .translating && self.key == key
    }

    func hasFailed(_ key: Key) -> Bool {
        phase == .failed && self.key == key
    }

    /// The `auto` on-view mode: start once per key. Returns whether a run
    /// started.
    @discardableResult
    func translateAutomatically<Value>(
        _ key: Key,
        fetch: @escaping @MainActor () async -> Value?,
        apply: @escaping @MainActor (Value) -> Bool
    ) -> Bool {
        guard !automaticKeys.contains(key) else { return false }
        guard translate(key, fetch: fetch, apply: apply) else { return false }
        automaticKeys.insert(key)
        return true
    }

    /// Start a run for `key`. `fetch` re-reads the surface showing the text
    /// (nil for a transient failure); `apply` publishes the read and returns
    /// true once it no longer reports a pending language. No-op while a run
    /// is in flight; returns whether a run started.
    @discardableResult
    func translate<Value>(
        _ key: Key,
        fetch: @escaping @MainActor () async -> Value?,
        apply: @escaping @MainActor (Value) -> Bool
    ) -> Bool {
        guard task == nil, !key.contentId.isEmpty, !key.targetLanguage.isEmpty else { return false }
        self.key = key
        phase = .translating
        let runID = UUID()
        activeRunID = runID
        task = Task { [weak self] in
            await self?.run(key, runID: runID, fetch: fetch, apply: apply)
        }
        return true
    }

    /// Cancel any in-flight run and reset to idle. A cancelled automatic run
    /// may start again the next time its surface appears. Safe to call from
    /// `onDisappear`.
    func cancel() {
        if phase == .translating, let key { automaticKeys.remove(key) }
        activeRunID = nil
        task?.cancel()
        task = nil
        if phase == .translating { phase = .idle }
    }

    /// Forget every run and latch: the account, profile or metadata language
    /// changed, so the same item may need a new translation.
    func reset() {
        cancel()
        automaticKeys.removeAll()
        key = nil
        phase = .idle
    }

    private func run<Value>(
        _ key: Key,
        runID: UUID,
        fetch: @escaping @MainActor () async -> Value?,
        apply: @escaping @MainActor (Value) -> Bool
    ) async {
        defer {
            if activeRunID == runID {
                activeRunID = nil
                task = nil
            }
        }

        // Capture the owner once: the POST runs for it, and a read is
        // applied only while it is still current.
        let auth: CapturedOrdinaryRequestAuth
        do {
            auth = try await api.captureAuthority()
        } catch {
            return fail(runID)
        }
        guard isCurrentRun(runID) else { return }
        do {
            let job = try await api.translateDescription(
                contentId: key.contentId,
                targetLanguage: key.targetLanguage,
                auth: auth
            )
            guard isCurrentRun(runID) else { return }
            // The server may return a recently failed job without new work.
            if job.failed { return fail(runID) }
        } catch {
            guard isCurrentRun(runID) else { return }
            // Refused (422: nothing is missing any more, for example because
            // another surface's job finished) or rate limited (429). One read
            // shows whether the text is already there.
            if await readOnce(runID: runID, auth: auth, fetch: fetch, apply: apply) == true {
                phase = .idle
            } else {
                fail(runID)
            }
            return
        }

        for delay in schedule {
            guard isCurrentRun(runID) else { return }
            try? await sleep(delay)
            guard let done = await readOnce(runID: runID, auth: auth, fetch: fetch, apply: apply) else {
                // Cancelled, or the owner changed (already reported).
                return
            }
            if done {
                phase = .idle
                return
            }
        }

        // Cap hit without the pending language clearing.
        fail(runID)
    }

    /// One read and publish for the run's owner. Nil when the run ended
    /// (cancelled or the owner changed); otherwise whether the text arrived.
    private func readOnce<Value>(
        runID: UUID,
        auth: CapturedOrdinaryRequestAuth,
        fetch: @MainActor () async -> Value?,
        apply: @MainActor (Value) -> Bool
    ) async -> Bool? {
        guard isCurrentRun(runID) else { return nil }
        guard await api.matchesAuthority(auth) else {
            fail(runID)
            return nil
        }
        guard isCurrentRun(runID) else { return nil }
        guard let value = await fetch() else { return false }
        // A cancellation (disappear / item change) may have landed during
        // the read; never publish a stale read over the next item's state.
        guard isCurrentRun(runID) else { return nil }
        // Nor publish a read made after the account or profile changed.
        guard await api.matchesAuthority(auth) else {
            fail(runID)
            return nil
        }
        guard isCurrentRun(runID) else { return nil }
        return apply(value)
    }

    private func fail(_ runID: UUID) {
        guard isCurrentRun(runID) else { return }
        phase = .failed
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        activeRunID == runID && !Task.isCancelled
    }
}
