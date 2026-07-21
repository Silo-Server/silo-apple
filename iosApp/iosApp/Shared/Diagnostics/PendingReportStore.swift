#if os(iOS) || os(tvOS)
import Foundation

struct DiagnosticsManifestDraft: Codable, Equatable {
    let schemaVersion: Int
    var report: DiagnosticsManifest.Report
    var destination: DiagnosticsManifest.Destination
    var consent: DiagnosticsManifest.Consent
    var crash: DiagnosticsCrashInfo?
    var deviceSummary: DiagnosticsManifest.DeviceSummary
    var playbackSessionIds: [String]
    var logSummary: DiagnosticsManifest.LogSummary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case report
        case destination
        case consent
        case crash
        case deviceSummary = "device_summary"
        case playbackSessionIds = "playback_session_ids"
        case logSummary = "log_summary"
    }

    func finalized(archive: DiagnosticsManifest.Archive) -> DiagnosticsManifest {
        DiagnosticsManifest(
            schemaVersion: schemaVersion,
            report: report,
            destination: destination,
            consent: consent,
            crash: crash,
            deviceSummary: deviceSummary,
            playbackSessionIds: playbackSessionIds,
            logSummary: logSummary,
            archive: archive
        )
    }
}

struct PendingReportBinding: Codable, Equatable {
    let serverInstanceID: String
    let accountUserID: String
    let profileID: String?
    let capturedAt: String
    let type: ReportType
    let fingerprint: String

    enum CodingKeys: String, CodingKey {
        case serverInstanceID = "server_instance_id"
        case accountUserID = "account_user_id"
        case profileID = "profile_id"
        case capturedAt = "captured_at"
        case type
        case fingerprint
    }

    var binding: DiagnosticsBinding {
        DiagnosticsBinding(serverInstanceID: serverInstanceID, accountUserID: accountUserID)
    }

    var capturedAtDate: Date {
        DiagnosticsDates.date(from: capturedAt) ?? .distantPast
    }
}

struct PendingReport: Identifiable, Equatable {
    let id: UUID
    let directoryURL: URL
    let binding: PendingReportBinding
    let manifest: DiagnosticsManifestDraft
    let state: PendingReportState

    var isExpired: Bool {
        Date().timeIntervalSince(binding.capturedAtDate) > PendingReportStore.expiryInterval
    }

    func isUploadable(to binding: DiagnosticsBinding) -> Bool {
        self.binding.binding == binding
    }
}

struct PendingReportState: Codable, Equatable {
    var needsServerUpdate: Bool
    /// The generated bundle exceeds the server's size limit. Like
    /// `needsServerUpdate`, this is a permanent local failure: retrying the
    /// same oversized payload will always be rejected, so it is excluded from
    /// auto-upload and prompting.
    var tooLarge: Bool
    /// The user tapped "Don't Send" on this report's Ask-mode prompt. Unlike a
    /// permanent failure the report stays visible and sendable from settings;
    /// this only suppresses re-prompting for the report's remaining lifetime.
    /// The auto-upload throttle alone can't do this — it expires in 24h while
    /// reports live 7 days, so the same crash would re-prompt on a later
    /// foreground.
    var promptDeclined: Bool

    static let empty = PendingReportState(needsServerUpdate: false)

    /// A permanent failure the client cannot resolve by retrying. Such reports
    /// are kept locally (for visibility) but never auto-uploaded or prompted.
    /// A declined prompt is not a permanent failure — the report can still be
    /// sent manually and auto-uploads under Always.
    var isPermanentFailure: Bool {
        needsServerUpdate || tooLarge
    }

    enum CodingKeys: String, CodingKey {
        case needsServerUpdate = "needs_server_update"
        case tooLarge = "too_large"
        case promptDeclined = "prompt_declined"
    }

    init(needsServerUpdate: Bool, tooLarge: Bool = false, promptDeclined: Bool = false) {
        self.needsServerUpdate = needsServerUpdate
        self.tooLarge = tooLarge
        self.promptDeclined = promptDeclined
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        needsServerUpdate = try container.decodeIfPresent(Bool.self, forKey: .needsServerUpdate) ?? false
        tooLarge = try container.decodeIfPresent(Bool.self, forKey: .tooLarge) ?? false
        promptDeclined = try container.decodeIfPresent(Bool.self, forKey: .promptDeclined) ?? false
    }
}

struct PendingReportArtifact: Equatable {
    let relativePath: String
    let data: Data
}

struct PendingReportCapture {
    var id: UUID = UUID()
    let binding: DiagnosticsBinding
    let profileID: String?
    let type: ReportType
    let fingerprint: String
    let capturedAt: Date
    let manifest: DiagnosticsManifestDraft
    let deviceSnapshot: DeviceSnapshotPayload
    let artifacts: [PendingReportArtifact]
}

struct DiagnosticsCaptureContext {
    let binding: DiagnosticsBinding
    let profileID: String?
    let consentMode: ConsentMode
    let noticeVersion: Int
    let appVersion: String
    let appBuild: String
    let platform: Platform
    let osVersion: String

    /// Returns a copy attributed to a different capturing profile — used when
    /// an abnormal-exit report must carry the profile that was active at crash
    /// time (from the marker) rather than the one active at capture time.
    func overridingProfileID(_ profileID: String?) -> DiagnosticsCaptureContext {
        DiagnosticsCaptureContext(
            binding: binding,
            profileID: profileID,
            consentMode: consentMode,
            noticeVersion: noticeVersion,
            appVersion: appVersion,
            appBuild: appBuild,
            platform: platform,
            osVersion: osVersion
        )
    }

    func makeManifestDraft(
        type: ReportType,
        capturedAt: Date,
        crash: DiagnosticsCrashInfo?,
        deviceSummary: DiagnosticsManifest.DeviceSummary,
        playbackSessionIDs: [String],
        captureSessionID: String = DiagLog.captureSessionID,
        consentMode: ConsentMode? = nil
    ) -> DiagnosticsManifestDraft {
        DiagnosticsManifestDraft(
            schemaVersion: 1,
            report: DiagnosticsManifest.Report(
                type: type,
                capturedAt: DiagnosticsTimestamp.string(from: capturedAt),
                captureSessionID: captureSessionID,
                appVersion: appVersion,
                appBuild: appBuild,
                platform: platform,
                osVersion: osVersion,
                profileID: profileID
            ),
            destination: DiagnosticsManifest.Destination(serverInstanceID: binding.serverInstanceID),
            consent: DiagnosticsManifest.Consent(mode: consentMode ?? self.consentMode, noticeVersion: noticeVersion),
            crash: crash,
            deviceSummary: deviceSummary,
            playbackSessionIds: Array(playbackSessionIDs.prefix(20)),
            logSummary: DiagnosticsManifest.LogSummary(
                lines: 0,
                bytesGz: 0,
                droppedLines: 0,
                categories: [],
                debugLogging: DiagnosticsConsentStore.shared.debugLoggingEnabled
            )
        )
    }
}

final class PendingReportStore {
    static let shared = PendingReportStore()
    static let expiryInterval: TimeInterval = 7 * 24 * 60 * 60

    private static let maxPendingPerBinding = 3
    private static let seenFingerprintsFile = "seen-fingerprints.json"
    private static let throttleFile = "auto-upload-throttle.json"

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.rootDirectory = rootDirectory ?? appSupport.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    var pendingDirectory: URL {
        rootDirectory
            .appendingPathComponent("pending", isDirectory: true)
    }

    @discardableResult
    func save(_ capture: PendingReportCapture) throws -> PendingReport {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectory(rootDirectory)
        try cleanupExpiredLocked(now: capture.capturedAt)

        let reportDirectory = pendingDirectory.appendingPathComponent(capture.id.uuidString.lowercased(), isDirectory: true)
        let stagingDirectory = pendingDirectory.appendingPathComponent(
            ".staging-\(capture.id.uuidString.lowercased())",
            isDirectory: true
        )
        try? fileManager.removeItem(at: stagingDirectory)

        let binding = PendingReportBinding(
            serverInstanceID: capture.binding.serverInstanceID,
            accountUserID: capture.binding.accountUserID,
            profileID: capture.profileID,
            capturedAt: DiagnosticsTimestamp.string(from: capture.capturedAt),
            type: capture.type,
            fingerprint: capture.fingerprint
        )

        var didPublishReportDirectory = false
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try excludeFromBackup(stagingDirectory)

            try writeJSON(capture.manifest, to: stagingDirectory.appendingPathComponent("manifest.json"))
            try writeJSON(binding, to: stagingDirectory.appendingPathComponent("binding.json"))
            try writeJSON(PendingReportState.empty, to: stagingDirectory.appendingPathComponent("state.json"))
            try writeJSON(capture.deviceSnapshot, to: stagingDirectory.appendingPathComponent("device.json"))

            for artifact in capture.artifacts {
                guard DiagnosticsManifest.Archive.allowedEntries.contains(artifact.relativePath),
                      artifact.relativePath != "manifest.json",
                      artifact.relativePath != "device.json",
                      !artifact.relativePath.contains("..") else {
                    throw DiagnosticsStoreError.invalidArtifactPath(artifact.relativePath)
                }
                let url = stagingDirectory.appendingPathComponent(artifact.relativePath, isDirectory: false)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try artifact.data.write(to: url, options: .atomic)
            }

            try fileManager.moveItem(at: stagingDirectory, to: reportDirectory)
            didPublishReportDirectory = true
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            if didPublishReportDirectory {
                try? fileManager.removeItem(at: reportDirectory)
            }
            throw error
        }

        markFingerprintSeenLocked(capture.fingerprint, now: capture.capturedAt)
        try enforceCapLocked(for: capture.binding)

        guard let report = loadReport(from: reportDirectory) else {
            throw DiagnosticsStoreError.unreadableReport(capture.id)
        }
        return report
    }

    func listReports(for binding: DiagnosticsBinding? = nil, now: Date? = nil) -> [PendingReport] {
        lock.lock()
        defer { lock.unlock() }

        try? ensureDirectory(rootDirectory)
        if let now {
            try? cleanupExpiredLocked(now: now)
        }

        return scanReportsLocked()
            .filter { report in
                guard let binding else { return true }
                return report.binding.binding == binding
            }
            .sorted { $0.binding.capturedAtDate < $1.binding.capturedAtDate }
    }

    func report(id: UUID, now: Date = Date()) -> PendingReport? {
        listReports(now: now).first(where: { $0.id == id })
    }

    func purge(binding: DiagnosticsBinding) {
        lock.lock()
        defer { lock.unlock() }

        for report in scanReportsLocked() where report.binding.binding == binding {
            try? fileManager.removeItem(at: report.directoryURL)
        }
    }

    func purge(serverInstanceID: String) {
        lock.lock()
        defer { lock.unlock() }

        for report in scanReportsLocked() where report.binding.serverInstanceID == serverInstanceID {
            try? fileManager.removeItem(at: report.directoryURL)
        }
    }

    func delete(_ report: PendingReport) {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: report.directoryURL)
    }

    func hasSeenFingerprint(_ fingerprint: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pruneFingerprintStateLocked(now: now)
        return loadDateMap(Self.seenFingerprintsFile)[fingerprint] != nil
    }

    func markFingerprintSeen(_ fingerprint: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        markFingerprintSeenLocked(fingerprint, now: now)
    }

    func canAutoUpload(fingerprint: String, binding: DiagnosticsBinding, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let key = throttleKey(fingerprint: fingerprint, binding: binding)
        guard let last = loadDateMap(Self.throttleFile)[key] else {
            return true
        }
        return now.timeIntervalSince(last) >= 24 * 60 * 60
    }

    func recordAutoUploadAttempt(fingerprint: String, binding: DiagnosticsBinding, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var state = loadDateMap(Self.throttleFile)
        state[throttleKey(fingerprint: fingerprint, binding: binding)] = now
        saveDateMap(state, fileName: Self.throttleFile)
    }

    func markNeedsServerUpdate(_ report: PendingReport) {
        lock.lock()
        defer { lock.unlock() }

        var state = report.state
        state.needsServerUpdate = true
        try? writeJSON(state, to: report.directoryURL.appendingPathComponent("state.json"))
    }

    func markTooLarge(_ report: PendingReport) {
        lock.lock()
        defer { lock.unlock() }

        var state = report.state
        state.tooLarge = true
        try? writeJSON(state, to: report.directoryURL.appendingPathComponent("state.json"))
    }

    /// Records that the user declined this report's prompt, suppressing further
    /// prompts for its lifetime while leaving it sendable from settings.
    func markPromptDeclined(_ report: PendingReport) {
        lock.lock()
        defer { lock.unlock() }

        var state = report.state
        state.promptDeclined = true
        try? writeJSON(state, to: report.directoryURL.appendingPathComponent("state.json"))
    }

    /// Rewrites the stored manifest's consent `mode` and `notice_version` so an
    /// upload built from this report reflects the current consent record. If
    /// the server's notice advanced after capture and demoted the account
    /// Always→Ask, refreshing only the notice version would leave the manifest
    /// claiming `mode = always` for the new notice; refreshing the mode too
    /// keeps it honest. Everything else — crash evidence, logs, device summary
    /// — stays frozen as captured. Returns the updated report, or the original
    /// if nothing changed or the rewrite failed.
    @discardableResult
    func updatingConsent(_ report: PendingReport, mode: ConsentMode, noticeVersion: Int) -> PendingReport {
        lock.lock()
        defer { lock.unlock() }

        guard report.manifest.consent.mode != mode
            || report.manifest.consent.noticeVersion != noticeVersion else {
            return report
        }
        var manifest = report.manifest
        manifest.consent = DiagnosticsManifest.Consent(
            mode: mode,
            noticeVersion: noticeVersion
        )
        do {
            try writeJSON(manifest, to: report.directoryURL.appendingPathComponent("manifest.json"))
        } catch {
            return report
        }
        return PendingReport(
            id: report.id,
            directoryURL: report.directoryURL,
            binding: report.binding,
            manifest: manifest,
            state: report.state
        )
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: rootDirectory)
    }

    private func scanReportsLocked() -> [PendingReport] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return urls.compactMap(loadReport(from:))
    }

    private func loadReport(from directory: URL) -> PendingReport? {
        guard let uuid = UUID(uuidString: directory.lastPathComponent),
              let binding = readJSON(PendingReportBinding.self, from: directory.appendingPathComponent("binding.json")),
              let manifest = readJSON(DiagnosticsManifestDraft.self, from: directory.appendingPathComponent("manifest.json")) else {
            return nil
        }
        let state = readJSON(PendingReportState.self, from: directory.appendingPathComponent("state.json")) ?? .empty
        return PendingReport(id: uuid, directoryURL: directory, binding: binding, manifest: manifest, state: state)
    }

    private func cleanupExpiredLocked(now: Date) throws {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls {
            guard let report = loadReport(from: url) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            if now.timeIntervalSince(report.binding.capturedAtDate) > Self.expiryInterval {
                try? fileManager.removeItem(at: url)
            }
        }
        pruneFingerprintStateLocked(now: now)
    }

    private func enforceCapLocked(for binding: DiagnosticsBinding) throws {
        let reports = scanReportsLocked()
            .filter { $0.binding.binding == binding }
            .sorted { $0.binding.capturedAtDate < $1.binding.capturedAtDate }
        guard reports.count > Self.maxPendingPerBinding else {
            return
        }
        for report in reports.prefix(reports.count - Self.maxPendingPerBinding) {
            try? fileManager.removeItem(at: report.directoryURL)
        }
    }

    private func markFingerprintSeenLocked(_ fingerprint: String, now: Date) {
        var state = loadDateMap(Self.seenFingerprintsFile)
        state[fingerprint] = now
        saveDateMap(state, fileName: Self.seenFingerprintsFile)
    }

    private func pruneFingerprintStateLocked(now: Date) {
        var seen = loadDateMap(Self.seenFingerprintsFile)
        seen = seen.filter { now.timeIntervalSince($0.value) <= 30 * 24 * 60 * 60 }
        saveDateMap(seen, fileName: Self.seenFingerprintsFile)

        var throttle = loadDateMap(Self.throttleFile)
        throttle = throttle.filter { now.timeIntervalSince($0.value) <= 30 * 24 * 60 * 60 }
        saveDateMap(throttle, fileName: Self.throttleFile)
    }

    private func throttleKey(fingerprint: String, binding: DiagnosticsBinding) -> String {
        "\(binding.storageKey)|\(fingerprint)"
    }

    private func loadDateMap(_ fileName: String) -> [String: Date] {
        let url = rootDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let strings = try? DiagnosticsJSONCoding.makeDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return strings.compactMapValues(DiagnosticsDates.date(from:))
    }

    private func saveDateMap(_ map: [String: Date], fileName: String) {
        try? ensureDirectory(rootDirectory)
        let strings = map.mapValues(DiagnosticsTimestamp.string(from:))
        guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(strings) else {
            return
        }
        try? data.write(to: rootDirectory.appendingPathComponent(fileName), options: .atomic)
    }

    private func ensureDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try excludeFromBackup(pendingDirectory)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? DiagnosticsJSONCoding.makeDecoder().decode(T.self, from: data)
    }
}

enum DiagnosticsStoreError: Error, Equatable {
    case invalidArtifactPath(String)
    case unreadableReport(UUID)
}

enum DiagnosticsDates {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        fractional.date(from: value) ?? whole.date(from: value)
    }
}

#endif
