#if os(iOS) || os(tvOS)
import Foundation
import Observation

@MainActor
@Observable
final class DiagnosticsViewModel {
    private(set) var featureState: DiagnosticsFeatureState = .loading
    private(set) var pendingReports: [PendingReport] = []
    private(set) var sentHistory: [DiagnosticsSentReport] = []
    private(set) var consentMode: DiagnosticsConsentChoice = .ask
    private(set) var selectedDestination: DiagnosticsDestinationChoice
    private(set) var canManageDiagnostics = false
    private(set) var isWorking = false
    var notice: DiagnosticsNotice?
    var prompt: DiagnosticsPrompt?
    var debugLoggingEnabled: Bool {
        didSet {
            consentStore.debugLoggingEnabled = debugLoggingEnabled
        }
    }

    var shouldShowSettings: Bool {
        canManageDiagnostics && featureState != .permanentlyHidden
    }

    var canChangeConsent: Bool {
        statusSnapshot != nil
    }

    var allowsAlwaysSend: Bool {
        selectedDestination == .selfHosted
    }

    var destinationServerName: String {
        if selectedDestination == .hosted {
            return "Silo Diagnostics"
        }
        return ServerRegistry.shared.activeServer?.displayName ?? "Current Silo server"
    }

    var hostedPrivacyDisclosure: String {
        let retentionDays = statusSnapshot?.status.retentionDays
            ?? HostedDiagnosticsCapabilities.conservativeCaptureStatus.retentionDays
        let dayLabel = retentionDays == 1 ? "day" : "days"
        return "Hosted reports use a pseudonymous installation credential that is not linked to your Silo account. They omit account, profile, server address, and playback session identifiers, are retained for up to \(retentionDays) \(dayLabel), and are never sent automatically."
    }

    private let coordinator: DiagnosticsCoordinator
    private let consentStore: DiagnosticsConsentStore
    private let pendingStore: PendingReportStore
    private let destinationStore: DiagnosticsDestinationStore
    private var statusSnapshot: DiagnosticsStatusSnapshot?
    private var generation = 0
    private var isHandlingForeground = false

    init(
        coordinator: DiagnosticsCoordinator = .shared,
        consentStore: DiagnosticsConsentStore = .shared,
        pendingStore: PendingReportStore = .shared,
        destinationStore: DiagnosticsDestinationStore = .shared
    ) {
        self.coordinator = coordinator
        self.consentStore = consentStore
        self.pendingStore = pendingStore
        self.destinationStore = destinationStore
        self.selectedDestination = destinationStore.selectedDestination
        self.debugLoggingEnabled = consentStore.debugLoggingEnabled
    }

    func load(profile: UserProfile?) async {
        _ = await coordinator.retryHostedDeletions()
        canManageDiagnostics = DiagnosticsConsentStore.canManageDiagnostics(profile: profile)
        guard canManageDiagnostics else {
            prompt = nil
            pendingReports = []
            sentHistory = []
            return
        }
        await refreshStatusAndLocalState()
    }

    func reset() {
        generation &+= 1
        featureState = .loading
        pendingReports = []
        sentHistory = []
        consentMode = .ask
        selectedDestination = destinationStore.selectedDestination
        canManageDiagnostics = false
        isWorking = false
        notice = nil
        prompt = nil
        statusSnapshot = nil
    }

    func handleForeground() async {
        _ = await coordinator.retryHostedDeletions()
        guard prompt == nil else { return }
        // Collapse overlapping triggers (auth-state, server/profile,
        // notification, scene-phase) into a single refresh. The guard is set
        // before the first suspension so concurrent callers on the main actor
        // don't each repeat the work.
        guard !isHandlingForeground else { return }
        isHandlingForeground = true
        defer { isHandlingForeground = false }

        let startingGeneration = generation
        guard let startingIdentity = await currentIdentity() else {
            reset()
            return
        }
        let profile = await activeProfile()
        await load(profile: profile)
        guard startingGeneration == generation,
              startingIdentity == (await currentIdentity()) else {
            reset()
            return
        }
        guard canManageDiagnostics,
              featureState == .available,
              let snapshot = statusSnapshot else {
            return
        }

        if consentMode == .always {
            await uploadAutomaticallyEligibleReports(binding: snapshot.binding)
            let identityAfterUpload = await currentIdentity()
            if startingGeneration != generation || startingIdentity != identityAfterUpload {
                reset()
            }
            return
        }

        let eligible = pendingReports.filter { report in
            report.binding.type != .manual
                && !report.state.isPermanentFailure
                && !report.state.promptDeclined
                && DiagnosticsPromptPolicy.isEligible(
                    reportBinding: report.binding.binding,
                    currentBinding: snapshot.binding,
                    status: snapshot.status.status,
                    mode: consentMode,
                    isSuppressed: !pendingStore.canAutoUpload(
                        fingerprint: report.binding.fingerprint,
                        binding: snapshot.binding
                    ),
                    isChildProfile: profile?.isChild ?? true
                )
        }
        guard startingGeneration == generation,
              startingIdentity == (await currentIdentity()) else {
            reset()
            return
        }
        if !eligible.isEmpty {
            prompt = DiagnosticsPrompt(reports: eligible)
        }
    }

    func setConsentMode(_ mode: DiagnosticsConsentChoice) async {
        guard canManageDiagnostics, let snapshot = statusSnapshot else { return }
        guard mode != .always || allowsAlwaysSend else { return }
        consentStore.setMode(
            mode,
            for: snapshot.binding,
            noticeVersion: snapshot.status.consentNoticeVersion,
            purgeImmediately: mode != .never
        )
        consentMode = mode
        if mode == .never {
            isWorking = true
            let erased = await coordinator.turnOffAndDelete(binding: snapshot.binding)
            isWorking = false
            pendingReports = []
            prompt = nil
            if !erased {
                let hasLocalEvidence = !pendingStore.listReports(
                    for: snapshot.binding,
                    now: Date()
                ).isEmpty
                notice = DiagnosticsNotice(
                    message: hasLocalEvidence
                        ? "Crash Reports is off. Some local reports could not be deleted and will retry."
                        : "Crash Reports is off. Remote deletion is queued and will retry."
                )
            }
        } else {
            await reloadLocalState(for: snapshot)
            if mode == .always, featureState.isUploadAvailable {
                await uploadAutomaticallyEligibleReports(binding: snapshot.binding)
            }
        }
    }

    func setDestination(_ destination: DiagnosticsDestinationChoice) async {
        guard destination != selectedDestination else { return }
        generation &+= 1
        destinationStore.select(destination)
        selectedDestination = destination
        statusSnapshot = nil
        featureState = .loading
        pendingReports = []
        sentHistory = []
        prompt = nil
        notice = nil
        await refreshStatusAndLocalState()
    }

    func createAndSendManualReport() async {
        guard canManageDiagnostics, featureState.isUploadAvailable else { return }
        isWorking = true
        notice = nil
        defer { isWorking = false }

        do {
            let report = try await coordinator.createManualReport(destination: selectedDestination)
            _ = try await coordinator.buildBundle(for: report)
            let decision = await coordinator.upload(report: report)
            handle(decision, report: report)
            await reloadLocalStateIfPossible()
        } catch {
            notice = DiagnosticsNotice(message: "The report could not be created. Please try again.")
            await reloadLocalStateIfPossible()
        }
    }

    func delete(_ report: PendingReport) async {
        isWorking = true
        let erased = await coordinator.delete(report: report)
        isWorking = false
        if !erased {
            let message = pendingStore.report(id: report.id) == nil
                ? "The local report was deleted. Remote deletion is queued and will retry."
                : "The report could not be deleted. Please try again."
            notice = DiagnosticsNotice(message: message)
        }
        await reloadLocalStateIfPossible()
    }

    func send(_ report: PendingReport) async {
        guard canManageDiagnostics, featureState.isUploadAvailable else { return }
        isWorking = true
        defer { isWorking = false }
        let decision = await coordinator.upload(report: report)
        handle(decision, report: report)
        await reloadLocalStateIfPossible()
    }

    func declinePrompt() {
        guard let prompt else { return }
        // Suppress re-prompting for each declined report's lifetime. The
        // auto-upload throttle used previously only lasts 24h (reports live 7
        // days), so it would re-surface the same crash on a later foreground.
        // The report stays sendable manually from settings.
        for report in prompt.reports {
            pendingStore.markPromptDeclined(report)
        }
        self.prompt = nil
    }

    func sendPrompt(always: Bool) async {
        guard let prompt, let snapshot = statusSnapshot else { return }
        let shouldAlwaysSend = always && allowsAlwaysSend
        let startingGeneration = generation
        isWorking = true
        if shouldAlwaysSend {
            consentStore.setMode(
                .always,
                for: snapshot.binding,
                noticeVersion: snapshot.status.consentNoticeVersion
            )
            consentMode = .always
        }

        var messages: [String] = []
        for report in prompt.reports {
            let decision = await coordinator.upload(report: report)
            guard startingGeneration == generation else { return }
            messages.append(message(for: decision))
            recordSuccessfulUpload(decision, binding: report.binding.binding)
        }
        let uniqueMessages = messages.reduce(into: [String]()) { result, message in
            if !result.contains(message) {
                result.append(message)
            }
        }
        notice = DiagnosticsNotice(message: uniqueMessages.joined(separator: " "))
        self.prompt = nil
        isWorking = false
        await reloadLocalStateIfPossible()
    }

    func summary(for report: PendingReport) async -> DiagnosticsReportSummary {
        let manifest = (try? await coordinator.buildBundle(for: report))?.manifest
        let logSummary = manifest?.logSummary ?? report.manifest.logSummary
        let device = report.manifest.deviceSummary
        return DiagnosticsReportSummary(
            reportID: report.id,
            type: report.binding.type,
            capturedAt: report.binding.capturedAtDate,
            expiresAt: report.binding.capturedAtDate.addingTimeInterval(PendingReportStore.expiryInterval),
            crashSummary: report.manifest.crash?.summary,
            deviceIdentity: "\(device.manufacturer) \(device.model) · \(device.os) · \(device.formFactor)",
            categories: logSummary.categories,
            lineCount: logSummary.lines,
            destinationServerName: report.binding.binding.destinationChoice == .hosted
                ? "Silo Diagnostics"
                : destinationServerName
        )
    }

    private func refreshStatusAndLocalState() async {
        do {
            let snapshot = try await coordinator.refreshStatus(destination: selectedDestination)
            statusSnapshot = snapshot
            featureState = Self.featureState(for: snapshot.status.status)
            await reloadLocalState(for: snapshot)
        } catch let error as HTTPError where error.statusCode == 404 {
            statusSnapshot = nil
            featureState = .permanentlyHidden
            pendingReports = []
            sentHistory = []
        } catch {
            statusSnapshot = await coordinator.cachedStatusForActiveServer(destination: selectedDestination)
            featureState = .offline
            if let statusSnapshot {
                await reloadLocalState(for: statusSnapshot)
            } else {
                pendingReports = []
                sentHistory = []
            }
        }
    }

    private func reloadLocalStateIfPossible() async {
        guard let statusSnapshot else { return }
        await reloadLocalState(for: statusSnapshot)
    }

    private func reloadLocalState(for snapshot: DiagnosticsStatusSnapshot) async {
        let record = consentStore.record(
            for: snapshot.binding,
            currentNoticeVersion: snapshot.status.consentNoticeVersion
        )
        consentMode = record.mode
        if record.mode == .never {
            _ = await coordinator.turnOffAndDelete(binding: snapshot.binding)
            pendingReports = []
        } else {
            pendingReports = await coordinator.pendingReports(for: snapshot.binding)
        }
        sentHistory = consentStore.sentHistory(for: snapshot.binding)
        debugLoggingEnabled = consentStore.debugLoggingEnabled
    }

    private func uploadAutomaticallyEligibleReports(binding: DiagnosticsBinding) async {
        isWorking = true
        defer { isWorking = false }

        // A report the user explicitly declined stays sendable manually but is
        // never sent automatically — not by prompt and not by Always-mode
        // auto-upload — even if they later switch to Always.
        for report in pendingReports where !report.state.isPermanentFailure
            && !report.state.promptDeclined
            && pendingStore.canAutoUpload(
                fingerprint: report.binding.fingerprint,
                binding: binding
            ) {
            pendingStore.recordAutoUploadAttempt(
                fingerprint: report.binding.fingerprint,
                binding: binding
            )
            let decision = await coordinator.upload(report: report)
            notice = DiagnosticsNotice(message: message(for: decision))
            recordSuccessfulUpload(decision, binding: binding)
        }
        await reloadLocalStateIfPossible()
    }

    private func handle(_ decision: DiagnosticsUploadDecision, report: PendingReport) {
        notice = DiagnosticsNotice(message: message(for: decision))
        recordSuccessfulUpload(decision, binding: report.binding.binding)
        if decision == .keptStaleConsent {
            consentMode = .ask
        }
    }

    private func recordSuccessfulUpload(
        _ decision: DiagnosticsUploadDecision,
        binding: DiagnosticsBinding
    ) {
        guard case .uploaded(let response) = decision else { return }
        consentStore.recordSent(shortID: response.shortID, for: binding)
    }

    private func message(for decision: DiagnosticsUploadDecision) -> String {
        switch decision {
        case .uploaded(let response):
            if let state = response.state {
                return "Sent as \(response.shortID) (\(state.rawValue))."
            }
            return "Sent as \(response.shortID)."
        case .keptProcessing(let shortID):
            return "Received as \(shortID); Silo Diagnostics is validating it."
        case .keptRejected(let code):
            if let code, !code.isEmpty {
                return "Collector rejected the report (\(code)); the local copy was kept."
            }
            return "Collector rejected the report; the local copy was kept."
        case .keptRetryable:
            return "Report kept; Silo will retry."
        case .keptNeedsServerUpdate:
            return "Report kept; your server needs an update."
        case .keptTooLarge:
            return "Report is too large to send and won't be retried."
        case .keptStaleConsent:
            consentMode = .ask
            return "Consent changed; Crash Reports was reset to Ask."
        case .keptDestinationMismatch:
            return "Report kept for the server where it was captured."
        case .discardedInvalidLocalBundle:
            return "The invalid local report was deleted."
        }
    }

    private func activeProfile() async -> UserProfile? {
        guard let activeID = AuthService.shared.profileId else { return nil }
        let profiles = (try? await AuthService.shared.getProfiles()) ?? []
        return profiles.first { $0.id == activeID }
    }

    private func currentIdentity() async -> RuntimeIdentity? {
        // A present, non-empty access token is still required so a sign-out
        // mid-load (token cleared) is detected as an identity change. But the
        // token's *value* is deliberately not part of the identity: HTTPClient
        // can transparently refresh an expired access token during load()'s
        // status/user calls, and fingerprinting the token would misread that
        // refresh as an account change and reset() — dropping the pending
        // prompt or Always-mode auto-upload until another foreground. The stable
        // identity is the server registry id plus the selected profile; a real
        // account switch on the same server goes through an unauthenticated
        // state that clears the token and bumps `generation`, both already
        // guarded here.
        guard let serverRegistryID = ServerRegistry.shared.activeServerId,
              let token = await TokenStore.shared.getAccessToken(),
              !token.isEmpty else {
            return nil
        }
        return RuntimeIdentity(
            serverRegistryID: serverRegistryID,
            profileID: AuthService.shared.profileId
        )
    }

    private static func featureState(
        for status: DiagnosticsAvailabilityStatus
    ) -> DiagnosticsFeatureState {
        switch status {
        case .available:
            return .available
        case .disabled:
            return .disabledByServer
        case .storageUnavailable:
            return .storageUnavailable
        }
    }

    private struct RuntimeIdentity: Equatable {
        let serverRegistryID: String
        let profileID: String?
    }
}

extension Notification.Name {
    static let diagnosticsPendingReportCreated = Notification.Name("diagnosticsPendingReportCreated")
}
#endif
