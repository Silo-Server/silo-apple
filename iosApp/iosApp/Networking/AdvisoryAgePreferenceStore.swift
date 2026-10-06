import Foundation

protocol AdvisoryAgePreferenceTransport: AnyObject, Sendable {
    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult
    func effectiveValue(requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse
    func putValue(_ enabled: Bool, requestIdentity: HTTPRequestIdentity) async throws
}

final class SiloAdvisoryAgePreferenceTransport: AdvisoryAgePreferenceTransport {
    private let api: SiloAPI

    init(api: SiloAPI = .shared) { self.api = api }

    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        await api.getContractCapabilities(requestIdentity: requestIdentity)
    }

    func effectiveValue(requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(
            keys: [.catalogShowAdvisoryAge],
            requestIdentity: requestIdentity
        )
    }

    func putValue(_ enabled: Bool, requestIdentity: HTTPRequestIdentity) async throws {
        try await api.putValue(
            key: .catalogShowAdvisoryAge,
            scope: .profile,
            value: .bool(enabled),
            requestIdentity: requestIdentity
        )
    }
}

/// Profile-scoped display choice for advisory ages on item detail.
///
/// The server sends advisory metadata independently of this setting. Matching
/// the web client, Apple first verifies that the connected settings contract
/// supports `catalog.show_advisory_age`, then resolves the active profile's
/// effective value. A missing setting or an older server fails closed.
///
/// The Apple app does not subscribe to settings change events, so a change
/// made on another device arrives at the next read: opening Settings, or the
/// first detail page after the app returns to the foreground.
@MainActor
final class AdvisoryAgePreferenceStore: ObservableObject {
    static let shared = AdvisoryAgePreferenceStore()

    @Published private(set) var showsAdvisoryAge = false
    /// True once the server supports the setting and this profile's value has
    /// been read, so the toggle never shows a value the app doesn't know.
    @Published private(set) var isSupported = false
    @Published private(set) var isSaving = false
    @Published private(set) var writeError: String?

    private let transport: AdvisoryAgePreferenceTransport
    private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    private var hasHydrated = false
    private var hydrationTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var localMutationRevision: UInt = 0
    /// Bumped by ``markStale()`` so a read already in flight can still show
    /// its answer without counting as the fresh read that was asked for.
    private var staleMarks: UInt = 0
    /// The ``staleMarks`` value the in-flight read started under.
    private var hydrationStaleMark: UInt = 0
    /// The last value the server confirmed; a failed write rolls back to it.
    private var confirmedValue = false

    init(
        transport: AdvisoryAgePreferenceTransport = SiloAdvisoryAgePreferenceTransport(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? =
            AdvisoryAgePreferenceStore.activeRequestIdentity
    ) {
        self.transport = transport
        self.requestIdentity = requestIdentity
    }

    func hydrateIfNeeded() async {
        guard !hasHydrated else { return }
        await refresh()
    }

    /// Lets the next ``hydrateIfNeeded()`` read again while keeping the last
    /// answer on screen. Called when the app returns to the foreground.
    func markStale() {
        staleMarks &+= 1
        hasHydrated = false
    }

    func refresh() async {
        // Join a read in flight, and read again once it finishes if the value
        // was marked stale before or while it ran.
        while let hydrationTask {
            let taskStaleMark = hydrationStaleMark
            await hydrationTask.value
            if taskStaleMark == staleMarks { return }
        }
        guard let identity = requestIdentity() else { return }

        let currentGeneration = generation
        let mutationRevision = localMutationRevision
        let staleMark = staleMarks
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration {
                    self.hydrationTask = nil
                }
            }

            let capabilities = await self.transport.contractCapabilities(requestIdentity: identity)
            guard self.canApply(generation: currentGeneration, identity: identity) else { return }

            switch capabilities {
            case .available(let contract) where contract.supports(.catalogShowAdvisoryAge):
                break
            case .available, .serverUpgradeRequired:
                guard self.localMutationRevision == mutationRevision else { return }
                self.isSupported = false
                self.showsAdvisoryAge = false
                self.confirmedValue = false
                self.hasHydrated = self.staleMarks == staleMark
                return
            case .unavailable, .failed:
                // Not a verdict about the server's version: keep the last
                // answer and retry on the next read.
                return
            }

            do {
                let response = try await self.transport.effectiveValue(requestIdentity: identity)
                // A write that succeeded while this read ran is newer than its answer.
                guard self.canApply(generation: currentGeneration, identity: identity),
                      self.localMutationRevision == mutationRevision else { return }
                let value = response.value(for: .catalogShowAdvisoryAge)?.value.boolValue == true
                self.confirmedValue = value
                self.isSupported = true
                self.hasHydrated = self.staleMarks == staleMark
                // A save still in flight keeps showing the choice; if it fails,
                // it rolls back to this answer.
                if !self.isSaving {
                    self.showsAdvisoryAge = value
                }
            } catch {
                // Keep the last answer. The next read retries.
            }
        }
        hydrationTask = task
        hydrationStaleMark = staleMark
        await task.value
    }

    /// Shows the choice at once and saves it at profile scope. A failed save
    /// rolls back to the last confirmed value and sets ``writeError``.
    func setShowsAdvisoryAge(_ enabled: Bool) async {
        guard isSupported, !isSaving, let identity = requestIdentity() else { return }
        let currentGeneration = generation
        writeError = nil
        showsAdvisoryAge = enabled
        isSaving = true
        defer {
            if generation == currentGeneration {
                isSaving = false
            }
        }
        do {
            try await transport.putValue(enabled, requestIdentity: identity)
            guard canApply(generation: currentGeneration, identity: identity) else { return }
            localMutationRevision &+= 1
            confirmedValue = enabled
            hasHydrated = true
        } catch {
            guard canApply(generation: currentGeneration, identity: identity) else { return }
            showsAdvisoryAge = confirmedValue
            writeError = Self.writeFailureMessage(for: error)
            // A save that timed out may still have landed; the next read
            // reconciles it.
            markStale()
        }
    }

    func clear() {
        generation &+= 1
        hydrationTask?.cancel()
        hydrationTask = nil
        showsAdvisoryAge = false
        confirmedValue = false
        isSupported = false
        isSaving = false
        writeError = nil
        hasHydrated = false
    }

    private func canApply(generation: UInt, identity: HTTPRequestIdentity) -> Bool {
        !Task.isCancelled && self.generation == generation && requestIdentity() == identity
    }

    static func writeFailureMessage(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't save Show Advisory Age. Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting:
            return "This server can't save Show Advisory Age."
        default:
            return "The server didn't save Show Advisory Age. Try again."
        }
    }

    private static func activeRequestIdentity() -> HTTPRequestIdentity? {
        guard let server = ServerRegistry.shared.activeServer,
              ServerRegistry.shared.activeServerId == server.id,
              let profileId = AuthService.shared.profileId,
              !profileId.isEmpty else { return nil }
        return HTTPRequestIdentity(
            serverId: server.id,
            serverURL: server.url,
            profileId: profileId,
            clientFamily: AppleDeviceIdentity.current.clientFamily
        )
    }
}
