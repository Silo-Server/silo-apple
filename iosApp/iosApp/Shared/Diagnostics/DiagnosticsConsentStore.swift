#if os(iOS) || os(tvOS)
import Foundation

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

final class DiagnosticsConsentStore {
    static let shared = DiagnosticsConsentStore()

    private static let recordsKey = "diagnostics.consent.records.v1"
    private static let debugLoggingKey = "diagnostics.debugLoggingEnabled.v1"
    private static let sentHistoryKey = "diagnostics.sentHistory.v1"
    private static let sentHistoryLimit = 10

    private let defaults: SharedDefaults
    private let onNeverSelected: (DiagnosticsBinding) -> Void
    private let lock = NSLock()

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

    func record(
        for binding: DiagnosticsBinding,
        currentNoticeVersion: Int,
        now: Date = Date()
    ) -> DiagnosticsConsentRecord {
        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords()
        var record = records[binding.storageKey] ?? DiagnosticsConsentRecord(
            binding: binding,
            mode: .ask,
            noticeVersion: currentNoticeVersion,
            updatedAt: DiagnosticsTimestamp.string(from: now)
        )

        if record.mode == .always, record.noticeVersion != currentNoticeVersion {
            record.mode = .ask
            record.noticeVersion = currentNoticeVersion
            record.updatedAt = DiagnosticsTimestamp.string(from: now)
            records[binding.storageKey] = record
            saveRecords(records)
        } else if record.mode == .ask, record.noticeVersion != currentNoticeVersion {
            record.noticeVersion = currentNoticeVersion
            record.updatedAt = DiagnosticsTimestamp.string(from: now)
            records[binding.storageKey] = record
            saveRecords(records)
        }

        return record
    }

    func setMode(
        _ mode: DiagnosticsConsentChoice,
        for binding: DiagnosticsBinding,
        noticeVersion: Int,
        now: Date = Date()
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

        if mode == .never {
            onNeverSelected(binding)
        }
    }

    func persistentCaptureEnabled(
        for binding: DiagnosticsBinding,
        currentNoticeVersion: Int,
        now: Date = Date()
    ) -> Bool {
        record(for: binding, currentNoticeVersion: currentNoticeVersion, now: now).mode != .never
    }

    func remove(binding: DiagnosticsBinding) {
        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords()
        records.removeValue(forKey: binding.storageKey)
        saveRecords(records)
        var history = loadSentHistory()
        history.removeValue(forKey: binding.storageKey)
        saveSentHistory(history)
    }

    func remove(serverInstanceID: String) {
        lock.lock()
        defer { lock.unlock() }

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
        defer { lock.unlock() }

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
