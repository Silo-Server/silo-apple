import Foundation

/// A saved account as Change Account, the profile menu and Settings ›
/// Accounts show it: no tokens, only what they draw. Read from
/// `AccountStore` by `AccountDirectory`.
struct SavedAccountSummary: Identifiable, Equatable, Sendable {
    let serverId: String
    let localAccountId: String
    let username: String?
    let cachedProfiles: [AccountProfile]
    /// How many profiles the account may have; nil when the server didn't
    /// say with its last profile list.
    let maxProfiles: Int?
    /// The server rejected the account's credentials; it must sign in again
    /// and its downloads stay.
    let needsSignIn: Bool
    let lastUsedAt: Date

    var id: String { localAccountId }

    init(_ account: Account) {
        serverId = account.serverId
        localAccountId = account.localAccountId
        username = account.username
        cachedProfiles = account.cachedProfiles
        maxProfiles = account.maxProfiles
        needsSignIn = !account.isSignedIn
        lastUsedAt = account.lastUsedAt
    }
}

/// The saved accounts on this device, read once from the keychain and kept
/// for views that draw them on every render (the profile menu header,
/// Change Account, Settings › Accounts). Call `reload()` after anything adds,
/// removes, or switches an account.
@Observable
@MainActor
final class AccountDirectory {
    static let shared = AccountDirectory()

    private(set) var accounts: [SavedAccountSummary] = []
    /// False when the keychain could not be read; `accounts` then holds the
    /// last list that could.
    private(set) var isReadable = true

    private let store: AccountStore

    init(store: AccountStore = .shared) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            let fresh = try store.accounts().map(SavedAccountSummary.init)
            if fresh != accounts { accounts = fresh }
            isReadable = true
        } catch {
            isReadable = false
        }
    }

    func accounts(onServer serverId: String) -> [SavedAccountSummary] {
        accounts.filter { $0.serverId == serverId }
    }

    func account(_ localAccountId: String) -> SavedAccountSummary? {
        accounts.first { $0.localAccountId == localAccountId }
    }

    /// Whether any saved account can open a profile now.
    var hasSignedInAccount: Bool { accounts.contains { !$0.needsSignIn } }
}

extension UserProfile {
    /// A cached profile, drawn in the picker while the server can't be
    /// reached. Fields the cache doesn't keep take their defaults until the
    /// account's fresh list loads.
    init(_ cached: AccountProfile) {
        self.init(
            id: cached.id,
            name: cached.name,
            avatarEmoji: cached.avatarEmoji,
            avatarImageUrl: cached.avatarImageUrl,
            hasPin: cached.hasPin,
            isChild: cached.isChild
        )
    }
}
