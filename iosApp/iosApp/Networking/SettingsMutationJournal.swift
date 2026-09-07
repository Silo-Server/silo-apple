import Foundation
import CryptoKit
import Observation

/// Nonsecret identity captured with a new settings command. A later login or
/// profile proof cannot take ownership of an earlier command.
struct SettingsMutationAuthority: Codable, Equatable, Sendable {
    let serverID: String
    let origin: String
    let accountID: String
    let accountEpoch: UUID
    let credentialGeneration: UUID
    let profileID: String
    let profileProofHash: String?
    let deviceID: String
    let clientFamily: String

    init(_ auth: CapturedDurableAccountAuth, deviceID: String = AppleDeviceIdentity.current.id,
         clientFamily: String = AppleDeviceIdentity.current.clientFamily) throws {
        guard case .persistentServer = auth.request.credentialOwner,
              let profile = auth.request.profileId, !profile.isEmpty, !deviceID.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        serverID = auth.request.account.serverId
        origin = auth.request.account.serverURL
        accountID = auth.accountID
        accountEpoch = auth.accountEpoch
        credentialGeneration = auth.request.account.credentialGenerationID
        profileID = profile
        profileProofHash = auth.request.profileToken.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        self.deviceID = deviceID
        self.clientFamily = clientFamily
    }

    /// Credential generations and profile proofs are transport snapshots, not
    /// durable queue ownership. A cold TokenStore must still see this target's
    /// unresolved commands under the same persisted account epoch.
    func sameDurableOwner(as other: Self) -> Bool {
        serverID == other.serverID && origin == other.origin && accountID == other.accountID
            && accountEpoch == other.accountEpoch && profileID == other.profileID
            && deviceID == other.deviceID && clientFamily == other.clientFamily
    }

    var legacyPlayerScope: String {
        Data("\(origin)|\(profileID)|\(deviceID)".utf8).base64EncodedString()
    }
}

struct SettingsMutationCommand: Codable, Equatable, Sendable {
    enum State: String, Codable { case prepared, uncertain, legacyHeld, applied }
    let id: UUID
    let authority: SettingsMutationAuthority
    let key: String
    let method: String
    let path: String
    let query: [String: String]
    let body: Data?
    var state: State

    func sameTarget(as other: Self) -> Bool {
        authority.sameDurableOwner(as: other.authority) && path == other.path
            && targetQuery == other.targetQuery
    }

    /// The old explicit own-device query and the declared header address one
    /// target. Normalize only for barriers; stored wire bytes never change.
    private var targetQuery: [String: String] {
        var target = query
        if target["scope"] == "profile_device", target["device_id"] == nil {
            target["device_id"] = authority.deviceID
        }
        return target
    }
}

enum SettingsMutationHold: LocalizedError {
    case legacy, uncertain, noAuthority
    var errorDescription: String? {
        switch self {
        case .legacy: return "An earlier settings change is held for its original owner. It has not been sent again."
        case .uncertain: return "A settings change has an unknown outcome. Further changes to that setting are held."
        case .noAuthority: return "Reload settings for this profile before saving a server preference."
        }
    }
}

/// This journal never opens or rewrites the legacy settings queue. Dispatch is
/// claimed durably before HTTP, so process death cannot turn uncertainty into
/// an automatic retry. Records are retained after receipts for identity checks.
final class SettingsMutationJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) {
        self.url = url
        self.write = write
    }

    private func load() throws -> [SettingsMutationCommand] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SettingsMutationCommand].self, from: Data(contentsOf: url))
    }

    private func save(_ commands: [SettingsMutationCommand]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(commands), url)
    }

    func append(_ command: SettingsMutationCommand) throws {
        try lock.withLock {
            var commands = try load()
            guard !commands.contains(where: { $0.id == command.id }) else { throw SettingsMutationHold.uncertain }
            commands.append(command)
            try save(commands)
        }
    }

    func snapshot() throws -> [SettingsMutationCommand] { try lock.withLock { try load() } }

    func claim(_ id: UUID) throws -> SettingsMutationCommand {
        try lock.withLock {
            var commands = try load()
            guard let index = commands.firstIndex(where: { $0.id == id }) else { throw SettingsMutationHold.uncertain }
            if commands[index].state == .legacyHeld { throw SettingsMutationHold.legacy }
            guard commands[index].state == .prepared,
                  !commands[..<index].contains(where: { $0.state != .applied && $0.sameTarget(as: commands[index]) }) else {
                throw SettingsMutationHold.uncertain
            }
            commands[index].state = .uncertain
            try save(commands)
            return commands[index]
        }
    }

    func acknowledge(_ sent: SettingsMutationCommand) throws {
        try lock.withLock {
            var commands = try load()
            guard let index = commands.firstIndex(where: { $0.id == sent.id }), commands[index] == sent else {
                throw SettingsMutationHold.uncertain
            }
            commands[index].state = .applied
            try save(commands)
        }
    }
}

/// One dispatch of an already persisted command; there is no mutation retry.
actor SettingsMutationDispatcher {
    private let journal: SettingsMutationJournal
    private let tokens: TokenStore
    private let api: SiloAPI

    init(journal: SettingsMutationJournal, tokens: TokenStore = .shared, api: SiloAPI = .shared) {
        self.journal = journal; self.tokens = tokens; self.api = api
    }

    func send(_ id: UUID) async throws {
        guard let saved = try journal.snapshot().first(where: { $0.id == id }),
              let auth = await tokens.captureDurableAccountAuth(),
              try SettingsMutationAuthority(auth).sameDurableOwner(as: saved.authority),
              try SettingsMutationAuthority(auth).profileProofHash == saved.authority.profileProofHash else {
            throw HTTPError.requestIdentityChanged
        }
        let sent = try journal.claim(id)
        try await api.v2.dispatchSettingCommand(sent, auth: auth.request)
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth.request) != nil,
              let current = await tokens.captureDurableAccountAuth(),
              try SettingsMutationAuthority(current).sameDurableOwner(as: sent.authority) else { throw HTTPError.requestIdentityChanged }
        try journal.acknowledge(sent)
    }
}

/// Production player adapter. Legacy journals remain read-only barriers; only
/// explicit edits made after an owner-bound settings read enter this journal.
@Observable
final class PlayerSettingsV2Queue: @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: TokenStore
    private let api: SiloAPI
    private let defaults: UserDefaults
    private let journal: SettingsMutationJournal
    private let dispatcher: SettingsMutationDispatcher
    @ObservationIgnored private var displayedAuth: CapturedDurableAccountAuth?
    private var lastIssue: String?

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, defaults: UserDefaults = .standard,
         journal: SettingsMutationJournal? = nil) {
        self.api = api; self.tokens = tokens; self.defaults = defaults
        let journal = journal ?? SettingsMutationJournal(url: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SettingsV2/player-commands.json"))
        self.journal = journal
        dispatcher = SettingsMutationDispatcher(journal: journal, tokens: tokens, api: api)
    }

    var issue: String? { lock.withLock { lastIssue } }
    var hasPending: Bool {
        guard let auth = lock.withLock({ displayedAuth }), let authority = try? SettingsMutationAuthority(auth) else { return false }
        return (try? journal.snapshot().contains { $0.authority.sameDurableOwner(as: authority) && $0.state != .applied }) ?? true
    }

    func read(keys: [SettingKey]) async throws -> EffectiveSettingValuesResponse {
        guard let auth = await tokens.captureDurableAccountAuth() else { throw SettingsMutationHold.noAuthority }
        let authority = try SettingsMutationAuthority(auth)
        await flush(authority: authority)
        let identity = HTTPRequestIdentity(serverId: authority.serverID, serverURL: authority.origin,
            profileId: authority.profileID, clientFamily: authority.clientFamily)
        let response = try await api.getEffectiveValues(keys: keys, profileId: authority.profileID, requestIdentity: identity)
        guard let current = await tokens.captureDurableAccountAuth(),
              try SettingsMutationAuthority(current) == authority else { throw HTTPError.requestIdentityChanged }
        lock.withLock { displayedAuth = auth }
        // Do not project an ambiguous server read over an optimistic queued edit.
        let outstanding = try journal.snapshot().filter { $0.authority.sameDurableOwner(as: authority) && $0.state != .applied }
        if !outstanding.isEmpty {
            let hold: SettingsMutationHold = outstanding.contains { $0.state == .legacyHeld } ? .legacy : .uncertain
            setIssue(hold.localizedDescription, for: authority)
            throw hold
        }
        setIssue(keys.contains { legacyBlocks($0, authority: authority) }
            ? SettingsMutationHold.legacy.localizedDescription : nil, for: authority)
        return response
    }

    func enqueue(_ key: SettingKey, operation: PendingSettingWrite.Operation) {
        do {
            guard let auth = lock.withLock({ displayedAuth }) else { throw SettingsMutationHold.noAuthority }
            let authority = try SettingsMutationAuthority(auth)
            let body: Data?
            let method: String
            switch operation {
            case .set(let value):
                body = try SettingsWireCoding.makeEncoder().encode(SettingValueWriteRequest(value: value))
                method = "PUT"
            case .delete: body = nil; method = "DELETE"
            }
            let held = legacyBlocks(key, authority: authority)
            let command = SettingsMutationCommand(id: UUID(), authority: authority, key: key.rawValue,
                method: method, path: "/api/v2/settings/values/\(key.rawValue)",
                query: ["scope": "profile_device"], body: body,
                state: held ? .legacyHeld : .prepared)
            try journal.append(command)
            if held { setIssue(SettingsMutationHold.legacy.localizedDescription, for: authority) }
            // Timers trigger dispatch only for prepared commands. An uncertain
            // command is never made prepared again, even after another edit.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                await self?.flush(authority: authority)
            }
        } catch { lock.withLock { lastIssue = error.localizedDescription } }
    }

    private func legacyBlocks(_ key: SettingKey, authority: SettingsMutationAuthority) -> Bool {
        let prefix = "player.pendingDeviceSettingWrites."
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(name.dropFirst(prefix.count))),
                  let scope = String(data: decoded, encoding: .utf8) else { continue }
            let parts = scope.components(separatedBy: "|")
            guard parts.count == 3, ServerRegistry.normalize(url: parts[0]) == authority.origin,
                  parts[1] == authority.profileID, parts[2] == authority.deviceID else { continue }
            guard let data = defaults.data(forKey: name),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            if entries[key.rawValue] != nil { return true }
        }
        return false
    }

    func flush() async {
        guard let auth = lock.withLock({ displayedAuth }), let authority = try? SettingsMutationAuthority(auth) else { return }
        await flush(authority: authority)
    }

    private func flush(authority: SettingsMutationAuthority) async {
        do {
            for command in try journal.snapshot() where command.authority.sameDurableOwner(as: authority) && command.state == .prepared {
                do { try await dispatcher.send(command.id) }
                catch { setIssue(error.localizedDescription, for: authority) }
            }
        } catch { setIssue(error.localizedDescription, for: authority) }
    }

    private func setIssue(_ message: String?, for authority: SettingsMutationAuthority) {
        lock.withLock {
            guard let displayedAuth, (try? SettingsMutationAuthority(displayedAuth)) == authority else { return }
            lastIssue = message
        }
    }
}
