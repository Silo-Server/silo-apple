import Foundation

/// The device's accounts as the screens show them (plan §2.10): each
/// account's username, email, and server, its Sign in again state, the
/// profiles cached for its card, and which account this Apple TV user (or
/// device) uses. Holds no secrets. `SiloAccountCoordinator` rebuilds it
/// after every change.
struct SiloAccountDirectory: Equatable, Sendable {
    /// One account (spec §5.2).
    struct Account: Equatable, Identifiable, Sendable {
        let id: SiloAccountRef
        /// The server account's username. Nil until the server names it: a
        /// pending legacy account, or a sign-in its item couldn't be read for.
        let username: String?
        let email: String?
        let serverID: String
        let serverName: String
        let serverAddress: String
        /// False once the saved sign-in expired: Sign in again.
        let isSignedIn: Bool
        /// Profiles cached for the card (`SavedSignIn.profiles`).
        let profiles: [SavedSignInProfile]
        /// Whether this Apple TV user (or device) is linked to the account.
        let isLinked: Bool

        var key: SignInKey? { id.signInKey }
        var needsSignInAgain: Bool { key != nil && !isSignedIn }

        /// The card's first line: the username, else the server's name.
        var name: String { username ?? serverName }

        /// The card's other lines: the email when known, and the server's
        /// name unless the first line already shows it.
        var detailLines: [String] {
            var lines: [String] = []
            if let email { lines.append(email) }
            if username != nil { lines.append(serverName) }
            return lines
        }
    }

    /// Index order.
    var accounts: [Account] = []
    /// False before sign-in migration, or while the accounts index can't be
    /// read: the device then runs on per-server sessions as before.
    var isAvailable = false
    /// The account whose credential is selected now, if any.
    var currentAccountID: SiloAccountRef?

    static let empty = SiloAccountDirectory()

    func account(_ id: SiloAccountRef?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    var currentAccount: Account? { account(currentAccountID) }
    var linkedAccount: Account? { accounts.first(where: \.isLinked) }

    /// Whether accounts span more than one server, so lines that name the
    /// current account name its server too.
    var spansServers: Bool {
        Set(accounts.map(\.serverID)).count > 1
    }
}

extension SiloAccountDirectory {
    /// Builds the UI snapshot from the secret-free index snapshot, the saved
    /// servers, and this Apple TV user's launch state. An account on a
    /// server that is no longer saved is left out, as launch leaves it out.
    init(
        snapshot: SiloAccountDirectorySnapshot,
        servers entries: [ServerEntry],
        state: ProfileLaunchState,
        currentAccountID: SiloAccountRef?
    ) {
        let entryByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Two saved servers with one name are told apart by their hosts.
        let nameCounts = Dictionary(entries.map { ($0.displayName.lowercased(), 1) }, uniquingKeysWith: +)
        func serverName(_ entry: ServerEntry) -> String {
            guard nameCounts[entry.displayName.lowercased(), default: 0] > 1 else { return entry.displayName }
            return "\(entry.displayName) (\(ServerBranding.hostLabel(entry.url)))"
        }
        let linked = state.linkedAccountRef.flatMap(snapshot.index.resolve)
        func trimmed(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        self.init(
            accounts: snapshot.accounts.compactMap { account in
                guard let entry = entryByID[account.serverID] else { return nil }
                let summary = snapshot.summary(account)
                return Account(
                    id: account,
                    username: trimmed(summary?.username),
                    email: trimmed(summary?.email),
                    serverID: account.serverID,
                    serverName: serverName(entry),
                    serverAddress: entry.url,
                    isSignedIn: snapshot.isSignedIn(account),
                    profiles: summary?.profiles ?? [],
                    isLinked: linked == account
                )
            },
            isAvailable: true,
            currentAccountID: currentAccountID
        )
    }
}
