#if os(iOS) || os(tvOS)
import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsStatusSnapshot: Equatable, Codable {
    let status: DiagnosticsStatusResponse
    let binding: DiagnosticsBinding
}

enum DiagnosticsUploadDecision: Equatable {
    case uploaded(DiagnosticsUploadResponse)
    case keptRetryable
    case keptNeedsServerUpdate
    case keptTooLarge
    case keptStaleConsent
    case keptDestinationMismatch
    case discardedInvalidLocalBundle
}

actor DiagnosticsCoordinator {
    static let shared = DiagnosticsCoordinator()

    nonisolated private static let breadcrumbJournal = BreadcrumbJournal(isEnabled: {
        DiagnosticsCoordinator.breadcrumbCaptureEnabled()
    })
    nonisolated private static let breadcrumbContextLock = NSLock()
    nonisolated(unsafe) private static var breadcrumbConsentContext: BreadcrumbConsentContext?

    private let api: DiagnosticsAPI
    private let continuumAPI: ContinuumAPI
    private let consentStore: DiagnosticsConsentStore
    private let pendingStore: PendingReportStore
    private let bundleBuilder: DiagnosticsBundleBuilder
    private let deviceSnapshotBuilder: DeviceSnapshotBuilder

    private var cachedStatus: DiagnosticsStatusSnapshot?
    private var cachedStatusServerRegistryID: String?
    private var cachedStatusAccessTokenFingerprint: String?

    init(
        api: DiagnosticsAPI = .shared,
        continuumAPI: ContinuumAPI = .shared,
        consentStore: DiagnosticsConsentStore = .shared,
        pendingStore: PendingReportStore = .shared,
        bundleBuilder: DiagnosticsBundleBuilder = DiagnosticsBundleBuilder(),
        deviceSnapshotBuilder: DeviceSnapshotBuilder = .live
    ) {
        self.api = api
        self.continuumAPI = continuumAPI
        self.consentStore = consentStore
        self.pendingStore = pendingStore
        self.bundleBuilder = bundleBuilder
        self.deviceSnapshotBuilder = deviceSnapshotBuilder
    }

    func refreshStatus() async throws -> DiagnosticsStatusSnapshot {
        let requestServerRegistryID = ServerRegistry.shared.activeServerId
        guard requestServerRegistryID != nil,
              await Self.currentAccessTokenFingerprint() != nil else {
            throw DiagnosticsCoordinatorError.identityChanged
        }

        let status = try await api.getDiagnosticsStatus()
        let user = try await continuumAPI.currentUser()
        // Re-check the *stable* identity after the awaits: the active server
        // registry id plus the freshly fetched account user id. Comparing
        // these rather than raw access-token fingerprints means a transparent
        // token refresh HTTPClient may perform during these calls is not
        // misread as an identity change. A genuine change — server switch or
        // sign-out — still flips the server id or drops the token.
        guard requestServerRegistryID == ServerRegistry.shared.activeServerId,
              let accessTokenFingerprint = await Self.currentAccessTokenFingerprint() else {
            throw DiagnosticsCoordinatorError.identityChanged
        }
        guard let accountUserID = user.id, !accountUserID.isEmpty else {
            throw DiagnosticsCoordinatorError.missingAccountUserID
        }
        let binding = DiagnosticsBinding(
            serverInstanceID: status.serverInstanceID,
            accountUserID: accountUserID
        )
        let snapshot = DiagnosticsStatusSnapshot(status: status, binding: binding)
        cachedStatus = snapshot
        cachedStatusServerRegistryID = requestServerRegistryID
        cachedStatusAccessTokenFingerprint = accessTokenFingerprint
        persistLastKnownSnapshot(snapshot, serverRegistryID: requestServerRegistryID)
        updateBreadcrumbConsentContext(binding: binding, noticeVersion: status.consentNoticeVersion)
        if let serverId = ServerRegistry.shared.activeServerId {
            Self.ServerBindingIndex.record(
                serverId: serverId,
                serverInstanceID: status.serverInstanceID
            )
        }
        _ = consentStore.record(for: binding, currentNoticeVersion: status.consentNoticeVersion)
        return snapshot
    }

    func cachedStatusForActiveServer() async -> DiagnosticsStatusSnapshot? {
        guard cachedStatusServerRegistryID == ServerRegistry.shared.activeServerId,
              let cachedStatusAccessTokenFingerprint,
              cachedStatusAccessTokenFingerprint == (await Self.currentAccessTokenFingerprint()) else {
            return nil
        }
        return cachedStatus
    }

    /// Best-effort last-known-good status for the active server, used when a
    /// live refresh is impossible (offline). Prefers the in-memory cache from
    /// this session, then the value persisted from the previous successful
    /// refresh — the latter survives relaunch, so a crash delivered by
    /// MetricKit at the next launch can still be queued while offline.
    private func lastKnownSnapshotForActiveServer() -> DiagnosticsStatusSnapshot? {
        guard let activeServerId = ServerRegistry.shared.activeServerId else {
            return nil
        }
        if cachedStatusServerRegistryID == activeServerId, let cachedStatus {
            return cachedStatus
        }
        return Self.LastKnownStatusStore.snapshot(for: activeServerId)
    }

    private func persistLastKnownSnapshot(_ snapshot: DiagnosticsStatusSnapshot, serverRegistryID: String?) {
        guard let serverRegistryID else { return }
        Self.LastKnownStatusStore.record(snapshot, for: serverRegistryID)
    }

    private func activeProfileIsChild() async -> Bool? {
        guard let activeProfileID = AuthService.shared.profileId else {
            return nil
        }
        guard let profiles = try? await AuthService.shared.getProfiles() else {
            return nil
        }
        return profiles.first { $0.id == activeProfileID }?.isChild
    }

    func pendingReportsForCurrentBinding() async -> [PendingReport] {
        guard let context = await captureContext(requirePersistentCapture: false) else {
            return []
        }
        return pendingStore.listReports(for: context.binding, now: Date())
    }

    func pendingReports(for binding: DiagnosticsBinding) -> [PendingReport] {
        pendingStore.listReports(for: binding, now: Date())
    }

    func buildBundle(for report: PendingReport) async throws -> DiagnosticsBundleBuildResult {
        let redactionTokens = await Self.currentTokenRedactionValues()

        // Crash/hang/abnormal-exit reports snapshot their logs at capture time
        // (see `logSnapshotArtifact`). Prefer that frozen snapshot so a report
        // sent hours or days later — possibly after using another server or
        // profile — carries the failure-time logs, not the current in-memory
        // ring. Manual reports have no snapshot and use the live ring.
        if let snapshotData = try? Data(contentsOf: logSnapshotURL(for: report)) {
            let lines = String(decoding: snapshotData, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            return try bundleBuilder.build(
                report: report,
                logLines: lines,
                droppedLogLines: 0,
                redactionTokens: redactionTokens
            )
        }

        let ringSnapshot = DiagLog.ring.snapshot()
        let osLogLines = harvestOSLogLines(since: report.binding.capturedAtDate)
        return try bundleBuilder.build(
            report: report,
            logLines: ringSnapshot.lines + osLogLines,
            droppedLogLines: ringSnapshot.droppedCount,
            redactionTokens: redactionTokens
        )
    }

    private nonisolated func logSnapshotURL(for report: PendingReport) -> URL {
        report.directoryURL.appendingPathComponent("logs.jsonl")
    }

    /// Freezes the current log ring plus this-process OSLog into a `logs.jsonl`
    /// artifact so it can be stored with a pending report at capture time.
    func logSnapshotArtifact(since: Date) -> PendingReportArtifact? {
        let ringSnapshot = DiagLog.ring.snapshot()
        let lines = ringSnapshot.lines + harvestOSLogLines(since: since)
        guard !lines.isEmpty else {
            return nil
        }
        let data = Data(lines.joined(separator: "\n").appending("\n").utf8)
        return PendingReportArtifact(relativePath: "logs.jsonl", data: data)
    }

    func createManualReport() async throws -> PendingReport {
        guard let context = await captureContext(requirePersistentCapture: false) else {
            throw DiagnosticsCoordinatorError.missingCaptureContext
        }

        let capturedAt = Date()
        let device = deviceSnapshotBuilder.build(provenance: .preFailure)
        let manifest = context.makeManifestDraft(
            type: .manual,
            capturedAt: capturedAt,
            crash: nil,
            deviceSummary: deviceSnapshotBuilder.deviceSummary(from: device),
            playbackSessionIDs: RecentSessionTracker.shared.recentSessionIDs(for: context.binding),
            consentMode: .manual
        )
        let fingerprint = DiagnosticsSHA256.hex(
            data: Data("manual|\(DiagLog.captureSessionID)|\(DiagnosticsTimestamp.string(from: capturedAt))".utf8)
        )

        return try pendingStore.save(PendingReportCapture(
            binding: context.binding,
            profileID: context.profileID,
            type: .manual,
            fingerprint: fingerprint,
            capturedAt: capturedAt,
            manifest: manifest,
            deviceSnapshot: device,
            artifacts: []
        ))
    }

    func upload(report: PendingReport) async -> DiagnosticsUploadDecision {
        guard let context = await captureContext(requirePersistentCapture: false),
              report.isUploadable(to: context.binding) else {
            return .keptDestinationMismatch
        }

        // Refresh only the consent notice version from the current consent
        // record before building the upload. If the server's notice advanced
        // after capture, the frozen manifest would carry a stale
        // notice_version and be rejected as stale_consent on every retry —
        // even after the user re-consents. The report evidence stays frozen.
        let currentNoticeVersion = consentStore.record(
            for: report.binding.binding,
            currentNoticeVersion: context.noticeVersion
        ).noticeVersion
        let report = pendingStore.updatingConsentNoticeVersion(report, to: currentNoticeVersion)

        do {
            let bundle = try await buildBundle(for: report)
            let response = try await api.upload(
                manifestData: bundle.manifestData,
                bundleData: bundle.bundleData
            )
            pendingStore.delete(report)
            return .uploaded(response)
        } catch let error as DiagnosticsUploadError {
            return handleUploadError(error, report: report)
        } catch {
            return .keptRetryable
        }
    }

    func captureContext(
        applicationVersionOverride: String? = nil,
        requirePersistentCapture: Bool = true
    ) async -> DiagnosticsCaptureContext? {
        let snapshot: DiagnosticsStatusSnapshot
        do {
            snapshot = try await refreshStatus()
        } catch {
            // The server is unreachable (or the identity is mid-change). For a
            // persistent capture (crash/hang/abnormal-exit) we must not drop
            // the report just because we are offline: fall back to the
            // last-known-good status/binding so it is still queued locally.
            // Only give up when there is genuinely no known binding to bind to.
            guard requirePersistentCapture,
                  let fallback = lastKnownSnapshotForActiveServer() else {
                return nil
            }
            snapshot = fallback
        }

        let record = consentStore.record(
            for: snapshot.binding,
            currentNoticeVersion: snapshot.status.consentNoticeVersion
        )
        if requirePersistentCapture {
            if record.mode == .never {
                return nil
            }
            // Child profiles cannot manage diagnostics. A crash captured while
            // one is active must not be persisted as an account-bound report,
            // or an adult profile on the same account could later be prompted
            // to upload the child's session. Mirror DiagnosticsPromptPolicy's
            // isChildProfile gating; only skip when we positively know it is a
            // child (an unknown profile stays capturable and is gated at the
            // prompt/upload layer).
            if await activeProfileIsChild() == true {
                return nil
            }
        }

        return DiagnosticsCaptureContext(
            binding: snapshot.binding,
            profileID: AuthService.shared.profileId,
            consentMode: record.mode.manifestMode,
            noticeVersion: snapshot.status.consentNoticeVersion,
            appVersion: applicationVersionOverride?.isEmpty == false ? applicationVersionOverride! : Self.appVersion(),
            appBuild: Self.appBuild(),
            platform: Self.platform(),
            osVersion: Self.osVersion()
        )
    }

    @discardableResult
    func purgeDiagnosticsForCurrentBinding() async -> Bool {
        let binding: DiagnosticsBinding?
        if let context = await captureContext(requirePersistentCapture: false) {
            binding = context.binding
        } else {
            binding = Self.currentBreadcrumbBinding()
        }

        if let binding {
            purgeDiagnostics(for: binding)
        }
        Self.purgeBreadcrumbJournal()
        return binding != nil
    }

    func purgeDiagnosticsForServerRegistryID(_ serverId: String) {
        let serverInstanceIDs = Self.ServerBindingIndex.serverInstanceIDs(for: serverId)
        if serverInstanceIDs.isEmpty {
            pendingStore.purge(serverInstanceID: serverId)
            consentStore.remove(serverInstanceID: serverId)
        } else {
            for serverInstanceID in serverInstanceIDs {
                pendingStore.purge(serverInstanceID: serverInstanceID)
                consentStore.remove(serverInstanceID: serverInstanceID)
            }
        }
        Self.ServerBindingIndex.remove(serverId: serverId)
        Self.purgeBreadcrumbJournal()
    }

    #if os(tvOS)
    func captureAbnormalExit(marker: ExitSentinelMarker) async -> Bool {
        guard let context = await captureContext() else {
            return false
        }
        let fingerprint = DiagnosticsSHA256.hex(
            data: Data("exit_sentinel|\(marker.runID)|\(marker.startedAt)".utf8)
        )
        if pendingStore.hasSeenFingerprint(fingerprint, now: Date()) {
            return true
        }

        let device = deviceSnapshotBuilder.build(provenance: .postRestart)
        let capturedAt = Date()
        let breadcrumbLines = Self.breadcrumbJournal.readAll()
        let crashedRunBreadcrumbLines = breadcrumbLines.filter { $0.run == marker.runID }
        let lastKnownAliveAt = crashedRunBreadcrumbLines
            .compactMap { DiagnosticsDates.date(from: $0.ts) }
            .max()
        let occurredAt = lastKnownAliveAt.map(DiagnosticsTimestamp.string(from:))
            ?? DiagnosticsTimestamp.string(from: capturedAt)
        let crash = DiagnosticsCrashInfo(
            summary: "Silo did not shut down cleanly last time",
            stackExcerpt: nil,
            thread: nil,
            foreground: true,
            source: .exitSentinel,
            provenance: .postRestart,
            occurredAt: occurredAt,
            occurredAtStart: marker.startedAt,
            occurredAtEnd: DiagnosticsTimestamp.string(from: capturedAt)
        )
        let manifest = context.makeManifestDraft(
            type: .abnormalExit,
            capturedAt: capturedAt,
            crash: crash,
            deviceSummary: deviceSnapshotBuilder.deviceSummary(from: device),
            playbackSessionIDs: RecentSessionTracker.shared.recentSessionIDs(for: context.binding),
            captureSessionID: marker.runID
        )
        var artifacts: [PendingReportArtifact] = []
        // Only the crashed run's breadcrumbs — the journal can also hold this
        // relaunch's startup/navigation lines and older retained segments,
        // which would pollute the failed run's evidence.
        let breadcrumbs = Self.renderBreadcrumbs(crashedRunBreadcrumbLines)
        if !breadcrumbs.isEmpty {
            artifacts.append(PendingReportArtifact(relativePath: "breadcrumbs.jsonl", data: breadcrumbs))
        }
        if let logSnapshot = logSnapshotArtifact(since: marker.startedAtDate) {
            artifacts.append(logSnapshot)
        }

        do {
            _ = try pendingStore.save(PendingReportCapture(
                binding: context.binding,
                profileID: context.profileID,
                type: .abnormalExit,
                fingerprint: fingerprint,
                capturedAt: capturedAt,
                manifest: manifest,
                deviceSnapshot: device,
                artifacts: artifacts
            ))
            return true
        } catch {
            return false
        }
    }
    #endif

    @discardableResult
    nonisolated static func recordBreadcrumb(
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date()
    ) -> Bool {
        breadcrumbJournal.append(
            level: level,
            category: category,
            tag: tag,
            message: message,
            attrs: attrs,
            timestamp: timestamp
        )
    }

    nonisolated static func purgeBreadcrumbJournal() {
        breadcrumbJournal.purge()
    }

    nonisolated func breadcrumbsData() -> Data {
        Self.renderBreadcrumbs(Self.breadcrumbJournal.readAll())
    }

    nonisolated private static func renderBreadcrumbs(_ lines: [DiagnosticsLogLine]) -> Data {
        guard !lines.isEmpty else {
            return Data()
        }
        let encoder = DiagnosticsJSONCoding.makeEncoder()
        let rendered = lines.compactMap { line -> String? in
            guard let data = try? encoder.encode(line) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        return Data(rendered.joined(separator: "\n").appending("\n").utf8)
    }

    private func purgeDiagnostics(for binding: DiagnosticsBinding) {
        pendingStore.purge(binding: binding)
        consentStore.remove(binding: binding)
        #if os(tvOS)
        ExitSentinel.shared.purge()
        #endif
    }

    private func handleUploadError(
        _ error: DiagnosticsUploadError,
        report: PendingReport
    ) -> DiagnosticsUploadDecision {
        switch error {
        case .unsupportedSchema:
            pendingStore.markNeedsServerUpdate(report)
            return .keptNeedsServerUpdate
        case .staleConsent:
            consentStore.setMode(
                .ask,
                for: report.binding.binding,
                noticeVersion: report.manifest.consent.noticeVersion
            )
            return .keptStaleConsent
        case .destinationMismatch:
            return .keptDestinationMismatch
        case .archiveMismatch, .invalidBundle:
            pendingStore.delete(report)
            return .discardedInvalidLocalBundle
        case .tooLarge:
            // The bundle is over the server's size limit. Its artifacts and
            // archive are fixed, so retrying uploads the same rejected payload
            // forever. Mark it a permanent local failure instead.
            pendingStore.markTooLarge(report)
            return .keptTooLarge
        case .disabled, .storageUnavailable, .quotaExceeded, .busy, .retryable, .underlying:
            return .keptRetryable
        }
    }

    private func harvestOSLogLines(since: Date) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let subsystem = Bundle.main.bundleIdentifier ?? "com.continuum.app"
            return try store.getEntries(at: position).compactMap { entry in
                guard let log = entry as? OSLogEntryLog,
                      log.subsystem == subsystem || log.subsystem == "com.continuum.app" else {
                    return nil
                }
                let category = DiagnosticsLogCategory(rawValue: log.category.lowercased()) ?? .other
                return DiagLog.renderedLine(
                    level: Self.logLevel(from: log.level),
                    category: category,
                    tag: log.category.isEmpty ? "OSLog" : log.category,
                    message: log.composedMessage,
                    timestamp: log.date,
                    captureSessionID: DiagLog.captureSessionID
                )
            }
        } catch {
            return []
        }
    }

    private static func logLevel(from level: OSLogEntryLog.Level) -> DiagnosticsLogLevel {
        switch level {
        case .debug:
            return .debug
        case .info, .notice:
            return .info
        case .error, .fault:
            return .error
        default:
            return .info
        }
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static func appBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static func platform() -> Platform {
        #if os(tvOS)
        return .tvos
        #else
        return .ios
        #endif
    }

    private static func osVersion() -> String {
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func currentTokenRedactionValues() async -> [String] {
        let values = [
            await TokenStore.shared.getAccessToken(),
            await TokenStore.shared.getProfileToken(),
        ]
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value, !value.isEmpty, seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

    private static func currentAccessTokenFingerprint() async -> String? {
        guard let token = await TokenStore.shared.getAccessToken(), !token.isEmpty else {
            return nil
        }
        return DiagnosticsSHA256.hex(data: Data(token.utf8))
    }

    private struct BreadcrumbConsentContext {
        let binding: DiagnosticsBinding
        let noticeVersion: Int
    }

    private func updateBreadcrumbConsentContext(binding: DiagnosticsBinding, noticeVersion: Int) {
        Self.breadcrumbContextLock.lock()
        Self.breadcrumbConsentContext = BreadcrumbConsentContext(
            binding: binding,
            noticeVersion: noticeVersion
        )
        Self.breadcrumbContextLock.unlock()
        #if os(tvOS)
        ExitSentinel.shared.setCaptureEnabled {
            DiagnosticsCoordinator.breadcrumbCaptureEnabled()
        }
        #endif
    }

    nonisolated private static func currentBreadcrumbBinding() -> DiagnosticsBinding? {
        breadcrumbContextLock.lock()
        let binding = breadcrumbConsentContext?.binding
        breadcrumbContextLock.unlock()
        return binding
    }

    /// The binding for the server/account currently in view, captured at the
    /// last successful status refresh. Exposed so playback-session recording
    /// can scope entries to the active binding (see `RecentSessionTracker`),
    /// preventing another server/account's session IDs from leaking into a
    /// report bound elsewhere.
    nonisolated static var currentDiagnosticsBinding: DiagnosticsBinding? {
        currentBreadcrumbBinding()
    }

    nonisolated private static func breadcrumbCaptureEnabled() -> Bool {
        breadcrumbContextLock.lock()
        let context = breadcrumbConsentContext
        breadcrumbContextLock.unlock()

        guard let context else {
            return true
        }
        return DiagnosticsConsentStore.shared.persistentCaptureEnabled(
            for: context.binding,
            currentNoticeVersion: context.noticeVersion
        )
    }

    private enum ServerBindingIndex {
        private static let key = "diagnostics.serverInstanceIndex.v1"
        private static let lock = NSLock()

        static func record(serverId: String, serverInstanceID: String) {
            guard !serverId.isEmpty, !serverInstanceID.isEmpty else {
                return
            }
            lock.lock()
            var index = load()
            var values = Set(index[serverId] ?? [])
            values.insert(serverInstanceID)
            index[serverId] = Array(values).sorted()
            save(index)
            lock.unlock()
        }

        static func serverInstanceIDs(for serverId: String) -> [String] {
            lock.lock()
            let values = load()[serverId] ?? []
            lock.unlock()
            return values
        }

        static func remove(serverId: String) {
            lock.lock()
            var index = load()
            index.removeValue(forKey: serverId)
            save(index)
            lock.unlock()
        }

        private static func load() -> [String: [String]] {
            guard let data = SharedDefaults.shared.data(forKey: key),
                  let decoded = try? DiagnosticsJSONCoding.makeDecoder().decode([String: [String]].self, from: data) else {
                return [:]
            }
            return decoded
        }

        private static func save(_ index: [String: [String]]) {
            guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(index) else {
                return
            }
            SharedDefaults.shared.set(data, forKey: key)
        }
    }

    /// Persists the last successful diagnostics status per server registry id
    /// so a persistent capture (crash/hang/abnormal-exit) can still be queued
    /// when the server is unreachable — including on the very next launch after
    /// a crash, before any live refresh has run.
    private enum LastKnownStatusStore {
        private static let key = "diagnostics.lastKnownStatus.v1"
        private static let lock = NSLock()

        static func record(_ snapshot: DiagnosticsStatusSnapshot, for serverId: String) {
            guard !serverId.isEmpty else { return }
            lock.lock()
            var index = load()
            index[serverId] = snapshot
            save(index)
            lock.unlock()
        }

        static func snapshot(for serverId: String) -> DiagnosticsStatusSnapshot? {
            lock.lock()
            let snapshot = load()[serverId]
            lock.unlock()
            return snapshot
        }

        private static func load() -> [String: DiagnosticsStatusSnapshot] {
            guard let data = SharedDefaults.shared.data(forKey: key),
                  let decoded = try? DiagnosticsJSONCoding.makeDecoder().decode(
                    [String: DiagnosticsStatusSnapshot].self,
                    from: data
                  ) else {
                return [:]
            }
            return decoded
        }

        private static func save(_ index: [String: DiagnosticsStatusSnapshot]) {
            guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(index) else {
                return
            }
            SharedDefaults.shared.set(data, forKey: key)
        }
    }
}

enum DiagnosticsCoordinatorError: Error, Equatable {
    case missingAccountUserID
    case missingCaptureContext
    case identityChanged
}
#endif
