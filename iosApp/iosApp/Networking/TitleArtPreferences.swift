//
//  TitleArtPreferences.swift
//  Silo (iOS + tvOS + macOS)
//
//  Whether title pages name a title with its logo artwork (`ui.title_art`).
//
//  The server resolves the key for this device: `profile` first, then this
//  device's `profile_device` value, then the default (on). A profile value is
//  the profile's "apply to all devices" choice, so the companion switch's state
//  is simply whether the effective answer came from `profile`. The client never
//  re-implements that precedence; it reads the effective value and source.
//
//  Writes follow the manifest notes on `ui.title_art`:
//  - the main switch writes `profile` while applying to all devices, and this
//    device's `profile_device` value otherwise;
//  - turning "Apply to All Devices" on writes the current value at `profile`;
//  - turning it off first writes the current value at `profile_device`, so
//    this device keeps its look, then clears the `profile` value (a 404 there
//    already is the state asked for).
//
//  Every surface that can show logo art (detail heroes, the tvOS marquee, logo
//  prefetch) reads ``showsTitleArt`` from this one store. An unknown answer, an
//  older server, or no signed-in profile all resolve to logos on, which is how
//  every build behaved before the key existed. The last confirmed answer is
//  cached per server and profile so a cold launch paints the right title on its
//  first frame instead of flashing a logo the profile turned off.
//
//  Refresh points: launch, server or profile switch, return to the foreground,
//  and opening the settings screen. The Apple app has no events-stream
//  subscriber yet, so a change made on another device arrives at the next one.
//

import Foundation

// MARK: - Transport

/// The slice of the settings API title art needs.
protocol TitleArtTransport: AnyObject, Sendable {
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
    /// Throws ``SettingsAPIError/noValueAtScope`` when nothing was stored.
    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws
}

final class SiloTitleArtTransport: TitleArtTransport {
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
        try await api.getEffectiveValues(keys: keys, requestIdentity: requestIdentity)
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.putValue(
            key: key,
            scope: scope,
            value: value,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await api.deleteValue(
            key: key,
            scope: scope,
            profileId: requestIdentity.profileId,
            requestIdentity: requestIdentity
        )
    }
}

// MARK: - Value

/// The resolved title-art choice for this device.
struct TitleArtSetting: Codable, Equatable, Sendable {
    var showTitleArt: Bool
    /// True when the answer is the profile's value, which wins on every device.
    var appliesToAllDevices: Bool

    /// Logos on and per-device: the contract default before anyone chose.
    static let contractDefault = TitleArtSetting(showTitleArt: true, appliesToAllDevices: false)

    /// Reads the server's effective answer. A missing or malformed row is the
    /// contract default rather than an error, matching how the server answers
    /// for a profile that never chose.
    init(effective row: EffectiveSettingValue?) {
        guard let row, case .bool(let value) = row.value else {
            self = .contractDefault
            return
        }
        showTitleArt = value
        appliesToAllDevices = row.source == .scope(.profile)
    }

    init(showTitleArt: Bool, appliesToAllDevices: Bool) {
        self.showTitleArt = showTitleArt
        self.appliesToAllDevices = appliesToAllDevices
    }
}

/// One server step of a title-art change.
enum TitleArtWriteStep: Equatable, Sendable {
    case put(scope: SettingScope, value: Bool)
    case clear(scope: SettingScope)
}

enum TitleArtWritePlan {
    /// The writes that turn `current` into the choice the user just made.
    /// Pure so the scope choice and ordering are testable on their own.
    static func steps(
        from current: TitleArtSetting,
        showTitleArt: Bool? = nil,
        appliesToAllDevices: Bool? = nil
    ) -> [TitleArtWriteStep] {
        if let showTitleArt {
            return [.put(scope: current.appliesToAllDevices ? .profile : .profileDevice, value: showTitleArt)]
        }
        guard let appliesToAllDevices, appliesToAllDevices != current.appliesToAllDevices else {
            return []
        }
        if appliesToAllDevices {
            return [.put(scope: .profile, value: current.showTitleArt)]
        }
        // Pin this device first so it keeps its look once the profile value
        // stops winning; other devices fall back to their own values.
        return [
            .put(scope: .profileDevice, value: current.showTitleArt),
            .clear(scope: .profile),
        ]
    }
}

// MARK: - State

enum TitleArtSyncState: Equatable, Sendable {
    case checking
    case supported
    /// The server's contract predates `ui.title_art` (revision 16).
    case serverUpgradeRequired
    case unavailable
}

// MARK: - Store

@MainActor
@Observable
final class TitleArtPreferences {
    static let shared = TitleArtPreferences()

    /// The server's answer for the loaded identity, live or from the last
    /// confirmed read. `nil` means no answer applies (never read, or a server
    /// without the key), and every surface shows logos as before.
    private(set) var setting: TitleArtSetting?
    private(set) var syncState: TitleArtSyncState = .checking
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    /// Whether title pages may show logo art right now. Display surfaces read
    /// only this.
    var showsTitleArt: Bool { currentSetting()?.showTitleArt ?? true }

    var appliesToAllDevices: Bool { currentSetting()?.appliesToAllDevices ?? false }

    /// Whether settings should offer the switches: the server knows the key,
    /// or it did at the last confirmed read and this refresh has not yet said
    /// otherwise.
    var isOffered: Bool {
        switch syncState {
        case .supported: return setting != nil
        case .checking, .unavailable: return setting != nil
        case .serverUpgradeRequired: return false
        }
    }

    var allowsEditing: Bool { syncState == .supported && setting != nil }

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let transport: TitleArtTransport
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    /// Observed on purpose: a view that answered from another identity's cache
    /// (``currentSetting()``) must re-render once a refresh adopts that identity.
    private var loadedCacheKey: String?
    /// The last answer the server confirmed; a failed change rolls back here.
    @ObservationIgnored private var confirmed: TitleArtSetting?
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var localMutationRevision = 0
    @ObservationIgnored private var pendingWrites: [String: Int] = [:]
    @ObservationIgnored private var settledWrites: [String: Int] = [:]
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    /// Per profile cache key, bumped when a queued change for that profile
    /// fails. Every change for the same profile queued behind it was planned
    /// from the optimistic state the failure just disproved, so those changes
    /// are dropped rather than sent. Other profiles' changes are unaffected.
    @ObservationIgnored private var failureEpochs: [String: Int] = [:]

    private struct OperationContext: Equatable {
        let cacheKey: String
        let requestIdentity: HTTPRequestIdentity
    }

    init(
        defaults: SharedDefaults = .shared,
        transport: TitleArtTransport = SiloTitleArtTransport(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? =
            TitleArtPreferences.activeRequestIdentity
    ) {
        self.defaults = defaults
        self.transport = transport
        self.requestIdentity = requestIdentity
        loadCache(for: requestIdentity().map(Self.cacheKey(for:)))
    }

    /// The answer for the active identity. After a profile or server switch,
    /// and until a refresh adopts it, use that identity's cached answer, never
    /// the previous profile's.
    private func currentSetting() -> TitleArtSetting? {
        // Both observed properties are read on every path, so a view that took
        // the cached-answer path is still invalidated when a refresh adopts the
        // new identity and replaces `setting`.
        let loaded = setting
        let key = requestIdentity().map(Self.cacheKey(for:))
        guard key != loadedCacheKey else { return loaded }
        return key.flatMap(cachedSetting(for:))
    }

    // MARK: Refresh

    /// Repaint from the active identity's cache, then reconcile with the
    /// server. A failed probe keeps the last answer; a server without the key
    /// drops it so every surface returns to logos.
    func refresh() async {
        guard let identity = requestIdentity() else {
            loadCache(for: nil)
            syncState = .unavailable
            return
        }
        let context = OperationContext(cacheKey: Self.cacheKey(for: identity), requestIdentity: identity)
        loadCache(for: context.cacheKey)
        refreshSequence += 1
        let sequence = refreshSequence
        let mutationRevision = localMutationRevision
        let settledBefore = settledWrites[context.cacheKey, default: 0]
        if syncState != .supported {
            syncState = .checking
        }

        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard refreshSequence == sequence, isCurrent(context) else { return }
        switch capabilities {
        case .available(let capabilities) where capabilities.supports(.uiTitleArt):
            syncState = .supported
        case .available, .serverUpgradeRequired:
            syncState = .serverUpgradeRequired
            clearServerValue(cacheKey: context.cacheKey)
            return
        case .unavailable, .failed:
            syncState = .unavailable
            return
        }

        do {
            let response = try await transport.effectiveValues(
                keys: [.uiTitleArt],
                requestIdentity: identity
            )
            guard refreshSequence == sequence, isCurrent(context) else { return }
            // A change made or settled while this read ran is newer than it.
            guard localMutationRevision == mutationRevision,
                  settledWrites[context.cacheKey, default: 0] == settledBefore,
                  pendingWrites[context.cacheKey, default: 0] == 0 else { return }
            let resolved = TitleArtSetting(effective: response.value(for: .uiTitleArt))
            confirmed = resolved
            setting = resolved
            errorMessage = nil
            persist(resolved, cacheKey: context.cacheKey)
        } catch {
            guard refreshSequence == sequence, isCurrent(context) else { return }
            if SettingsAPIError.from(error) == .serverUpgradeRequired {
                syncState = .serverUpgradeRequired
                clearServerValue(cacheKey: context.cacheKey)
            }
            // Any other failure keeps the last answer on screen.
        }
    }

    // MARK: Writing

    func setShowTitleArt(_ isOn: Bool) {
        guard let current = setting, current.showTitleArt != isOn else { return }
        var next = current
        next.showTitleArt = isOn
        enqueue(
            next: next,
            steps: TitleArtWritePlan.steps(from: current, showTitleArt: isOn)
        )
    }

    func setAppliesToAllDevices(_ isOn: Bool) {
        guard let current = setting else { return }
        var next = current
        next.appliesToAllDevices = isOn
        enqueue(
            next: next,
            steps: TitleArtWritePlan.steps(from: current, appliesToAllDevices: isOn)
        )
    }

    /// Resolves once every queued change, and any re-read a failure queued
    /// behind them, has finished. For tests.
    func waitForPendingWrites() async {
        var awaited: Task<Void, Never>?
        repeat {
            awaited = writeTail
            await awaited?.value
        } while writeTail != awaited
    }

    private func enqueue(next: TitleArtSetting, steps: [TitleArtWriteStep]) {
        guard !steps.isEmpty,
              allowsEditing,
              let identity = requestIdentity() else { return }
        let context = OperationContext(cacheKey: Self.cacheKey(for: identity), requestIdentity: identity)
        guard context.cacheKey == loadedCacheKey else { return }

        localMutationRevision += 1
        let epoch = failureEpochs[context.cacheKey, default: 0]
        errorMessage = nil
        setting = next
        pendingWrites[context.cacheKey, default: 0] += 1
        isSaving = true
        let prior = writeTail
        // Serialized so quick changes reach the server in the order made, and
        // so "apply to all devices off" can never interleave its two steps
        // with another change.
        writeTail = Task { [weak self] in
            await prior?.value
            await self?.perform(steps: steps, next: next, epoch: epoch, context: context)
        }
    }

    private func perform(
        steps: [TitleArtWriteStep],
        next: TitleArtSetting,
        epoch: Int,
        context: OperationContext
    ) async {
        defer {
            pendingWrites[context.cacheKey] = max(0, pendingWrites[context.cacheKey, default: 0] - 1)
            settledWrites[context.cacheKey, default: 0] += 1
            isSaving = pendingWrites[loadedCacheKey ?? "", default: 0] > 0
        }
        // An earlier change failed after this one was planned on top of it.
        guard epoch == failureEpochs[context.cacheKey, default: 0] else { return }
        do {
            for step in steps {
                switch step {
                case .put(let scope, let value):
                    try await transport.putValue(
                        key: .uiTitleArt,
                        scope: Self.identity(for: scope),
                        value: .bool(value),
                        requestIdentity: context.requestIdentity
                    )
                case .clear(let scope):
                    do {
                        try await transport.deleteValue(
                            key: .uiTitleArt,
                            scope: Self.identity(for: scope),
                            requestIdentity: context.requestIdentity
                        )
                    } catch SettingsAPIError.noValueAtScope {
                        // Already clear: the state this step asked for.
                    }
                }
            }
            // The server holds this for the change's own profile and server,
            // even if another one became active while it was in flight.
            persist(next, cacheKey: context.cacheKey)
            guard isCurrent(context) else { return }
            confirmed = next
            // The last change still pending for this profile is its final
            // choice. Adopt it: switching away and back repaints the profile's
            // older cache, and the refresh after that skips its read while this
            // write is pending. With newer changes queued, their optimistic
            // value stays on screen until the last one lands. (The defer above
            // has not decremented yet, so 1 means this change only.)
            if pendingWrites[context.cacheKey, default: 0] == 1 {
                setting = next
            }
        } catch {
            // Drop everything queued behind this change: it was planned from a
            // state the server never reached. A later choice is planned afresh
            // from the confirmed state below.
            failureEpochs[context.cacheKey, default: 0] &+= 1
            guard isCurrent(context) else { return }
            let message = Self.writeFailureMessage(for: error)
            errorMessage = message
            setting = confirmed
            // A failed step may have been applied anyway (a lost response, or
            // the first half of "apply to all devices off"), so re-read what
            // the server resolves once the queue drains instead of trusting
            // `confirmed`.
            let prior = writeTail
            writeTail = Task { [weak self] in
                await prior?.value
                await self?.reconcile(afterFailure: message, context: context)
            }
        }
    }

    private func reconcile(afterFailure message: String, context: OperationContext) async {
        await refresh()
        if isCurrent(context), errorMessage == nil {
            errorMessage = message
        }
    }

    // MARK: Cache and identity

    private func persist(_ value: TitleArtSetting, cacheKey: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private func clearServerValue(cacheKey: String) {
        confirmed = nil
        setting = nil
        errorMessage = nil
        defaults.removeObject(forKey: cacheKey)
    }

    private func loadCache(for key: String?) {
        guard key != loadedCacheKey else { return }
        loadedCacheKey = key
        isSaving = pendingWrites[key ?? "", default: 0] > 0
        syncState = .checking
        errorMessage = nil
        setting = key.flatMap(cachedSetting(for:))
        confirmed = setting
    }

    private func cachedSetting(for key: String) -> TitleArtSetting? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TitleArtSetting.self, from: $0) }
    }

    private func isCurrent(_ context: OperationContext) -> Bool {
        requestIdentity() == context.requestIdentity && loadedCacheKey == context.cacheKey
    }

    private static func identity(for scope: SettingScope) -> SettingScopeIdentity {
        scope == .profile ? .profile : .profileDevice
    }

    static func writeFailureMessage(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't save the title art setting. Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting, .scopeNotAllowed:
            return "This server can't save the title art setting."
        default:
            return "The server didn't save the title art setting. Try again."
        }
    }

    static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "silo.titleArt.\(identity.serverId).\(identity.profileId)"
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
