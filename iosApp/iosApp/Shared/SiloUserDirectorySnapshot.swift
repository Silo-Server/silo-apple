import Foundation

/// A sign-in without its tokens, for the UI and the launch policies.
struct SignInSummary: Equatable, Sendable {
    let key: SignInKey
    let userID: String
    let username: String?
    let isSignedIn: Bool
    let profiles: [SavedSignInProfile]
    let addedAt: Date
}

// In an extension so the memberwise initializer stays synthesized.
extension SignInSummary {
    init(_ signIn: SavedSignIn) {
        self.init(
            key: signIn.key,
            userID: signIn.userID,
            username: signIn.username,
            isSignedIn: signIn.isSignedIn,
            profiles: signIn.profiles,
            addedAt: signIn.addedAt
        )
    }
}

/// The user index plus a summary of each readable sign-in. Holds no secrets.
struct SiloUserDirectorySnapshot: Equatable, Sendable {
    /// Index order.
    var users: [SiloUser] = []
    /// A key the index lists but whose item couldn't be read has no entry.
    var signIns: [SignInKey: SignInSummary] = [:]
    var migratedUserID: String? = nil
    var legacyDataOwnerByServerID: [String: String] = [:]

    static let empty = SiloUserDirectorySnapshot()
}

// In an extension so the memberwise initializer stays synthesized.
extension SiloUserDirectorySnapshot {
    init(index: SiloUserIndex, signIns: [SignInSummary]) {
        self.init(
            users: index.users,
            signIns: Dictionary(signIns.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }),
            migratedUserID: index.migratedUserID,
            legacyDataOwnerByServerID: index.legacyDataOwnerByServerID ?? [:]
        )
    }

    func user(withID id: String) -> SiloUser? {
        users.first { $0.id == id }
    }

    func user(owning key: SignInKey) -> SiloUser? {
        users.first { $0.signIns.contains(key) }
    }

    /// The user's readable sign-ins in membership order, oldest first.
    func summaries(for user: SiloUser) -> [SignInSummary] {
        user.signIns.compactMap { signIns[$0] }
    }
}
