//
//  ThemeMusicPreferences.swift
//  Silo (iOS + tvOS + macOS)
//
//  Whether title pages play local theme music (`ui.theme_music_enabled`) and
//  whether it repeats (`ui.theme_music_loop`). Both default to off.
//
//  The server resolves each key for this device: its `profile_device` value,
//  then the profile's, then the default. The switches write this device's
//  value, which wins over a profile value, so a change always takes effect
//  here. The client reads the effective answers rather than re-implementing
//  that order.
//
//  Theme music only plays for the identity the answer was read for: after a
//  server or profile switch it stays off until a refresh reads the new
//  profile's choice. Refresh points match title art: launch, server or profile
//  switch, return to the foreground, and opening settings.
//

import Foundation

/// The settings slice theme music needs; the title-art transport already
/// carries any key.
typealias ThemeMusicTransport = TitleArtTransport

struct ThemeMusicSetting: Equatable, Sendable {
    var enabled: Bool
    var loop: Bool

    init(enabled: Bool, loop: Bool) {
        self.enabled = enabled
        self.loop = loop
    }

    /// A missing or malformed row is the contract default, off.
    init(effective response: EffectiveSettingValuesResponse) {
        func flag(_ key: SettingKey) -> Bool {
            guard case .bool(let value)? = response.value(for: key)?.value else { return false }
            return value
        }
        enabled = flag(.uiThemeMusicEnabled)
        loop = flag(.uiThemeMusicLoop)
    }
}

@MainActor
@Observable
final class ThemeMusicPreferences {
    static let shared = ThemeMusicPreferences()

    static let keys: [SettingKey] = [.uiThemeMusicEnabled, .uiThemeMusicLoop]

    /// The answer for ``loadedIdentity``; nil before one arrives or on a
    /// server without the keys.
    private(set) var setting: ThemeMusicSetting?
    private(set) var errorMessage: String?
    /// Observed so views re-render when a refresh adopts another identity.
    private var loadedIdentity: HTTPRequestIdentity?

    /// Whether title pages may play theme music right now.
    var playsThemeMusic: Bool { currentSetting?.enabled ?? false }
    var loops: Bool { currentSetting?.loop ?? false }
    /// Whether settings should show the switches.
    var isOffered: Bool { setting != nil }
    var allowsEditing: Bool { currentSetting != nil }

    @ObservationIgnored private let transport: ThemeMusicTransport
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    /// The last answer the server confirmed; a failed write rolls back to it.
    @ObservationIgnored private var confirmed: ThemeMusicSetting?
    @ObservationIgnored private var refreshSequence = 0
    /// Per identity, so a write still in flight for one profile never holds
    /// back the next profile's read.
    @ObservationIgnored private var pendingWrites: [String: Int] = [:]
    @ObservationIgnored private var writeTail: Task<Void, Never>?

    init(
        transport: ThemeMusicTransport = SiloTitleArtTransport(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = TitleArtPreferences.activeRequestIdentity
    ) {
        self.transport = transport
        self.requestIdentity = requestIdentity
    }

    private var currentSetting: ThemeMusicSetting? {
        let loaded = setting
        guard let identity = requestIdentity(), identity == loadedIdentity else { return nil }
        return loaded
    }

    // MARK: Refresh

    func refresh() async {
        guard let identity = requestIdentity() else {
            adopt(nil, for: nil)
            return
        }
        if identity != loadedIdentity { adopt(nil, for: identity) }
        refreshSequence += 1
        let sequence = refreshSequence
        let capabilities = await transport.contractCapabilities(requestIdentity: identity)
        guard sequence == refreshSequence, requestIdentity() == identity else { return }
        switch capabilities {
        case .available(let capabilities) where capabilities.supports(.uiThemeMusicEnabled)
            && capabilities.supports(.uiThemeMusicLoop):
            break
        case .available, .serverUpgradeRequired:
            adopt(nil, for: identity)
            return
        case .unavailable, .failed:
            // Keep the last answer for this identity; nothing new to read.
            return
        }
        await read(identity: identity, sequence: sequence)
    }

    private func read(identity: HTTPRequestIdentity, sequence: Int) async {
        guard pendingWrites[identity.profileKey, default: 0] == 0 else { return }
        guard let response = try? await transport.effectiveValues(keys: Self.keys, requestIdentity: identity) else { return }
        guard sequence == refreshSequence, requestIdentity() == identity,
              pendingWrites[identity.profileKey, default: 0] == 0 else { return }
        adopt(ThemeMusicSetting(effective: response), for: identity)
    }

    private func adopt(_ value: ThemeMusicSetting?, for identity: HTTPRequestIdentity?) {
        loadedIdentity = identity
        setting = value
        confirmed = value
        errorMessage = nil
    }

    /// Forget every answer: sign-out, or an identity-scoped reset.
    func reset() {
        refreshSequence += 1
        adopt(nil, for: nil)
    }

    // MARK: Writing

    func setEnabled(_ isOn: Bool) {
        write(.uiThemeMusicEnabled, isOn) { $0.enabled = isOn }
    }

    func setLoop(_ isOn: Bool) {
        write(.uiThemeMusicLoop, isOn) { $0.loop = isOn }
    }

    /// Resolves once every queued write, and the read-back after them, has finished. For tests.
    func waitForPendingWrites() async {
        var awaited: Task<Void, Never>?
        repeat {
            awaited = writeTail
            await awaited?.value
        } while writeTail != awaited
    }

    private func write(_ key: SettingKey, _ value: Bool, apply: (inout ThemeMusicSetting) -> Void) {
        guard var next = currentSetting, let identity = loadedIdentity else { return }
        apply(&next)
        guard next != setting else { return }
        setting = next
        errorMessage = nil
        pendingWrites[identity.profileKey, default: 0] += 1
        let prior = writeTail
        // Serialized so quick changes reach the server in the order made.
        writeTail = Task { [weak self] in
            await prior?.value
            await self?.perform(key: key, value: value, identity: identity)
        }
    }

    private func perform(key: SettingKey, value: Bool, identity: HTTPRequestIdentity) async {
        do {
            try await transport.putValue(key: key, scope: .profileDevice, value: .bool(value), requestIdentity: identity)
        } catch {
            pendingWrites[identity.profileKey, default: 0] -= 1
            guard requestIdentity() == identity, loadedIdentity == identity else { return }
            // Roll back only the key that failed; a queued change to the other one stands.
            if key == .uiThemeMusicEnabled {
                setting?.enabled = confirmed?.enabled ?? false
            } else {
                setting?.loop = confirmed?.loop ?? false
            }
            errorMessage = Self.writeFailureMessage(for: error)
            return
        }
        pendingWrites[identity.profileKey, default: 0] -= 1
        guard requestIdentity() == identity, loadedIdentity == identity else { return }
        if key == .uiThemeMusicEnabled { confirmed?.enabled = value } else { confirmed?.loop = value }
        // The last queued change landed: adopt what the server now resolves.
        guard pendingWrites[identity.profileKey, default: 0] == 0 else { return }
        refreshSequence += 1
        await read(identity: identity, sequence: refreshSequence)
    }

    static func writeFailureMessage(for error: Error) -> String {
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't save the theme music setting. Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting, .scopeNotAllowed:
            return "This server can't save the theme music setting."
        default:
            return "The server didn't save the theme music setting. Try again."
        }
    }
}

extension HTTPRequestIdentity {
    /// One account's profile on one server, as a key. Profile IDs repeat
    /// across accounts.
    var profileKey: String { "\(serverId)/\(localAccountId ?? "")/\(profileId)" }
}
