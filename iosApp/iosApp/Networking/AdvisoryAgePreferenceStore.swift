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
@MainActor
final class AdvisoryAgePreferenceStore: ObservableObject {
    static let shared = AdvisoryAgePreferenceStore()

    @Published private(set) var showsAdvisoryAge = false
    @Published private(set) var isSupported = false
    @Published private(set) var isSaving = false

    private let transport: AdvisoryAgePreferenceTransport
    private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    private var hasHydrated = false
    private var hydrationTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var localMutationRevision: UInt = 0
    private var writeSequence: UInt = 0

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

    func refresh() async {
        if let hydrationTask {
            await hydrationTask.value
            return
        }
        guard let identity = requestIdentity() else { return }

        let currentGeneration = generation
        let mutationRevision = localMutationRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration {
                    self.hydrationTask = nil
                }
            }

            let capabilities = await self.transport.contractCapabilities(requestIdentity: identity)
            guard self.canApply(generation: currentGeneration, identity: identity) else { return }

            guard let contract = capabilities.capabilities,
                  contract.supports(.catalogShowAdvisoryAge) else {
                self.isSupported = false
                self.showsAdvisoryAge = false
                if case .failed = capabilities {
                    return
                }
                self.hasHydrated = true
                return
            }
            self.isSupported = true

            do {
                let response = try await self.transport.effectiveValue(requestIdentity: identity)
                guard self.canApply(generation: currentGeneration, identity: identity),
                      self.localMutationRevision == mutationRevision else { return }
                self.showsAdvisoryAge = response.value(for: .catalogShowAdvisoryAge)?
                    .value.boolValue == true
                self.hasHydrated = true
            } catch {
                // Keep the badge hidden. A later detail visit retries.
            }
        }
        hydrationTask = task
        await task.value
    }

    func setShowsAdvisoryAge(_ enabled: Bool) async {
        guard isSupported, !isSaving, let identity = requestIdentity() else { return }
        localMutationRevision &+= 1
        writeSequence &+= 1
        let currentWrite = writeSequence
        let currentGeneration = generation
        isSaving = true
        defer {
            if generation == currentGeneration, writeSequence == currentWrite {
                isSaving = false
            }
        }
        do {
            try await transport.putValue(enabled, requestIdentity: identity)
            guard canApply(generation: currentGeneration, identity: identity),
                  writeSequence == currentWrite else { return }
            showsAdvisoryAge = enabled
            hasHydrated = true
        } catch {
            // Keep the acknowledged server value visible; a later attempt can retry.
        }
    }

    func clear() {
        generation &+= 1
        writeSequence &+= 1
        hydrationTask?.cancel()
        hydrationTask = nil
        showsAdvisoryAge = false
        isSupported = false
        isSaving = false
        hasHydrated = false
    }

    private func canApply(generation: UInt, identity: HTTPRequestIdentity) -> Bool {
        !Task.isCancelled && self.generation == generation && requestIdentity() == identity
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
