import Foundation

/// A sign-in without its tokens, for the UI and the launch policies.
struct SignInSummary: Equatable, Sendable {
    let key: SignInKey
    let username: String?
    let email: String?
    let isSignedIn: Bool
    let profiles: [SavedSignInProfile]
    let addedAt: Date
}

// In an extension so the memberwise initializer stays synthesized.
extension SignInSummary {
    init(_ signIn: SavedSignIn) {
        self.init(
            key: signIn.key,
            username: signIn.username,
            email: signIn.email,
            isSignedIn: signIn.isSignedIn,
            profiles: signIn.profiles,
            addedAt: signIn.addedAt
        )
    }
}

/// The accounts index plus a summary of each readable sign-in. Holds no
/// secrets.
struct SiloAccountDirectorySnapshot: Equatable, Sendable {
    /// Index order.
    var accounts: [SiloAccountRef] = []
    /// A key the index lists but whose item couldn't be read has no entry.
    var signIns: [SignInKey: SignInSummary] = [:]
    var migrated = false
    var legacyDataOwnerByServerID: [String: String] = [:]

    static let empty = SiloAccountDirectorySnapshot()
}

// In an extension so the memberwise initializer stays synthesized.
extension SiloAccountDirectorySnapshot {
    init(index: SiloAccountIndex, signIns: [SignInSummary]) {
        self.init(
            accounts: index.accounts,
            signIns: Dictionary(signIns.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }),
            migrated: index.migrated == true,
            legacyDataOwnerByServerID: index.legacyDataOwnerByServerID ?? [:]
        )
    }

    var index: SiloAccountIndex {
        SiloAccountIndex(
            accounts: accounts,
            migrated: migrated ? true : nil,
            legacyDataOwnerByServerID: legacyDataOwnerByServerID.isEmpty ? nil : legacyDataOwnerByServerID
        )
    }

    func contains(_ account: SiloAccountRef) -> Bool {
        accounts.contains(account)
    }

    /// The summary of a signed-in-or-expired account. Nil for a pending
    /// legacy account and for an item that couldn't be read.
    func summary(_ account: SiloAccountRef) -> SignInSummary? {
        account.signInKey.flatMap { signIns[$0] }
    }

    /// An item the index lists but that couldn't be read counts as expired,
    /// so opening it asks for sign-in instead of failing.
    func isSignedIn(_ account: SiloAccountRef) -> Bool {
        switch account {
        case .signIn(let key): return signIns[key]?.isSignedIn ?? false
        case .pendingLegacy: return true
        }
    }
}
