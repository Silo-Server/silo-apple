#if os(iOS) || os(tvOS)
import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsStatusSnapshot: Equatable {
    let status: DiagnosticsStatusResponse
    let binding: DiagnosticsBinding
}

enum DiagnosticsUploadDecision: Equatable {
    case uploaded(DiagnosticsUploadResponse)
    case keptRetryable
    case keptNeedsServerUpdate
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
        let status = try await api.getDiagnosticsStatus()
        let user = try await continuumAPI.currentUser()
        guard let accountUserID = user.id, !accountUserID.isEmpty else {
            throw DiagnosticsCoordinatorError.missingAccountUserID
        }
        let binding = DiagnosticsBinding(
            serverInstanceID: status.serverInstanceID,
            accountUserID: accountUserID
        )
        let snapshot = DiagnosticsStatusSnapshot(status: status, binding: binding)
        cachedStatus = snapshot
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
        let ringSnapshot = DiagLog.ring.snapshot()
        let osLogLines = harvestOSLogLines(since: report.binding.capturedAtDate)
        let redactionTokens = await Self.currentTokenRedactionValues()
        return try bundleBuilder.build(
            report: report,
            logLines: ringSnapshot.lines + osLogLines,
            droppedLogLines: ringSnapshot.droppedCount,
            redactionTokens: redactionTokens
        )
    }

    func upload(report: PendingReport) async -> DiagnosticsUploadDecision {
        guard let context = await captureContext(requirePersistentCapture: false),
              report.isUploadable(to: context.binding) else {
            return .keptDestinationMismatch
        }

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
            return nil
        }

        let record = consentStore.record(
            for: snapshot.binding,
            currentNoticeVersion: snapshot.status.consentNoticeVersion
        )
        if requirePersistentCapture, record.mode == .never {
            return nil
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
            playbackSessionIDs: RecentSessionTracker.shared.recentSessionIDs(),
            captureSessionID: marker.runID
        )
        var artifacts: [PendingReportArtifact] = []
        let breadcrumbs = Self.renderBreadcrumbs(breadcrumbLines)
        if !breadcrumbs.isEmpty {
            artifacts.append(PendingReportArtifact(relativePath: "breadcrumbs.jsonl", data: breadcrumbs))
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
        case .disabled, .storageUnavailable, .quotaExceeded, .tooLarge, .busy, .retryable, .underlying:
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
        ExitSentinel.shared.captureEnabled = {
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
}

enum DiagnosticsCoordinatorError: Error, Equatable {
    case missingAccountUserID
}
#endif
