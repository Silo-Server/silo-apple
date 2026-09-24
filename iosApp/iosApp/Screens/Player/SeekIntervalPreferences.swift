//
//  SeekIntervalPreferences.swift
//  Silo (iOS + tvOS + macOS)
//
//  The active profile's skip intervals, read from and written to the server at
//  `scope=profile`. Every relative-seek surface asks this store for the
//  interval it should use, so a change here reaches buttons, gestures, remote
//  clicks, and system media controls without restarting playback.
//
//  Servers without revision-9 support keep this build's fixed per-surface
//  intervals and never receive a write. Apple builds before revision 9 stored
//  no interval on the device, so there is nothing to import.
//
//  The Apple app has no events-stream subscriber, so it does not see the
//  server's `user_settings.changed` event. A change made on another device
//  arrives at the next refresh point: app launch, server or profile switch,
//  return to the foreground, opening a video or audiobook, or opening
//  playback settings. Wire `refresh()` to that event once a subscriber exists.
//

import Foundation

// MARK: - Transport

/// The slice of the settings API the seek intervals need. The write scope is
/// baked in at `profile`, the only scope the contract allows for these keys.
protocol SeekIntervalTransport: AnyObject, Sendable {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult
    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse
    func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws
}

final class SiloSeekIntervalTransport: SeekIntervalTransport {
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

    func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.putValue(
            key: key,
            scope: .profile,
            value: value,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }
}

// MARK: - State

enum SeekIntervalSyncState: Equatable, Sendable {
    case checking
    case supported
    case serverUpgradeRequired
    case unavailable

    var userMessage: String? {
        switch self {
        case .checking:
            return "Checking whether this server supports skip interval settings…"
        case .supported:
            return nil
        case .serverUpgradeRequired:
            return "Update this Silo server to choose skip intervals. Playback uses the built-in intervals."
        case .unavailable:
            return "Skip intervals can be changed once this server is reachable."
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class SeekIntervalPreferences {
    static let shared = SeekIntervalPreferences()

    /// Server-resolved intervals for the active profile, live or from the last
    /// successful read. `nil` means no server answer applies, and every
    /// surface keeps its fixed legacy interval.
    private(set) var values: SeekIntervalValues?
    private(set) var syncState: SeekIntervalSyncState = .checking
    private(set) var isSaving = false
    /// Failures are per key so a failed rewind write never hides behind a
    /// successful fast-forward write, or the reverse.
    private(set) var writeErrors: [SettingKey: String] = [:]
    private(set) var readErrorMessage: String?

    var allowsEditing: Bool { syncState == .supported && values != nil }
    var statusMessage: String? { readErrorMessage ?? syncState.userMessage }

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let transport: SeekIntervalTransport
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var loadedCacheKey: String?
    /// Last value the server confirmed per key; a failed write rolls back to
    /// it rather than to an earlier optimistic value that may never have
    /// landed.
    @ObservationIgnored private var confirmed: [SettingKey: Int] = [:]
    @ObservationIgnored private var latestWriteGeneration: [SettingKey: Int] = [:]
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var localMutationRevision = 0
    /// Writes still in flight, per profile cache key.
    @ObservationIgnored private var pendingWrites: [String: Int] = [:]
    /// Writes that finished, successfully or not, per profile cache key. A
    /// read that saw one of its profile's writes settle may carry the value
    /// from before that write. Keyed so another profile's queued write never
    /// fences this profile's refresh.
    @ObservationIgnored private var settledWrites: [String: Int] = [:]
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    @ObservationIgnored private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let onChange: @MainActor () -> Void
    }

    private struct OperationContext: Equatable {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    private struct Cache: Codable {
        let values: SeekIntervalValues
    }

    init(
        defaults: SharedDefaults = .shared,
        transport: SeekIntervalTransport = SiloSeekIntervalTransport(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? =
            SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.defaults = defaults
        self.transport = transport
        self.requestIdentity = requestIdentity
        loadCache(for: requestIdentity().map(Self.cacheKey(for:)))
    }

    // MARK: Reading

    /// The pair a surface should use right now.
    func pair(for surface: SeekIntervalSurface) -> SeekIntervalPair {
        currentValues()?[surface.media] ?? surface.legacy
    }

    /// `values` belongs to the identity it was loaded for. After a profile or
    /// server switch, and until a refresh adopts the new identity, use that
    /// identity's cached answer (or the legacy intervals), never the previous
    /// profile's. Reads only; `refresh()` owns the switch itself.
    private func currentValues() -> SeekIntervalValues? {
        let key = requestIdentity().map(Self.cacheKey(for:))
        guard key != loadedCacheKey else { return values }
        return key.flatMap(cachedValues(for:))
    }

    func seconds(_ direction: SeekDirection, for surface: SeekIntervalSurface) -> Int {
        pair(for: surface)[direction]
    }

    func interval(_ direction: SeekDirection, for surface: SeekIntervalSurface) -> Double {
        Double(seconds(direction, for: surface))
    }

    /// Calls `onChange` on the main actor whenever the resolved intervals may
    /// have changed, for as long as `owner` is alive. For non-view owners such
    /// as system media command bindings that must push new preferred
    /// intervals; SwiftUI views observe ``values`` directly.
    func observe(_ owner: AnyObject, onChange: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil || $0.owner === owner }
        observers.append(Observer(owner: owner, onChange: onChange))
    }

    // MARK: Refresh

    /// Repaint from the active profile's cache, then reconcile with the
    /// server. A failed probe keeps the last answer; an explicitly older
    /// server drops it so surfaces return to their fixed intervals.
    ///
    /// Once this profile is known to be supported, a refresh revalidates in
    /// the background: the pickers stay enabled and a choice made meanwhile
    /// is written, rather than flickering to disabled and dropping it.
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
        // Snapshot before the first suspension: a choice made, or a write that
        // settles, at any point during this refresh is newer than its answer.
        let mutationRevision = localMutationRevision
        let settledBefore = settledWrites[context.cacheKey, default: 0]
        // `loadCache` already reset the state if the identity changed.
        if syncState != .supported {
            syncState = .checking
        }
        readErrorMessage = nil

        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard refreshSequence == sequence, isCurrent(context) else { return }
        switch capabilities {
        case .available(let capabilities) where SeekIntervalContract.isSupported(by: capabilities):
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
                keys: SeekIntervalContract.keys,
                requestIdentity: identity
            )
            guard refreshSequence == sequence, isCurrent(context) else { return }
            // A write made or settled while this refresh ran is newer than the
            // answer; keep it and let the next refresh reconcile.
            guard localMutationRevision == mutationRevision,
                  settledWrites[context.cacheKey, default: 0] == settledBefore,
                  pendingWrites[context.cacheKey, default: 0] == 0 else { return }
            let resolved = SeekIntervalContract.resolve(response)
            for key in SeekIntervalContract.keys {
                confirmed[key] = Self.value(for: key, in: resolved)
            }
            writeErrors = [:]
            apply(resolved, cacheKey: context.cacheKey)
            persistConfirmed(cacheKey: context.cacheKey)
        } catch {
            guard refreshSequence == sequence, isCurrent(context) else { return }
            if SettingsAPIError.from(error) == .serverUpgradeRequired {
                syncState = .serverUpgradeRequired
                clearServerValues(cacheKey: context.cacheKey)
            } else {
                readErrorMessage = values == nil
                    ? "Couldn't load skip intervals from the server."
                    : "Couldn't refresh skip intervals. Showing the last saved values."
            }
        }
    }

    // MARK: Writing

    /// Saves one direction at profile scope. Ignored unless the server
    /// supports the key and has answered at least once, so an older server
    /// never receives a write.
    func setInterval(_ seconds: Int, media: SeekMedia, direction: SeekDirection) {
        guard SeekIntervalContract.isValid(seconds),
              allowsEditing,
              var next = values,
              let identity = requestIdentity() else { return }
        let context = OperationContext(
            cacheKey: Self.cacheKey(for: identity),
            requestIdentity: identity
        )
        guard context.cacheKey == loadedCacheKey, next[media][direction] != seconds else { return }

        let key = SeekIntervalContract.key(media, direction)
        next[media][direction] = seconds
        localMutationRevision += 1
        let generation = localMutationRevision
        latestWriteGeneration[key] = generation
        writeErrors[key] = nil
        apply(next, cacheKey: context.cacheKey)

        pendingWrites[context.cacheKey, default: 0] += 1
        isSaving = true
        let prior = writeTail
        // Serialized so two quick choices for one key reach the server in
        // the order the user made them.
        writeTail = Task { [weak self] in
            await prior?.value
            await self?.performWrite(
                key: key,
                seconds: seconds,
                media: media,
                direction: direction,
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
        key: SettingKey,
        seconds: Int,
        media: SeekMedia,
        direction: SeekDirection,
        generation: Int,
        context: OperationContext
    ) async {
        defer {
            pendingWrites[context.cacheKey] = max(0, pendingWrites[context.cacheKey, default: 0] - 1)
            settledWrites[context.cacheKey, default: 0] += 1
            isSaving = pendingWrites[loadedCacheKey ?? "", default: 0] > 0
        }
        do {
            try await transport.putProfileValue(
                key: key,
                value: .int(seconds),
                requestIdentity: context.requestIdentity
            )
            guard isCurrent(context) else { return }
            confirmed[key] = seconds
            persistConfirmed(cacheKey: context.cacheKey)
            if latestWriteGeneration[key] == generation {
                writeErrors[key] = nil
            }
        } catch {
            guard isCurrent(context), latestWriteGeneration[key] == generation else { return }
            writeErrors[key] = Self.writeFailureMessage(media: media, direction: direction, error: error)
            guard var rolledBack = values, let confirmedSeconds = confirmed[key] else { return }
            rolledBack[media][direction] = confirmedSeconds
            apply(rolledBack, cacheKey: context.cacheKey)
        }
    }

    // MARK: Cache and identity

    /// Shows `next` on every surface. Only ``persistConfirmed(cacheKey:)``
    /// writes the cache, so an optimistic choice never outlives a relaunch.
    private func apply(_ next: SeekIntervalValues?, cacheKey: String) {
        let changed = values != next
        values = next
        if next == nil {
            defaults.removeObject(forKey: cacheKey)
        }
        if changed { notifyObservers() }
    }

    /// Caches the values the server confirmed. A choice still in flight is
    /// shown but not cached: if the app ends before the write settles, the
    /// next offline launch must not treat it as the profile's setting.
    private func persistConfirmed(cacheKey: String) {
        guard var cached = values else { return }
        for media in SeekMedia.allCases {
            for direction in SeekDirection.allCases {
                if let seconds = confirmed[SeekIntervalContract.key(media, direction)] {
                    cached[media][direction] = seconds
                }
            }
        }
        if let data = try? JSONEncoder().encode(Cache(values: cached)) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private func clearServerValues(cacheKey: String) {
        confirmed = [:]
        writeErrors = [:]
        apply(nil, cacheKey: cacheKey)
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
        let previous = values
        values = key.flatMap(cachedValues(for:))
        if let values {
            for key in SeekIntervalContract.keys {
                confirmed[key] = Self.value(for: key, in: values)
            }
        }
        if previous != values { notifyObservers() }
    }

    private func cachedValues(for key: String) -> SeekIntervalValues? {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            .map(\.values)
            .map(Self.validated)
    }

    private func isCurrent(_ context: OperationContext) -> Bool {
        guard let identity = requestIdentity() else { return false }
        return identity == context.requestIdentity
            && loadedCacheKey == context.cacheKey
    }

    private func notifyObservers() {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.onChange()
        }
    }

    private static func validated(_ values: SeekIntervalValues) -> SeekIntervalValues {
        var result = values
        for media in SeekMedia.allCases {
            for direction in SeekDirection.allCases
            where !SeekIntervalContract.isValid(values[media][direction]) {
                result[media][direction] = SeekIntervalContract.defaultValue(direction)
            }
        }
        return result
    }

    private static func value(for key: SettingKey, in values: SeekIntervalValues) -> Int? {
        for media in SeekMedia.allCases {
            for direction in SeekDirection.allCases
            where SeekIntervalContract.key(media, direction) == key {
                return values[media][direction]
            }
        }
        return nil
    }

    static func writeFailureMessage(
        media: SeekMedia,
        direction: SeekDirection,
        error: Error
    ) -> String {
        let setting = "\(media == .video ? "video" : "audiobook") \(direction == .backward ? "rewind" : "fast-forward") interval"
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't save the \(setting). Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting:
            return "This server can't save the \(setting)."
        default:
            return "The server didn't save the \(setting). Try again."
        }
    }

    static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "silo.seekIntervals.\(identity.serverId).\(identity.profileId)"
    }

    static func activeRequestIdentity() -> HTTPRequestIdentity? {
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
