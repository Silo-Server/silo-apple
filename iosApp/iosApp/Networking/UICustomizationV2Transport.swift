import Foundation
import CryptoKit

/// New interface intents use a separate durable outbox and cache namespace.
/// The legacy cache is read only, including every old pending operation byte.
final class SiloUICustomizationTransport: UICustomizationTransport, @unchecked Sendable {
    private let api: SiloAPI
    private let tokens: TokenStore
    private let defaults: SharedDefaults
    private let journal: SettingsMutationJournal
    private let dispatcher: SettingsMutationDispatcher
    private let lock = NSLock()
    private var owner: CapturedDurableAccountAuth?

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, defaults: SharedDefaults = .shared,
         journal: SettingsMutationJournal? = nil) {
        self.api = api; self.tokens = tokens; self.defaults = defaults
        let journal = journal ?? SettingsMutationJournal(url: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SettingsV2/interface-commands.json"))
        self.journal = journal
        dispatcher = SettingsMutationDispatcher(journal: journal, tokens: tokens, api: api)
    }

    func authority(for identity: HTTPRequestIdentity) -> SettingsMutationAuthority? {
        guard let auth = lock.withLock({ owner }), let authority = try? SettingsMutationAuthority(auth),
              authority.serverID == identity.serverId, authority.origin == identity.serverURL,
              authority.profileID == identity.profileId, authority.clientFamily == identity.clientFamily else { return nil }
        return authority
    }

    func storageKey(for legacyKey: String) -> String? {
        guard let auth = lock.withLock({ owner }), let authority = try? SettingsMutationAuthority(auth),
              Self.legacyKey(authority) == legacyKey,
              let encoded = try? SettingsWireCoding.makeEncoder().encode([
                "server": authority.serverID, "origin": authority.origin, "account": authority.accountID,
                "epoch": authority.accountEpoch.uuidString, "profile": authority.profileID,
                "device": authority.deviceID, "family": authority.clientFamily
              ]) else { return nil }
        let hash = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return "silo.uiCustomizationV2.\(hash)"
    }

    private static func legacyKey(_ authority: SettingsMutationAuthority) -> String {
        "silo.uiCustomization.\(authority.serverID).\(authority.profileID).\(authority.clientFamily)"
    }

    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        guard let auth = await tokens.captureDurableAccountAuth(),
              let authority = try? SettingsMutationAuthority(auth),
              authority.serverID == requestIdentity.serverId, authority.origin == requestIdentity.serverURL,
              authority.profileID == requestIdentity.profileId, authority.clientFamily == requestIdentity.clientFamily else {
            return .failed(.transport(description: HTTPError.requestIdentityChanged.localizedDescription))
        }
        let result = await api.getContractCapabilities(requestIdentity: requestIdentity)
        guard let current = await tokens.captureDurableAccountAuth(),
              (try? SettingsMutationAuthority(current)) == authority else { return .failed(.transport(description: HTTPError.requestIdentityChanged.localizedDescription)) }
        lock.withLock { owner = auth }
        return result
    }

    func effectiveValues(keys: [SettingKey], requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        guard let captured = authority(for: requestIdentity) else { throw SettingsMutationHold.noAuthority }
        let requested = Set(keys.map(\.rawValue))
        for command in try journal.snapshot() where command.authority.sameDurableOwner(as: captured)
            && requested.contains(command.key) && command.state == .prepared {
            try await send(id: command.id.uuidString, identity: requestIdentity)
        }
        if let held = try journal.snapshot().first(where: {
            $0.authority.sameDurableOwner(as: captured) && requested.contains($0.key) && $0.state != .applied
        }) { throw held.state == .legacyHeld ? SettingsMutationHold.legacy : SettingsMutationHold.uncertain }
        let response = try await api.getEffectiveValues(keys: keys, profileId: captured.profileID, requestIdentity: requestIdentity)
        try await requireCurrent(captured)
        return response
    }

    func isCurrent(_ authority: SettingsMutationAuthority?) async -> Bool {
        guard let authority else { return false }
        return (try? await requireCurrent(authority)) != nil
    }

    private func requireCurrent(_ authority: SettingsMutationAuthority) async throws {
        guard let auth = await tokens.captureDurableAccountAuth(),
              try SettingsMutationAuthority(auth) == authority else { throw HTTPError.requestIdentityChanged }
    }

    func prepareValue(id: String, key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue?,
                      identity: HTTPRequestIdentity) throws {
        guard let authority = authority(for: identity) else { throw SettingsMutationHold.noAuthority }
        let query = scope.queryItems
        let body = try value.map { try SettingsWireCoding.makeEncoder().encode(SettingValueWriteRequest(value: $0)) }
        try prepare(id: id, authority: authority, key: key, path: "/api/v2/settings/values/\(key.rawValue)",
            method: value == nil ? "DELETE" : "PUT", query: query, body: body)
    }

    func prepareShortcut(id: String, item: PrimaryMenuItem, present: Bool, identity: HTTPRequestIdentity) throws {
        guard let authority = authority(for: identity), item.isContractValid else { throw SettingsMutationHold.noAuthority }
        if case .builtin = item { throw SettingsMutationHold.noAuthority }
        struct Body: Encodable { let item: PrimaryMenuItem; let present: Bool }
        try prepare(id: id, authority: authority, key: .navShortcuts,
            path: "/api/v2/settings/values/nav.shortcuts/item", method: "PUT", query: [:],
            body: SettingsWireCoding.makeEncoder().encode(Body(item: item, present: present)))
    }

    private func prepare(id: String, authority: SettingsMutationAuthority, key: SettingKey,
                         path: String, method: String, query: [String: String], body: Data?) throws {
        guard let uuid = UUID(uuidString: id) else { throw SettingsMutationHold.noAuthority }
        try journal.append(SettingsMutationCommand(id: uuid, authority: authority, key: key.rawValue,
            method: method, path: path, query: query, body: body,
            state: legacyBlocks(key: key.rawValue, authority: authority) ? .legacyHeld : .prepared))
    }

    private func legacyBlocks(key: String, authority: SettingsMutationAuthority) -> Bool {
        guard let data = defaults.data(forKey: Self.legacyKey(authority)) else { return false }
        guard let cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        for field in ["pendingSyncWrites", "pendingDeletes", "pendingShortcutOperations"] {
            if let value = cache[field], !(value is [String: Any]) { return true }
        }
        let writes = cache["pendingSyncWrites"] as? [String: Any] ?? [:]
        let deletes = cache["pendingDeletes"] as? [String: Any] ?? [:]
        let shortcuts = cache["pendingShortcutOperations"] as? [String: Any] ?? [:]
        if writes[key] != nil || deletes.keys.contains(where: { $0.hasPrefix(key + "|") }) { return true }
        return [SettingKey.navShortcuts.rawValue, SettingKey.navPrimaryMenu.rawValue].contains(key)
            && (!shortcuts.isEmpty || writes[SettingKey.navShortcuts.rawValue] != nil)
    }

    func heldIssue(identity: HTTPRequestIdentity) -> String? {
        guard let authority = authority(for: identity) else { return nil }
        if [SettingKey.navShortcuts, .navPrimaryMenu, .uiCardPresentation].contains(where: {
            legacyBlocks(key: $0.rawValue, authority: authority)
        }) { return SettingsMutationHold.legacy.localizedDescription }
        guard let commands = try? journal.snapshot() else { return SettingsMutationHold.uncertain.localizedDescription }
        return commands.contains { $0.authority.sameDurableOwner(as: authority) && [.uncertain, .legacyHeld].contains($0.state) }
            ? SettingsMutationHold.uncertain.localizedDescription : nil
    }

    /// Prepared predecessors retain their original envelopes. Applied receipts
    /// may finish a cache projection after restart; uncertain commands never resend.
    func send(id: String, identity: HTTPRequestIdentity) async throws {
        guard let uuid = UUID(uuidString: id), let authority = authority(for: identity) else { throw SettingsMutationHold.noAuthority }
        try await requireCurrent(authority)
        let commands = try journal.snapshot()
        guard let index = commands.firstIndex(where: { $0.id == uuid }), commands[index].authority.sameDurableOwner(as: authority) else {
            throw SettingsMutationHold.legacy
        }
        do {
            for command in commands[...index] where command.authority.sameDurableOwner(as: authority) && command.state == .prepared {
                // Only predecessors of this setting belong to this dispatch.
                if command.sameTarget(as: commands[index]) { try await dispatcher.send(command.id) }
            }
            guard try journal.snapshot().first(where: { $0.id == uuid })?.state == .applied else {
                throw commands[index].state == .legacyHeld ? SettingsMutationHold.legacy : SettingsMutationHold.uncertain
            }
            try await requireCurrent(authority)
        } catch is SettingsMutationHold { throw SettingsMutationHold.uncertain }
        catch { throw SettingsMutationHold.uncertain }
    }

    func putShortcutItem(_ item: PrimaryMenuItem, present: Bool, mutationId: String,
                         requestIdentity: HTTPRequestIdentity) async throws {
        try await send(id: mutationId, identity: requestIdentity)
    }

    func putValue(key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
                  mutationId: String, requestIdentity: HTTPRequestIdentity) async throws {
        try await send(id: mutationId, identity: requestIdentity)
    }

    func deleteValue(key: SettingKey, scope: SettingScopeIdentity, requestIdentity: HTTPRequestIdentity) async throws {
        // Production deletion requires the command identity captured by the UI.
        throw SettingsMutationHold.noAuthority
    }
}
