import Foundation
import Observation

// MARK: - Shared wire models

enum CardPosterSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    /// Artwork scale used by free-scrolling rails and standalone cards.
    /// Grids also adjust their column count so the selected size never causes
    /// overlapping focus frames.
    var scale: CGFloat {
        switch self {
        case .compact: return 0.86
        case .standard: return 1
        case .large: return 1.2
        }
    }
}

/// `ui.card_presentation`. Revision 24 of the settings contract retired the
/// caption choice, so every card shows its title and details. The schema still
/// requires `caption`: encoding always writes `title_metadata`, and decoding
/// ignores whatever an older client stored.
struct CardPresentationPreference: Equatable, Sendable {
    var posterSize: CardPosterSize

    static let standard = CardPresentationPreference(posterSize: .standard)
}

extension CardPresentationPreference: Codable {
    private enum CodingKeys: String, CodingKey {
        case posterSize = "poster_size"
        case caption
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        posterSize = try container.decode(CardPosterSize.self, forKey: .posterSize)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(posterSize, forKey: .posterSize)
        try container.encode("title_metadata", forKey: .caption)
    }
}

// MARK: - Transport

protocol UICustomizationTransport: AnyObject, Sendable {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult
    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse
    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws
    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws
}

extension UICustomizationTransport {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        .serverUpgradeRequired
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        throw URLError(.unsupportedURL)
    }
}

final class SiloUICustomizationTransport: UICustomizationTransport {
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await api.getContractCapabilities(requestIdentity: requestIdentity)
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await api.getEffectiveValues(
            keys: keys,
            requestIdentity: requestIdentity
        )
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.putValue(key: key, scope: scope, value: value, requestIdentity: requestIdentity)
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.deleteValue(key: key, scope: scope, requestIdentity: requestIdentity)
    }
}

enum UICustomizationCapabilityState: Equatable, Sendable {
    case checking
    case supported
    case serverUpgradeRequired
    case unavailable

    var allowsEditing: Bool { self == .supported }

    var userMessage: String? {
        switch self {
        case .checking:
            return "Checking whether this server supports synced interface settings…"
        case .supported:
            return nil
        case .serverUpgradeRequired:
            return "Update this Silo server to use synced interface settings."
        case .unavailable:
            return "Interface settings are read-only until server support can be verified."
        }
    }
}

/// Last authoritative compatibility conclusion for one server/profile/family
/// cache. Probe failures are deliberately not conclusions: offline clients can
/// keep rendering a previously valid cache, while an explicitly older server
/// must not keep revision-5 card presentation active.
enum UICustomizationSupportProjection: String, Codable, Equatable, Sendable {
    case unknown
    case supported
    case knownUnsupported = "known_unsupported"

    var projectsCachedValues: Bool { self != .knownUnsupported }
}

// MARK: - Observable preference store

/// Effective card presentation for the active profile and client family.
///
/// Server values are authoritative when reachable. A per-profile/family cache
/// is painted first and updated optimistically so poster layout remains
/// useful offline; a failed sync never erases the last working UI.
@MainActor
@Observable
final class UICustomizationPreferences {
    static let shared = UICustomizationPreferences()

    private var storedCardPresentation: CardPresentationPreference = .standard
    private var storedCardPresentationSource: SettingSource?
    private(set) var isSaving = false
    private(set) var syncErrorMessage: String?
    private(set) var capabilityState: UICustomizationCapabilityState = .checking
    private(set) var supportProjection: UICustomizationSupportProjection = .unknown

    var cardPresentation: CardPresentationPreference {
        supportProjection.projectsCachedValues ? storedCardPresentation : .standard
    }
    private var cardPresentationSource: SettingSource? {
        supportProjection.projectsCachedValues ? storedCardPresentationSource : nil
    }

    var allowsEditing: Bool { capabilityState.allowsEditing }
    var capabilityMessage: String? { capabilityState.userMessage }

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let transport: UICustomizationTransport
    @ObservationIgnored private let cacheKey: @MainActor () -> String?
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var localMutationRevision = 0
    @ObservationIgnored private var saveTail: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveCount = 0
    @ObservationIgnored private var syncErrorsByKey: [String: String] = [:]
    @ObservationIgnored private var refreshSyncErrorMessage: String?
    @ObservationIgnored private var loadedCacheKey: String?
    @ObservationIgnored private var pendingSyncWrites: [String: PendingSyncWrite] = [:]
    @ObservationIgnored private var pendingDeletes: [String: PendingDelete] = [:]
    @ObservationIgnored private let writeRetryPolicy: SettingWriteRetryPolicy
    @ObservationIgnored private var outboxRetryTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightRefresh: InFlightRefresh?

    /// True while a change is out of automatic retries and waits for
    /// "Try Again" or "Discard Held Change".
    private(set) var hasHeldChanges = false

    /// Resolves once every queued save has finished, including saves that a
    /// finishing save enqueues. For tests.
    func waitForPendingSaves() async {
        while let tail = saveTail {
            await tail.value
            if saveTail == tail { return }
        }
    }

    /// Whether a backoff timer will resend failed writes. Read by tests.
    var hasArmedOutboxRetry: Bool { outboxRetryTask != nil }

    private struct InFlightRefresh {
        let cacheKey: String?
        let mutationRevision: Int
        let task: Task<Void, Never>
    }

    private struct OperationContext {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    /// Retry bookkeeping for one outbox entry.
    private struct OutboxRetryState: Codable, Equatable {
        /// Failed sends of this exact operation that a retry could fix.
        var failedAttempts = 0
        /// Out of automatic retries: kept and shown locally, not sent until
        /// the user retries or discards it.
        var isHeld = false
    }

    private struct PendingSyncWrite: Codable {
        let value: SettingJSONValue
        /// A new user edit replaces this record with a new id; a retry of the
        /// same value keeps it.
        let operationId: String
        var retry = OutboxRetryState()

        private enum CodingKeys: String, CodingKey {
            case value, operationId, retry
            case legacyMutationId = "mutationId"
        }

        init(value: SettingJSONValue, operationId: String = UUID().uuidString) {
            self.value = value
            self.operationId = operationId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(SettingJSONValue.self, forKey: .value)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? container.decodeIfPresent(String.self, forKey: .legacyMutationId)
                ?? UUID().uuidString
            retry = try container.decodeIfPresent(OutboxRetryState.self, forKey: .retry) ?? OutboxRetryState()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
            try container.encode(operationId, forKey: .operationId)
            try container.encode(retry, forKey: .retry)
        }
    }

    private struct PendingDelete: Codable {
        let scope: SettingScope
        /// A local operation identity prevents an older queued DELETE from
        /// clearing a newer same-scope reset that still needs to be replayed.
        let operationId: String
        var retry = OutboxRetryState()

        private enum CodingKeys: String, CodingKey {
            case scope
            case operationId
            case retry
        }

        init(scope: SettingScope, operationId: String = UUID().uuidString) {
            self.scope = scope
            self.operationId = operationId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try container.decode(SettingScope.self, forKey: .scope)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
                ?? UUID().uuidString
            retry = try container.decodeIfPresent(OutboxRetryState.self, forKey: .retry) ?? OutboxRetryState()
        }

        var scopeIdentity: SettingScopeIdentity? {
            switch scope {
            case .profileClient: return .profileClient
            case .profileDevice: return .profileDevice
            default: return nil
            }
        }
    }

    /// Caches written before the menu settings were dropped also carry menu
    /// and shortcut members; decoding ignores them.
    private struct Cache: Codable {
        let cardPresentation: CardPresentationPreference
        let cardPresentationSource: SettingSource?
        let supportProjection: UICustomizationSupportProjection?
        let pendingSyncWrites: [String: PendingSyncWrite]?
        let pendingDeletes: [String: PendingDelete]?
    }

    init(
        defaults: SharedDefaults = .shared,
        transport: UICustomizationTransport = SiloUICustomizationTransport(),
        cacheKey: @escaping @MainActor () -> String? = UICustomizationPreferences.activeCacheKey,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = UICustomizationPreferences.activeRequestIdentity,
        initialCapabilityState: UICustomizationCapabilityState = .checking,
        writeRetryPolicy: SettingWriteRetryPolicy = .default
    ) {
        self.defaults = defaults
        self.transport = transport
        self.cacheKey = cacheKey
        self.requestIdentity = requestIdentity
        self.writeRetryPolicy = writeRetryPolicy
        capabilityState = initialCapabilityState
        loadCache(for: cacheKey())
    }

    /// Repaint from the active identity's cache, then reconcile from the
    /// server. Transiently unknown servers retain the last compatible cache;
    /// explicitly older servers project the legacy/default presentation.
    ///
    /// Calls for the same identity and local revision share one pass. `force`
    /// starts a new pass, for outbox changes that don't advance the revision
    /// (device-row deletes, discarded held changes).
    func refresh(force: Bool = false) async {
        let targetCacheKey = cacheKey()
        if !force,
           let inFlight = inFlightRefresh,
           inFlight.cacheKey == targetCacheKey,
           inFlight.mutationRevision == localMutationRevision {
            await inFlight.task.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlightRefresh = InFlightRefresh(
            cacheKey: targetCacheKey,
            mutationRevision: localMutationRevision,
            task: task
        )
        await task.value
        if inFlightRefresh?.task == task {
            inFlightRefresh = nil
        }
    }

    private func performRefresh() async {
        AppNavPreferences.shared.refresh()
        let targetCacheKey = cacheKey()
        loadCache(for: targetCacheKey)
        refreshSequence += 1
        let sequence = refreshSequence
        let mutationRevision = localMutationRevision

        guard let identity = capturedIdentity(for: targetCacheKey) else {
            capabilityState = .unavailable
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            return
        }

        capabilityState = .checking
        // A new probe supersedes the prior probe/read failure. Per-key outbox
        // failures remain visible until their own retry succeeds.
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard refreshIsCurrent(sequence, mutationRevision, targetCacheKey, identity) else { return }

        switch capabilities {
        case .available(let capabilities)
            where capabilities.supportsUICustomization(clientFamily: identity.clientFamily):
            capabilityState = .supported
            supportProjection = .supported
            saveCache(for: targetCacheKey)
        case .available, .serverUpgradeRequired:
            capabilityState = .serverUpgradeRequired
            supportProjection = .knownUnsupported
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            saveCache(for: targetCacheKey)
            return
        case .unavailable, .failed:
            capabilityState = .unavailable
            refreshSyncErrorMessage = capabilityState.userMessage
            updateSyncErrorMessage()
            return
        }

        do {
            guard await drainPendingWrites(
                targetCacheKey: targetCacheKey,
                requestIdentity: identity,
                sequence: sequence,
                mutationRevision: mutationRevision
            ) else { return }
            let response = try await transport.effectiveValues(
                keys: Self.keys,
                requestIdentity: identity
            )
            guard refreshIsCurrent(sequence, mutationRevision, targetCacheKey, identity) else { return }
            let values = response.byKey
            var decodedEveryValue = true
            let heldKeys = heldOutboxKeys
            for key in Self.keys where !heldKeys.contains(key) {
                guard let row = values[key] else {
                    setSyncError(Self.missingEffectiveValueMessage, for: key)
                    decodedEveryValue = false
                    continue
                }
                decodedEveryValue = applyEffectiveValue(row, for: key) && decodedEveryValue
            }

            if decodedEveryValue {
                clearReconciledSyncErrors()
            } else {
                refreshSyncErrorMessage = nil
                updateSyncErrorMessage()
            }
            saveCache(for: targetCacheKey)
        } catch {
            guard refreshIsCurrent(sequence, mutationRevision, targetCacheKey, identity) else { return }
            refreshSyncErrorMessage = Self.message(for: error)
            updateSyncErrorMessage()
        }
    }

    func setCardPresentation(_ value: CardPresentationPreference) {
        guard !cardPresentationUsesDeviceOverride,
              let context = operationContext() else { return }
        localMutationRevision += 1
        storedCardPresentation = value
        storedCardPresentationSource = .scope(.profileClient)
        pendingDeletes.removeValue(
            forKey: Self.deleteIdentity(key: .uiCardPresentation, scope: .profileClient)
        )
        persist(
            key: .uiCardPresentation,
            scope: .profileClient,
            value: value,
            context: context
        )
    }

    func setPosterSize(_ value: CardPosterSize) {
        var updated = cardPresentation
        updated.posterSize = value
        setCardPresentation(updated)
    }

    var cardPresentationUsesDeviceOverride: Bool {
        cardPresentationSource == .scope(.profileDevice)
    }
    var cardPresentationUsesFamilyOverride: Bool {
        cardPresentationSource == .scope(.profileClient)
    }
    var hasDeviceOverrides: Bool {
        cardPresentationUsesDeviceOverride
    }

    /// Clear the higher-precedence per-device row so the family-scoped
    /// controls can truthfully represent and sync the effective value again.
    func useFamilySettings() {
        guard let context = operationContext() else { return }
        if cardPresentationUsesDeviceOverride {
            scheduleDelete(
                key: .uiCardPresentation,
                scope: .profileDevice,
                context: context
            )
        }
        let deletes = saveTail
        Task { @MainActor [weak self] in
            await deletes?.value
            guard let self,
                  self.contextIsCurrent(context),
                  self.syncErrorsByKey.isEmpty else { return }
            await self.refresh(force: true)
        }
    }

    /// Remove this family's explicit card row so resolution falls through to
    /// the profile-wide value or the contract default. This is distinct from
    /// clearing an older per-device row, which only exposes the family row.
    func resetCardPresentationToInherited() {
        guard let context = operationContext() else { return }
        localMutationRevision += 1
        pendingSyncWrites.removeValue(forKey: SettingKey.uiCardPresentation.rawValue)
        storedCardPresentationSource = nil
        scheduleDelete(
            key: .uiCardPresentation,
            scope: .profileClient,
            context: context
        )
        let delete = saveTail
        Task { @MainActor [weak self] in
            await delete?.value
            guard let self,
                  self.contextIsCurrent(context),
                  self.syncErrorsByKey[SettingKey.uiCardPresentation.rawValue] == nil else { return }
            await self.refresh(force: true)
        }
    }

    @discardableResult
    private func persist<T: Encodable>(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: T,
        context: OperationContext
    ) -> Bool {
        let encodedValue: SettingJSONValue
        do {
            encodedValue = try SettingJSONValue.encoding(value)
        } catch {
            setSyncError(Self.message(for: error), for: key)
            return false
        }
        let pendingWrite = PendingSyncWrite(value: encodedValue)
        pendingSyncWrites[key.rawValue] = pendingWrite
        saveCache(for: context.cacheKey)
        enqueuePersist(
            key: key,
            scope: scope,
            write: pendingWrite,
            context: context
        )
        return true
    }

    private func enqueuePersist(
        key: SettingKey,
        scope: SettingScopeIdentity,
        write: PendingSyncWrite,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.putValue(
                    key: key,
                    scope: scope,
                    value: write.value,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                if pendingSyncWrites[key.rawValue]?.operationId == write.operationId {
                    pendingSyncWrites.removeValue(forKey: key.rawValue)
                    saveCache(for: context.cacheKey)
                }
                setSyncError(nil, for: key)
            } catch {
                guard contextIsCurrent(context) else { return }
                // Only the key's latest operation decides anything: an older
                // one was replaced by a newer edit, which reports for itself.
                guard var current = pendingSyncWrites[key.rawValue],
                      current.operationId == write.operationId else { return }
                switch SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope).writeFailure {
                case .retry:
                    let held = recordRetryableFailure(&current.retry)
                    pendingSyncWrites[key.rawValue] = current
                    saveCache(for: context.cacheKey)
                    setSyncError(held ? HeldSettingChange.message : Self.message(for: error), for: key)
                    if !held { scheduleOutboxRetry(context: context) }
                case .release:
                    // A definite refusal: sending the same value again cannot
                    // land. Release it; the next refresh repaints the server's
                    // value.
                    pendingSyncWrites.removeValue(forKey: key.rawValue)
                    saveCache(for: context.cacheKey)
                    setSyncError(Self.message(for: error), for: key)
                case .ownerChanged, .waitForCondition:
                    // Keep the optimistic cache. A later refresh or another
                    // edit retries against the server without making the app
                    // unusable while offline.
                    setSyncError(Self.message(for: error), for: key)
                }
            }
        }
        saveTail = save
    }

    private func scheduleDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        context: OperationContext
    ) {
        if scope.scope == .profileClient {
            pendingSyncWrites.removeValue(forKey: key.rawValue)
        }
        let pendingDelete = PendingDelete(scope: scope.scope)
        pendingDeletes[Self.deleteIdentity(key: key, scope: scope.scope)] = pendingDelete
        saveCache(for: context.cacheKey)
        enqueueDelete(
            key: key,
            scope: scope,
            pendingDelete: pendingDelete,
            context: context
        )
    }

    private func enqueueDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        pendingDelete: PendingDelete,
        context: OperationContext
    ) {
        let previousSave = saveTail
        pendingSaveCount += 1
        isSaving = true

        let save = Task { @MainActor [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer { self.completeSave() }
            guard contextIsCurrent(context) else { return }
            do {
                try await transport.deleteValue(
                    key: key,
                    scope: scope,
                    requestIdentity: context.requestIdentity
                )
                guard contextIsCurrent(context) else { return }
                await finishAcceptedDelete(
                    key: key,
                    scope: scope,
                    pendingDelete: pendingDelete,
                    context: context
                )
            } catch {
                guard contextIsCurrent(context) else { return }
                let mapped = SettingsAPIError.from(error, key: key.rawValue, scope: scope.scope)
                if case .noValueAtScope = mapped {
                    await finishAcceptedDelete(
                        key: key,
                        scope: scope,
                        pendingDelete: pendingDelete,
                        context: context
                    )
                } else {
                    let identity = Self.deleteIdentity(key: key, scope: scope.scope)
                    guard var current = pendingDeletes[identity],
                          current.operationId == pendingDelete.operationId else {
                        return
                    }
                    var message = "Could not reset this setting to its inherited value."
                    switch mapped.writeFailure {
                    case .retry:
                        let held = recordRetryableFailure(&current.retry)
                        pendingDeletes[identity] = current
                        saveCache(for: context.cacheKey)
                        if held {
                            message = HeldSettingChange.message
                        } else {
                            scheduleOutboxRetry(context: context)
                        }
                    case .release:
                        pendingDeletes.removeValue(forKey: identity)
                        saveCache(for: context.cacheKey)
                    case .ownerChanged, .waitForCondition:
                        break
                    }
                    setSyncError(message, for: key)
                }
            }
        }
        saveTail = save
    }

    /// A successful device-row delete changes the effective value immediately,
    /// even if another queued delete fails. Reconcile only this accepted key so
    /// a failed sibling remains durable for retry without blocking the value
    /// that the server has already exposed underneath the deleted override.
    private func finishAcceptedDelete(
        key: SettingKey,
        scope: SettingScopeIdentity,
        pendingDelete: PendingDelete,
        context: OperationContext
    ) async {
        let identity = Self.deleteIdentity(key: key, scope: scope.scope)
        guard pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }

        guard scope.scope == .profileDevice else {
            pendingDeletes.removeValue(forKey: identity)
            saveCache(for: context.cacheKey)
            setSyncError(nil, for: key)
            return
        }

        do {
            let response = try await transport.effectiveValues(
                keys: [key],
                requestIdentity: context.requestIdentity
            )
            guard contextIsCurrent(context),
                  pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }
            guard let row = response.byKey[key] else {
                setSyncError(Self.missingEffectiveValueMessage, for: key)
                return
            }
            guard applyEffectiveValue(row, for: key) else { return }
            pendingDeletes.removeValue(forKey: identity)
            saveCache(for: context.cacheKey)
        } catch {
            guard contextIsCurrent(context),
                  pendingDeletes[identity]?.operationId == pendingDelete.operationId else { return }
            setSyncError(Self.message(for: error), for: key)
        }
    }

    /// Decode and apply one key atomically. A future value for one setting must
    /// not prevent compatible siblings from reconciling, and its source must
    /// never be paired with a stale value from an earlier successful read.
    @discardableResult
    private func applyEffectiveValue(
        _ row: EffectiveSettingValue,
        for key: SettingKey
    ) -> Bool {
        do {
            switch key {
            case .uiCardPresentation:
                let presentation = try row.value.decoded(as: CardPresentationPreference.self)
                storedCardPresentation = presentation
                storedCardPresentationSource = row.source
            default:
                throw SettingsAPIError.unknownSetting(key: key.rawValue)
            }
            setSyncError(nil, for: key)
            return true
        } catch {
            setSyncError(Self.effectiveValueDecodeMessage, for: key)
            return false
        }
    }

    /// Durable optimistic writes are replayed before reading effective values.
    /// Otherwise an online refresh after an offline edit would replace the
    /// user's cached choice with the server's older value before retrying it.
    private func drainPendingWrites(
        targetCacheKey: String?,
        requestIdentity: HTTPRequestIdentity,
        sequence: Int,
        mutationRevision: Int
    ) async -> Bool {
        await saveTail?.value
        guard refreshIsCurrent(sequence, mutationRevision, targetCacheKey, requestIdentity) else { return false }

        guard let targetCacheKey else { return false }
        let context = OperationContext(
            cacheKey: targetCacheKey,
            requestIdentity: requestIdentity
        )
        // Held changes are sent only by retryHeldChanges().
        guard enqueueOutbox(context: context, where: { _, retry in !retry.isHeld }) else { return true }
        await saveTail?.value
        guard refreshIsCurrent(sequence, mutationRevision, targetCacheKey, requestIdentity) else { return false }
        return pendingSyncWrites.values.allSatisfy(\.retry.isHeld)
            && pendingDeletes.values.allSatisfy(\.retry.isHeld)
    }

    /// One outbox entry: a value write by key, or a delete by `key|scope`.
    private enum OutboxEntry: Hashable {
        case value(String)
        case delete(String)
    }

    /// Queue every outbox entry `include` accepts, deletes first, then value
    /// writes. Returns whether anything was queued.
    @discardableResult
    private func enqueueOutbox(
        context: OperationContext,
        where include: (OutboxEntry, OutboxRetryState) -> Bool
    ) -> Bool {
        let deletes = pendingDeletes.sorted(by: { $0.key < $1.key })
            .filter { include(.delete($0.key), $0.value.retry) }
        let pending = Self.keys.compactMap { key -> (SettingKey, SettingScopeIdentity, PendingSyncWrite)? in
            guard let write = pendingSyncWrites[key.rawValue], include(.value(key.rawValue), write.retry),
                  let scope = Self.writeScope(for: key) else { return nil }
            return (key, scope, write)
        }
        guard !deletes.isEmpty || !pending.isEmpty else { return false }

        for (identity, delete) in deletes {
            guard let key = Self.deleteKey(identity),
                  let scope = delete.scopeIdentity else { continue }
            enqueueDelete(
                key: key,
                scope: scope,
                pendingDelete: delete,
                context: context
            )
        }
        for (key, scope, write) in pending {
            enqueuePersist(
                key: key,
                scope: scope,
                write: write,
                context: context
            )
        }
        return true
    }

    // MARK: - Held changes

    /// Records one failed send that a retry could fix and returns whether the
    /// change is now held (the retry bound ran out).
    private func recordRetryableFailure(_ state: inout OutboxRetryState) -> Bool {
        state.failedAttempts += 1
        if state.failedAttempts > writeRetryPolicy.maximumAutomaticRetries {
            state.isHeld = true
        }
        return state.isHeld
    }

    /// One timer for every change still retrying, paced by the one that has
    /// failed least. It re-queues only changes that already failed: anything
    /// newer is queued by its own edit.
    private func scheduleOutboxRetry(context: OperationContext) {
        let retrying = pendingSyncWrites.values.map(\.retry)
            + pendingDeletes.values.map(\.retry)
        guard let attempt = retrying
            .filter({ !$0.isHeld && $0.failedAttempts > 0 })
            .map(\.failedAttempts)
            .min() else { return }
        outboxRetryTask?.cancel()
        let delay = writeRetryPolicy.delay(forAttempt: attempt)
        outboxRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.contextIsCurrent(context) else { return }
            self.outboxRetryTask = nil
            self.enqueueOutbox(context: context, where: { _, retry in !retry.isHeld && retry.failedAttempts > 0 })
        }
    }

    /// "Try Again": send every held change once more with a fresh retry
    /// budget.
    func retryHeldChanges() {
        guard let context = operationContext() else { return }
        var released = Set<OutboxEntry>()
        for (key, var write) in pendingSyncWrites where write.retry.isHeld {
            write.retry = OutboxRetryState()
            pendingSyncWrites[key] = write
            released.insert(.value(key))
            if let settingKey = SettingKey(rawValue: key) { setSyncError(nil, for: settingKey) }
        }
        for (identity, var delete) in pendingDeletes where delete.retry.isHeld {
            delete.retry = OutboxRetryState()
            pendingDeletes[identity] = delete
            released.insert(.delete(identity))
            if let key = Self.deleteKey(identity) { setSyncError(nil, for: key) }
        }
        saveCache(for: context.cacheKey)
        updateSyncErrorMessage()
        enqueueOutbox(context: context, where: { entry, _ in released.contains(entry) })
    }

    /// "Discard Held Change": forget every held change and repaint what the
    /// server holds. Nothing is sent.
    func discardHeldChanges() async {
        guard let targetCacheKey = cacheKey() else { return }
        for (key, write) in pendingSyncWrites where write.retry.isHeld {
            pendingSyncWrites.removeValue(forKey: key)
            if let settingKey = SettingKey(rawValue: key) { setSyncError(nil, for: settingKey) }
        }
        for (identity, delete) in pendingDeletes where delete.retry.isHeld {
            pendingDeletes.removeValue(forKey: identity)
            if let key = Self.deleteKey(identity) { setSyncError(nil, for: key) }
        }
        saveCache(for: targetCacheKey)
        updateSyncErrorMessage()
        await refresh(force: true)
    }

    /// Keys whose effective value a refresh must not paint over, because a
    /// held change for them is still shown locally.
    private var heldOutboxKeys: Set<SettingKey> {
        var keys = Set<SettingKey>()
        for (key, write) in pendingSyncWrites where write.retry.isHeld {
            if let settingKey = SettingKey(rawValue: key) { keys.insert(settingKey) }
        }
        for (identity, delete) in pendingDeletes where delete.retry.isHeld {
            if let key = Self.deleteKey(identity) { keys.insert(key) }
        }
        return keys
    }

    private func completeSave() {
        pendingSaveCount = max(0, pendingSaveCount - 1)
        isSaving = pendingSaveCount > 0
    }

    private func loadCache(for key: String?) {
        defer { updateHeldState() }
        if loadedCacheKey != key {
            if loadedCacheKey != nil {
                capabilityState = .checking
            }
            loadedCacheKey = key
            clearSyncErrors()
        }
        // Decode first and assign each observed value once. Resetting to the
        // defaults and then restoring would invalidate every view reading
        // them (every card reads `cardPresentation`) on each refresh.
        let cached = key
            .flatMap { defaults.data(forKey: $0) }
            .flatMap { try? SettingsWireCoding.makeDecoder().decode(Cache.self, from: $0) }
        storedCardPresentation = cached?.cardPresentation ?? .standard
        storedCardPresentationSource = cached?.cardPresentationSource
        supportProjection = cached?.supportProjection ?? .unknown
        // Older caches can hold queued top-menu writes; those settings are no
        // longer synced from Apple clients, so drop them.
        pendingSyncWrites = (cached?.pendingSyncWrites ?? [:]).filter { key, _ in
            SettingKey(rawValue: key).map { Self.keys.contains($0) } ?? false
        }
        pendingDeletes = Self.validPendingDeletes(cached?.pendingDeletes ?? [:])
    }

    private func updateHeldState() {
        let held = pendingSyncWrites.values.contains(where: \.retry.isHeld)
            || pendingDeletes.values.contains(where: \.retry.isHeld)
        if hasHeldChanges != held { hasHeldChanges = held }
    }

    private func saveCache(for key: String?) {
        updateHeldState()
        guard let key,
              let data = try? SettingsWireCoding.makeEncoder().encode(Cache(
                cardPresentation: storedCardPresentation,
                cardPresentationSource: storedCardPresentationSource,
                supportProjection: supportProjection,
                pendingSyncWrites: pendingSyncWrites.isEmpty ? nil : pendingSyncWrites,
                pendingDeletes: pendingDeletes.isEmpty ? nil : pendingDeletes
              ))
        else { return }
        defaults.set(data, forKey: key)
    }

    /// Writes are serialized, but a later successful setting must not erase a
    /// failure from an earlier key. A successful refresh is the only operation
    /// that proves the complete effective bundle reconciled.
    private func setSyncError(_ message: String?, for key: SettingKey) {
        if let message {
            syncErrorsByKey[key.rawValue] = message
        } else {
            syncErrorsByKey.removeValue(forKey: key.rawValue)
        }
        updateSyncErrorMessage()
    }

    private func clearSyncErrors() {
        syncErrorsByKey.removeAll()
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
    }

    /// A successful effective read resolves ordinary write/read failures.
    private func clearReconciledSyncErrors() {
        syncErrorsByKey.removeAll()
        refreshSyncErrorMessage = nil
        updateSyncErrorMessage()
    }

    private func updateSyncErrorMessage() {
        syncErrorMessage = refreshSyncErrorMessage
            ?? Self.keys.lazy.compactMap { self.syncErrorsByKey[$0.rawValue] }.first
    }

    private func operationContext() -> OperationContext? {
        guard allowsEditing,
              let targetCacheKey = cacheKey(),
              let identity = capturedIdentity(for: targetCacheKey) else { return nil }
        return OperationContext(cacheKey: targetCacheKey, requestIdentity: identity)
    }

    private func contextIsCurrent(_ context: OperationContext) -> Bool {
        cacheKey() == context.cacheKey
            && capturedIdentity(for: context.cacheKey) == context.requestIdentity
    }

    /// A refresh pass may still apply results: no newer pass started, no
    /// local edit landed, and the identity it captured is still active.
    private func refreshIsCurrent(
        _ sequence: Int,
        _ mutationRevision: Int,
        _ targetCacheKey: String?,
        _ identity: HTTPRequestIdentity
    ) -> Bool {
        refreshSequence == sequence
            && localMutationRevision == mutationRevision
            && cacheKey() == targetCacheKey
            && capturedIdentity(for: targetCacheKey) == identity
    }

    private func capturedIdentity(for targetCacheKey: String?) -> HTTPRequestIdentity? {
        guard let targetCacheKey,
              let identity = requestIdentity(),
              Self.cacheKey(for: identity) == targetCacheKey else { return nil }
        return identity
    }

    private static func activeCacheKey() -> String? {
        guard let identity = activeRequestIdentity() else { return nil }
        return cacheKey(for: identity)
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

    private static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "silo.uiCustomization.\(identity.serverId).\(identity.profileId).\(identity.clientFamily)"
    }

    private static func deleteIdentity(key: SettingKey, scope: SettingScope) -> String {
        "\(key.rawValue)|\(scope.rawValue)"
    }

    private static func deleteKey(_ identity: String) -> SettingKey? {
        identity.split(separator: "|", maxSplits: 1).first.flatMap { SettingKey(rawValue: String($0)) }
    }

    private static let keys: [SettingKey] = [.uiCardPresentation]

    private static let effectiveValueDecodeMessage =
        "Could not read this interface preference from the server."
    private static let missingEffectiveValueMessage =
        "The server did not return this interface preference."

    private static func writeScope(for key: SettingKey) -> SettingScopeIdentity? {
        switch key {
        case .uiCardPresentation:
            return .profileClient
        default:
            return nil
        }
    }

    private static func validPendingDeletes(
        _ deletes: [String: PendingDelete]
    ) -> [String: PendingDelete] {
        deletes.filter { identity, delete in
            guard let key = deleteKey(identity),
                  let scope = delete.scopeIdentity,
                  !delete.operationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return identity == deleteIdentity(key: key, scope: scope.scope)
                && keys.contains(key)
        }
    }

    private static func message(for error: Error) -> String {
        let mapped = SettingsAPIError.from(error)
        switch mapped {
        case .serverUpgradeRequired, .unknownSetting:
            return "Update this Silo server to sync interface preferences."
        default:
            return mapped.writeFailure == .release
                ? "The server didn't accept this change, so it wasn't saved."
                : "Saved on this device. Sync will resume when the server is reachable."
        }
    }
}
