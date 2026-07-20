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

final class DiagnosticsConsentStore {
    static let shared = DiagnosticsConsentStore()

    private static let recordsKey = "diagnostics.consent.records.v1"
    private static let debugLoggingKey = "diagnostics.debugLoggingEnabled.v1"

    private let defaults: SharedDefaults
    private let onNeverSelected: (DiagnosticsBinding) -> Void
    private let lock = NSLock()

    init(
        defaults: SharedDefaults = .shared,
        onNeverSelected: @escaping (DiagnosticsBinding) -> Void = { binding in
            PendingReportStore.shared.purge(binding: binding)
            DiagnosticsCoordinator.purgeBreadcrumbJournal()
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
    }

    func remove(serverInstanceID: String) {
        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords()
        records = records.filter { _, record in
            record.binding.serverInstanceID != serverInstanceID
        }
        saveRecords(records)
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }

        defaults.removeObject(forKey: Self.recordsKey)
        defaults.removeObject(forKey: Self.debugLoggingKey)
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
}
#endif
