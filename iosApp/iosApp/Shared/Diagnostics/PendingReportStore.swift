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
    var hostedEnvelopeGeneration: String?
    var hostedConsentRefreshRequired: Bool
    var hostedRemoteShortID: String?
    var hostedRejectionCode: String?

    static let empty = PendingReportState(needsServerUpdate: false)

    /// A permanent failure the client cannot resolve by retrying. Such reports
    /// are kept locally (for visibility) but never auto-uploaded or prompted.
    /// A declined prompt is not a permanent failure — the report can still be
    /// sent manually and auto-uploads under Always.
    var isPermanentFailure: Bool {
        needsServerUpdate || tooLarge || hostedRejectionCode != nil
    }

    /// The collector has accepted this hosted report and local actions should
    /// poll its status rather than offering to send it again.
    var isAwaitingHostedStatus: Bool {
        hostedRemoteShortID != nil && hostedRejectionCode == nil
    }

    enum CodingKeys: String, CodingKey {
        case needsServerUpdate = "needs_server_update"
        case tooLarge = "too_large"
        case promptDeclined = "prompt_declined"
        case hostedEnvelopeGeneration = "hosted_envelope_generation"
        case hostedConsentRefreshRequired = "hosted_consent_refresh_required"
        case hostedRemoteShortID = "hosted_remote_short_id"
        case hostedRejectionCode = "hosted_rejection_code"
    }

    init(
        needsServerUpdate: Bool,
        tooLarge: Bool = false,
        promptDeclined: Bool = false,
        hostedEnvelopeGeneration: String? = nil,
        hostedConsentRefreshRequired: Bool = false,
        hostedRemoteShortID: String? = nil,
        hostedRejectionCode: String? = nil
    ) {
        self.needsServerUpdate = needsServerUpdate
        self.tooLarge = tooLarge
        self.promptDeclined = promptDeclined
        self.hostedEnvelopeGeneration = hostedEnvelopeGeneration
        self.hostedConsentRefreshRequired = hostedConsentRefreshRequired
        self.hostedRemoteShortID = hostedRemoteShortID
        self.hostedRejectionCode = hostedRejectionCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        needsServerUpdate = try container.decodeIfPresent(Bool.self, forKey: .needsServerUpdate) ?? false
        tooLarge = try container.decodeIfPresent(Bool.self, forKey: .tooLarge) ?? false
        promptDeclined = try container.decodeIfPresent(Bool.self, forKey: .promptDeclined) ?? false
        hostedEnvelopeGeneration = try container.decodeIfPresent(
            String.self,
            forKey: .hostedEnvelopeGeneration
        )
        hostedConsentRefreshRequired = try container.decodeIfPresent(
            Bool.self,
            forKey: .hostedConsentRefreshRequired
        ) ?? false
        hostedRemoteShortID = try container.decodeIfPresent(String.self, forKey: .hostedRemoteShortID)
        hostedRejectionCode = try container.decodeIfPresent(String.self, forKey: .hostedRejectionCode)
    }
}

enum HostedEnvelopeLoadResult {
    case missing
    case available(DiagnosticsBundleBuildResult)
    case corrupt
    /// An erasure ledger exists but cannot be trusted. The report remains on
    /// disk, hidden and non-uploadable, until the ledger can be recovered.
    case quarantined
}

struct HostedDeletionRetryBatch {
    let reportIDs: [UUID]
    let hasBlockedLocalEvidence: Bool
    let hasCorruptLedger: Bool
}

private struct HostedReadyReceipt: Codable, Equatable {
    let binding: DiagnosticsBinding
    let readyAt: String

    enum CodingKeys: String, CodingKey {
        case binding
        case readyAt = "ready_at"
    }
}

private struct HostedErasureLedgers {
    let deletionIntents: [String: String]
    let readyReceipts: [String: HostedReadyReceipt]
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
    var destinationServerInstanceID: String? = nil
    var maxBundleBytes: Int? = nil
    var maxManifestBytes: Int? = nil
    var availabilityStatus: DiagnosticsAvailabilityStatus = .available
    /// Process-local credential-owner epoch that produced a live hosted
    /// binding. It is never serialized into the report; the upload path uses
    /// it only to prevent evidence captured for account A from crossing a
    /// same-server account replacement before the collector POST.
    var hostedCredentialIdentity: RefreshAccountIdentity? = nil

    var destinationChoice: DiagnosticsDestinationChoice {
        binding.destinationChoice
    }

    /// Returns a copy attributed to a different capturing profile — used when
    /// an abnormal-exit report must carry the profile that was active at crash
    /// time (from the marker) rather than the one active at capture time.
    func overridingProfileID(_ profileID: String?) -> DiagnosticsCaptureContext {
        DiagnosticsCaptureContext(
            binding: binding,
            profileID: destinationChoice == .hosted ? nil : profileID,
            consentMode: consentMode,
            noticeVersion: noticeVersion,
            appVersion: appVersion,
            appBuild: appBuild,
            platform: platform,
            osVersion: osVersion,
            destinationServerInstanceID: destinationServerInstanceID,
            maxBundleBytes: maxBundleBytes,
            maxManifestBytes: maxManifestBytes,
            availabilityStatus: availabilityStatus,
            hostedCredentialIdentity: hostedCredentialIdentity
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
                profileID: destinationChoice == .hosted ? nil : profileID
            ),
            destination: DiagnosticsManifest.Destination(
                serverInstanceID: destinationServerInstanceID ?? binding.serverInstanceID
            ),
            consent: DiagnosticsManifest.Consent(mode: consentMode ?? self.consentMode, noticeVersion: noticeVersion),
            crash: crash,
            deviceSummary: deviceSummary,
            playbackSessionIds: destinationChoice == .hosted
                ? []
                : Array(playbackSessionIDs.prefix(20)),
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
    /// READY receipts outlive the collector's 30-day retention window with a
    /// local-report-lifetime margin. They contain no evidence or remote short
    /// ID—only the random report UUID and its local consent binding.
    static let hostedReadyReceiptInterval: TimeInterval = 37 * 24 * 60 * 60

    private static let maxPendingPerBinding = 3
    private static let maxHostedReadyReceipts = 4_096
    private static let maxHostedDeletionIntents = 4_096
    /// Bounds defensive reads before allocating ledger contents. Four thousand
    /// receipts fit comfortably below this ceiling while corrupt/hostile files
    /// cannot consume unbounded memory at launch.
    static let maxHostedErasureLedgerBytes = 2 * 1024 * 1024
    private static let seenFingerprintsFile = "seen-fingerprints.json"
    private static let throttleFile = "auto-upload-throttle.json"
    private static let hostedDeletionIntentsFile = "hosted-deletion-intents.json"
    private static let hostedReadyReceiptsFile = "hosted-ready-receipts.json"
    private static let hostedEnvelopePrefix = ".hosted-envelope-"
    private static let hostedEnvelopeStagingPrefix = ".hosted-envelope-staging-"

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let hostedDeletionRemover: (URL) throws -> Void
    private let lock = NSLock()

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        hostedDeletionRemover: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.hostedDeletionRemover = hostedDeletionRemover ?? { url in
            try fileManager.removeItem(at: url)
        }
        self.rootDirectory = rootDirectory ?? DiagnosticsStorageRoot.baseDirectory(fileManager: fileManager)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        lock.lock()
        try? reconcileHostedReadyReceiptsLocked(now: Date())
        lock.unlock()
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
        if capture.binding.destinationChoice == .hosted {
            // Do not create newly uploadable hosted evidence while existing
            // erasure state is quarantined. Missing ledgers are the one valid
            // empty state; present-but-unreadable files throw here.
            _ = try loadHostedErasureLedgersLocked()
        }
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
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }

        try enforceCapLocked(for: capture.binding)

        guard let report = loadReport(from: reportDirectory) else {
            throw DiagnosticsStoreError.unreadableReport(capture.id)
        }
        // A delayed capture can be older than every retained report and be
        // evicted immediately by the cap. Only suppress future delivery after
        // confirming this report actually survived retention.
        markFingerprintSeenLocked(capture.fingerprint, now: capture.capturedAt)
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

    @discardableResult
    func purge(binding: DiagnosticsBinding) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let reports = binding.destinationChoice == .selfHosted
            ? scanSelfHostedReportsLocked()
            : scanReportsLocked()
        var removedAll = true
        for report in reports where report.binding.binding == binding {
            do {
                try fileManager.removeItem(at: report.directoryURL)
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }

    func purge(serverInstanceID: String) {
        lock.lock()
        defer { lock.unlock() }

        let bindingDestination = DiagnosticsBinding(
            serverInstanceID: serverInstanceID,
            accountUserID: ""
        ).destinationChoice
        let reports = bindingDestination == .selfHosted
            ? scanSelfHostedReportsLocked()
            : scanReportsLocked()
        for report in reports where report.binding.serverInstanceID == serverInstanceID {
            try? fileManager.removeItem(at: report.directoryURL)
        }
    }

    @discardableResult
    func delete(_ report: PendingReport) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: report.directoryURL.path) else {
            return true
        }
        do {
            try fileManager.removeItem(at: report.directoryURL)
            return true
        } catch {
            return false
        }
    }

    /// Publishes an evidence-free UUID/binding receipt before removing a READY
    /// report. This makes a later Turn Off and Delete action able to erase the
    /// remote report after an app restart, and makes an interrupted local
    /// removal non-uploadable when the store is reconstructed.
    func recordHostedReadyAndDelete(_ report: PendingReport, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        guard report.binding.binding.destinationChoice == .hosted else {
            throw DiagnosticsStoreError.invalidHostedEnvelope
        }
        try pruneHostedReadyReceiptsLocked(now: now)
        var receipts = try loadHostedErasureLedgersLocked().readyReceipts
        receipts[report.id.uuidString.lowercased()] = HostedReadyReceipt(
            binding: report.binding.binding,
            readyAt: DiagnosticsTimestamp.string(from: now)
        )
        try saveHostedReadyReceiptsLocked(receipts)
        if fileManager.fileExists(atPath: report.directoryURL.path) {
            try hostedDeletionRemover(report.directoryURL)
        }
    }

    func hostedReadyReceiptIDs(for binding: DiagnosticsBinding? = nil) throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }

        try pruneHostedReadyReceiptsLocked(now: Date())
        return try loadHostedErasureLedgersLocked().readyReceipts
            .compactMap { key, receipt in
                guard binding == nil || receipt.binding == binding else { return nil }
                return UUID(uuidString: key)
            }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Makes a hosted erasure request durable before removing the evidence it
    /// refers to. The collector DELETE endpoint is idempotent, so a response
    /// lost after acceptance can be retried safely without retaining logs.
    func stageHostedDeletionAndDelete(
        _ report: PendingReport,
        forceRemoteIntent: Bool = false,
        now: Date = Date()
    ) throws {
        guard report.binding.binding.destinationChoice == .hosted else {
            throw DiagnosticsStoreError.invalidHostedEnvelope
        }
        lock.lock()
        defer { lock.unlock() }

        try stageHostedDeletionAndDeleteLocked(
            report,
            forceRemoteIntent: forceRemoteIntent,
            now: now
        )
    }

    /// Lock-held implementation shared by explicit deletion and automatic
    /// retention. Any report that may have crossed the collector create
    /// boundary gets a UUID-only deletion intent before its evidence leaves
    /// disk, so expiry and capacity eviction cannot destroy the erasure handle.
    private func stageHostedDeletionAndDeleteLocked(
        _ report: PendingReport,
        forceRemoteIntent: Bool = false,
        now: Date
    ) throws {
        let erasureState = try loadHostedErasureLedgersLocked()
        let current = loadReport(from: report.directoryURL)
        let deletionCandidate = current ?? report
        let readyReceipt = erasureState.readyReceipts[report.id.uuidString.lowercased()]
        let crossedCreateBoundary = deletionCandidate.binding.binding.destinationChoice == .hosted
            && (forceRemoteIntent
                || deletionCandidate.state.hostedEnvelopeGeneration != nil
                || deletionCandidate.state.hostedRemoteShortID != nil)
        if readyReceipt != nil || crossedCreateBoundary {
            var intents = erasureState.deletionIntents
            intents[deletionCandidate.id.uuidString.lowercased()] = DiagnosticsTimestamp.string(from: now)
            try saveHostedDeletionIntentsLocked(intents)
        }
        if let current {
            try fileManager.removeItem(at: current.directoryURL)
        }
    }

    /// Stages every potentially remote hosted report before clearing a
    /// binding's local evidence for the Turn Off and Delete action.
    func stageHostedDeletionsAndPurge(
        binding: DiagnosticsBinding,
        additionalRemoteReportIDs: Set<UUID> = [],
        now: Date = Date()
    ) throws {
        guard binding.destinationChoice == .hosted else {
            throw DiagnosticsStoreError.invalidHostedEnvelope
        }
        lock.lock()
        defer { lock.unlock() }

        let erasureState = try loadHostedErasureLedgersLocked()
        let reports = scanReportsLocked().filter { $0.binding.binding == binding }
        var intents = erasureState.deletionIntents
        for report in reports where report.binding.binding.destinationChoice == .hosted
            && (report.state.hostedEnvelopeGeneration != nil || report.state.hostedRemoteShortID != nil) {
            intents[report.id.uuidString.lowercased()] = DiagnosticsTimestamp.string(from: now)
        }
        if binding.destinationChoice == .hosted {
            for (reportID, receipt) in erasureState.readyReceipts
                where receipt.binding == binding {
                intents[reportID] = DiagnosticsTimestamp.string(from: now)
            }
            for reportID in additionalRemoteReportIDs {
                intents[reportID.uuidString.lowercased()] = DiagnosticsTimestamp.string(from: now)
            }
        }
        try saveHostedDeletionIntentsLocked(intents)
        for report in reports {
            try fileManager.removeItem(at: report.directoryURL)
        }
    }

    func stageHostedDeletionsAndPurge(
        serverInstanceID: String,
        additionalRemoteReportIDs: Set<UUID> = [],
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let erasureState = try loadHostedErasureLedgersLocked()
        let reports = scanReportsLocked().filter { $0.binding.serverInstanceID == serverInstanceID }
        var intents = erasureState.deletionIntents
        for report in reports where report.binding.binding.destinationChoice == .hosted
            && (report.state.hostedEnvelopeGeneration != nil || report.state.hostedRemoteShortID != nil) {
            intents[report.id.uuidString.lowercased()] = DiagnosticsTimestamp.string(from: now)
        }
        for (reportID, receipt) in erasureState.readyReceipts
            where receipt.binding.serverInstanceID == serverInstanceID {
            intents[reportID] = DiagnosticsTimestamp.string(from: now)
        }
        for reportID in additionalRemoteReportIDs {
            intents[reportID.uuidString.lowercased()] = DiagnosticsTimestamp.string(from: now)
        }
        try saveHostedDeletionIntentsLocked(intents)
        for report in reports {
            try fileManager.removeItem(at: report.directoryURL)
        }
    }

    func hostedDeletionIntents() throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }

        return try loadHostedErasureLedgersLocked().deletionIntents.keys
            .compactMap(UUID.init(uuidString:))
            .sorted { $0.uuidString < $1.uuidString }
    }

    func prepareHostedDeletionRetries() -> HostedDeletionRetryBatch {
        lock.lock()
        defer { lock.unlock() }

        let erasureState: HostedErasureLedgers
        do {
            erasureState = try loadHostedErasureLedgersLocked()
        } catch {
            return HostedDeletionRetryBatch(
                reportIDs: [],
                hasBlockedLocalEvidence: true,
                hasCorruptLedger: true
            )
        }
        let reportIDs = erasureState.deletionIntents.keys.compactMap(UUID.init(uuidString:))
        var ready: [UUID] = []
        var blocked = false
        // If the process stopped after the intent's atomic write but before
        // removing raw evidence, finish that local half before any retry can
        // rediscover or upload the report.
        for reportID in reportIDs {
            let directory = pendingDirectory.appendingPathComponent(
                reportID.uuidString.lowercased(),
                isDirectory: true
            )
            if fileManager.fileExists(atPath: directory.path) {
                try? hostedDeletionRemover(directory)
            }
            if fileManager.fileExists(atPath: directory.path) {
                blocked = true
            } else {
                ready.append(reportID)
            }
        }
        return HostedDeletionRetryBatch(
            reportIDs: ready,
            hasBlockedLocalEvidence: blocked,
            hasCorruptLedger: false
        )
    }

    @discardableResult
    func completeHostedDeletion(reportID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let erasureState: HostedErasureLedgers
        do {
            erasureState = try loadHostedErasureLedgersLocked()
        } catch {
            return false
        }
        let directory = pendingDirectory.appendingPathComponent(
            reportID.uuidString.lowercased(),
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            try? hostedDeletionRemover(directory)
        }
        guard !fileManager.fileExists(atPath: directory.path) else { return false }
        var receipts = erasureState.readyReceipts
        receipts.removeValue(forKey: reportID.uuidString.lowercased())
        do {
            try saveHostedReadyReceiptsLocked(receipts)
        } catch {
            return false
        }
        var intents = erasureState.deletionIntents
        intents.removeValue(forKey: reportID.uuidString.lowercased())
        do {
            try saveHostedDeletionIntentsLocked(intents)
            return true
        } catch {
            return false
        }
    }

    func hasSeenFingerprint(_ fingerprint: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pruneFingerprintStateLocked(now: now)
        return loadDateMap(Self.seenFingerprintsFile)[fingerprint] != nil
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

    func loadHostedEnvelope(for report: PendingReport) -> HostedEnvelopeLoadResult {
        lock.lock()
        defer { lock.unlock() }

        do {
            _ = try loadHostedErasureLedgersLocked()
        } catch {
            return .quarantined
        }
        guard let current = loadReport(from: report.directoryURL) else { return .corrupt }
        if let generation = current.state.hostedEnvelopeGeneration {
            guard UUID(uuidString: generation) != nil else { return .corrupt }
            let directory = current.directoryURL.appendingPathComponent(
                Self.hostedEnvelopePrefix + generation,
                isDirectory: true
            )
            guard let bundle = readHostedEnvelope(report: current, from: directory) else {
                return .corrupt
            }
            return .available(bundle)
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: current.directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )) ?? []
        for child in children where child.lastPathComponent.hasPrefix(Self.hostedEnvelopeStagingPrefix) {
            // The network request is made only after a published generation is
            // committed to state. An interrupted staging write therefore has
            // never crossed the send boundary and is safe to discard/rebuild.
            try? fileManager.removeItem(at: child)
        }
        let recoverable = children
            .filter {
                $0.lastPathComponent.hasPrefix(Self.hostedEnvelopePrefix)
                    && !$0.lastPathComponent.hasPrefix(Self.hostedEnvelopeStagingPrefix)
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for directory in recoverable {
            let generation = String(directory.lastPathComponent.dropFirst(Self.hostedEnvelopePrefix.count))
            guard UUID(uuidString: generation) != nil,
                  let bundle = readHostedEnvelope(report: current, from: directory) else {
                continue
            }
            var state = current.state
            state.hostedEnvelopeGeneration = generation
            try? writeJSON(state, to: current.directoryURL.appendingPathComponent("state.json"))
            return .available(bundle)
        }
        return recoverable.isEmpty ? .missing : .corrupt
    }

    func saveHostedEnvelope(_ bundle: DiagnosticsBundleBuildResult, for report: PendingReport) throws {
        lock.lock()
        defer { lock.unlock() }

        _ = try loadHostedErasureLedgersLocked()
        guard let current = loadReport(from: report.directoryURL) else {
            throw DiagnosticsStoreError.unreadableReport(report.id)
        }
        try validateHostedEnvelope(bundle, report: current)
        let generation = UUID().uuidString.lowercased()
        let staging = current.directoryURL.appendingPathComponent(
            Self.hostedEnvelopeStagingPrefix + generation,
            isDirectory: true
        )
        let published = current.directoryURL.appendingPathComponent(
            Self.hostedEnvelopePrefix + generation,
            isDirectory: true
        )
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try excludeFromBackup(staging)
            try bundle.manifestData.write(
                to: staging.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try bundle.bundleData.write(
                to: staging.appendingPathComponent("bundle.tar.gz"),
                options: .atomic
            )
            let entriesRoot = staging.appendingPathComponent("entries", isDirectory: true)
            for entry in bundle.archiveEntries {
                let target = entriesRoot.appendingPathComponent(entry.relativePath)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.data.write(to: target, options: .atomic)
            }
            try fileManager.moveItem(at: staging, to: published)

            var state = current.state
            state.hostedEnvelopeGeneration = generation
            state.hostedConsentRefreshRequired = false
            try writeJSON(state, to: current.directoryURL.appendingPathComponent("state.json"))

            let siblings = (try? fileManager.contentsOfDirectory(
                at: current.directoryURL,
                includingPropertiesForKeys: nil
            )) ?? []
            for sibling in siblings where sibling != published
                && sibling.lastPathComponent.hasPrefix(Self.hostedEnvelopePrefix) {
                try? fileManager.removeItem(at: sibling)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func markHostedConsentRefreshRequired(_ report: PendingReport) {
        lock.lock()
        defer { lock.unlock() }

        guard let current = loadReport(from: report.directoryURL) else { return }
        var state = current.state
        state.hostedConsentRefreshRequired = true
        try? writeJSON(state, to: current.directoryURL.appendingPathComponent("state.json"))
    }

    func markHostedProcessing(_ report: PendingReport, shortID: String) {
        guard !shortID.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        guard let current = loadReport(from: report.directoryURL) else { return }
        var state = current.state
        state.hostedRemoteShortID = shortID
        state.hostedRejectionCode = nil
        try? writeJSON(state, to: current.directoryURL.appendingPathComponent("state.json"))
    }

    func markHostedRejected(_ report: PendingReport, code: String?) {
        lock.lock()
        defer { lock.unlock() }

        guard let current = loadReport(from: report.directoryURL) else { return }
        var state = current.state
        state.hostedRemoteShortID = nil
        state.hostedRejectionCode = code?.isEmpty == false ? code : "rejected"
        try? writeJSON(state, to: current.directoryURL.appendingPathComponent("state.json"))
    }

    private func readHostedEnvelope(
        report: PendingReport,
        from directory: URL
    ) -> DiagnosticsBundleBuildResult? {
        do {
            let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let manifest = try DiagnosticsJSONCoding.makeDecoder().decode(
                DiagnosticsManifest.self,
                from: manifestData
            )
            let bundleData = try Data(contentsOf: directory.appendingPathComponent("bundle.tar.gz"))
            let entriesRoot = directory.appendingPathComponent("entries", isDirectory: true)
            let entries = try manifest.archive.entries.map { path in
                guard DiagnosticsManifest.Archive.allowedEntries.contains(path) else {
                    throw DiagnosticsStoreError.invalidArtifactPath(path)
                }
                return PendingReportArtifact(
                    relativePath: path,
                    data: try Data(contentsOf: entriesRoot.appendingPathComponent(path))
                )
            }
            let result = DiagnosticsBundleBuildResult(
                manifest: manifest,
                manifestData: manifestData,
                bundleData: bundleData,
                archiveEntries: entries
            )
            try validateHostedEnvelope(result, report: report)
            return result
        } catch {
            return nil
        }
    }

    private func validateHostedEnvelope(
        _ bundle: DiagnosticsBundleBuildResult,
        report: PendingReport
    ) throws {
        try bundle.manifest.validate()
        try DiagnosticsBundleBuilder(fileManager: fileManager).validateCachedHostedEnvelope(bundle)
        guard report.binding.binding.destinationChoice == .hosted,
              bundle.manifest.report.capturedAt == report.binding.capturedAt,
              bundle.manifest.report.type == report.binding.type else {
            throw DiagnosticsStoreError.invalidHostedEnvelope
        }
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: rootDirectory)
    }

    private func scanReportsLocked() -> [PendingReport] {
        let erasureState: HostedErasureLedgers?
        do {
            try pruneHostedReadyReceiptsLocked(now: Date())
            erasureState = try loadHostedErasureLedgersLocked()
        } catch {
            erasureState = nil
        }
        let readyReportIDs = Set(erasureState.map { Array($0.readyReceipts.keys) } ?? [])
        guard let urls = try? fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return urls.compactMap { url in
            if readyReportIDs.contains(url.lastPathComponent.lowercased()) {
                try? hostedDeletionRemover(url)
                return nil
            }
            guard let report = loadReport(from: url) else { return nil }
            if report.binding.binding.destinationChoice == .hosted, erasureState == nil {
                return nil
            }
            return report
        }
    }

    /// Enumerates only the compatibility path's local reports without
    /// consulting collector erasure state. A corrupt hosted ledger must fail
    /// hosted operations closed, but it has no authority over evidence stored
    /// for a user's own Silo server.
    private func scanSelfHostedReportsLocked() -> [PendingReport] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return urls.compactMap(loadReport(from:)).filter {
            $0.binding.binding.destinationChoice == .selfHosted
        }
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
        let hostedErasureStateIsReadable = (try? loadHostedErasureLedgersLocked()) != nil
        if !hostedErasureStateIsReadable {
            // Without trustworthy erasure state an unreadable directory could
            // be the only surviving copy of a report already marked READY or
            // deleting. Preserve every hosted directory; self-hosted expiry
            // remains independent of this collector-local state.
        }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls {
            guard let report = loadReport(from: url) else {
                if hostedErasureStateIsReadable {
                    try? fileManager.removeItem(at: url)
                }
                continue
            }
            if report.binding.binding.destinationChoice == .hosted,
               !hostedErasureStateIsReadable {
                continue
            }
            if now.timeIntervalSince(report.binding.capturedAtDate) > Self.expiryInterval {
                if report.binding.binding.destinationChoice == .hosted {
                    // Preserve the evidence for a later maintenance pass if
                    // staging its durable remote deletion fails. An expired
                    // report must not abort an unrelated new capture.
                    try? stageHostedDeletionAndDeleteLocked(report, now: now)
                } else {
                    try? fileManager.removeItem(at: url)
                }
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
            if report.binding.binding.destinationChoice == .hosted {
                // The new report is already committed by this point. If the
                // ledger or removal write fails, retain the extra evidence and
                // retry cleanup later rather than reporting a failed capture
                // whose directory actually exists.
                try? stageHostedDeletionAndDeleteLocked(report, now: Date())
            } else {
                try? fileManager.removeItem(at: report.directoryURL)
            }
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

    private func loadHostedErasureLedgersLocked() throws -> HostedErasureLedgers {
        HostedErasureLedgers(
            deletionIntents: try loadHostedDeletionIntentsLocked(),
            readyReceipts: try loadHostedReadyReceiptsLocked()
        )
    }

    private func loadHostedDeletionIntentsLocked() throws -> [String: String] {
        let corruption = DiagnosticsStoreError.corruptHostedDeletionIntents
        guard let data = try readHostedLedgerDataLocked(
            fileName: Self.hostedDeletionIntentsFile,
            corruptionError: corruption
        ) else {
            return [:]
        }
        guard let intents = try? DiagnosticsJSONCoding.makeDecoder().decode(
            [String: String].self,
            from: data
        ), !intents.isEmpty,
           intents.count <= Self.maxHostedDeletionIntents,
           intents.allSatisfy({ reportID, createdAt in
               Self.isCanonicalHostedReportID(reportID)
                   && DiagnosticsDates.date(from: createdAt) != nil
           }) else {
            throw corruption
        }
        return intents
    }

    private func saveHostedDeletionIntentsLocked(_ intents: [String: String]) throws {
        guard intents.count <= Self.maxHostedDeletionIntents,
              intents.allSatisfy({ reportID, createdAt in
                  Self.isCanonicalHostedReportID(reportID)
                      && DiagnosticsDates.date(from: createdAt) != nil
              }) else {
            throw DiagnosticsStoreError.invalidHostedDeletionIntent
        }
        try ensureDirectory(rootDirectory)
        let url = rootDirectory.appendingPathComponent(Self.hostedDeletionIntentsFile)
        if intents.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } else {
            try writeJSON(intents, to: url)
        }
    }

    private func loadHostedReadyReceiptsLocked() throws -> [String: HostedReadyReceipt] {
        let corruption = DiagnosticsStoreError.corruptHostedReadyReceipts
        guard let data = try readHostedLedgerDataLocked(
            fileName: Self.hostedReadyReceiptsFile,
            corruptionError: corruption
        ) else {
            return [:]
        }
        guard let receipts = try? DiagnosticsJSONCoding.makeDecoder().decode(
            [String: HostedReadyReceipt].self,
            from: data
        ), !receipts.isEmpty,
           receipts.count <= Self.maxHostedReadyReceipts,
           receipts.allSatisfy({ reportID, receipt in
               Self.isCanonicalHostedReportID(reportID)
                   && receipt.binding.destinationChoice == .hosted
                   && DiagnosticsDates.date(from: receipt.readyAt) != nil
           }) else {
            throw corruption
        }
        return receipts
    }

    private func saveHostedReadyReceiptsLocked(
        _ receipts: [String: HostedReadyReceipt]
    ) throws {
        guard receipts.count <= Self.maxHostedReadyReceipts,
              receipts.keys.allSatisfy(Self.isCanonicalHostedReportID),
              receipts.values.allSatisfy({
                  $0.binding.destinationChoice == .hosted
                      && DiagnosticsDates.date(from: $0.readyAt) != nil
              }) else {
            throw DiagnosticsStoreError.invalidHostedReadyReceipt
        }
        try ensureDirectory(rootDirectory)
        let url = rootDirectory.appendingPathComponent(Self.hostedReadyReceiptsFile)
        if receipts.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } else {
            try writeJSON(receipts, to: url)
        }
    }

    private static func isCanonicalHostedReportID(_ value: String) -> Bool {
        // Ledger keys are also compared with lowercase report-directory names.
        // Requiring one spelling prevents an equivalent UUID from bypassing
        // READY/deletion quarantine through case-sensitive path lookup.
        guard let reportID = UUID(uuidString: value) else { return false }
        return value == reportID.uuidString.lowercased()
    }

    private func pruneHostedReadyReceiptsLocked(now: Date) throws {
        let erasureState = try loadHostedErasureLedgersLocked()
        let receipts = erasureState.readyReceipts
        let deletionIntents = Set(erasureState.deletionIntents.keys)
        let retained = receipts.filter { reportID, receipt in
            let directory = pendingDirectory.appendingPathComponent(reportID, isDirectory: true)
            if fileManager.fileExists(atPath: directory.path) {
                // Never let age pruning resurrect raw evidence whose local
                // removal has been failing; the receipt remains the upload
                // exclusion marker until the directory is actually absent.
                return true
            }
            guard let readyAt = DiagnosticsDates.date(from: receipt.readyAt) else {
                return deletionIntents.contains(reportID)
            }
            return deletionIntents.contains(reportID)
                || now.timeIntervalSince(readyAt) <= Self.hostedReadyReceiptInterval
        }
        if retained != receipts {
            try saveHostedReadyReceiptsLocked(retained)
        }
    }

    private func reconcileHostedReadyReceiptsLocked(now: Date) throws {
        try pruneHostedReadyReceiptsLocked(now: now)
        for reportID in try loadHostedErasureLedgersLocked().readyReceipts.keys {
            let directory = pendingDirectory.appendingPathComponent(reportID, isDirectory: true)
            if fileManager.fileExists(atPath: directory.path) {
                try? hostedDeletionRemover(directory)
            }
        }
    }

    /// Reads only a regular, bounded file. File attributes are inspected
    /// directly because `fileExists` follows symbolic links and reports a
    /// dangling link as absent. Only a genuine no-such-file result represents
    /// empty state; a race, unreadable inode, directory, symlink, or oversized
    /// payload is quarantined as corruption.
    private func readHostedLedgerDataLocked(
        fileName: String,
        corruptionError: DiagnosticsStoreError
    ) throws -> Data? {
        let url = rootDirectory.appendingPathComponent(fileName)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            let nsError = error as NSError
            let missingCodes = [
                CocoaError.Code.fileNoSuchFile.rawValue,
                CocoaError.Code.fileReadNoSuchFile.rawValue,
            ]
            if nsError.domain == NSCocoaErrorDomain,
               missingCodes.contains(nsError.code) {
                return nil
            }
            throw corruptionError
        }
        do {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.int64Value >= 0,
                  fileSize.int64Value <= Int64(Self.maxHostedErasureLedgerBytes) else {
                throw corruptionError
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= Self.maxHostedErasureLedgerBytes else {
                throw corruptionError
            }
            return data
        } catch {
            throw corruptionError
        }
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
    case invalidHostedEnvelope
    case invalidHostedDeletionIntent
    case invalidHostedReadyReceipt
    case corruptHostedDeletionIntents
    case corruptHostedReadyReceipts
}

enum DiagnosticsDates {
    static func date(from value: String) -> Date? {
        DateFormatters.parseRFC3339(value)
    }
}

#endif
