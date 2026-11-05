import Foundation

/// The badge beside an account in Change Account.
enum ChangeAccountBadge: Equatable {
    /// The open account.
    case current
    /// Its credentials expired or were revoked.
    case signInAgain

    var title: String {
        switch self {
        case .current: "Current"
        case .signInAgain: "Sign in again"
        }
    }
}

/// One saved account in Change Account.
struct ChangeAccountRow: Identifiable, Equatable {
    let account: SavedAccountSummary
    let badge: ChangeAccountBadge?

    var id: String { account.localAccountId }
    var serverId: String { account.serverId }
    var username: String { account.username ?? "Account" }
    /// The avatar's letter.
    var initial: String { username.first.map { String($0).uppercased() } ?? "?" }
    /// "3 profiles" or "1 profile", from the account's cached list. Nil
    /// before any list was cached (an account migrated without one).
    var profileCount: String? { ChangeAccountList.profileCount(account.cachedProfiles.count) }
    var isCurrent: Bool { badge == .current }
    var needsSignIn: Bool { account.needsSignIn }
    /// What choosing the row does, for VoiceOver.
    var accessibilityHint: String {
        if needsSignIn { return "Opens sign-in" }
        return isCurrent ? "Shows this account's profiles" : "Switches to this account"
    }
}

/// One saved server in Change Account: its accounts, then Add an account.
struct ChangeAccountServer: Identifiable, Equatable {
    let server: ServerEntry
    let rows: [ChangeAccountRow]

    var id: String { server.id }
    var name: String { server.displayName }
    /// The line under Add an account.
    var addAccountDetail: String { "Sign in on \(name)" }
}

/// Builds Change Account's list (spec §4.1). Pure, so it draws offline and
/// every platform lists the same thing.
enum ChangeAccountList {
    /// - Parameters:
    ///   - servers: saved servers, active first, then by last use
    ///     (`ServerRegistry.sortedEntries`).
    ///   - accounts: every saved account, most recently used first.
    ///   - openAccountId: the account requests use now, when it is signed in.
    static func servers(
        _ servers: [ServerEntry],
        accounts: [SavedAccountSummary],
        openAccountId: String?
    ) -> [ChangeAccountServer] {
        servers.map { server in
            let rows = accounts.filter { $0.serverId == server.id }.map { account in
                ChangeAccountRow(account: account, badge: badge(for: account, openAccountId: openAccountId))
            }
            return ChangeAccountServer(server: server, rows: rows)
        }
    }

    static func badge(for account: SavedAccountSummary, openAccountId: String?) -> ChangeAccountBadge? {
        if account.needsSignIn { return .signInAgain }
        return account.localAccountId == openAccountId ? .current : nil
    }

    static func profileCount(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 profile" : "\(count) profiles"
    }
}

/// Change Account: every saved account, grouped by server, with the actions
/// behind each row. Shared by the phone, tablet and Mac list and the TV's
/// rail and pane; each draws `servers` and calls these actions.
@Observable
@MainActor
final class ChangeAccountModel {
    private(set) var servers: [ChangeAccountServer] = []
    /// The account being opened while its switch runs.
    private(set) var openingAccountId: String?

    /// One model for every copy of the screen. Switching to an account on
    /// another server switches the server first, which rebuilds the app
    /// shell and with it Change Account; the rebuilt copy has to find the
    /// switch still in progress, or it draws the half-switched list.
    static let shared = ChangeAccountModel()

    private let directory: AccountDirectory

    init(directory: AccountDirectory? = nil) {
        self.directory = directory ?? .shared
        reload(refreshingDirectory: false)
    }

    var isBusy: Bool { openingAccountId != nil }

    /// Rebuilds `servers`. `refreshingDirectory: false` when
    /// `AccountDirectory` just changed.
    func reload(refreshingDirectory: Bool = true) {
        // Mid-switch the accounts are half moved; keep the list as chosen.
        guard !isBusy else { return }
        if refreshingDirectory { directory.reload() }
        let built = ChangeAccountList.servers(
            ServerRegistry.shared.sortedEntries,
            accounts: directory.accounts,
            openAccountId: Self.openAccountId
        )
        if built != servers { servers = built }
    }

    /// The account whose profiles the picker shows: the active server's
    /// signed-in account.
    static var openAccountId: String? { AuthService.shared.openAccount?.localAccountId }

    /// Opens an account: the open one shows its picker again; one that must
    /// sign in again goes to sign-in with its username filled in; any other
    /// becomes the active account on its server and shows its picker.
    func choose(_ row: ChangeAccountRow, router: AppRouter) {
        guard !isBusy else { return }
        if row.needsSignIn {
            router.beginSignIn(onServer: row.serverId, renewing: row.id, returningToChangeAccount: true)
            return
        }
        if row.isCurrent {
            router.showCurrentAccountPicker()
            return
        }
        openingAccountId = row.id
        Task {
            do {
                // The picker has replaced this screen once this returns.
                try await router.openAccount(row.id, onServer: row.serverId)
                openingAccountId = nil
            } catch {
                openingAccountId = nil
                guard !(error is CancellationError) else { return }
                router.accountActionError = error.localizedDescription
                reload()
            }
        }
    }

    /// Add an account on a saved server.
    func addAccount(on server: ChangeAccountServer, router: AppRouter) {
        guard !isBusy else { return }
        router.beginAddAccount(onServer: server.id, returningToChangeAccount: true)
    }

    func addServer(router: AppRouter) {
        guard !isBusy else { return }
        router.resetToServerSetup()
    }
}
