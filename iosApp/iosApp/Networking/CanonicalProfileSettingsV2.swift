import Foundation

/// Immediate canonical settings intents share one durable target barrier across
/// profile editors, overlays, and onboarding. No uncertain command is replayed.
final class CanonicalProfileSettingsV2: @unchecked Sendable {
    private let api: SiloAPI
    private let tokens: TokenStore
    private let journal: SettingsMutationJournal
    private let dispatcher: SettingsMutationDispatcher
    private let defaults: UserDefaults

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, journal: SettingsMutationJournal? = nil,
         defaults: UserDefaults = .standard) {
        self.api = api
        self.tokens = tokens
        self.defaults = defaults
        let journal = journal ?? SettingsMutationJournal.sharedCanonical
        self.journal = journal
        dispatcher = SettingsMutationDispatcher(journal: journal, tokens: tokens, api: api)
    }

    func capture() async throws -> CapturedDurableAccountAuth {
        guard let auth = await tokens.captureDurableAccountAuth() else { throw SettingsMutationHold.noAuthority }
        _ = try SettingsMutationAuthority(auth)
        return auth
    }

    func requireCurrent(_ auth: CapturedDurableAccountAuth) async throws {
        guard let current = await tokens.captureDurableAccountAuth(),
              try SettingsMutationAuthority(current) == SettingsMutationAuthority(auth),
              await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth.request) != nil else {
            throw HTTPError.requestIdentityChanged
        }
    }

    func read(_ keys: [SettingKey], owner: CapturedDurableAccountAuth) async throws -> EffectiveSettingValuesResponse {
        try await requireCurrent(owner)
        let authority = try SettingsMutationAuthority(owner)
        let requested = Set(keys.map(\.rawValue))
        if let held = try journal.snapshot().first(where: {
            $0.authority.sameDurableOwner(as: authority) && requested.contains($0.key) && $0.state != .applied
        }) { throw held.state == .legacyHeld ? SettingsMutationHold.legacy : SettingsMutationHold.uncertain }
        let response = try await api.getEffectiveValues(keys: keys, profileId: authority.profileID,
            requestIdentity: HTTPRequestIdentity(serverId: authority.serverID, serverURL: authority.origin,
                profileId: authority.profileID, clientFamily: authority.clientFamily))
        try await requireCurrent(owner)
        return response
    }

    func prepare(key: SettingKey, value: SettingJSONValue?, scope: SettingScope = .profile,
                 owner: CapturedDurableAccountAuth, id: UUID = UUID()) async throws -> UUID {
        try await requireCurrent(owner)
        guard scope == .profile || scope == .profileDevice else { throw SettingsMutationHold.noAuthority }
        let body = try value.map { try SettingsWireCoding.makeEncoder().encode(SettingValueWriteRequest(value: $0)) }
        let authority = try SettingsMutationAuthority(owner)
        try journal.append(SettingsMutationCommand(id: id, authority: authority,
            key: key.rawValue, method: value == nil ? "DELETE" : "PUT",
            path: "/api/v2/settings/values/\(key.rawValue)", query: ["scope": scope.rawValue],
            body: body, state: legacyBlocks(key, scope: scope, authority: authority) ? .legacyHeld : .prepared))
        return id
    }

    /// Legacy own-device intents remain read-only barriers, never converted.
    private func legacyBlocks(_ key: SettingKey, scope: SettingScope, authority: SettingsMutationAuthority) -> Bool {
        guard scope == .profileDevice else { return false }
        let prefix = "player.pendingDeviceSettingWrites."
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(name.dropFirst(prefix.count))),
                  let raw = String(data: decoded, encoding: .utf8) else { continue }
            let parts = raw.components(separatedBy: "|")
            guard parts.count == 3, ServerRegistry.normalize(url: parts[0]) == authority.origin,
                  parts[1] == authority.profileID, parts[2] == authority.deviceID else { continue }
            guard let data = defaults.data(forKey: name),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            if entries[key.rawValue] != nil { return true }
        }
        return false
    }

    func send(_ id: UUID, owner: CapturedDurableAccountAuth) async throws {
        try await requireCurrent(owner)
        guard let command = try journal.snapshot().first(where: { $0.id == id }),
              command.authority.sameDurableOwner(as: try SettingsMutationAuthority(owner)) else {
            throw SettingsMutationHold.noAuthority
        }
        // Another canonical caller may have dispatched this prepared envelope
        // through the shared journal. Its validated receipt needs no resend.
        if command.state == .applied { return }
        try await dispatcher.send(id)
        try await requireCurrent(owner)
    }

    func write(key: SettingKey, value: SettingJSONValue?, scope: SettingScope = .profile,
               owner: CapturedDurableAccountAuth, id: UUID = UUID()) async throws {
        let id = try await prepare(key: key, value: value, scope: scope, owner: owner, id: id)
        try await send(id, owner: owner)
    }
}
