#if os(iOS) || os(tvOS)
import Foundation
import os

struct DiagnosticsBinding: Codable, Equatable, Hashable, Sendable {
    let serverInstanceID: String
    let accountUserID: String

    enum CodingKeys: String, CodingKey {
        case serverInstanceID = "server_instance_id"
        case accountUserID = "account_user_id"
    }

    var storageKey: String {
        "\(serverInstanceID)|\(accountUserID)"
    }
}

enum DiagnosticsConsentChoice: String, Codable, Equatable, CaseIterable, Sendable {
    case ask
    case always
    case never

    var manifestMode: ConsentMode {
        switch self {
        case .ask, .never:
            return .prompt
        case .always:
            return .always
        }
    }
}

struct DiagnosticsConsentRecord: Codable, Equatable, Sendable {
    let binding: DiagnosticsBinding
    var mode: DiagnosticsConsentChoice
    var noticeVersion: Int
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case binding
        case mode
        case noticeVersion = "notice_version"
        case updatedAt = "updated_at"
    }
}

struct DiagnosticsSentReport: Codable, Equatable, Identifiable, Sendable {
    let shortID: String
    let sentAt: String

    var id: String { "\(shortID)|\(sentAt)" }
}

/// Monotonic counter for consent mutations, read from the synchronous log
/// gate on every thread. Its only job is to let a cached capture decision
/// notice that stored consent changed underneath it, so it is deliberately
/// separate from the store's `NSLock`: it is bumped *after* a write is durable
/// and is never held across a `UserDefaults` access.
final class DiagnosticsConsentMutationCounter: @unchecked Sendable {
    /// `OSAllocatedUnfairLock` rather than a stored `os_unfair_lock_s`: locking
    /// the latter through `&lock` passes an inout access, which the compiler may
    /// satisfy with a temporary copy, so concurrent callers can end up locking
    /// different memory and the mutual exclusion silently disappears. This type
    /// owns stable allocated storage, so every caller locks the same word.
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    var value: UInt64 {
        generation.withLock { $0 }
    }

    func bump() {
        generation.withLock { $0 &+= 1 }
    }
}

final class DiagnosticsConsentStore {
    static let shared = DiagnosticsConsentStore()

    private static let recordsKey = "diagnostics.consent.records.v1"
    private static let debugLoggingKey = "diagnostics.debugLoggingEnabled.v1"
    private static let sentHistoryKey = "diagnostics.sentHistory.v1"
    private static let sentHistoryLimit = 10

    private let defaults: SharedDefaults
    private let onNeverSelected: (DiagnosticsBinding) -> Void
    private let lock = NSLock()
    private let mutationCounter = DiagnosticsConsentMutationCounter()

    /// Bumped by every mutation that can change what `persistentCaptureEnabled`
    /// answers for some binding: mode changes, record removal, and test resets.
    /// Callers that memoize a capture decision key it on this value so a
    /// consent revocation invalidates the memo immediately.
    var mutationGeneration: UInt64 { mutationCounter.value }

    init(
        defaults: SharedDefaults = .shared,
        onNeverSelected: @escaping (DiagnosticsBinding) -> Void = { binding in
            PendingReportStore.shared.purge(binding: binding)
            RecentSessionTracker.shared.purge(binding: binding)
            DiagnosticsCoordinator.purgeBreadcrumbJournal()
            DiagLog.ring.clear()
            #if os(tvOS)
            // Turning Crash Reports to Never must also disarm the exit sentinel.
            // The armed marker is otherwise only cleared on a normal
            // background/terminate, so a crash in this same foreground would
            // leave it as a leftover that could still surface as an
            // abnormal-exit report if the user later switches back to
            // Ask/Always — reporting a run that happened after collection was
            // turned off.
            ExitSentinel.shared.purge()
            #endif
        }
    ) {
        self.defaults = defaults
        self.onNeverSelected = onNeverSelected
    }

    var debugLoggingEnabled: Bool {
        get { defaults.bool(forKey: Self.debugLoggingKey) }
        set { defaults.set(newValue, forKey: Self.debugLoggingKey) }
    }

    /// Resolve *and persist* the effective consent record, applying the notice
    /// re-consent migration. Every caller of this is an explicit diagnostics
    /// action (a status refresh, a capture-context build, the settings screen);
    /// the synchronous log gate deliberately uses `resolvedRecord` instead so
    /// asking "should I log this line?" can never write to `UserDefaults`.
    func record(
        for binding: DiagnosticsBinding,
        currentNoticeVersion: Int,
        now: Date = Date()
    ) -> DiagnosticsConsentRecord {
        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords()
        let stored = records[binding.storageKey]
        let record = Self.resolve(
            stored: stored,
            binding: binding,
            currentNoticeVersion: currentNoticeVersion,
            now: now
        )
        if let stored, stored != record {
            records[binding.storageKey] = record
            saveRecords(records)
            // Persisted consent for this binding changed shape; any memoized
            // capture decision keyed on the generation must re-resolve.
            mutationCounter.bump()
        }

        return record
    }

    /// The same resolution with no persistence and no side effects. A record
    /// that has never been stored resolves to the default `.ask`; a stored one
    /// gets the notice-version migration applied in memory only.
    ///
    /// The migration cannot change the answer `persistentCaptureEnabled` gives
    /// — it only ever rewrites `.always` to `.ask`, and both are "not never" —
    /// so reading through here is behavior-identical to reading through
    /// `record(for:)` while leaving the durable write to explicit call sites.
    func resolvedRecord(
        for binding: DiagnosticsBinding,
        currentNoticeVersion: Int,
        now: Date = Date()
    ) -> DiagnosticsConsentRecord {
        lock.lock()
        defer { lock.unlock() }
        return Self.resolve(
            stored: loadRecords()[binding.storageKey],
            binding: binding,
            currentNoticeVersion: currentNoticeVersion,
            now: now
        )
    }

    private static func resolve(
        stored: DiagnosticsConsentRecord?,
        binding: DiagnosticsBinding,
        currentNoticeVersion: Int,
        now: Date
    ) -> DiagnosticsConsentRecord {
        var record = stored ?? DiagnosticsConsentRecord(
            binding: binding,
            mode: .ask,
            noticeVersion: currentNoticeVersion,
            updatedAt: DiagnosticsTimestamp.string(from: now)
        )

        if record.mode == .always, record.noticeVersion != currentNoticeVersion {
            record.mode = .ask
            record.noticeVersion = currentNoticeVersion
            record.updatedAt = DiagnosticsTimestamp.string(from: now)
        } else if record.mode == .ask, record.noticeVersion != currentNoticeVersion {
            record.noticeVersion = currentNoticeVersion
            record.updatedAt = DiagnosticsTimestamp.string(from: now)
        }

        return record
    }

    func setMode(
        _ mode: DiagnosticsConsentChoice,
        for binding: DiagnosticsBinding,
        noticeVersion: Int,
        now: Date = Date(),
        purgeImmediately: Bool = true
    ) {
        lock.lock()
        var records = loadRecords()
        records[binding.storageKey] = DiagnosticsConsentRecord(
            binding: binding,
            mode: mode,
            noticeVersion: noticeVersion,
            updatedAt: DiagnosticsTimestamp.string(from: now)
        )
        saveRecords(records)
        lock.unlock()
        // Publish before the purge callback runs: `onNeverSelected` clears the
        // ring and journal, and any log emitted during that teardown must
        // already see the revoked decision rather than a stale cached `true`.
        mutationCounter.bump()

        if mode == .never, purgeImmediately {
            onNeverSelected(binding)
        }
    }

    /// Whether stored consent permits capture for `binding`. Deliberately reads
    /// through `resolvedRecord`, not `record(for:)`: this is the predicate the
    /// synchronous log gate ends up calling, and evaluating "should I log?"
    /// must never mutate persisted consent. The notice-version migration it
    /// skips is performed by the explicit diagnostics call sites (status
    /// refresh, capture-context build, settings screen) and cannot change this
    /// answer anyway — it only rewrites `.always` to `.ask`.
    func persistentCaptureEnabled(
        for binding: DiagnosticsBinding,
        currentNoticeVersion: Int,
        now: Date = Date()
    ) -> Bool {
        resolvedRecord(
            for: binding,
            currentNoticeVersion: currentNoticeVersion,
            now: now
        ).mode != .never
    }

    func remove(binding: DiagnosticsBinding) {
        lock.lock()
        defer {
            lock.unlock()
            mutationCounter.bump()
        }

        var records = loadRecords()
        records.removeValue(forKey: binding.storageKey)
        saveRecords(records)
        var history = loadSentHistory()
        history.removeValue(forKey: binding.storageKey)
        saveSentHistory(history)
    }

    func remove(serverInstanceID: String) {
        lock.lock()
        defer {
            lock.unlock()
            mutationCounter.bump()
        }

        var records = loadRecords()
        records = records.filter { _, record in
            record.binding.serverInstanceID != serverInstanceID
        }
        saveRecords(records)
        var history = loadSentHistory()
        history = history.filter { key, _ in
            !key.hasPrefix("\(serverInstanceID)|")
        }
        saveSentHistory(history)
    }

    func recordSent(shortID: String, for binding: DiagnosticsBinding, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var history = loadSentHistory()
        var reports = history[binding.storageKey] ?? []
        reports.removeAll { $0.shortID == shortID }
        reports.insert(
            DiagnosticsSentReport(
                shortID: shortID,
                sentAt: DiagnosticsTimestamp.string(from: now)
            ),
            at: 0
        )
        history[binding.storageKey] = Array(reports.prefix(Self.sentHistoryLimit))
        saveSentHistory(history)
    }

    func sentHistory(for binding: DiagnosticsBinding) -> [DiagnosticsSentReport] {
        lock.lock()
        defer { lock.unlock() }
        return loadSentHistory()[binding.storageKey] ?? []
    }

    func resetForTests() {
        lock.lock()
        defer {
            lock.unlock()
            mutationCounter.bump()
        }

        defaults.removeObject(forKey: Self.recordsKey)
        defaults.removeObject(forKey: Self.debugLoggingKey)
        defaults.removeObject(forKey: Self.sentHistoryKey)
    }

    static func canManageDiagnostics(profile: UserProfile?) -> Bool {
        profile?.isChild == false
    }

    private func loadRecords() -> [String: DiagnosticsConsentRecord] {
        guard let data = defaults.data(forKey: Self.recordsKey) else {
            return [:]
        }
        return (try? DiagnosticsJSONCoding.makeDecoder().decode(
            [String: DiagnosticsConsentRecord].self,
            from: data
        )) ?? [:]
    }

    private func saveRecords(_ records: [String: DiagnosticsConsentRecord]) {
        guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: Self.recordsKey)
    }

    private func loadSentHistory() -> [String: [DiagnosticsSentReport]] {
        guard let data = defaults.data(forKey: Self.sentHistoryKey) else {
            return [:]
        }
        return (try? DiagnosticsJSONCoding.makeDecoder().decode(
            [String: [DiagnosticsSentReport]].self,
            from: data
        )) ?? [:]
    }

    private func saveSentHistory(_ history: [String: [DiagnosticsSentReport]]) {
        guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(history) else {
            return
        }
        defaults.set(data, forKey: Self.sentHistoryKey)
    }
}
#endif
