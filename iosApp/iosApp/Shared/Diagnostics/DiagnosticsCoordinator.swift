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

struct DiagnosticsProfileEligibilityRecord: Codable, Equatable {
    let binding: DiagnosticsBinding
    let profileID: String
    let isChild: Bool

    enum CodingKeys: String, CodingKey {
        case binding
        case profileID = "profile_id"
        case isChild = "is_child"
    }
}

/// Persists the last profile eligibility resolved from `/profiles`, scoped to
/// the diagnostics binding as well as the profile id. MetricKit can deliver a
/// one-shot crash payload on a later offline launch; this cache lets that path
/// retain the last known adult eligibility without ever reusing another
/// account's profile result.
final class DiagnosticsProfileEligibilityStore {
    static let shared = DiagnosticsProfileEligibilityStore()

    private static let key = "diagnostics.profileEligibility.v1"
    private let defaults: SharedDefaults
    private let lock = NSLock()

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    func record(isChild: Bool, profileID: String, binding: DiagnosticsBinding) {
        guard !profileID.isEmpty else { return }
        lock.lock()
        var records = load()
        records.removeAll { $0.binding == binding && $0.profileID == profileID }
        records.append(DiagnosticsProfileEligibilityRecord(
            binding: binding,
            profileID: profileID,
            isChild: isChild
        ))
        save(records)
        lock.unlock()
    }

    func isChild(profileID: String, binding: DiagnosticsBinding) -> Bool? {
        lock.lock()
        let value = load().first { $0.binding == binding && $0.profileID == profileID }?.isChild
        lock.unlock()
        return value
    }

    func remove(binding: DiagnosticsBinding) {
        lock.lock()
        let records = load()
        let filtered = records.filter { $0.binding != binding }
        if filtered.count != records.count {
            save(filtered)
        }
        lock.unlock()
    }

    func remove(serverInstanceID: String) {
        lock.lock()
        let records = load()
        let filtered = records.filter { $0.binding.serverInstanceID != serverInstanceID }
        if filtered.count != records.count {
            save(filtered)
        }
        lock.unlock()
    }

    private func load() -> [DiagnosticsProfileEligibilityRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? DiagnosticsJSONCoding.makeDecoder().decode(
                  [DiagnosticsProfileEligibilityRecord].self,
                  from: data
              ) else {
            return []
        }
        return records
    }

    private func save(_ records: [DiagnosticsProfileEligibilityRecord]) {
        guard let data = try? DiagnosticsJSONCoding.makeEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }
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
    /// Whether the profile active right now may capture diagnostics. Breadcrumb
    /// capture is a synchronous gate, but child-profile eligibility needs an
    /// async lookup, so it is cached here and re-resolved on profile switches
    /// (`activeProfileDidChange`) and status refreshes. Defaults to ineligible:
    /// a restored child profile can cold-launch without performing a profile
    /// write, so capture must stay off until an async child check positively
    /// confirms the active profile is not a child. Guarded by
    /// `breadcrumbContextLock`.
    nonisolated(unsafe) private static var activeProfileBreadcrumbEligible = false
    /// Monotonic token for async profile-eligibility checks. A profile/server
    /// change can start a new `/profiles` request before the old one completes;
    /// only the newest generation may publish into the synchronous capture gate.
    nonisolated(unsafe) private static var activeProfileEligibilityGeneration: UInt64 = 0

    private let api: DiagnosticsAPI
    private let continuumAPI: ContinuumAPI
    private let consentStore: DiagnosticsConsentStore
    private let pendingStore: PendingReportStore
    private let bundleBuilder: DiagnosticsBundleBuilder
    private let deviceSnapshotBuilder: DeviceSnapshotBuilder
    private let profileEligibilityStore: DiagnosticsProfileEligibilityStore

    private var cachedStatus: DiagnosticsStatusSnapshot?
    private var cachedStatusServerRegistryID: String?
    private var cachedStatusAccessTokenFingerprint: String?

    init(
        api: DiagnosticsAPI = .shared,
        continuumAPI: ContinuumAPI = .shared,
        consentStore: DiagnosticsConsentStore = .shared,
        pendingStore: PendingReportStore = .shared,
        bundleBuilder: DiagnosticsBundleBuilder = DiagnosticsBundleBuilder(),
        deviceSnapshotBuilder: DeviceSnapshotBuilder = .live,
        profileEligibilityStore: DiagnosticsProfileEligibilityStore = .shared
    ) {
        self.api = api
        self.continuumAPI = continuumAPI
        self.consentStore = consentStore
        self.pendingStore = pendingStore
        self.bundleBuilder = bundleBuilder
        self.deviceSnapshotBuilder = deviceSnapshotBuilder
        self.profileEligibilityStore = profileEligibilityStore
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
        updateBreadcrumbConsentContext(
            binding: binding,
            noticeVersion: status.consentNoticeVersion,
            statusAvailable: status.status == .available
        )
        // Keep the synchronous breadcrumb eligibility flag current for the
        // profile in view (covers a launch directly into a child profile).
        // Fire-and-forget so a status refresh is not gated on getProfiles.
        let eligibilityGeneration = Self.beginActiveProfileEligibilityResolution(invalidateCurrent: false)
        Task {
            await reevaluateActiveProfileBreadcrumbEligibility(generation: eligibilityGeneration)
        }
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

    /// Whether `profileID` is a child profile on the active account. Returns
    /// nil when it cannot be determined — `getProfiles()` failed (e.g. offline)
    /// or the id is not among the account's profiles — so callers can fail
    /// closed rather than treat "unknown" as "not a child".
    private func profileIsChild(_ profileID: String) async -> Bool? {
        guard let profiles = try? await AuthService.shared.getProfiles() else {
            return nil
        }
        return profiles.first(where: { $0.id == profileID })?.isChild
    }

    /// Child status of the profile active right now. No profile selected means
    /// no child session is in front of us, so it reports non-child (false); an
    /// active profile whose child status can't be resolved reports nil.
    private func activeProfileIsChild(
        binding: DiagnosticsBinding,
        persistResult: Bool = true
    ) async -> Bool? {
        guard let activeProfileID = AuthService.shared.profileId else {
            return false
        }
        let serverRegistryID = ServerRegistry.shared.activeServerId
        let isChild = await profileIsChild(activeProfileID)
        // A profile/server switch can happen while `/profiles` is in flight.
        // Never publish the result into the new identity's synchronous gate.
        guard activeProfileID == AuthService.shared.profileId,
              serverRegistryID == ServerRegistry.shared.activeServerId,
              binding == Self.currentDiagnosticsBinding else {
            return nil
        }
        if let isChild, persistResult {
            profileEligibilityStore.record(
                isChild: isChild,
                profileID: activeProfileID,
                binding: binding
            )
        }
        return isChild
    }

    /// Last positively resolved child status for this exact account/profile.
    /// Persistent captures use it only after accepting a last-known diagnostics
    /// status fallback, because re-fetching `/profiles` while offline would turn
    /// an otherwise valid crash capture into a guaranteed drop. An absent cache
    /// entry fails closed.
    private func cachedActiveProfileIsChild(binding: DiagnosticsBinding) -> Bool? {
        guard let activeProfileID = AuthService.shared.profileId else {
            return false
        }
        return profileEligibilityStore.isChild(profileID: activeProfileID, binding: binding)
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
    /// artifact so it can be stored with an abnormal-exit report at capture
    /// time. The tvOS sentinel provides the concrete start of the failed run.
    func logSnapshotArtifact(since start: Date, runID: String) -> PendingReportArtifact? {
        let ringSnapshot = DiagLog.ring.snapshot()
        let candidateLines = ringSnapshot.lines + harvestOSLogLines(since: start)
        let lines = Self.logLines(candidateLines, forRunID: runID, since: start)
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
        // A non-persistent capture context is nil only when the status refresh
        // failed (offline or identity mid-change) — the destination was never
        // actually checked. Returning keptDestinationMismatch here would show
        // the wrong message and, on the Always path (already throttled before
        // upload), suppress retries for 24h. Keep it retryable instead; a
        // genuine binding mismatch is still reported below.
        guard let context = await captureContext(requirePersistentCapture: false) else {
            return .keptRetryable
        }
        guard report.isUploadable(to: context.binding) else {
            return .keptDestinationMismatch
        }

        // The server attributes an upload to the profile in the X-Profile-Id
        // header (HTTPClient sends the *currently active* profile) and rejects
        // it as profile_mismatch (HTTP 400) when that disagrees with the
        // manifest's captured report.profile_id. A report captured under
        // profile A must therefore not be uploaded while profile B is active;
        // hold it retryable so it uploads cleanly next time the capturing
        // profile is active. Checked here before the (slow) bundle build for
        // the common case, and again right before the POST below in case the
        // profile switches while the bundle is building.
        if Self.isProfileUploadMismatch(
            captured: report.manifest.report.profileID,
            active: await TokenStore.shared.getProfileId()
        ) {
            return .keptRetryable
        }

        // Refresh both the consent notice version and mode from the current
        // consent record before building the upload. If the server's notice
        // advanced after capture, the frozen manifest would carry a stale
        // notice_version and be rejected as stale_consent on every retry — even
        // after the user re-consents. And if that advance demoted the account
        // Always→Ask, the manifest must not still claim mode=always for the new
        // notice. A manual report stays manual regardless of the account's
        // ask/always setting. The report evidence stays frozen.
        let currentConsent = consentStore.record(
            for: report.binding.binding,
            currentNoticeVersion: context.noticeVersion
        )
        let refreshedMode: ConsentMode = report.manifest.consent.mode == .manual
            ? .manual
            : currentConsent.mode.manifestMode
        let report = pendingStore.updatingConsent(
            report,
            mode: refreshedMode,
            noticeVersion: currentConsent.noticeVersion
        )

        do {
            // Snapshot the destination *identity* before building the bundle.
            // The build harvests OSLog and gzips the archive, which takes long
            // enough for the active server/account/profile to change underneath
            // us. HTTPClient resolves the current TokenStore at request time,
            // and a same-server account switch keeps the report's
            // server_instance_id while swapping the account — so without
            // re-checking, this old report could post to the newly active
            // account.
            //
            // Compare a *stable* identity — the active server registry id and
            // the selected profile — not the access-token value. HTTPClient can
            // transparently refresh an expired access token while buildBundle is
            // running; fingerprinting the token would misread that refresh as a
            // destination change and, on the already-throttled Always path, turn
            // a sendable report into keptRetryable and defer the next auto-upload
            // for 24h. A genuine account switch on the same server passes through
            // a token-cleared (unauthenticated) state and lands on a different
            // profile, so requiring the token to still be present (sign-out
            // check) plus an unchanged server and profile still rejects a moved
            // destination. The captured profile is also re-checked against the
            // active one so the server's X-Profile-Id can't disagree with the
            // manifest's report.profile_id. The next attempt's `isUploadable`
            // check above reclassifies a genuine account move as a destination
            // mismatch precisely.
            let destinationServerRegistryID = ServerRegistry.shared.activeServerId
            let destinationProfileID = await TokenStore.shared.getProfileId()
            let capturedProfileID = report.manifest.report.profileID
            let bundle = try await buildBundle(for: report)
            let activeProfileID = await TokenStore.shared.getProfileId()
            guard await Self.currentAccessTokenFingerprint() != nil,
                  ServerRegistry.shared.activeServerId == destinationServerRegistryID,
                  activeProfileID == destinationProfileID,
                  !Self.isProfileUploadMismatch(
                    captured: capturedProfileID,
                    active: activeProfileID
                  ) else {
                return .keptRetryable
            }
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
        let usedLastKnownSnapshot: Bool
        do {
            snapshot = try await refreshStatus()
            usedLastKnownSnapshot = false
        } catch {
            // A persistent capture (crash/hang/abnormal-exit) must survive being
            // offline: fall back to the last-known-good status/binding so it is
            // still queued locally. But the fallback is only safe for genuinely
            // transient failures — offline/network or a 5xx server error. A
            // definitive server answer (401/403 auth failure, 404 missing
            // endpoint, any other 4xx) or an identity-level coordinator error
            // means the session may already be signed out or the endpoint gone;
            // binding a capture to the last-known binding there would attribute
            // it to a signed-out or stale account, so we fail closed. Also only
            // persistent captures use the fallback at all.
            guard Self.isTransientCaptureFallbackFailure(error),
                  requirePersistentCapture,
                  let fallback = lastKnownSnapshotForActiveServer() else {
                return nil
            }
            snapshot = fallback
            usedLastKnownSnapshot = true
        }

        let record = consentStore.record(
            for: snapshot.binding,
            currentNoticeVersion: snapshot.status.consentNoticeVersion
        )
        if requirePersistentCapture {
            // The server-side feature must be available. When offline we fall
            // back to the last-known status above, so persist only if that
            // last-known status was itself available — a disabled or
            // storage-unavailable server must never accumulate crash reports
            // that could auto-upload once it is re-enabled.
            guard snapshot.status.status == .available else {
                return nil
            }
            if record.mode == .never {
                return nil
            }
            // Child profiles cannot manage diagnostics. Resolve live whenever
            // the status request succeeded. If the status itself fell back
            // because the server is offline, use only the last eligibility
            // recorded for this exact binding/profile; making another live
            // `/profiles` request there would always fail and discard a
            // one-shot MetricKit delivery. Missing or stale identity data still
            // fails closed.
            let isChild = usedLastKnownSnapshot
                ? cachedActiveProfileIsChild(binding: snapshot.binding)
                : await activeProfileIsChild(binding: snapshot.binding)
            guard isChild == false else {
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
            profileEligibilityStore.remove(serverInstanceID: serverId)
        } else {
            for serverInstanceID in serverInstanceIDs {
                pendingStore.purge(serverInstanceID: serverInstanceID)
                consentStore.remove(serverInstanceID: serverInstanceID)
                profileEligibilityStore.remove(serverInstanceID: serverInstanceID)
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
        // Attribute the report to the account that was active when the marker
        // was written, never to whoever is active now. The evidence (this-run
        // breadcrumbs/logs) belongs to the crashed account.
        //
        // - Marker carries a binding (written with binding support): capture
        //   only when it still matches the active account. A mismatch means a
        //   different account is in front of us now; drop the stale marker
        //   rather than leak the crashed account's breadcrumbs/logs to it.
        // - Legacy marker without a binding (predates binding support): we
        //   cannot prove which account crashed, so fall back to the current
        //   binding — the pre-existing best-effort behavior.
        if let markerBinding = marker.binding, markerBinding != context.binding {
            return true
        }
        // The marker records the profile active when the crashed run started. A
        // child profile can't manage diagnostics, so an abnormal exit captured
        // under one must never be re-attributed to (and later uploaded by) an
        // adult profile on the same account. captureContext() above only gates
        // the profile active *now*, so re-check the marker's own profile and
        // drop child-run markers. A legacy marker without a profile id keeps the
        // pre-existing behavior; an undeterminable status keeps the marker for a
        // later retry (captureContext already resolved the account's profiles,
        // so this is normally a cache hit) rather than losing or leaking it.
        if let markerProfileID = marker.profileID {
            switch await profileIsChild(markerProfileID) {
            case true?:
                return true
            case nil:
                return false
            case false?:
                break
            }
        }
        let boundContext = marker.binding != nil
            ? context.overridingProfileID(marker.profileID)
            : context
        let fingerprint = DiagnosticsSHA256.hex(
            data: Data("exit_sentinel|\(marker.runID)|\(marker.startedAt)".utf8)
        )
        if pendingStore.hasSeenFingerprint(fingerprint, now: Date()) {
            return true
        }

        let device = deviceSnapshotBuilder.build(provenance: .postRestart)
        let capturedAt = Date()
        let breadcrumbLines = Self.breadcrumbJournal.readAll()
        let crashedRunBreadcrumbLines = Self.breadcrumbLines(
            breadcrumbLines,
            forRunID: marker.runID,
            since: marker.startedAtDate
        )
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
        let manifest = boundContext.makeManifestDraft(
            type: .abnormalExit,
            capturedAt: capturedAt,
            crash: crash,
            deviceSummary: deviceSnapshotBuilder.deviceSummary(from: device),
            playbackSessionIDs: RecentSessionTracker.shared.recentSessionIDs(for: boundContext.binding),
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
        if let logSnapshot = logSnapshotArtifact(since: marker.startedAtDate, runID: marker.runID) {
            artifacts.append(logSnapshot)
        }

        do {
            _ = try pendingStore.save(PendingReportCapture(
                binding: boundContext.binding,
                profileID: boundContext.profileID,
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

    nonisolated static func breadcrumbLines(
        _ lines: [DiagnosticsLogLine],
        forRunID runID: String,
        since start: Date
    ) -> [DiagnosticsLogLine] {
        lines.filter { line in
            guard line.run == runID,
                  let timestamp = DiagnosticsDates.date(from: line.ts) else {
                return false
            }
            return timestamp >= start
        }
    }

    /// Keeps only evidence emitted by the failed process run. The abnormal-exit
    /// marker is consumed on the next launch, when both the ring and OSLog can
    /// already contain new-session lines whose timestamps are after `start`.
    nonisolated static func logLines(
        _ lines: [String],
        forRunID runID: String,
        since start: Date
    ) -> [String] {
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        return lines.filter { line in
            guard let decoded = try? decoder.decode(DiagnosticsLogLine.self, from: Data(line.utf8)),
                  decoded.run == runID,
                  let timestamp = DiagnosticsDates.date(from: decoded.ts) else {
                return false
            }
            return timestamp >= start
        }
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
        clearContext(for: binding)
        #if os(tvOS)
        ExitSentinel.shared.purge()
        #endif
    }

    /// After purging a binding (e.g. an active-server sign-out) the pending
    /// files and consent record are gone, but the cached/persisted status and
    /// the breadcrumb consent context can still point at it. Since the consent
    /// record was removed, a later capture or breadcrumb check would recreate
    /// it as the default Ask and resume saving diagnostics for the signed-out
    /// account. Drop every in-memory and persisted pointer to the binding.
    private func clearContext(for binding: DiagnosticsBinding) {
        if cachedStatus?.binding == binding {
            cachedStatus = nil
            cachedStatusServerRegistryID = nil
            cachedStatusAccessTokenFingerprint = nil
        }
        Self.LastKnownStatusStore.removeSnapshots(matching: binding)
        profileEligibilityStore.remove(binding: binding)
        Self.clearBreadcrumbConsentContext(matching: binding)
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

    /// Whether a `refreshStatus()` failure is transient enough that a
    /// persistent capture may fall back to the last-known snapshot. Only
    /// offline/network errors and 5xx server errors qualify; auth/permission
    /// failures (401/403), a missing endpoint (404), any other definitive
    /// server answer, and identity-level coordinator errors fail closed so a
    /// capture is never queued against a signed-out or unavailable binding.
    nonisolated static func isTransientCaptureFallbackFailure(_ error: Error) -> Bool {
        if error is DiagnosticsCoordinatorError {
            return false
        }
        if let httpError = error as? HTTPError {
            switch httpError {
            case .network:
                return true
            case .http(let statusCode, _):
                return (500...599).contains(statusCode)
            case .serverUrlNotConfigured, .invalidURL, .invalidResponse,
                 .encodingFailed, .decodingFailed:
                return false
            }
        }
        // HTTPClient wraps transport failures as `.network`, but treat a raw
        // URLError as transient too in case one reaches here unwrapped.
        if error is URLError {
            return true
        }
        return false
    }

    /// Mirror of the server's `resolveProfileID` conflict rule: an upload is
    /// rejected as profile_mismatch only when the manifest's captured
    /// `report.profile_id` and the X-Profile-Id header (the profile active at
    /// upload time) are both non-empty and disagree. If either side is
    /// nil/blank the server resolves attribution from the single present value
    /// with no conflict, so those cases must not be held back. Whitespace is
    /// trimmed on both sides to match the server's comparison exactly.
    nonisolated static func isProfileUploadMismatch(captured: String?, active: String?) -> Bool {
        let capturedID = captured?.trimmingCharacters(in: .whitespaces) ?? ""
        let activeID = active?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !capturedID.isEmpty, !activeID.isEmpty else {
            return false
        }
        return capturedID != activeID
    }

    private static func currentAccessTokenFingerprint() async -> String? {
        guard let token = await TokenStore.shared.getAccessToken(), !token.isEmpty else {
            return nil
        }
        return DiagnosticsSHA256.hex(data: Data(token.utf8))
    }

    struct BreadcrumbConsentContext {
        let binding: DiagnosticsBinding
        let noticeVersion: Int
        /// Whether the server reported diagnostics as `available`. Breadcrumb
        /// capture stays off while the feature is disabled/storage-unavailable,
        /// mirroring the persistent-capture gate.
        let isAvailable: Bool

        init(binding: DiagnosticsBinding, noticeVersion: Int, isAvailable: Bool = true) {
            self.binding = binding
            self.noticeVersion = noticeVersion
            self.isAvailable = isAvailable
        }
    }

    private func updateBreadcrumbConsentContext(
        binding: DiagnosticsBinding,
        noticeVersion: Int,
        statusAvailable: Bool
    ) {
        Self.breadcrumbContextLock.lock()
        let previousBinding = Self.breadcrumbConsentContext?.binding
        Self.breadcrumbConsentContext = BreadcrumbConsentContext(
            binding: binding,
            noticeVersion: noticeVersion,
            isAvailable: statusAvailable
        )
        Self.breadcrumbContextLock.unlock()
        // A server/account switch mid-run leaves the previous binding's trail in
        // the on-disk breadcrumb journal AND in the process-wide log ring.
        // MetricKit (and the tvOS abnormal-exit path) can later bundle either
        // into a report bound to the NEW account, leaking the old account's
        // navigation/playback breadcrumbs and CMP/playback log lines (including
        // session_ids). Rotate the journal and clear the ring when the active
        // binding actually changes so the new binding starts clean. A plain
        // refresh of the same binding keeps its trail, and the first establish
        // of a launch (previousBinding == nil) keeps the prior run's lines so
        // the abnormal-exit capture can still read them.
        if let previousBinding, previousBinding != binding {
            Self.purgeBreadcrumbJournal()
            DiagLog.ring.clear()
        }
        #if os(tvOS)
        ExitSentinel.shared.setCaptureEnabled {
            DiagnosticsCoordinator.breadcrumbCaptureEnabled()
        }
        // The tvOS sentinel arms in SiloApp.init, before the first status
        // refresh. With no last-known snapshot the current run's marker was
        // written with binding == nil and would otherwise only be back-filled
        // on a later foreground event. Bind it now — the moment the diagnostics
        // binding first resolves — so a crash later in this same foreground is
        // attributed to this account instead of being treated as a legacy
        // marker (and bound to whoever is active) on relaunch.
        ExitSentinel.shared.bindCurrentMarker(
            binding: binding,
            profileID: AuthService.shared.profileId
        )
        #endif
    }

    nonisolated private static func currentBreadcrumbBinding() -> DiagnosticsBinding? {
        resolvedBreadcrumbContext()?.binding
    }

    /// The breadcrumb consent context for the account currently in view. A live
    /// status refresh populates it (see `updateBreadcrumbConsentContext`);
    /// until the first refresh of a launch it is nil, so fall back to the last
    /// successful status persisted for the active server. That lets a fresh
    /// launch honor the account's stored consent — including Never — before any
    /// network call, and lets abnormal-exit markers record a binding even
    /// before the first refresh. Returns nil when nothing is known yet, which
    /// callers treat as "capture disabled".
    nonisolated private static func resolvedBreadcrumbContext() -> BreadcrumbConsentContext? {
        breadcrumbContextLock.lock()
        let context = breadcrumbConsentContext
        breadcrumbContextLock.unlock()
        if let context {
            return context
        }
        guard let serverId = ServerRegistry.shared.activeServerId,
              let snapshot = LastKnownStatusStore.snapshot(for: serverId) else {
            return nil
        }
        return BreadcrumbConsentContext(
            binding: snapshot.binding,
            noticeVersion: snapshot.status.consentNoticeVersion,
            isAvailable: snapshot.status.status == .available
        )
    }

    nonisolated private static func clearBreadcrumbConsentContext(matching binding: DiagnosticsBinding) {
        breadcrumbContextLock.lock()
        if breadcrumbConsentContext?.binding == binding {
            breadcrumbConsentContext = nil
        }
        breadcrumbContextLock.unlock()
    }

    /// The binding for the server/account currently in view, captured at the
    /// last successful status refresh. Exposed so playback-session recording
    /// can scope entries to the active binding (see `RecentSessionTracker`),
    /// preventing another server/account's session IDs from leaking into a
    /// report bound elsewhere.
    nonisolated static var currentDiagnosticsBinding: DiagnosticsBinding? {
        currentBreadcrumbBinding()
    }

    /// Whether diagnostics is actively collecting for the account currently in
    /// view — server-available, consent not Never, and a non-child profile.
    /// Exposed so playback-session recording (RecentSessionTracker) uses the
    /// same gate as breadcrumb capture and does not accumulate session IDs while
    /// collection is off; those would otherwise surface in a later manual report
    /// or after diagnostics is re-enabled for the same binding.
    nonisolated static var isDiagnosticsCaptureEnabled: Bool {
        breadcrumbCaptureEnabled()
    }

    /// Re-evaluate breadcrumb eligibility for the profile now active. Call on
    /// profile switches: a child profile can't manage diagnostics, so breadcrumb
    /// capture and the tvOS exit sentinel must disarm even though the
    /// server/account binding (and its consent) is unchanged. Fails closed
    /// immediately, then confirms asynchronously so a switch into a child profile
    /// can't capture even one breadcrumb before the child lookup lands.
    nonisolated static func activeProfileWillChange() {
        _ = beginActiveProfileEligibilityResolution(invalidateCurrent: true)
    }

    nonisolated static func activeProfileDidChange() {
        let generation = beginActiveProfileEligibilityResolution(invalidateCurrent: true)
        Task {
            await shared.reevaluateActiveProfileBreadcrumbEligibility(generation: generation)
        }
    }

    func reevaluateActiveProfileBreadcrumbEligibility(generation: UInt64) async {
        guard let binding = Self.currentDiagnosticsBinding else {
            _ = Self.publishActiveProfileBreadcrumbEligibility(false, generation: generation)
            return
        }
        let isChild = await activeProfileIsChild(
            binding: binding,
            persistResult: false
        )
        // Eligible only when positively known to be a non-child profile; an
        // undeterminable status (offline getProfiles failure) fails closed,
        // consistent with the persistent-capture child gate in captureContext().
        let eligible = isChild == false
        let resolvedEligibility = isChild.flatMap { isChild in
            AuthService.shared.profileId.map { profileID in
                (
                    store: profileEligibilityStore,
                    isChild: isChild,
                    profileID: profileID,
                    binding: binding
                )
            }
        }
        guard Self.publishActiveProfileBreadcrumbEligibility(
            eligible,
            generation: generation,
            resolvedEligibility: resolvedEligibility
        ) else {
            return
        }
        #if os(tvOS)
        ExitSentinel.shared.profileEligibilityDidResolve(
            binding: binding,
            profileID: AuthService.shared.profileId
        )
        #endif
    }

    /// Start an async resolution and return its ownership token. Explicit
    /// profile/server changes invalidate synchronously; routine same-identity
    /// status refreshes keep the last resolved gate while revalidating so they
    /// do not create a sentinel coverage gap.
    nonisolated private static func beginActiveProfileEligibilityResolution(
        invalidateCurrent: Bool
    ) -> UInt64 {
        breadcrumbContextLock.lock()
        activeProfileEligibilityGeneration &+= 1
        if invalidateCurrent {
            activeProfileBreadcrumbEligible = false
        }
        let generation = activeProfileEligibilityGeneration
        breadcrumbContextLock.unlock()
        #if os(tvOS)
        if invalidateCurrent {
            // The marker may belong to the prior adult profile. Remove this
            // process's current-run slot immediately; a previous-run crash
            // marker is preserved by the run-id check.
            ExitSentinel.shared.disarmCurrentRun()
        }
        #endif
        return generation
    }

    /// Publish only if no newer profile/server resolution has started.
    @discardableResult
    nonisolated private static func publishActiveProfileBreadcrumbEligibility(
        _ eligible: Bool,
        generation: UInt64,
        resolvedEligibility: (
            store: DiagnosticsProfileEligibilityStore,
            isChild: Bool,
            profileID: String,
            binding: DiagnosticsBinding
        )? = nil
    ) -> Bool {
        breadcrumbContextLock.lock()
        guard generation == activeProfileEligibilityGeneration else {
            breadcrumbContextLock.unlock()
            return false
        }
        if let resolvedEligibility {
            resolvedEligibility.store.record(
                isChild: resolvedEligibility.isChild,
                profileID: resolvedEligibility.profileID,
                binding: resolvedEligibility.binding
            )
        }
        activeProfileBreadcrumbEligible = eligible
        breadcrumbContextLock.unlock()
        return true
    }

    nonisolated private static func breadcrumbCaptureEnabled() -> Bool {
        // A child profile can't manage diagnostics, so breadcrumb capture (and
        // the tvOS exit sentinel that shares this gate) must disarm the moment
        // one becomes active — even though the server/account binding and its
        // consent are unchanged. Mirrors the persistent-capture child gate in
        // captureContext(); the eligibility flag is re-resolved on profile
        // switches and status refreshes. Read the flag before resolving the
        // context, which takes the same lock.
        breadcrumbContextLock.lock()
        let profileEligible = activeProfileBreadcrumbEligible
        breadcrumbContextLock.unlock()
        guard profileEligible else { return false }
        return breadcrumbCaptureEnabled(for: resolvedBreadcrumbContext())
    }

    /// Pure consent check shared by the live gate and tests. No resolvable
    /// context means no account has been established yet on this launch, so
    /// breadcrumb capture stays disabled rather than defaulting on — otherwise
    /// a Never account's fresh launch would write breadcrumbs until the first
    /// status refresh. A context whose status is not `available`
    /// (disabled/storage_unavailable) also stays disabled: the server-side
    /// feature is off, so arming capture would only accumulate breadcrumbs that
    /// could be bundled if diagnostics is later re-enabled — consistent with
    /// the persistent-capture availability gate in captureContext().
    nonisolated static func breadcrumbCaptureEnabled(
        for context: BreadcrumbConsentContext?,
        consentStore: DiagnosticsConsentStore = .shared
    ) -> Bool {
        guard let context, context.isAvailable else {
            return false
        }
        return consentStore.persistentCaptureEnabled(
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

        static func removeSnapshots(matching binding: DiagnosticsBinding) {
            lock.lock()
            let index = load()
            let filtered = index.filter { $0.value.binding != binding }
            if filtered.count != index.count {
                save(filtered)
            }
            lock.unlock()
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
