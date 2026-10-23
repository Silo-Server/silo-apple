import Foundation

/// A profile as Silo last saw it on a sign-in's account, cached so user
/// cards can draw avatars without reaching the server. Display only.
struct SavedSignInProfile: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let avatarEmoji: String?
    let avatarImageUrl: String?
    let hasPin: Bool
    let isChild: Bool
}

/// One account's sign-in on one server, shared by every Apple TV user.
/// Stored in the user-independent keychain under
/// `SharedStorage.signInAccount(_:)`. The index (`SiloAccountIndex`) lists
/// it; an item the index doesn't list is an orphan.
struct SavedSignIn: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let key: SignInKey
    var serverID: String { key.serverID }
    var accountID: String { key.accountID }
    /// Normalized server URL. The bearer is only ever sent here.
    let origin: String
    /// Nil after migration or pairing until `/api/v2/account/me` fills it.
    var username: String?
    /// The server account's email, when it has one. Filled by
    /// `/api/v2/account/me`.
    var email: String?
    /// Tokens and epoch all nil means the sign-in expired and shows
    /// "Sign in again".
    var accessToken: String?
    var refreshToken: String?
    var epoch: UUID?
    let addedAt: Date
    var profiles: [SavedSignInProfile]
    /// True only for sign-ins created by migration: they take over local data
    /// still stored under the old server-and-profile keys.
    var adoptsLegacyLocalData: Bool?

    init(
        key: SignInKey,
        origin: String,
        username: String? = nil,
        email: String? = nil,
        accessToken: String?,
        refreshToken: String?,
        epoch: UUID?,
        addedAt: Date,
        profiles: [SavedSignInProfile] = [],
        adoptsLegacyLocalData: Bool? = nil
    ) {
        self.version = Self.currentVersion
        self.key = key
        self.origin = origin
        self.username = username
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.epoch = epoch
        self.addedAt = addedAt
        self.profiles = profiles
        self.adoptsLegacyLocalData = adoptsLegacyLocalData
    }

    var isSignedIn: Bool {
        accessToken?.isEmpty == false && refreshToken?.isEmpty == false && epoch != nil
    }

    // The key is stored as two flat fields, matching the record's other
    // identity fields. Items written by the first multi-account design also
    // carry a `userID`, which is ignored.
    private enum CodingKeys: String, CodingKey {
        case version, serverID, accountID, origin, username, email
        case accessToken, refreshToken, epoch, addedAt, profiles, adoptsLegacyLocalData
    }

    init(from decoder: Decoder) throws {
        // The flat serverID and accountID fields are SignInKey's own coding
        // keys, so it decodes and validates them from this same object.
        key = try SignInKey(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        origin = try container.decode(String.self, forKey: .origin)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        epoch = try container.decodeIfPresent(UUID.self, forKey: .epoch)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        profiles = try container.decode([SavedSignInProfile].self, forKey: .profiles)
        adoptsLegacyLocalData = try container.decodeIfPresent(Bool.self, forKey: .adoptsLegacyLocalData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(key.serverID, forKey: .serverID)
        try container.encode(key.accountID, forKey: .accountID)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(epoch, forKey: .epoch)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(profiles, forKey: .profiles)
        try container.encodeIfPresent(adoptsLegacyLocalData, forKey: .adoptsLegacyLocalData)
    }
}

/// This Apple TV user's PIN proof for one sign-in. Stored in the
/// current-user keychain under `SharedStorage.signInProofAccount(_:)`; one
/// slot per sign-in, holding the proof for whichever profile was last
/// selected with its PIN.
struct SignInProfileProof: Codable, Equatable, Sendable {
    /// Nil only for a legacy proof adopted by migration, whose profile is
    /// unknown.
    let profileID: String?
    let token: String
}
