#if os(iOS) || os(tvOS)
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Memo for the synchronous capture gate (`breadcrumbCaptureEnabled()`).
///
/// The gate is the predicate every `DiagTrace.log` call evaluates *before*
/// deciding to drop a line, so at a few hundred HTTP responses a minute it was
/// running a full `UserDefaults` read plus a `JSONDecoder` pass over the whole
/// consent-record dictionary, under a lock shared with the main actor, for
/// lines that were then suppressed anyway.
///
/// This is a memo, not a second source of truth: the authoritative gate is
/// still computed, just not per call. Every input it reads is folded into
/// `Key`, so a cache hit is only possible when nothing the decision depends on
/// has moved. It fails closed in both directions:
///
/// * A miss recomputes authoritatively rather than assuming anything.
/// * A publish that races an invalidation is discarded and answers `false`, so
///   a consent revocation or a switch into a child profile mid-computation can
///   never leave capture latched on. Losing one line at a consent boundary is
///   the correct trade.
/// * A memoized `true` additionally expires on a short timer, so even a
///   hypothetical unmodelled input (consent records live in the App Group
///   suite, which another process could in principle write) cannot keep capture
///   on indefinitely. A memoized `false` never expires — leaving capture off
///   too long is the safe direction, and the boundary hooks reopen it.
final class DiagnosticsCaptureGateCache: @unchecked Sendable {
    /// Ceiling on how long a positive decision may be reused without being
    /// re-derived. Short enough that no realistic unmodelled change stays
    /// invisible; long enough that a burst of requests costs one evaluation.
    static let positiveLifetime: TimeInterval = 2

    /// Everything the authoritative gate reads. `epoch` covers the coordinator's
    /// own breadcrumb context, destination-transition latch, and profile
    /// eligibility; `consentGeneration` covers stored consent; the server id and
    /// destination cover the last-known-status fallback the gate resolves
    /// through when no live context exists yet.
    struct Key: Equatable {
        let epoch: UInt64
        let consentGeneration: UInt64
        let serverRegistryID: String?
        let destination: DiagnosticsDestinationChoice
    }

    private let now: () -> TimeInterval
    /// `OSAllocatedUnfairLock` owns stable allocated storage, which a stored
    /// `os_unfair_lock_s` does not: locking that through `&lock` is an inout
    /// access the compiler may satisfy with a temporary copy, so the threads
    /// that reach the gate — URLSession callbacks, the `HTTPClient` actor, the
    /// main actor — could each lock a different word and lose mutual exclusion
    /// over the memo. That would break the fail-closed epoch check below, which
    /// is the only thing keeping a consent revocation from latching capture on.
    private let lock = OSAllocatedUnfairLock()
    private var epoch: UInt64 = 0
    private var cachedKey: Key?
    private var cachedValue = false
    private var cachedExpiry: TimeInterval = 0
    #if DEBUG
    private var authoritativeEvaluations = 0
    #endif

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var currentEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// Drop the memo and move the epoch so an in-flight computation started
    /// before this boundary can no longer publish. Called from every mutation
    /// of the coordinator state the gate reads.
    func invalidate() {
        lock.lock()
        epoch &+= 1
        cachedKey = nil
        cachedValue = false
        cachedExpiry = 0
        lock.unlock()
    }

    /// `nil` means "not resolved for this exact state" — the caller must
    /// recompute. There is no default-on branch here by construction.
    func value(for key: Key) -> Bool? {
        let timestamp = now()
        lock.lock()
        defer { lock.unlock() }
        guard let cachedKey, cachedKey == key else { return nil }
        // Only a positive decision carries an expiry; a cached `false` is
        // reusable forever because the failure direction is the safe one.
        guard !cachedValue || timestamp < cachedExpiry else { return nil }
        return cachedValue
    }

    /// Publish `value` only if the state it was computed from is still the
    /// current state. `current` is re-read by the caller after the computation;
    /// if it moved, some boundary was crossed while we were deciding, so the
    /// result is discarded and the answer is `false`.
    func store(_ value: Bool, for key: Key, still current: Key) -> Bool {
        let timestamp = now()
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        authoritativeEvaluations += 1
        #endif
        guard key == current, key.epoch == epoch else {
            return false
        }
        cachedKey = key
        cachedValue = value
        cachedExpiry = timestamp + Self.positiveLifetime
        return value
    }

    #if DEBUG
    /// Number of authoritative (cache-missing) evaluations since the last
    /// reset. Tests use it to prove the hot path is memoized.
    var authoritativeEvaluationCountForTests: Int {
        lock.lock()
        defer { lock.unlock() }
        return authoritativeEvaluations
    }

    func resetForTests() {
        lock.lock()
        epoch &+= 1
        cachedKey = nil
        cachedValue = false
        cachedExpiry = 0
        authoritativeEvaluations = 0
        lock.unlock()
    }
    #endif
}

struct DiagnosticsStatusSnapshot: Equatable, Codable {
    let status: DiagnosticsStatusResponse
    let binding: DiagnosticsBinding
}

/// Equivalent refreshes share an epoch. Only an actual destination change
/// invalidates an in-flight result, so a batch of MetricKit payloads can all
/// resolve the same current capture context without dropping earlier items.
struct DiagnosticsStatusRefreshEpoch {
    private(set) var generation: UInt64 = 0
    private(set) var destination: DiagnosticsDestinationChoice?

    mutating func begin(destination: DiagnosticsDestinationChoice) -> UInt64 {
        if self.destination != destination {
            generation &+= 1
            self.destination = destination
        }
        return generation
    }

    func isCurrent(_ generation: UInt64, destination: DiagnosticsDestinationChoice) -> Bool {
        self.generation == generation && self.destination == destination
    }
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
    case keptProcessing(shortID: String)
    case keptRejected(code: String?)
    case keptRetryable
    case keptNeedsServerUpdate
    case keptTooLarge
    case keptStaleConsent
    case keptDestinationMismatch
    case discardedInvalidLocalBundle
}

enum HostedDiagnosticsHTTPFailureDisposition: Equatable {
    case retryable
    case needsServerUpdate
    case tooLarge
    case staleConsent
    case invalidLocalBundle
}

actor DiagnosticsCoordinator {
    static let shared = DiagnosticsCoordinator()

    nonisolated private static let breadcrumbJournal = BreadcrumbJournal(isEnabled: {
        DiagnosticsCoordinator.breadcrumbCaptureEnabled()
    })
    /// Pre-consent startup breadcrumbs, held in memory only. See
    /// `EarlyBootBuffer` and `applyEarlyBootStaging(...)`.
    nonisolated private static let earlyBootBuffer = EarlyBootBuffer.shared
    nonisolated private static let breadcrumbContextLock = NSLock()
    nonisolated(unsafe) private static var breadcrumbConsentContext: BreadcrumbConsentContext?
    /// The binding whose first-establish consent check passed but whose live
    /// capture gate (`breadcrumbCaptureEnabled()`) has not opened yet, because
    /// child-profile eligibility resolves asynchronously. The staged lines wait
    /// until it opens; any boundary event clears this and drops them. Guarded by
    /// `breadcrumbContextLock`.
    nonisolated(unsafe) private static var earlyBootFlushArmedBinding: DiagnosticsBinding?
    /// Whether this launch's breadcrumb capture decision is *in effect* yet.
    ///
    /// A closed capture gate means two very different things, and the journal
    /// cannot tell them apart on its own: it purges its entire directory on
    /// every refused write (`BreadcrumbJournal.appendRenderedLine`). That purge
    /// is required for a decided refusal — a user who chose "Never" must be
    /// left with no on-disk trail — and destructive before any decision exists,
    /// because the only thing on disk then is the *previous* run's trail, which
    /// is the evidence the tvOS abnormal-exit report is built from.
    ///
    /// Latched the first time this launch observes its decision actually take
    /// effect, which is exactly one of:
    ///
    /// * the first establish refused capture (`applyEarlyBootStaging` produced
    ///   `.discard`) — a real denial, so every refusal from here on must purge;
    /// * a breadcrumb reached the journal, which proves the live gate opened.
    ///
    /// A `.flush` decision deliberately does *not* latch it. Consent said yes,
    /// but child-profile eligibility resolves asynchronously and still holds
    /// the live gate closed, and on the tvOS relaunch path that window contains
    /// `captureAbnormalExit`'s read of the previous run's breadcrumbs — the
    /// exact lines a purge there would destroy.
    ///
    /// Guarded by `breadcrumbContextLock`. Never cleared within a launch: a
    /// later boundary closes the gate, it does not return the launch to its
    /// undecided state.
    nonisolated(unsafe) private static var breadcrumbDecisionInEffect = false
    /// Whether this launch has already spent its one profile-*restoration* pass.
    ///
    /// `activeProfileWillChange` is an account boundary for the staging buffer:
    /// the profile arriving may be a child that must capture nothing at all, so
    /// the launch's pre-consent lines cannot be left available to it. But every
    /// launch with a restored session reaches that same function *before*
    /// authentication resolves — `ContentView.checkInitialState` calls
    /// `AuthService.resolveActiveProfileForSession`, which opens with the
    /// boundary — and no profile is arriving there. Both sides of that call are
    /// the identity this launch is still resolving, so discarding emptied and
    /// sealed the buffer on every authenticated cold launch, which is precisely
    /// the case it exists for.
    ///
    /// Latched by the first `activeProfileWillChange` of the process, so exactly
    /// one call per launch reads as restoration and every later one is a real
    /// switch that still discards. A launch that restores nothing spends the
    /// latch on the user's first sign-in profile selection instead, which is the
    /// same situation by a different route: those staged lines also predate any
    /// account, and `applyEarlyBootStaging`'s first-establish consent check —
    /// not this latch — is what decides whether they may be attributed at all.
    ///
    /// Guarded by `breadcrumbContextLock`. Never cleared within a launch: the
    /// allowance is per launch, not per boundary.
    nonisolated(unsafe) private static var launchProfileRestorationPassSpent = false
    /// Blocks last-known consent fallback between a destination selection and
    /// the first successful status refresh for that destination.
    nonisolated(unsafe) private static var destinationTransitionInProgress = false
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
    /// Memo of the synchronous capture gate. Not a second source of truth: see
    /// `breadcrumbCaptureEnabled()`. Invalidated by every mutation of the state
    /// above, so it never survives a consent, destination, or profile boundary.
    nonisolated private static let captureGateCache = DiagnosticsCaptureGateCache()

    private let api: DiagnosticsAPI
    private let hostedAPI: HostedDiagnosticsAPI
    private let continuumAPI: ContinuumAPI
    private let consentStore: DiagnosticsConsentStore
    private let destinationStore: DiagnosticsDestinationStore
    private let pendingStore: PendingReportStore
    private let bundleBuilder: DiagnosticsBundleBuilder
    private let deviceSnapshotBuilder: DeviceSnapshotBuilder
    private let profileEligibilityStore: DiagnosticsProfileEligibilityStore

    private var cachedStatus: DiagnosticsStatusSnapshot?
    private var cachedStatusDestination: DiagnosticsDestinationChoice?
    private var cachedStatusServerRegistryID: String?
    private var cachedStatusAccessTokenFingerprint: String?
    private var statusRefreshEpoch = DiagnosticsStatusRefreshEpoch()
    /// Credential-owner epoch associated with the exact live hosted status
    /// response. Kept separate from the persisted snapshot because it is
    /// process-local and exists only as a pre-POST race guard.
    private var cachedHostedCredentialIdentity: RefreshAccountIdentity?
    /// Hosted creates can suspend while resolving identity, registering the
    /// installation, and transferring bytes. Keep that interval explicit so a
    /// concurrent user erasure can make the UUID durable without racing a
    /// pre-POST 404 and then allowing the create to resurrect the report.
    private var hostedUploadsInFlight: [UUID: DiagnosticsBinding] = [:]
    /// UUIDs that crossed the collector handoff in this process. This small,
    /// evidence-free receipt closes the opposite ordering: a READY response can
    /// remove the pending directory just before a queued Turn Off action runs.
    /// The receipt lives only for this process and is removed after DELETE is
    /// confirmed; ordinary sent-history semantics remain unchanged.
    private var hostedNetworkCandidates: [UUID: DiagnosticsBinding] = [:]
    private var hostedDeletionMaintenanceTask: Task<Void, Never>?

    init(
        api: DiagnosticsAPI = .shared,
        hostedAPI: HostedDiagnosticsAPI = .shared,
        continuumAPI: ContinuumAPI = .shared,
        consentStore: DiagnosticsConsentStore = .shared,
        destinationStore: DiagnosticsDestinationStore = .shared,
        pendingStore: PendingReportStore = .shared,
        bundleBuilder: DiagnosticsBundleBuilder = DiagnosticsBundleBuilder(),
        deviceSnapshotBuilder: DeviceSnapshotBuilder = .live,
        profileEligibilityStore: DiagnosticsProfileEligibilityStore = .shared
    ) {
        self.api = api
        self.hostedAPI = hostedAPI
        self.continuumAPI = continuumAPI
        self.consentStore = consentStore
        self.destinationStore = destinationStore
        self.pendingStore = pendingStore
        self.bundleBuilder = bundleBuilder
        self.deviceSnapshotBuilder = deviceSnapshotBuilder
        self.profileEligibilityStore = profileEligibilityStore
    }

    func refreshStatus(
        destination: DiagnosticsDestinationChoice? = nil
    ) async throws -> DiagnosticsStatusSnapshot {
        let destination = destination ?? destinationStore.selectedDestination
        let requestGeneration = statusRefreshEpoch.begin(destination: destination)
        if destination == .hosted {
            do {
                return try await refreshHostedStatus(requestGeneration: requestGeneration)
            } catch {
                guard statusRefreshEpoch.isCurrent(requestGeneration, destination: destination) else {
                    throw DiagnosticsCoordinatorError.identityChanged
                }
                if Self.isTransientCaptureFallbackFailure(error),
                   let fallback = await hostedPersistentCaptureFallback() {
                    guard statusRefreshEpoch.isCurrent(requestGeneration, destination: destination) else {
                        throw DiagnosticsCoordinatorError.identityChanged
                    }
                    _ = await activateHostedPersistentCaptureFallback(fallback)
                }
                throw error
            }
        }

        let requestServerRegistryID = ServerRegistry.activeServerIDSnapshot
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
        guard statusRefreshEpoch.isCurrent(requestGeneration, destination: destination),
              requestServerRegistryID == ServerRegistry.activeServerIDSnapshot,
              let accessTokenFingerprint = await Self.currentAccessTokenFingerprint() else {
            throw DiagnosticsCoordinatorError.identityChanged
        }
        guard let accountUserID = user.id, !accountUserID.isEmpty else {
            throw DiagnosticsCoordinatorError.missingAccountUserID
        }
        guard let binding = DiagnosticsBinding.selfHosted(
            serverInstanceID: status.serverInstanceID,
            accountUserID: accountUserID
        ) else {
            throw DiagnosticsCoordinatorError.reservedServerInstanceID
        }
        let snapshot = DiagnosticsStatusSnapshot(status: status, binding: binding)
        cachedStatus = snapshot
        cachedStatusDestination = .selfHosted
        cachedStatusServerRegistryID = requestServerRegistryID
        cachedStatusAccessTokenFingerprint = accessTokenFingerprint
        persistLastKnownSnapshot(
            snapshot,
            serverRegistryID: requestServerRegistryID,
            destination: .selfHosted
        )
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
        if let serverId = ServerRegistry.activeServerIDSnapshot {
            Self.ServerBindingIndex.record(
                serverId: serverId,
                serverInstanceID: status.serverInstanceID
            )
        }
        _ = consentStore.record(for: binding, currentNoticeVersion: status.consentNoticeVersion)
        return snapshot
    }

    private func refreshHostedStatus(
        requestGeneration: UInt64
    ) async throws -> DiagnosticsStatusSnapshot {
        let requestServerRegistryID = ServerRegistry.activeServerIDSnapshot
        guard let requestServerRegistryID,
              let requestCredentialIdentity = await TokenStore.shared.refreshAccountIdentity(),
              requestCredentialIdentity.serverId == requestServerRegistryID,
              await Self.currentAccessTokenFingerprint() != nil else {
            throw DiagnosticsCoordinatorError.identityChanged
        }

        async let capabilitiesRequest = hostedAPI.capabilities()
        async let currentUserRequest = continuumAPI.currentUser()
        let (capabilities, user) = try await (capabilitiesRequest, currentUserRequest)
        guard statusRefreshEpoch.isCurrent(requestGeneration, destination: .hosted),
              requestServerRegistryID == ServerRegistry.activeServerIDSnapshot,
              Self.hostedCredentialIdentityMatches(
                expected: requestCredentialIdentity,
                current: await TokenStore.shared.refreshAccountIdentity(),
                serverRegistryID: requestServerRegistryID
              ),
              let accessTokenFingerprint = await Self.currentAccessTokenFingerprint() else {
            throw DiagnosticsCoordinatorError.identityChanged
        }
        guard let accountUserID = user.id, !accountUserID.isEmpty else {
            throw DiagnosticsCoordinatorError.missingAccountUserID
        }

        let status = capabilities.statusResponse
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: requestServerRegistryID,
            accountUserID: accountUserID
        )
        let snapshot = DiagnosticsStatusSnapshot(status: status, binding: binding)
        cachedStatus = snapshot
        cachedStatusDestination = .hosted
        cachedStatusServerRegistryID = requestServerRegistryID
        cachedStatusAccessTokenFingerprint = accessTokenFingerprint
        cachedHostedCredentialIdentity = requestCredentialIdentity
        persistLastKnownSnapshot(
            snapshot,
            serverRegistryID: requestServerRegistryID,
            destination: .hosted
        )
        updateBreadcrumbConsentContext(
            binding: binding,
            noticeVersion: status.consentNoticeVersion,
            statusAvailable: status.status == .available
        )
        let eligibilityGeneration = Self.beginActiveProfileEligibilityResolution(invalidateCurrent: false)
        Task {
            await reevaluateActiveProfileBreadcrumbEligibility(generation: eligibilityGeneration)
        }

        let record = consentStore.record(
            for: binding,
            currentNoticeVersion: status.consentNoticeVersion
        )
        if record.mode == .always {
            consentStore.setMode(
                .ask,
                for: binding,
                noticeVersion: status.consentNoticeVersion
            )
        }
        return snapshot
    }

    func cachedStatusForActiveServer(
        destination: DiagnosticsDestinationChoice? = nil
    ) async -> DiagnosticsStatusSnapshot? {
        let destination = destination ?? destinationStore.selectedDestination
        guard cachedStatusServerRegistryID == ServerRegistry.activeServerIDSnapshot,
              cachedStatusDestination == destination,
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
    private func lastKnownSnapshotForActiveServer(
        destination: DiagnosticsDestinationChoice
    ) -> DiagnosticsStatusSnapshot? {
        guard let activeServerId = ServerRegistry.activeServerIDSnapshot else {
            return nil
        }
        if cachedStatusServerRegistryID == activeServerId,
           cachedStatusDestination == destination,
           let cachedStatus {
            return cachedStatus
        }
        return Self.LastKnownStatusStore.snapshot(for: activeServerId, destination: destination)
    }

    private func persistLastKnownSnapshot(
        _ snapshot: DiagnosticsStatusSnapshot,
        serverRegistryID: String?,
        destination: DiagnosticsDestinationChoice
    ) {
        guard let serverRegistryID else { return }
        Self.LastKnownStatusStore.record(snapshot, for: serverRegistryID, destination: destination)
        // The capture gate falls back to this store before the first live
        // context of a launch resolves, so a new snapshot is a gate input.
        Self.invalidateCaptureGateCache()
    }

    enum ProfileLookupResult: Equatable {
        case adult
        case child
        case missing
        case unavailable
    }

    static func profileLookupResult(
        profileID: String,
        profiles: [UserProfile]?
    ) -> ProfileLookupResult {
        guard let profiles else { return .unavailable }
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return .missing
        }
        return profile.isChild ? .child : .adult
    }

    /// Resolve the marker/profile separately from transport failure so a
    /// deleted profile can be dropped while an offline lookup remains retryable.
    private func profileLookupResult(_ profileID: String) async -> ProfileLookupResult {
        do {
            return Self.profileLookupResult(
                profileID: profileID,
                profiles: try await AuthService.shared.getProfiles()
            )
        } catch {
            return .unavailable
        }
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
        let serverRegistryID = ServerRegistry.activeServerIDSnapshot
        let lookup = await profileLookupResult(activeProfileID)
        let isChild: Bool?
        switch lookup {
        case .child:
            isChild = true
        case .adult:
            isChild = false
        case .missing, .unavailable:
            isChild = nil
        }
        // A profile/server switch can happen while `/profiles` is in flight.
        // Never publish the result into the new identity's synchronous gate.
        guard activeProfileID == AuthService.shared.profileId,
              serverRegistryID == ServerRegistry.activeServerIDSnapshot,
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
        return await pendingReports(for: context.binding)
    }

    func pendingReports(for binding: DiagnosticsBinding) async -> [PendingReport] {
        let deleting: Set<UUID>
        if binding.destinationChoice == .hosted {
            guard let hostedDeletionIntents = try? pendingStore.hostedDeletionIntents() else {
                // An unreadable erasure ledger may contain an intent/READY
                // marker for any surviving hosted directory. Keep all such
                // evidence quarantined rather than polling or presenting it.
                return []
            }
            deleting = Set(hostedDeletionIntents)
        } else {
            // Hosted erasure bookkeeping does not govern the compatibility
            // path to a user's own Silo server.
            deleting = []
        }
        let reports = pendingStore.listReports(for: binding, now: Date()).filter {
            !deleting.contains($0.id)
        }
        for report in reports where report.binding.binding.destinationChoice == .hosted
            && report.state.hostedRemoteShortID != nil
            && report.state.hostedRejectionCode == nil {
            if case .uploaded(let response) = await pollHostedStatus(report) {
                consentStore.recordSent(
                    shortID: response.shortID,
                    for: report.binding.binding
                )
            }
        }
        return pendingStore.listReports(for: binding, now: Date()).filter {
            !deleting.contains($0.id)
        }
    }

    @discardableResult
    func delete(report: PendingReport) async -> Bool {
        if report.binding.binding.destinationChoice == .selfHosted {
            return pendingStore.delete(report)
        }
        do {
            // Explicit deletion of a hosted report always stages its UUID,
            // including an unsent report and a report whose READY response just
            // removed local evidence. The collector records a bounded
            // preemptive tombstone for a not-yet-created UUID.
            try pendingStore.stageHostedDeletionAndDelete(
                report,
                forceRemoteIntent: true
            )
        } catch {
            return false
        }
        let erased = await deleteHostedReport(report.id)
        if erased {
            scheduleHostedDeletionMaintenance()
        }
        return erased
    }

    /// Implements the user-facing Turn Off and Delete boundary. Potentially
    /// remote hosted reports become durable UUID-only deletion intents before
    /// their local logs are removed; retries need no Silo account/server data.
    /// Self-hosted reports have no collector state, so they are purged directly
    /// and remain independent of hosted erasure-ledger health.
    @discardableResult
    func turnOffAndDelete(binding: DiagnosticsBinding) async -> Bool {
        let erased: Bool
        if binding.destinationChoice == .selfHosted {
            erased = pendingStore.purge(binding: binding)
        } else {
            do {
                let additionalReportIDs = Set(
                    hostedUploadsInFlight.compactMap { reportID, candidateBinding in
                        candidateBinding == binding ? reportID : nil
                    } + hostedNetworkCandidates.compactMap { reportID, candidateBinding in
                        candidateBinding == binding ? reportID : nil
                    }
                )
                try pendingStore.stageHostedDeletionsAndPurge(
                    binding: binding,
                    additionalRemoteReportIDs: additionalReportIDs
                )
                erased = true
            } catch {
                erased = false
            }
        }
        RecentSessionTracker.shared.purge(binding: binding)
        // Also drops the pre-consent staging buffer: it is evidence for this
        // binding that has not been written yet, and flushing it after an
        // erasure would undo the erasure.
        Self.purgeBreadcrumbJournal()
        DiagLog.ring.clear()
        #if os(tvOS)
        ExitSentinel.shared.purge()
        #endif
        guard erased else { return false }
        guard binding.destinationChoice == .hosted else { return true }
        return await drainHostedDeletionIntents(maximumAttempts: 4)
    }

    @discardableResult
    func retryHostedDeletions(maximumAttempts: Int? = nil) async -> Bool {
        await drainHostedDeletionIntents(maximumAttempts: maximumAttempts)
    }

    /// Foreground settings/prompt hydration must not wait behind remote
    /// maintenance. Coalesce triggers and bound each pass; future foregrounds
    /// continue draining the durable queue.
    func scheduleHostedDeletionMaintenance() {
        guard hostedDeletionMaintenanceTask == nil else { return }
        hostedDeletionMaintenanceTask = Task { [weak self] in
            await self?.runHostedDeletionMaintenance()
        }
    }

    private func runHostedDeletionMaintenance() async {
        defer { hostedDeletionMaintenanceTask = nil }
        _ = await drainHostedDeletionIntents(maximumAttempts: 4)
    }

    @discardableResult
    private func drainHostedDeletionIntents(maximumAttempts: Int? = nil) async -> Bool {
        let batch = pendingStore.prepareHostedDeletionRetries()
        var completedAll = !batch.hasBlockedLocalEvidence && !batch.hasCorruptLedger
        let activeUploads = Set(hostedUploadsInFlight.keys)
        if batch.reportIDs.contains(where: activeUploads.contains) {
            completedAll = false
        }
        let readyReportIDs = batch.reportIDs.filter { !activeUploads.contains($0) }
        let attemptCount = maximumAttempts.map { max(0, $0) } ?? readyReportIDs.count
        let attemptedReportIDs = Array(readyReportIDs.prefix(attemptCount))
        if attemptedReportIDs.count < readyReportIDs.count {
            completedAll = false
        }
        for reportID in attemptedReportIDs {
            do {
                try await hostedAPI.deleteReport(reportID: reportID)
                if !pendingStore.completeHostedDeletion(reportID: reportID) {
                    completedAll = false
                } else {
                    hostedNetworkCandidates.removeValue(forKey: reportID)
                }
            } catch {
                completedAll = false
            }
        }
        return completedAll
    }

    private func deleteHostedReport(_ reportID: UUID) async -> Bool {
        guard !hostedUploadsInFlight.keys.contains(reportID),
              (try? pendingStore.hostedDeletionIntents().contains(reportID)) == true else {
            return false
        }
        do {
            try await hostedAPI.deleteReport(reportID: reportID)
            let completed = pendingStore.completeHostedDeletion(reportID: reportID)
            if completed {
                hostedNetworkCandidates.removeValue(forKey: reportID)
            }
            return completed
        } catch {
            return false
        }
    }

    func buildBundle(for report: PendingReport) async throws -> DiagnosticsBundleBuildResult {
        let redactionTokens = Self.mergeRedactionTokens(
            await Self.currentTokenRedactionValues(),
            hostedInstallationToken: await hostedAPI.installationTokenForRedaction()
        )

        // Reports snapshot their logs at capture time. Prefer that frozen
        // evidence so a report sent hours or days later — possibly after using
        // another server or profile — carries capture-time logs and can replay
        // a byte-identical hosted create after an ambiguous response. The live
        // ring fallback remains only for legacy pending manual reports.
        if let snapshotData = try? Data(contentsOf: logSnapshotURL(for: report)),
           let snapshotText = String(data: snapshotData, encoding: .utf8) {
            let lines = snapshotText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            return try bundleBuilder.build(
                report: report,
                logLines: lines,
                droppedLogLines: report.manifest.logSummary.droppedLines,
                redactionTokens: redactionTokens
            )
        }

        let ringSnapshot = DiagLog.ring.snapshot()
        return try bundleBuilder.build(
            report: report,
            logLines: ringSnapshot.lines,
            droppedLogLines: ringSnapshot.droppedCount,
            redactionTokens: redactionTokens
        )
    }

    private nonisolated func logSnapshotURL(for report: PendingReport) -> URL {
        report.directoryURL.appendingPathComponent("logs.jsonl")
    }

    /// Freezes the typed, allowlisted diagnostics ring into a `logs.jsonl`
    /// artifact at abnormal-exit capture time. General OSLog is deliberately
    /// excluded because it has no Diagnostics PII admission boundary.
    func logSnapshotArtifact(since start: Date, runID: String) -> PendingReportArtifact {
        let ringSnapshot = DiagLog.ring.snapshot()
        let lines = Self.logLines(ringSnapshot.lines, forRunID: runID, since: start)
        // The ring is process-local, so an abnormal exit normally has no lines
        // from the failed run after relaunch. Still persist an empty artifact:
        // its presence freezes the failed run's known-empty log set and keeps
        // `buildBundle` from falling back to the relaunch process's live ring.
        let data = lines.isEmpty
            ? Data()
            : Data(lines.joined(separator: "\n").appending("\n").utf8)
        return PendingReportArtifact(relativePath: "logs.jsonl", data: data)
    }

    func createManualReport(
        destination: DiagnosticsDestinationChoice? = nil
    ) async throws -> PendingReport {
        guard let context = await captureContext(
            destination: destination,
            requirePersistentCapture: false
        ) else {
            throw DiagnosticsCoordinatorError.missingCaptureContext
        }

        let capturedAt = Date()
        let device = deviceSnapshotBuilder.build(provenance: .preFailure)
        let manifest = context.makeManifestDraft(
            type: .manual,
            capturedAt: capturedAt,
            crash: nil,
            deviceSummary: deviceSnapshotBuilder.deviceSummary(from: device),
            playbackSessionIDs: context.destinationChoice == .hosted
                ? []
                : RecentSessionTracker.shared.recentSessionIDs(for: context.binding),
            consentMode: .manual
        )
        // A hosted create is idempotent only for the same canonical manifest,
        // bundle length, and SHA. Freeze the manual report's live ring now so
        // an ambiguous upload response can safely replay the same envelope;
        // this also keeps review and send faithful to the evidence captured
        // when the user tapped Send.
        let frozenEvidence = Self.frozenManualEvidence(
            manifest: manifest,
            logSnapshot: DiagLog.ring.snapshot()
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
            manifest: frozenEvidence.manifest,
            deviceSnapshot: device,
            artifacts: [frozenEvidence.artifact]
        ))
    }

    nonisolated static func frozenManualEvidence(
        manifest: DiagnosticsManifestDraft,
        logSnapshot: LogRingSnapshot
    ) -> (manifest: DiagnosticsManifestDraft, artifact: PendingReportArtifact) {
        var frozenManifest = manifest
        frozenManifest.logSummary = DiagnosticsManifest.LogSummary(
            lines: 0,
            bytesGz: 0,
            droppedLines: logSnapshot.droppedCount,
            categories: [],
            debugLogging: manifest.logSummary.debugLogging
        )
        let data = logSnapshot.lines.isEmpty
            ? Data()
            : Data(logSnapshot.lines.joined(separator: "\n").appending("\n").utf8)
        return (
            manifest: frozenManifest,
            artifact: PendingReportArtifact(relativePath: "logs.jsonl", data: data)
        )
    }

    func upload(report: PendingReport) async -> DiagnosticsUploadDecision {
        let destination = report.binding.binding.destinationChoice
        if destination == .hosted, report.state.hostedRemoteShortID == nil {
            guard beginHostedUploadFence(for: report) else {
                return .keptRetryable
            }
            let decision = await performUpload(report: report)
            _ = await endHostedUploadFence(reportID: report.id)
            return decision
        }
        return await performUpload(report: report)
    }

    /// Internal visibility gives the deterministic race tests a real fence to
    /// exercise without adding timing sleeps around URLSession callbacks.
    @discardableResult
    func beginHostedUploadFence(for report: PendingReport) -> Bool {
        guard let deletionIntents = try? pendingStore.hostedDeletionIntents(),
              report.binding.binding.destinationChoice == .hosted,
              report.state.hostedRemoteShortID == nil,
              hostedUploadsInFlight[report.id] == nil,
              !deletionIntents.contains(report.id),
              pendingStore.report(id: report.id) != nil else {
            return false
        }
        hostedUploadsInFlight[report.id] = report.binding.binding
        return true
    }

    /// Marks the exact point after which a collector create may have been
    /// accepted even if the response is lost.
    func markHostedNetworkHandoff(reportID: UUID) {
        guard let binding = hostedUploadsInFlight[reportID] else { return }
        hostedNetworkCandidates[reportID] = binding
    }

    @discardableResult
    func endHostedUploadFence(reportID: UUID) async -> Bool {
        hostedUploadsInFlight.removeValue(forKey: reportID)
        return await drainHostedDeletionIntents(maximumAttempts: 4)
    }

    private func performUpload(report: PendingReport) async -> DiagnosticsUploadDecision {
        let destination = report.binding.binding.destinationChoice
        if destination == .hosted {
            guard let deletionIntents = try? pendingStore.hostedDeletionIntents(),
                  !deletionIntents.contains(report.id) else {
                return .keptRetryable
            }
        }
        if destination == .hosted, report.state.hostedRemoteShortID != nil {
            // Once the collector has durably accepted the bytes, completion no
            // longer depends on a fresh capability or Silo consent request.
            // Poll first so a temporary kill switch, storage outage, or Silo
            // connectivity failure cannot strand a processing report locally.
            hostedNetworkCandidates[report.id] = report.binding.binding
            return await pollHostedStatus(report)
        }
        // A non-persistent capture context is nil only when the status refresh
        // failed (offline or identity mid-change) — the destination was never
        // actually checked. Returning keptDestinationMismatch here would show
        // the wrong message and, on the Always path (already throttled before
        // upload), suppress retries for 24h. Keep it retryable instead; a
        // genuine binding mismatch is still reported below.
        guard let context = await captureContext(
            destination: destination,
            requirePersistentCapture: false
        ) else {
            return .keptRetryable
        }
        guard report.isUploadable(to: context.binding) else {
            return .keptDestinationMismatch
        }
        guard Self.canBeginUpload(status: context.availabilityStatus) else {
            return .keptRetryable
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
        if destination == .selfHosted, Self.isProfileUploadMismatch(
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
        let refreshedMode: ConsentMode
        if report.manifest.consent.mode == .manual {
            refreshedMode = .manual
        } else if destination == .hosted {
            refreshedMode = .prompt
        } else {
            refreshedMode = currentConsent.mode.manifestMode
        }
        if destination == .hosted {
            return await uploadHosted(
                report: report,
                context: context,
                consent: DiagnosticsManifest.Consent(
                    mode: refreshedMode,
                    noticeVersion: currentConsent.noticeVersion
                )
            )
        }

        let report = pendingStore.updatingConsent(
            report,
            mode: refreshedMode,
            noticeVersion: currentConsent.noticeVersion
        )

        do {
            // Snapshot the destination *identity* before building the bundle.
            // Bundle construction and sanitization can take long enough for the
            // active server/account/profile to change underneath us. HTTPClient
            // resolves the current TokenStore at request time,
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
            let destinationServerRegistryID = ServerRegistry.activeServerIDSnapshot
            let destinationProfileID = await TokenStore.shared.getProfileId()
            let capturedProfileID = report.manifest.report.profileID
            let bundle = try await buildBundle(for: report)
            let activeProfileID = await TokenStore.shared.getProfileId()
            guard await Self.currentAccessTokenFingerprint() != nil,
                  ServerRegistry.activeServerIDSnapshot == destinationServerRegistryID,
                  activeProfileID == destinationProfileID,
                  !Self.isProfileUploadMismatch(
                    captured: capturedProfileID,
                    active: activeProfileID
                  ) else {
                return .keptRetryable
            }
            let response: DiagnosticsUploadResponse
            do {
                response = try await api.upload(
                    manifestData: bundle.manifestData,
                    bundleData: bundle.bundleData
                )
            } catch DiagnosticsUploadError.requestBlockedByProxy {
                // A proxy in front of the server capped the request body below
                // the bundle size (nginx defaults to 1 MiB; bundles may be
                // 10 MiB). Retrying the same request can never succeed, so
                // fall back to the chunked upload, whose per-request size
                // stays under such caps.
                response = try await uploadChunkedFallback(report: report, bundle: bundle)
            }
            pendingStore.delete(report)
            return .uploaded(response)
        } catch let error as DiagnosticsUploadError {
            return handleUploadError(error, report: report)
        } catch {
            return .keptRetryable
        }
    }

    private func uploadHosted(
        report: PendingReport,
        context: DiagnosticsCaptureContext,
        consent: DiagnosticsManifest.Consent
    ) async -> DiagnosticsUploadDecision {
        do {
            let destinationServerRegistryID = ServerRegistry.activeServerIDSnapshot
            guard let destinationCredentialIdentity = context.hostedCredentialIdentity,
                  Self.hostedCredentialIdentityMatches(
                    expected: destinationCredentialIdentity,
                    current: await TokenStore.shared.refreshAccountIdentity(),
                    serverRegistryID: destinationServerRegistryID
                  ) else {
                return .keptRetryable
            }
            // Capture the limit from the exact capability snapshot that made
            // this context. `buildBundle` awaits Keychain access and permits
            // actor reentrancy; consulting the coordinator-wide cache after it
            // returns could accidentally observe a concurrent self-hosted or
            // different-account refresh.
            let maximumBundleBytes = context.maxBundleBytes
                ?? HostedDiagnosticsCapabilities.conservativeCaptureStatus.maxBundleBytes
            let maximumManifestBytes = context.maxManifestBytes
                ?? HostedDiagnosticsCapabilities.conservativeCaptureStatus.maxManifestBytes
            let bundle: DiagnosticsBundleBuildResult
            let mustPersistEnvelope: Bool
            switch pendingStore.loadHostedEnvelope(for: report) {
            case .quarantined:
                return .keptRetryable
            case .corrupt:
                pendingStore.markHostedRejected(report, code: "invalid_hosted_envelope")
                return .keptRejected(code: "invalid_hosted_envelope")
            case .available(let cached):
                if report.state.hostedConsentRefreshRequired {
                    bundle = try bundleBuilder.reframeHosted(cached: cached, consent: consent)
                    mustPersistEnvelope = true
                } else {
                    // Policy and credential rotation cannot change an already
                    // committed create envelope after an ambiguous response.
                    bundle = cached
                    mustPersistEnvelope = false
                }
            case .missing:
                let framedReport = pendingStore.updatingConsent(
                    report,
                    mode: consent.mode,
                    noticeVersion: consent.noticeVersion
                )
                bundle = try await buildBundle(for: framedReport)
                mustPersistEnvelope = true
            }
            guard bundle.manifest.report.profileID == nil,
                  bundle.manifest.playbackSessionIds.isEmpty,
                  bundle.manifest.destination.serverInstanceID == context.destinationServerInstanceID,
                  await Self.currentAccessTokenFingerprint() != nil,
                  Self.hostedCredentialIdentityMatches(
                    expected: destinationCredentialIdentity,
                    current: await TokenStore.shared.refreshAccountIdentity(),
                    serverRegistryID: ServerRegistry.activeServerIDSnapshot
                  ) else {
                return .keptRetryable
            }
            // An unchanged committed envelope may already exist remotely after
            // an ambiguous POST. Its exact retry must reach the collector's
            // acceptance-time idempotency path even if a later policy lowers
            // the advertised limit. New or explicitly reframed envelopes use
            // the current live bound.
            guard !mustPersistEnvelope || Self.hostedEnvelopeFitsAdvertisedLimits(
                bundleBytes: bundle.bundleData.count,
                manifestBytes: bundle.manifestData.count,
                maximumBundleBytes: maximumBundleBytes,
                maximumManifestBytes: maximumManifestBytes
            ) else {
                pendingStore.markTooLarge(report)
                return .keptTooLarge
            }
            if mustPersistEnvelope {
                // The collector create request is allowed only after the exact
                // sanitized envelope is durable and replayable across a crash.
                try pendingStore.saveHostedEnvelope(bundle, for: report)
            }

            // Persisting a new envelope performs several synchronous file
            // writes. TokenStore is a separate actor, so a same-server account
            // replacement can complete concurrently even while this
            // coordinator is occupied by those writes. Revalidate at the
            // literal network handoff boundary; otherwise the durable
            // account-A envelope could still be POSTed after account B takes
            // ownership of the active credentials.
            guard Self.hostedCredentialIdentityMatches(
                expected: destinationCredentialIdentity,
                current: await TokenStore.shared.refreshAccountIdentity(),
                serverRegistryID: ServerRegistry.activeServerIDSnapshot
            ) else {
                return .keptRetryable
            }

            // The credential lookup above is the final suspension before the
            // POST. Re-check consent, erasure, and local ownership
            // synchronously after it so Turn Off/Delete cannot slip between
            // this gate and the network handoff.
            let currentConsent = consentStore.record(
                for: report.binding.binding,
                currentNoticeVersion: context.noticeVersion
            )
            guard let deletionIntents = try? pendingStore.hostedDeletionIntents(),
                  currentConsent.mode != .never,
                  !deletionIntents.contains(report.id),
                  pendingStore.report(id: report.id) != nil else {
                return .keptRetryable
            }

            markHostedNetworkHandoff(reportID: report.id)
            let response = try await hostedAPI.upload(
                reportID: report.id,
                manifest: bundle.manifest,
                bundleData: bundle.bundleData
            )
            if response.state == .ready {
                // If local READY bookkeeping cannot be committed, retain an
                // awaiting-status marker so the accepted report is never
                // presented for consent or uploaded again.
                pendingStore.markHostedProcessing(report, shortID: response.shortID)
                try? pendingStore.recordHostedReadyAndDelete(report)
                return .uploaded(response)
            }
            pendingStore.markHostedProcessing(report, shortID: response.shortID)
            return .keptProcessing(shortID: response.shortID)
        } catch let error as HostedDiagnosticsAPIError {
            return handleHostedUploadError(error, report: report)
        } catch {
            return .keptRetryable
        }
    }

    func handleHostedUploadError(
        _ error: HostedDiagnosticsAPIError,
        report: PendingReport
    ) -> DiagnosticsUploadDecision {
        switch error {
        case .reportIdentityMismatch:
            pendingStore.markHostedRejected(report, code: "report_identity_mismatch")
            return .keptRejected(code: "report_identity_mismatch")
        case .rejected(let code):
            pendingStore.markHostedRejected(report, code: code)
            return .keptRejected(code: code)
        case .http(let statusCode, let code):
            return handleHostedHTTPFailure(
                statusCode: statusCode,
                code: code,
                report: report
            )
        case .invalidBaseURL, .invalidResponse, .collectorIdentityMismatch,
             .credentialPersistenceFailed, .remoteReportIdentityMismatch, .underlying:
            return .keptRetryable
        }
    }

    private func pollHostedStatus(_ report: PendingReport) async -> DiagnosticsUploadDecision {
        guard let expectedShortID = report.state.hostedRemoteShortID else {
            return .keptRetryable
        }
        // A READY response removes the pending directory. Retain the UUID-only
        // ownership candidate before suspending so a queued Turn Off action can
        // still erase the remote report whichever actor continuation wins.
        hostedNetworkCandidates[report.id] = report.binding.binding
        do {
            let status = try await hostedAPI.reportStatus(reportID: report.id)
            guard status.shortID == expectedShortID else {
                pendingStore.markHostedRejected(report, code: "invalid_response")
                return .keptRejected(code: "invalid_response")
            }
            switch status.state {
            case .ready:
                let response = DiagnosticsUploadResponse(
                    reportId: status.reportID,
                    shortId: status.shortID,
                    state: .ready
                )
                try? pendingStore.recordHostedReadyAndDelete(report)
                return .uploaded(response)
            case .processing:
                return .keptProcessing(shortID: expectedShortID)
            case .rejected, .deleting, .deleted:
                pendingStore.markHostedRejected(report, code: status.errorCode ?? status.state.rawValue)
                return .keptRejected(code: status.errorCode ?? status.state.rawValue)
            case .receiving, .uploaded:
                return .keptRetryable
            }
        } catch {
            return .keptRetryable
        }
    }

    private func handleHostedHTTPFailure(
        statusCode: Int,
        code: String?,
        report: PendingReport
    ) -> DiagnosticsUploadDecision {
        switch Self.hostedHTTPFailureDisposition(statusCode: statusCode, code: code) {
        case .retryable:
            return .keptRetryable
        case .needsServerUpdate:
            pendingStore.markNeedsServerUpdate(report)
            return .keptNeedsServerUpdate
        case .tooLarge:
            pendingStore.markTooLarge(report)
            return .keptTooLarge
        case .staleConsent:
            pendingStore.markHostedConsentRefreshRequired(report)
            consentStore.setMode(
                .ask,
                for: report.binding.binding,
                noticeVersion: report.manifest.consent.noticeVersion
            )
            return .keptStaleConsent
        case .invalidLocalBundle:
            let rejectionCode = code?.isEmpty == false ? code : "invalid_hosted_envelope"
            pendingStore.markHostedRejected(report, code: rejectionCode)
            return .keptRejected(code: rejectionCode)
        }
    }

    nonisolated static func hostedHTTPFailureDisposition(
        statusCode: Int,
        code: String?
    ) -> HostedDiagnosticsHTTPFailureDisposition {
        // Rate limiting, service failures, and transport failures retain the
        // local report even if a malformed intermediary happens to attach an
        // otherwise permanent code.
        if statusCode == 429 || (500...599).contains(statusCode) {
            return .retryable
        }
        if statusCode == 413
            || code == "too_large"
            || code == "bundle_too_large"
            || code == "compression_ratio_exceeded" {
            return .tooLarge
        }
        switch code {
        case "unsupported_schema":
            return .needsServerUpdate
        case "stale_consent":
            return .staleConsent
        case "invalid_request", "unexpected_field", "invalid_report_id",
             "invalid_bundle_size", "invalid_bundle_sha256", "invalid_manifest",
             "privacy_field_rejected", "privacy_value_rejected", "wrong_destination",
             "archive_metadata_mismatch", "report_conflict", "unsupported_media_type",
             "size_mismatch", "archive_mismatch", "invalid_bundle",
             "sensitive_header_rejected", "content_length_required",
             "invalid_content_length", "invalid_json", "invalid_platform",
             "hosted_consent_required", "privacy_artifact_rejected",
             "upload_attempt_limit_exceeded":
            return .invalidLocalBundle
        default:
            return .retryable
        }
    }

    /// Chunked-upload fallback for a single-shot upload the fronting proxy
    /// refused. Throws `DiagnosticsUploadError` for the caller's shared
    /// error mapping.
    private func uploadChunkedFallback(
        report: PendingReport,
        bundle: DiagnosticsBundleBuildResult
    ) async throws -> DiagnosticsUploadResponse {
        // Chunking needs server support (upload_chunk_bytes in status). An
        // older server behind a capping proxy can't take this bundle by any
        // route until it updates — the same terminal state as an unsupported
        // schema, so reuse that classification (kept, visible, manually
        // retryable after the deployment is fixed; never auto-retried).
        guard cachedStatus?.status.supportsChunkedUpload == true else {
            throw DiagnosticsUploadError.unsupportedSchema
        }
        // Pin the destination identity for the whole multi-request sequence.
        // HTTPClient resolves the active server URL and auth per request, so
        // without this a server/account/profile switch between chunk PUTs
        // would send the remaining bundle bytes to the newly active
        // destination. Same stable identity as the single-shot pre-POST check:
        // server registry id + profile, token presence only (a transparent
        // token refresh mid-upload must not abort the sequence).
        let destinationServerRegistryID = ServerRegistry.activeServerIDSnapshot
        let destinationProfileID = await TokenStore.shared.getProfileId()
        do {
            return try await api.uploadChunked(
                manifestData: bundle.manifestData,
                bundleData: bundle.bundleData,
                destinationUnchanged: {
                    guard await Self.currentAccessTokenFingerprint() != nil else { return false }
                    guard ServerRegistry.activeServerIDSnapshot == destinationServerRegistryID else { return false }
                    let activeProfileID = await TokenStore.shared.getProfileId()
                    return activeProfileID == destinationProfileID
                }
            )
        } catch DiagnosticsUploadError.requestBlockedByProxy {
            // Even individual chunk-sized requests are blocked: the proxy cap
            // is below the chunk size. No retry of this fixed payload can
            // succeed — the same permanence as a server-side size rejection.
            throw DiagnosticsUploadError.tooLarge
        }
    }

    func captureContext(
        applicationVersionOverride: String? = nil,
        destination: DiagnosticsDestinationChoice? = nil,
        requirePersistentCapture: Bool = true
    ) async -> DiagnosticsCaptureContext? {
        let destination = destination ?? destinationStore.selectedDestination
        let snapshot: DiagnosticsStatusSnapshot
        let usedLastKnownSnapshot: Bool
        let usedHostedFallback: Bool
        let hostedCredentialIdentity: RefreshAccountIdentity?
        do {
            snapshot = try await refreshStatus(destination: destination)
            usedLastKnownSnapshot = false
            usedHostedFallback = false
            hostedCredentialIdentity = destination == .hosted
                ? cachedHostedCredentialIdentity
                : nil
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
            guard Self.isTransientCaptureFallbackFailure(error), requirePersistentCapture else {
                return nil
            }
            if destination == .hosted {
                guard let fallback = await hostedPersistentCaptureFallback() else {
                    return nil
                }
                snapshot = fallback.snapshot
                usedLastKnownSnapshot = fallback.requiresCachedProfileEligibility
                usedHostedFallback = true
                hostedCredentialIdentity = nil
            } else {
                guard let fallback = lastKnownSnapshotForActiveServer(destination: destination) else {
                    return nil
                }
                snapshot = fallback
                usedLastKnownSnapshot = true
                usedHostedFallback = false
                hostedCredentialIdentity = nil
            }
        }

        let record = consentStore.record(
            for: snapshot.binding,
            currentNoticeVersion: snapshot.status.consentNoticeVersion
        )
        if requirePersistentCapture {
            if usedHostedFallback {
                let fallback = HostedPersistentCaptureFallback(
                    snapshot: snapshot,
                    requiresCachedProfileEligibility: usedLastKnownSnapshot
                )
                guard await activateHostedPersistentCaptureFallback(fallback) else {
                    return nil
                }
            } else {
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
        }

        let manifestConsentMode: ConsentMode = destination == .hosted && record.mode == .always
            ? .prompt
            : record.mode.manifestMode
        return DiagnosticsCaptureContext(
            binding: snapshot.binding,
            profileID: destination == .hosted ? nil : AuthService.shared.profileId,
            consentMode: manifestConsentMode,
            noticeVersion: snapshot.status.consentNoticeVersion,
            appVersion: applicationVersionOverride?.isEmpty == false ? applicationVersionOverride! : Self.appVersion(),
            appBuild: Self.appBuild(),
            platform: Self.platform(),
            osVersion: Self.osVersion(),
            destinationServerInstanceID: snapshot.status.serverInstanceID,
            maxBundleBytes: snapshot.status.maxBundleBytes,
            maxManifestBytes: snapshot.status.maxManifestBytes,
            availabilityStatus: snapshot.status.status,
            hostedCredentialIdentity: hostedCredentialIdentity
        )
    }

    nonisolated static func canBeginUpload(status: DiagnosticsAvailabilityStatus) -> Bool {
        status == .available
    }

    nonisolated static func hostedEnvelopeFitsAdvertisedLimits(
        bundleBytes: Int,
        manifestBytes: Int,
        maximumBundleBytes: Int,
        maximumManifestBytes: Int
    ) -> Bool {
        bundleBytes <= maximumBundleBytes && manifestBytes <= maximumManifestBytes
    }

    /// A hosted binding is valid only while the exact credential owner that
    /// produced `/currentUser` remains active. The generation intentionally
    /// survives transparent access-token refresh, but changes on login,
    /// sign-out, or credential retargeting — including a replacement account
    /// on the same server URL.
    nonisolated static func hostedCredentialIdentityMatches(
        expected: RefreshAccountIdentity,
        current: RefreshAccountIdentity?,
        serverRegistryID: String?
    ) -> Bool {
        expected.serverId == serverRegistryID && current == expected
    }

    private struct HostedPersistentCaptureFallback {
        let snapshot: DiagnosticsStatusSnapshot
        let requiresCachedProfileEligibility: Bool
    }

    /// Hosted crash evidence is captured locally under Ask consent even when
    /// the public collector is temporarily unreachable. Prefer a prior live
    /// capability result, but the collector identity and v1 limits are pinned
    /// in the app so a first-run capture can safely use conservative defaults.
    /// Sending still calls `refreshHostedStatus()` and therefore requires a
    /// live capability response with the exact pinned collector identity.
    private func hostedPersistentCaptureFallback() async -> HostedPersistentCaptureFallback? {
        guard let requestCredentialIdentity = await TokenStore.shared.refreshAccountIdentity(),
              await Self.currentAccessTokenFingerprint() != nil else {
            return nil
        }
        let serverRegistryID = requestCredentialIdentity.serverId

        if let user = try? await continuumAPI.currentUser(),
           Self.hostedCredentialIdentityMatches(
               expected: requestCredentialIdentity,
               current: await TokenStore.shared.refreshAccountIdentity(),
               serverRegistryID: ServerRegistry.activeServerIDSnapshot
           ),
           let accessTokenFingerprint = await Self.currentAccessTokenFingerprint(),
           let accountUserID = user.id,
           !accountUserID.isEmpty {
            let snapshot = Self.hostedPersistentCaptureFallbackSnapshot(
                serverRegistryID: serverRegistryID,
                accountUserID: accountUserID,
                previous: lastKnownSnapshotForActiveServer(destination: .hosted)
            )
            cacheHostedFallback(
                snapshot,
                serverRegistryID: serverRegistryID,
                accessTokenFingerprint: accessTokenFingerprint
            )
            return HostedPersistentCaptureFallback(
                snapshot: snapshot,
                requiresCachedProfileEligibility: false
            )
        }

        guard Self.hostedCredentialIdentityMatches(
            expected: requestCredentialIdentity,
            current: await TokenStore.shared.refreshAccountIdentity(),
            serverRegistryID: ServerRegistry.activeServerIDSnapshot
        ), await Self.currentAccessTokenFingerprint() != nil,
              let previous = lastKnownSnapshotForActiveServer(destination: .hosted) else {
            return nil
        }
        return HostedPersistentCaptureFallback(
            snapshot: previous,
            requiresCachedProfileEligibility: true
        )
    }

    private func activateHostedPersistentCaptureFallback(
        _ fallback: HostedPersistentCaptureFallback
    ) async -> Bool {
        let snapshot = fallback.snapshot
        let generation = Self.beginActiveProfileEligibilityResolution(invalidateCurrent: true)
        updateBreadcrumbConsentContext(
            binding: snapshot.binding,
            noticeVersion: snapshot.status.consentNoticeVersion,
            statusAvailable: snapshot.status.status == .available
        )
        let record = consentStore.record(
            for: snapshot.binding,
            currentNoticeVersion: snapshot.status.consentNoticeVersion
        )
        guard snapshot.status.status == .available, record.mode != .never else {
            _ = Self.publishActiveProfileBreadcrumbEligibility(false, generation: generation)
            return false
        }

        let isChild = fallback.requiresCachedProfileEligibility
            ? cachedActiveProfileIsChild(binding: snapshot.binding)
            : await activeProfileIsChild(binding: snapshot.binding)
        let eligible = isChild == false
        _ = Self.publishActiveProfileBreadcrumbEligibility(eligible, generation: generation)
        #if os(tvOS)
        if eligible {
            ExitSentinel.shared.profileEligibilityDidResolve(
                binding: snapshot.binding,
                profileID: AuthService.shared.profileId
            )
        }
        #endif
        return eligible
    }

    nonisolated static func hostedPersistentCaptureFallbackSnapshot(
        serverRegistryID: String,
        accountUserID: String,
        previous: DiagnosticsStatusSnapshot?
    ) -> DiagnosticsStatusSnapshot {
        let binding = DiagnosticsBinding.hosted(
            serverRegistryID: serverRegistryID,
            accountUserID: accountUserID
        )
        if let previous, previous.binding == binding {
            return previous
        }
        return DiagnosticsStatusSnapshot(
            status: HostedDiagnosticsCapabilities.conservativeCaptureStatus,
            binding: binding
        )
    }

    private func cacheHostedFallback(
        _ snapshot: DiagnosticsStatusSnapshot,
        serverRegistryID: String,
        accessTokenFingerprint: String
    ) {
        cachedStatus = snapshot
        cachedStatusDestination = .hosted
        cachedStatusServerRegistryID = serverRegistryID
        cachedStatusAccessTokenFingerprint = accessTokenFingerprint
        persistLastKnownSnapshot(
            snapshot,
            serverRegistryID: serverRegistryID,
            destination: .hosted
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
            await purgeDiagnostics(for: binding)
        }
        Self.purgeBreadcrumbJournal()
        return binding != nil
    }

    func purgeDiagnosticsForServerRegistryID(_ serverId: String) async {
        let hostedServerInstanceID = DiagnosticsBinding.hosted(
            serverRegistryID: serverId,
            accountUserID: "local-purge"
        ).serverInstanceID
        let additionalReportIDs = Set(
            hostedUploadsInFlight.compactMap { reportID, binding in
                binding.serverInstanceID == hostedServerInstanceID ? reportID : nil
            } + hostedNetworkCandidates.compactMap { reportID, binding in
                binding.serverInstanceID == hostedServerInstanceID ? reportID : nil
            }
        )
        try? pendingStore.stageHostedDeletionsAndPurge(
            serverInstanceID: hostedServerInstanceID,
            additionalRemoteReportIDs: additionalReportIDs
        )
        consentStore.remove(serverInstanceID: hostedServerInstanceID)
        profileEligibilityStore.remove(serverInstanceID: hostedServerInstanceID)
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
        _ = await drainHostedDeletionIntents()
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
            switch await profileLookupResult(markerProfileID) {
            case .child, .missing:
                return true
            case .unavailable:
                return false
            case .adult:
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
            playbackSessionIDs: boundContext.destinationChoice == .hosted
                ? []
                : RecentSessionTracker.shared.recentSessionIDs(for: boundContext.binding),
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
        artifacts.append(logSnapshotArtifact(since: marker.startedAtDate, runID: marker.runID))

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

    /// Returns whether the breadcrumb reached the journal. A `false` result
    /// before the launch's consent context resolves means the line was staged
    /// in memory instead (see `EarlyBootBuffer`); it reaches disk only if the
    /// first consent establish of this launch permits it.
    ///
    /// The journal is deliberately not consulted before that decision is in
    /// effect. Its refusal path is destructive — `appendRenderedLine` purges
    /// the whole breadcrumb directory when `isEnabled()` is false — and on a
    /// cold launch the only thing in that directory is the *previous* run's
    /// trail, which is what the tvOS abnormal-exit report is made of. Asking it
    /// "may I write?" during the pre-consent window therefore destroys the
    /// evidence before anyone reads it, and the launch breadcrumbs this
    /// subsystem emits from `SiloApp.init` onward hit that window on every
    /// cold launch. So the routing decision is made here instead:
    ///
    /// * decision not in effect -> stage in memory, leave the journal alone
    /// * decision in effect, allow -> journal writes
    /// * decision in effect, deny -> journal refuses *and purges*, as intended
    @discardableResult
    nonisolated static func recordBreadcrumb(
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date()
    ) -> Bool {
        // Hoisted ahead of the routing below. The journal asserts on a
        // non-breadcrumb category, and that contract check must not become
        // conditional on the launch's consent state: a miscategorized call site
        // would otherwise trip the assertion only on launches that happened to
        // get far enough to address the journal.
        guard category == .lifecycle || category == .playback || category == .focus else {
            #if DEBUG
            assertionFailure("Breadcrumb category must be lifecycle, playback, or focus")
            #endif
            return false
        }
        if !breadcrumbDecisionIsInEffect {
            guard breadcrumbCaptureEnabled() else {
                // Pre-decision and the gate is closed: the expected pre-auth
                // state, not a denial. `EarlyBootBuffer` seals itself the
                // moment the launch's decision is made, so a line arriving
                // after that is dropped here rather than re-staged.
                earlyBootBuffer.record(
                    level: level,
                    category: category,
                    tag: tag,
                    message: message,
                    attrs: attrs,
                    timestamp: timestamp
                )
                return false
            }
            // The live gate is open, so this launch's decision is allow and is
            // now observable. Latch it: the append below writes rather than
            // purges, and any later refusal is a real revocation whose purge
            // is the point.
            markBreadcrumbDecisionInEffect()
        }
        return breadcrumbJournal.append(
            level: level,
            category: category,
            tag: tag,
            message: message,
            attrs: attrs,
            timestamp: timestamp
        )
    }

    /// See `breadcrumbDecisionInEffect`. Read on every breadcrumb, so it is a
    /// bare flag read under the existing lock rather than anything derived.
    nonisolated private static var breadcrumbDecisionIsInEffect: Bool {
        breadcrumbContextLock.lock()
        defer { breadcrumbContextLock.unlock() }
        return breadcrumbDecisionInEffect
    }

    /// Latch the launch's capture decision as observable. Never call while
    /// holding `breadcrumbContextLock` — it is a plain `NSLock`.
    nonisolated private static func markBreadcrumbDecisionInEffect() {
        breadcrumbContextLock.lock()
        breadcrumbDecisionInEffect = true
        breadcrumbContextLock.unlock()
    }

    /// Claim this launch's single profile-restoration allowance, returning
    /// whether this caller got it. Read-and-latch in one locked section: two
    /// profile boundaries racing must not both come away believing they are the
    /// restoration pass, because the second one is a real switch.
    ///
    /// See `launchProfileRestorationPassSpent`. Never call while holding
    /// `breadcrumbContextLock` — it is a plain `NSLock`.
    nonisolated private static func claimLaunchProfileRestorationPass() -> Bool {
        breadcrumbContextLock.lock()
        let claimed = !launchProfileRestorationPassSpent
        launchProfileRestorationPassSpent = true
        breadcrumbContextLock.unlock()
        return claimed
    }

    /// What the pre-consent staging buffer's lines are worth once the
    /// diagnostics consent context moves.
    enum EarlyBootStagingDecision: Equatable {
        /// First establish of this launch and consent permits capture: the
        /// staged lines may be written for this binding.
        case flush
        /// Consent refuses, or an account/server boundary was crossed: drop
        /// the staged lines without ever writing them.
        case discard
        /// Nothing to decide (a plain refresh of the same binding). The buffer
        /// sealed on the first establish, so it already holds nothing.
        case ignore
    }

    /// Pure decision shared by the live path and tests.
    ///
    /// - `previousBinding == nil`: the first establish of this launch. The
    ///   staged lines were emitted before any account existed, so this is the
    ///   only moment they can legitimately be attributed — and only if the same
    ///   consent check the journal enforces passes for the resolved context.
    /// - `previousBinding != nil && != binding`: an account/server switch
    ///   mid-launch. The staged lines belong to the launch, not to the account
    ///   arriving now; this path already purges the journal and clears the ring
    ///   for exactly that reason.
    nonisolated static func earlyBootStagingDecision(
        previousBinding: DiagnosticsBinding?,
        binding: DiagnosticsBinding,
        noticeVersion: Int,
        statusAvailable: Bool,
        consentStore: DiagnosticsConsentStore = .shared
    ) -> EarlyBootStagingDecision {
        guard previousBinding == nil else {
            return previousBinding == binding ? .ignore : .discard
        }
        let allowed = breadcrumbCaptureEnabled(
            for: BreadcrumbConsentContext(
                binding: binding,
                noticeVersion: noticeVersion,
                isAvailable: statusAvailable
            ),
            consentStore: consentStore
        )
        return allowed ? .flush : .discard
    }

    /// Apply the decision to the process-wide buffer.
    ///
    /// A `.flush` only *arms* the flush rather than writing immediately: the
    /// live gate also depends on child-profile eligibility, which resolves
    /// asynchronously and is still closed here on a cold launch. The armed
    /// flush is attempted now and again when eligibility publishes, and always
    /// goes through `breadcrumbJournal.append`, so the enabled-gate is enforced
    /// at write time rather than duplicated.
    nonisolated private static func applyEarlyBootStaging(
        previousBinding: DiagnosticsBinding?,
        binding: DiagnosticsBinding,
        noticeVersion: Int,
        statusAvailable: Bool
    ) {
        switch earlyBootStagingDecision(
            previousBinding: previousBinding,
            binding: binding,
            noticeVersion: noticeVersion,
            statusAvailable: statusAvailable
        ) {
        case .ignore:
            return
        case .discard:
            // The launch's decision is "no capture" — a Never account, an
            // unavailable server, or an account boundary — so the on-disk trail
            // goes with the staged lines.
            //
            // This purge is not new behavior, it is the same clearing relocated
            // to the decision. It used to happen incidentally: the next
            // breadcrumb of the launch would be offered to the journal, refused,
            // and `appendRenderedLine` would purge as a side effect.
            // `recordBreadcrumb` no longer routes pre-decision lines through
            // that path (it would destroy the previous run's evidence on every
            // cold launch), so the clearing is stated here instead of depending
            // on a later breadcrumb arriving at all.
            //
            // Latch before purging: a breadcrumb racing this must address the
            // journal — be refused, and purge — rather than quietly re-stage in
            // memory behind the decision that just refused it.
            markBreadcrumbDecisionInEffect()
            purgeBreadcrumbJournal()
        case .flush:
            breadcrumbContextLock.lock()
            earlyBootFlushArmedBinding = binding
            breadcrumbContextLock.unlock()
            flushEarlyBootBufferIfArmed()
        }
    }

    /// Write the staged lines once the live capture gate is actually open for
    /// the binding the flush was armed for. Called on the first establish and
    /// again whenever profile eligibility publishes; a no-op until both agree.
    nonisolated static func flushEarlyBootBufferIfArmed() {
        breadcrumbContextLock.lock()
        let armedBinding = earlyBootFlushArmedBinding
        breadcrumbContextLock.unlock()
        // Take no lock across these calls: both resolve the consent context and
        // the eligibility flag, which use `breadcrumbContextLock` themselves.
        guard let armedBinding,
              armedBinding == currentBreadcrumbBinding(),
              breadcrumbCaptureEnabled() else {
            return
        }
        breadcrumbContextLock.lock()
        earlyBootFlushArmedBinding = nil
        breadcrumbContextLock.unlock()
        // The gate was observed open for the armed binding, so this launch's
        // decision is allow and is now in effect: later breadcrumbs address the
        // journal directly, and a refusal from here on is a genuine revocation
        // whose purge is intended.
        markBreadcrumbDecisionInEffect()
        flushEarlyBootBuffer(earlyBootBuffer, into: breadcrumbJournal)
    }

    /// Drain `buffer` into `journal`, returning how many lines the journal
    /// accepted. Exposed with explicit collaborators so tests can exercise the
    /// flush against a temp-directory journal instead of the process one.
    ///
    /// Nothing here decides whether the write is allowed: every line goes
    /// through `BreadcrumbJournal.append`, which re-checks `isEnabled()` under
    /// its own lock. A consent change landing between the arming check and this
    /// call still wins, and a journal whose gate is closed writes nothing and
    /// purges instead.
    @discardableResult
    nonisolated static func flushEarlyBootBuffer(
        _ buffer: EarlyBootBuffer,
        into journal: BreadcrumbJournal
    ) -> Int {
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        var written = 0
        for rendered in buffer.drain() {
            guard let line = try? decoder.decode(DiagnosticsLogLine.self, from: Data(rendered.utf8)) else {
                continue
            }
            if journal.append(line) {
                written += 1
            }
        }
        return written
    }

    /// Drop the staged pre-consent lines and disarm any pending flush. Called
    /// from every path that purges the journal for account isolation.
    nonisolated static func discardEarlyBootBuffer() {
        breadcrumbContextLock.lock()
        earlyBootFlushArmedBinding = nil
        breadcrumbContextLock.unlock()
        earlyBootBuffer.discard()
    }

    /// Rotate away the on-disk breadcrumb trail. Every caller does this for
    /// account isolation or user-requested erasure, so the pre-consent staging
    /// buffer — unwritten evidence of the same launch — is dropped alongside
    /// it. Folding the discard in here rather than at each call site also
    /// covers the "Never" path, which reaches this from the consent store.
    nonisolated static func purgeBreadcrumbJournal() {
        breadcrumbJournal.purge()
        discardEarlyBootBuffer()
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
    /// marker is consumed on the next launch, when the process-local ring can
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

    private func purgeDiagnostics(for binding: DiagnosticsBinding) async {
        _ = await turnOffAndDelete(binding: binding)
        consentStore.remove(binding: binding)
        clearContext(for: binding)
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
            cachedStatusDestination = nil
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
        case .requestBlockedByProxy:
            // Normally consumed by the chunked-upload fallback before reaching
            // here; if it does surface (fallback path itself unavailable),
            // the report is kept — a proxy config fix makes it sendable again.
            return .keptRetryable
        case .disabled, .storageUnavailable, .quotaExceeded, .busy, .retryable, .underlying:
            return .keptRetryable
        }
    }

    private static func appVersion() -> String {
        AppleDeviceIdentity.bundleAppVersion
    }

    private static func appBuild() -> String {
        AppleDeviceIdentity.bundleAppBuild
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
            await TokenStore.shared.getRefreshToken(),
        ]
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value, !value.isEmpty, seen.insert(value).inserted else {
                return nil
            }
            return value
        }
    }

    nonisolated static func mergeRedactionTokens(
        _ existing: [String],
        hostedInstallationToken: String?
    ) -> [String] {
        var seen = Set<String>()
        var merged = existing.filter { !$0.isEmpty && seen.insert($0).inserted }
        if let hostedInstallationToken,
           !hostedInstallationToken.isEmpty,
           seen.insert(hostedInstallationToken).inserted {
            merged.append(hostedInstallationToken)
        }
        return merged
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
        if let hostedError = error as? HostedDiagnosticsAPIError {
            switch hostedError {
            case .underlying, .invalidResponse:
                return true
            case .http(let statusCode, _):
                return statusCode == 429 || (500...599).contains(statusCode)
            case .invalidBaseURL, .collectorIdentityMismatch,
                 .credentialPersistenceFailed, .reportIdentityMismatch,
                 .remoteReportIdentityMismatch, .rejected:
                return false
            }
        }
        if let httpError = error as? HTTPError {
            switch httpError {
            case .network:
                return true
            case .http(let statusCode, _):
                return (500...599).contains(statusCode)
            case .serverUrlNotConfigured, .invalidURL, .invalidResponse,
                 .requestIdentityChanged, .encodingFailed, .decodingFailed:
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
        // A request for the previous destination may finish after the picker
        // persisted a new choice. It may refresh its own cache, but it must not
        // reopen the synchronous capture gate for that stale destination.
        guard binding.destinationChoice == destinationStore.selectedDestination else {
            return
        }
        Self.breadcrumbContextLock.lock()
        let previousBinding = Self.breadcrumbConsentContext?.binding
        Self.destinationTransitionInProgress = false
        Self.breadcrumbConsentContext = BreadcrumbConsentContext(
            binding: binding,
            noticeVersion: noticeVersion,
            isAvailable: statusAvailable
        )
        Self.breadcrumbContextLock.unlock()
        // The gate's context input just changed (binding, notice version, or
        // availability). Drop the memo before anything below can read it.
        Self.invalidateCaptureGateCache()
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
            RecentSessionTracker.shared.purge(binding: previousBinding)
            Self.purgeBreadcrumbJournal()
            DiagLog.ring.clear()
        }
        // Decide the fate of the pre-consent staging buffer with the same
        // previous/current binding comparison the purge above uses. Must run
        // after the context is published: the flush re-checks the live capture
        // gate, which reads that context.
        Self.applyEarlyBootStaging(
            previousBinding: previousBinding,
            binding: binding,
            noticeVersion: noticeVersion,
            statusAvailable: statusAvailable
        )
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
        let transitionInProgress = destinationTransitionInProgress
        let context = breadcrumbConsentContext
        breadcrumbContextLock.unlock()
        guard !transitionInProgress else { return nil }
        if let context {
            return context
        }
        guard let serverId = ServerRegistry.activeServerIDSnapshot,
              let snapshot = LastKnownStatusStore.snapshot(
                for: serverId,
                destination: DiagnosticsDestinationStore.shared.selectedDestination
              ) else {
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
        // Unconditional: even when the binding did not match, the purge that
        // brought us here removed persisted state (`LastKnownStatusStore`,
        // profile eligibility) that the gate's fallback resolution reads.
        invalidateCaptureGateCache()
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

    /// Close the synchronous capture gate while authentication is unresolved
    /// without treating that transient state as a server/profile boundary.
    /// In particular, a cold launch begins in `.loading`; purging there would
    /// erase the previous failed run's persisted evidence before tvOS consumes
    /// its abnormal-exit marker after restored auth resolves.
    nonisolated static func authenticationStateBecameUnavailable() {
        _ = beginActiveProfileEligibilityResolution(invalidateCurrent: true)
    }

    /// Close and rotate the synchronous capture gate before persisting a new
    /// diagnostics destination. Until that destination refreshes successfully,
    /// capture stays off instead of inheriting the old destination's consent.
    nonisolated static func diagnosticsDestinationWillChange() {
        breadcrumbContextLock.lock()
        let previousBinding = breadcrumbConsentContext?.binding
        breadcrumbConsentContext = nil
        destinationTransitionInProgress = true
        activeProfileBreadcrumbEligible = false
        activeProfileEligibilityGeneration &+= 1
        breadcrumbContextLock.unlock()
        invalidateCaptureGateCache()

        if let previousBinding {
            RecentSessionTracker.shared.purge(binding: previousBinding)
        }
        // The locked block above already closed the gate (context cleared,
        // eligibility invalidated, generation bumped), so this function is
        // ordered the same way `activeProfileWillChange` is: invalidate, then
        // purge. Keep the purge after it — an in-flight early-boot flush must
        // not be able to append into a journal this has already emptied.
        //
        // Also drops the pre-consent staging buffer, for the same reason the
        // journal and ring are purged: those lines must not follow the user
        // into the new destination's account.
        //
        // Both stay unconditional here, unlike `activeProfileWillChange`, which
        // has to tell a real boundary from a launch's profile restoration. This
        // function has no such ambiguity: its only caller is
        // `DiagnosticsViewModel.setDestination`, which returns early unless the
        // choice actually differs and is reachable only from the diagnostics
        // settings screen of an authenticated session. There is no path that
        // runs it during pre-consent startup, so every call is a genuine
        // destination change.
        purgeBreadcrumbJournal()
        DiagLog.ring.clear()
        #if os(tvOS)
        ExitSentinel.shared.disarmCurrentRun()
        #endif
    }

    #if DEBUG
    nonisolated static func installBreadcrumbConsentContextForTests(
        _ context: BreadcrumbConsentContext?
    ) {
        breadcrumbContextLock.lock()
        breadcrumbConsentContext = context
        destinationTransitionInProgress = false
        breadcrumbContextLock.unlock()
        invalidateCaptureGateCache()
    }

    nonisolated static func installActiveProfileBreadcrumbEligibilityForTests(_ eligible: Bool) {
        breadcrumbContextLock.lock()
        activeProfileEligibilityGeneration &+= 1
        activeProfileBreadcrumbEligible = eligible
        breadcrumbContextLock.unlock()
        invalidateCaptureGateCache()
    }

    /// The latch is process-wide and one-way within a launch, so a test that
    /// reproduces a cold boot must put it back to its launch value — and a test
    /// that reproduces a post-decision state must be able to set it without
    /// driving a whole status refresh.
    nonisolated static func installBreadcrumbDecisionInEffectForTests(_ inEffect: Bool) {
        breadcrumbContextLock.lock()
        breadcrumbDecisionInEffect = inEffect
        breadcrumbContextLock.unlock()
    }

    nonisolated static var breadcrumbDecisionInEffectForTests: Bool {
        breadcrumbDecisionIsInEffect
    }

    /// The restoration allowance is process-wide and one-way within a launch,
    /// so a test reproducing a cold boot must hand it back, and a test
    /// reproducing a post-launch switch must be able to spend it without
    /// driving `ContentView.checkInitialState`.
    nonisolated static func installLaunchProfileRestorationPassSpentForTests(_ spent: Bool) {
        breadcrumbContextLock.lock()
        launchProfileRestorationPassSpent = spent
        breadcrumbContextLock.unlock()
    }

    nonisolated static var launchProfileRestorationPassSpentForTests: Bool {
        breadcrumbContextLock.lock()
        defer { breadcrumbContextLock.unlock() }
        return launchProfileRestorationPassSpent
    }

    /// Drive the real staging decision against the process-wide state, so a
    /// test can assert what a first establish does to the journal without
    /// reaching into `applyEarlyBootStaging`'s private call chain.
    nonisolated static func applyEarlyBootStagingForTests(
        previousBinding: DiagnosticsBinding?,
        binding: DiagnosticsBinding,
        noticeVersion: Int,
        statusAvailable: Bool
    ) {
        applyEarlyBootStaging(
            previousBinding: previousBinding,
            binding: binding,
            noticeVersion: noticeVersion,
            statusAvailable: statusAvailable
        )
    }

    /// Number of times the authoritative gate actually ran. Tests assert the
    /// hot path is memoized without reaching into the cache's internals.
    nonisolated static var captureGateAuthoritativeEvaluationCountForTests: Int {
        captureGateCache.authoritativeEvaluationCountForTests
    }

    /// The gate with the memo bypassed. Tests compare the two so "the memo is
    /// a memo" is asserted against the real decision rather than a hardcoded
    /// expectation that could drift from the gating logic.
    nonisolated static var uncachedCaptureEnabledForTests: Bool {
        breadcrumbCaptureEnabledUncached()
    }

    nonisolated static func resetCaptureGateCacheForTests() {
        captureGateCache.resetForTests()
    }

    /// Empty the last-known-status fallback the capture gate resolves through
    /// when no live context exists, returning the previous contents so the
    /// caller can restore them. Without this a test cannot express "nothing
    /// resolves": the store is App-Group-persistent, so a simulator that has
    /// run the app before still answers with a real snapshot.
    nonisolated static func takeLastKnownStatusIndexForTests()
        -> [String: DiagnosticsStatusSnapshot] {
        let index = LastKnownStatusStore.takeIndexForTests()
        invalidateCaptureGateCache()
        return index
    }

    nonisolated static func restoreLastKnownStatusIndexForTests(
        _ index: [String: DiagnosticsStatusSnapshot]
    ) {
        LastKnownStatusStore.restoreIndexForTests(index)
        invalidateCaptureGateCache()
    }
    #endif

    /// Re-evaluate breadcrumb eligibility for the profile now active. Call on
    /// profile switches: a child profile can't manage diagnostics, so breadcrumb
    /// capture and the tvOS exit sentinel must disarm even though the
    /// server/account binding (and its consent) is unchanged. Fails closed
    /// immediately, then confirms asynchronously so a switch into a child profile
    /// can't capture even one breadcrumb before the child lookup lands.
    nonisolated static func activeProfileWillChange() {
        if let binding = currentDiagnosticsBinding {
            RecentSessionTracker.shared.purge(binding: binding)
        }
        // Invalidate *before* purging, never after. These boundary functions
        // run synchronously on the caller's thread while
        // `flushEarlyBootBufferIfArmed` can be draining the staging buffer on
        // the actor's executor. That flush checks the gate once and then
        // appends its lines one at a time, so a purge landing mid-drain would
        // be followed by further appends that still pass the journal's own
        // `isEnabled()` — staged launch lines written back into a journal that
        // was just emptied for the profile arriving now. Closing the gate
        // first makes every remaining append fail that check under the
        // journal's lock, so the purge is the last write of the boundary.
        _ = beginActiveProfileEligibilityResolution(invalidateCurrent: true)
        // Every launch with a restored session reaches this function *before*
        // authentication resolves: `ContentView.checkInitialState` calls
        // `AuthService.resolveActiveProfileForSession`, which opens with this
        // boundary. No profile is arriving there — both sides of that call are
        // the identity this launch is still resolving — so it is a restoration
        // pass, not a switch. The two things this function isolates each answer
        // that separately below.
        let isLaunchProfileRestoration = claimLaunchProfileRestorationPass()
        // A real profile switch is an account boundary for the staging buffer:
        // its pre-consent lines cannot be flushed into the profile arriving
        // now, which may be a child that must capture nothing at all. Discarding
        // seals the buffer permanently, so doing it on the restoration pass
        // emptied it on every authenticated cold launch — deleting `process_start`,
        // `root_view`, and `initial_state` before any consent context existed to
        // decide their fate, which is the exact case the buffer was added for.
        //
        // The signal is the launch's one-shot restoration allowance rather than
        // `breadcrumbDecisionIsInEffect` (which the journal purge below uses).
        // The decision latch is too weak here: it is set by a refusal or by the
        // first breadcrumb the journal accepts, and on a first-ever launch —
        // no `LastKnownStatusStore` snapshot to resolve a context from — neither
        // has happened by the time a user restores one profile and then switches
        // to another. Both boundaries would read as pre-decision and the second
        // one would keep the first profile's staged lines. Spending a single
        // per-launch allowance instead means every boundary after the first is
        // unconditionally a switch.
        //
        // Keeping the lines is not attributing them. The restoration pass just
        // closed the eligibility gate above, and the staged lines still reach
        // disk only through `applyEarlyBootStaging` (first establish, consent
        // permits) and then `flushEarlyBootBufferIfArmed`, which re-checks the
        // live gate — so a restored *child* profile never resolves eligible,
        // never flushes, and the staging window expires the lines instead.
        if !isLaunchProfileRestoration {
            discardEarlyBootBuffer()
        }
        // The on-disk trail is a different question, and the answer turns on
        // whether this launch's capture decision is in effect yet.
        //
        // Nothing this launch wrote can be in the journal before that decision —
        // the gate has never been open — so its entire contents are the previous
        // run's, which on tvOS is exactly the evidence `captureAbnormalExit`
        // reads once authentication lands. Purging there isolates nothing; it
        // empties the crash report before anyone opens it. Two neighbours
        // already take that position for the same reason:
        // `authenticationStateBecameUnavailable` refuses to treat the cold
        // launch's `.loading` state as a boundary, and
        // `updateBreadcrumbConsentContext` keeps the prior run's lines on a
        // first establish.
        //
        // Once the decision is in effect, the trail can hold this launch's own
        // lines for the outgoing profile, so the purge is the isolation it was
        // written to be. A refused launch latches the decision at the refusal,
        // so a "Never" account still clears here. The restoration allowance is
        // deliberately not consulted: a decision already in effect means this
        // launch reached an established account, and a purge is right for it
        // whether or not it is the launch's first profile boundary.
        if breadcrumbDecisionIsInEffect {
            purgeBreadcrumbJournal()
        }
        DiagLog.ring.clear()
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
        // Unconditional even when `invalidateCurrent` is false: a routine
        // revalidation keeps the last resolved flag, but bumping the memo's
        // epoch here is what makes the publish below able to detect that a
        // newer boundary raced it.
        invalidateCaptureGateCache()
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
        // The gate's profile-eligibility input just changed. Invalidate before
        // the flush below, which re-reads the live gate.
        invalidateCaptureGateCache()
        if eligible {
            // The first establish of a launch can arm the early-boot flush
            // while this async child-profile check is still pending, which
            // keeps the live gate closed. Retry now that it has opened. A
            // no-op when nothing is armed; still gated by the journal.
            flushEarlyBootBufferIfArmed()
        }
        return true
    }

    /// The live capture gate, evaluated on every `DiagTrace.log` call including
    /// the ones it then suppresses. The authoritative computation is
    /// `breadcrumbCaptureEnabledUncached()`; this wrapper only avoids running it
    /// per call, because it ends in a `UserDefaults` read plus a full
    /// `JSONDecoder` pass over the consent records under a shared lock.
    ///
    /// The memo is keyed on every input the authoritative path reads, so a hit
    /// is only possible when none of them moved. On a miss it recomputes
    /// authoritatively, then publishes only if the key is *still* current — a
    /// consent revocation, destination change, or profile switch landing during
    /// the computation discards the result and answers `false`. There is no
    /// path here that produces `true` without the authoritative gate having
    /// said so for exactly this state.
    nonisolated private static func breadcrumbCaptureEnabled() -> Bool {
        let key = captureGateKey()
        if let cached = captureGateCache.value(for: key) {
            return cached
        }
        let value = breadcrumbCaptureEnabledUncached()
        // Re-read the state after the computation. `store` publishes only when
        // it matches and the epoch has not moved; otherwise it returns false.
        return captureGateCache.store(value, for: key, still: captureGateKey())
    }

    /// Snapshot of every input the authoritative gate depends on. Anything added
    /// to `breadcrumbCaptureEnabledUncached` must be represented here (directly,
    /// or via a call to `invalidateCaptureGateCache()` when it changes) or the
    /// memo can outlive a boundary.
    nonisolated private static func captureGateKey() -> DiagnosticsCaptureGateCache.Key {
        DiagnosticsCaptureGateCache.Key(
            epoch: captureGateCache.currentEpoch,
            consentGeneration: DiagnosticsConsentStore.shared.mutationGeneration,
            serverRegistryID: ServerRegistry.activeServerIDSnapshot,
            destination: DiagnosticsDestinationStore.shared.selectedDestination
        )
    }

    /// Drop the memoized capture decision. Called from every mutation of the
    /// breadcrumb consent context, the destination-transition latch, and the
    /// profile-eligibility flag, so a stale `true` cannot outlive a boundary.
    nonisolated private static func invalidateCaptureGateCache() {
        captureGateCache.invalidate()
    }

    nonisolated private static func breadcrumbCaptureEnabledUncached() -> Bool {
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

        static func record(
            _ snapshot: DiagnosticsStatusSnapshot,
            for serverId: String,
            destination: DiagnosticsDestinationChoice
        ) {
            guard !serverId.isEmpty else { return }
            lock.lock()
            var index = load()
            index[key(serverId: serverId, destination: destination)] = snapshot
            save(index)
            lock.unlock()
        }

        static func snapshot(
            for serverId: String,
            destination: DiagnosticsDestinationChoice
        ) -> DiagnosticsStatusSnapshot? {
            lock.lock()
            let index = load()
            let snapshot = index[key(serverId: serverId, destination: destination)]
                ?? (destination == .selfHosted ? index[serverId] : nil)
            lock.unlock()
            return snapshot
        }

        private static func key(
            serverId: String,
            destination: DiagnosticsDestinationChoice
        ) -> String {
            "\(destination.rawValue)|\(serverId)"
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

        #if DEBUG
        /// Take the whole index and leave the store empty, returning what was
        /// there so a test can put it back. The store is App-Group-persistent,
        /// so a simulator that has ever run the app carries a real snapshot for
        /// the active server; a test asserting "no context resolves" has to
        /// clear this fallback too, not just the live context.
        static func takeIndexForTests() -> [String: DiagnosticsStatusSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            let index = load()
            save([:])
            return index
        }

        static func restoreIndexForTests(_ index: [String: DiagnosticsStatusSnapshot]) {
            lock.lock()
            save(index)
            lock.unlock()
        }
        #endif

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
    case reservedServerInstanceID
}
#endif
