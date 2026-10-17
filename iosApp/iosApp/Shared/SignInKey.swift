import Foundation

/// Names one saved sign-in: a server account (`users.id` on the server) on
/// one registry server. Both parts are joined into keychain account names
/// and into `storageKey`, so each is validated to keep those joins
/// unambiguous: neither part may contain "." or "/".
struct SignInKey: Hashable, Codable, Sendable {
    /// Registry server ID: base64url of the server URL.
    let serverID: String
    /// The server's `users.id`, as a string.
    let accountID: String

    init?(serverID: String, accountID: String) {
        guard Self.isValidServerID(serverID), Self.isValidAccountID(accountID) else { return nil }
        self.serverID = serverID
        self.accountID = accountID
    }

    /// Map key in `ProfileLaunchState`. Neither part contains "/", so the
    /// separator splits it back exactly.
    var storageKey: String { "\(serverID)/\(accountID)" }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(serverID: String(parts[0]), accountID: String(parts[1]))
    }

    /// Registry IDs are base64url without padding, so a real one never
    /// contains "." or "/".
    static func isValidServerID(_ serverID: String) -> Bool {
        !serverID.isEmpty && !serverID.contains(".") && !serverID.contains("/")
    }

    static func isValidAccountID(_ accountID: String) -> Bool {
        guard (1...128).contains(accountID.count) else { return false }
        return accountID.unicodeScalars.allSatisfy { scalar in
            scalar != "." && scalar != "/"
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case serverID, accountID
    }

    /// A stored key that fails validation is corrupt, never a usable key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverID = try container.decode(String.self, forKey: .serverID)
        let accountID = try container.decode(String.self, forKey: .accountID)
        guard let key = SignInKey(serverID: serverID, accountID: accountID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .accountID,
                in: container,
                debugDescription: "Invalid sign-in key"
            )
        }
        self = key
    }
}

// Kept beside `SignInKey` rather than in SharedStorage.swift: the iOS
// Notification Service compiles that file without this one.
extension SharedStorage {
    static func signInAccount(_ key: SignInKey) -> String {
        signInAccountPrefix + "\(key.serverID).\(key.accountID)"
    }

    static func signInProofAccount(_ key: SignInKey) -> String {
        signInProofAccountPrefix + "\(key.serverID).\(key.accountID)"
    }
}
