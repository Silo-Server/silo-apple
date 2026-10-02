//
//  EpisodeSpoilerPreferences.swift
//  Silo (iOS + tvOS + macOS)
//
//  The active profile's spoiler switches, read from and written to the server
//  at `scope=profile`. Every surface that shows an episode still or
//  description reads `settings` from here, so a change reaches open screens
//  without a reload.
//
//  Servers below contract revision 16 do not serve the keys: both switches
//  read as off, the settings rows stay hidden, and the server never receives
//  a write. The switches have never been stored on the device.
//
//  Like the skip intervals, a change made on another device arrives at the
//  next refresh point: app launch, server or profile switch, return to the
//  foreground, or opening playback settings.
//

import Foundation

// MARK: - Contract

enum EpisodeSpoilerContract {
    static let keys: [SettingKey] = [
        .catalogHideUnwatchedEpisodeImages,
        .catalogHideUnwatchedEpisodeOverviews,
    ]

    static func isSupported(by capabilities: APIv2SettingsContractCapabilities) -> Bool {
        keys.allSatisfy(capabilities.supports)
    }

    /// Both keys default to false; anything that is not a boolean reads as
    /// the default.
    static func resolve(_ response: EffectiveSettingValuesResponse) -> EpisodeSpoilerSettings {
        EpisodeSpoilerSettings(
            hidesImages: response.byKey[.catalogHideUnwatchedEpisodeImages]?.value.boolValue ?? false,
            hidesOverviews: response.byKey[.catalogHideUnwatchedEpisodeOverviews]?.value.boolValue ?? false
        )
    }
}

enum EpisodeSpoilerSetting: CaseIterable, Sendable {
    case images
    case overviews

    var key: SettingKey {
        switch self {
        case .images: return .catalogHideUnwatchedEpisodeImages
        case .overviews: return .catalogHideUnwatchedEpisodeOverviews
        }
    }
}

extension EpisodeSpoilerSettings {
    subscript(setting: EpisodeSpoilerSetting) -> Bool {
        get { setting == .images ? hidesImages : hidesOverviews }
        set {
            switch setting {
            case .images: hidesImages = newValue
            case .overviews: hidesOverviews = newValue
            }
        }
    }
}

// MARK: - State

enum EpisodeSpoilerSyncState: Equatable, Sendable {
    case checking
    case supported
    case serverUpgradeRequired
    case unavailable

    var userMessage: String? {
        switch self {
        case .checking:
            return "Checking whether this server supports spoiler settings…"
        case .supported, .serverUpgradeRequired:
            // An older server hides the rows entirely.
            return nil
        case .unavailable:
            return "Spoiler settings can be changed once this server is reachable."
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class EpisodeSpoilerPreferences {
    static let shared = EpisodeSpoilerPreferences()

    /// Server-resolved switches for the active profile, live or from the last
    /// successful read. `nil` means no server answer applies and nothing is
    /// hidden.
    private(set) var values: EpisodeSpoilerSettings?
    private(set) var syncState: EpisodeSpoilerSyncState = .checking
    private(set) var isSaving = false
    private(set) var writeErrors: [SettingKey: String] = [:]
    private(set) var readErrorMessage: String?

    /// What every surface applies right now. Off until a server that serves
    /// both keys has answered for this profile.
    var settings: EpisodeSpoilerSettings { currentValues() ?? .off }
    /// The settings rows appear only for a server known to serve the keys, or
    /// while a cached answer from one is on screen.
    var showsSettings: Bool { syncState == .supported || values != nil }
    var allowsEditing: Bool { syncState == .supported && values != nil }
    var statusMessage: String? { readErrorMessage ?? syncState.userMessage }

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let transport: ProfileScopedSettingTransport
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var loadedCacheKey: String?
    /// Last value the server confirmed per key; a failed write rolls back to it.
    @ObservationIgnored private var confirmed: [SettingKey: Bool] = [:]
    @ObservationIgnored private var latestWriteGeneration: [SettingKey: Int] = [:]
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var localMutationRevision = 0
    /// Writes still in flight, per profile cache key.
    @ObservationIgnored private var pendingWrites: [String: Int] = [:]
    /// Writes that finished, per profile cache key. A read that saw one of its
    /// profile's writes settle may carry the value from before that write.
    @ObservationIgnored private var settledWrites: [String: Int] = [:]
    @ObservationIgnored private var writeTail: Task<Void, Never>?

    private struct OperationContext: Equatable {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    private struct Cache: Codable {
        let values: EpisodeSpoilerSettings
    }

    init(
        defaults: SharedDefaults = .shared,
        transport: ProfileScopedSettingTransport = SiloProfileScopedSettingTransport(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? =
            SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.defaults = defaults
        self.transport = transport
        self.requestIdentity = requestIdentity
        loadCache(for: requestIdentity().map(Self.cacheKey(for:)))
    }

    // MARK: Reading

    /// `values` belongs to the identity it was loaded for. After a profile or
    /// server switch, and until a refresh adopts the new identity, use that
    /// identity's cached answer, never the previous profile's.
    private func currentValues() -> EpisodeSpoilerSettings? {
        let key = requestIdentity().map(Self.cacheKey(for:))
        guard key != loadedCacheKey else { return values }
        return key.flatMap(cachedValues(for:))
    }

    // MARK: Refresh

    /// Repaint from the active profile's cache, then reconcile with the
    /// server. A failed probe keeps the last answer; an older server drops it
    /// so nothing is hidden and the rows disappear.
    func refresh() async {
        guard let identity = requestIdentity() else {
            loadCache(for: nil)
            syncState = .unavailable
            return
        }
        let context = OperationContext(
            cacheKey: Self.cacheKey(for: identity),
            requestIdentity: identity
        )
        loadCache(for: context.cacheKey)
        refreshSequence += 1
        let sequence = refreshSequence
        let mutationRevision = localMutationRevision
        let settledBefore = settledWrites[context.cacheKey, default: 0]
        if syncState != .supported {
            syncState = .checking
        }
        readErrorMessage = nil

        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard refreshSequence == sequence, isCurrent(context) else { return }
        switch capabilities {
        case .available(let capabilities) where EpisodeSpoilerContract.isSupported(by: capabilities):
            syncState = .supported
        case .available, .serverUpgradeRequired:
            syncState = .serverUpgradeRequired
            clearServerValues(cacheKey: context.cacheKey)
            return
        case .unavailable, .failed:
            // Not a verdict about the server's version: keep the last answer.
            syncState = .unavailable
            return
        }

        do {
            let response = try await transport.effectiveValues(
                keys: EpisodeSpoilerContract.keys,
                requestIdentity: identity
            )
            guard refreshSequence == sequence, isCurrent(context) else { return }
            // A write made or settled while this refresh ran is newer than the
            // answer; keep it and let the next refresh reconcile.
            guard localMutationRevision == mutationRevision,
                  settledWrites[context.cacheKey, default: 0] == settledBefore,
                  pendingWrites[context.cacheKey, default: 0] == 0 else { return }
            let resolved = EpisodeSpoilerContract.resolve(response)
            for setting in EpisodeSpoilerSetting.allCases {
                confirmed[setting.key] = resolved[setting]
            }
            writeErrors = [:]
            values = resolved
            persistConfirmed(cacheKey: context.cacheKey)
        } catch {
            guard refreshSequence == sequence, isCurrent(context) else { return }
            if SettingsAPIError.from(error) == .serverUpgradeRequired {
                syncState = .serverUpgradeRequired
                clearServerValues(cacheKey: context.cacheKey)
            } else {
                readErrorMessage = values == nil
                    ? "Couldn't load spoiler settings from the server."
                    : "Couldn't refresh spoiler settings. Showing the last saved values."
            }
        }
    }

    // MARK: Writing

    /// Saves one switch at profile scope. Ignored unless the server serves
    /// the keys and has answered at least once, so an older server never
    /// receives a write.
    func set(_ setting: EpisodeSpoilerSetting, to isOn: Bool) {
        guard allowsEditing,
              var next = values,
              let identity = requestIdentity() else { return }
        let context = OperationContext(
            cacheKey: Self.cacheKey(for: identity),
            requestIdentity: identity
        )
        guard context.cacheKey == loadedCacheKey, next[setting] != isOn else { return }

        let key = setting.key
        next[setting] = isOn
        localMutationRevision += 1
        let generation = localMutationRevision
        latestWriteGeneration[key] = generation
        writeErrors[key] = nil
        values = next

        pendingWrites[context.cacheKey, default: 0] += 1
        isSaving = true
        let prior = writeTail
        // Serialized so two quick flips of one switch reach the server in the
        // order the user made them.
        writeTail = Task { [weak self] in
            await prior?.value
            await self?.performWrite(
                setting: setting,
                isOn: isOn,
                generation: generation,
                context: context
            )
        }
    }

    /// Resolves once every queued write has finished. For tests.
    func waitForPendingWrites() async {
        await writeTail?.value
    }

    private func performWrite(
        setting: EpisodeSpoilerSetting,
        isOn: Bool,
        generation: Int,
        context: OperationContext
    ) async {
        let key = setting.key
        defer {
            pendingWrites[context.cacheKey] = max(0, pendingWrites[context.cacheKey, default: 0] - 1)
            settledWrites[context.cacheKey, default: 0] += 1
            isSaving = pendingWrites[loadedCacheKey ?? "", default: 0] > 0
        }
        do {
            try await transport.putProfileValue(
                key: key,
                value: .bool(isOn),
                requestIdentity: context.requestIdentity
            )
            guard isCurrent(context) else { return }
            confirmed[key] = isOn
            persistConfirmed(cacheKey: context.cacheKey)
            if latestWriteGeneration[key] == generation {
                writeErrors[key] = nil
            }
        } catch {
            guard isCurrent(context), latestWriteGeneration[key] == generation else { return }
            writeErrors[key] = Self.writeFailureMessage(setting: setting, error: error)
            guard var rolledBack = values, let confirmedValue = confirmed[key] else { return }
            rolledBack[setting] = confirmedValue
            values = rolledBack
        }
    }

    // MARK: Cache and identity

    /// Caches the values the server confirmed. A choice still in flight is
    /// shown but not cached.
    private func persistConfirmed(cacheKey: String) {
        guard var cached = values else { return }
        for setting in EpisodeSpoilerSetting.allCases {
            if let value = confirmed[setting.key] {
                cached[setting] = value
            }
        }
        if let data = try? JSONEncoder().encode(Cache(values: cached)) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private func clearServerValues(cacheKey: String) {
        confirmed = [:]
        writeErrors = [:]
        values = nil
        defaults.removeObject(forKey: cacheKey)
    }

    private func loadCache(for key: String?) {
        guard key != loadedCacheKey else { return }
        loadedCacheKey = key
        isSaving = pendingWrites[key ?? "", default: 0] > 0
        syncState = .checking
        readErrorMessage = nil
        writeErrors = [:]
        latestWriteGeneration = [:]
        confirmed = [:]
        values = key.flatMap(cachedValues(for:))
        if let values {
            for setting in EpisodeSpoilerSetting.allCases {
                confirmed[setting.key] = values[setting]
            }
        }
    }

    private func cachedValues(for key: String) -> EpisodeSpoilerSettings? {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            .map(\.values)
    }

    private func isCurrent(_ context: OperationContext) -> Bool {
        guard let identity = requestIdentity() else { return false }
        return identity == context.requestIdentity
            && loadedCacheKey == context.cacheKey
    }

    static func writeFailureMessage(setting: EpisodeSpoilerSetting, error: Error) -> String {
        let name = setting == .images ? "image setting" : "description setting"
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't save the \(name). Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting:
            return "This server can't save the \(name)."
        default:
            return "The server didn't save the \(name). Try again."
        }
    }

    static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "silo.episodeSpoilers.\(identity.serverId).\(identity.profileId)"
    }
}
