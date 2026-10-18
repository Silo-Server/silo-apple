import Foundation

/// The device's Silo users as the screens show them (plan §2.10): names
/// with duplicates told apart, each user's servers with their usernames and
/// Sign in again state, the profiles cached for user cards, and which user
/// and server this Apple TV user (or device) uses. Holds no secrets.
/// `SiloUserCoordinator` rebuilds it after every change.
struct SiloUserDirectory: Equatable, Sendable {
    /// One server in a user (spec §5.3).
    struct Server: Equatable, Identifiable, Sendable {
        /// Registry server ID.
        let id: String
        let name: String
        let address: String
        /// The saved sign-in. Nil for a pending legacy server, which signs
        /// in with the server's own session until its account is known.
        let key: SignInKey?
        /// The server account's username, when known.
        let username: String?
        /// Whether the row shows `username`: when it differs from the user's
        /// name, and always once the user was renamed.
        let showsUsername: Bool
        /// False once the saved sign-in expired: Sign in again.
        let isSignedIn: Bool
        let isPendingLegacy: Bool
        /// Profiles cached for user cards (`SavedSignIn.profiles`).
        let profiles: [SavedSignInProfile]

        var needsSignInAgain: Bool { key != nil && !isSignedIn }
    }

    /// One user (spec §5.2).
    struct User: Equatable, Identifiable, Sendable {
        let id: String
        /// The name screens show, told apart from other users' (plan G7).
        let name: String
        /// The name without the server added to tell users apart: the rename,
        /// or the default name. Rename pre-fills this.
        let baseName: String
        let isRenamed: Bool
        /// Oldest first.
        let servers: [Server]
        /// The server this Apple TV user last opened in this user, when it
        /// is still in the user.
        let lastServerID: String?
        /// Whether this Apple TV user (or device) is linked to the user.
        let isLinked: Bool

        /// The server cards describe: the last one, else the oldest.
        var lastUsedServer: Server? {
            servers.first { $0.id == lastServerID } ?? servers.first
        }

        /// The last-used sign-in expired (spec §5.2 badge).
        var needsSignInAgain: Bool { lastUsedServer?.needsSignInAgain == true }

        func server(_ id: String) -> Server? {
            servers.first { $0.id == id }
        }

        /// `name` for text that already names `serverNames` (a card's
        /// server label, a sentence about signing out of a server): a server
        /// added to tell users apart is left out there, since the text names
        /// it anyway. Any other server added, and "(2)" numbering, stay, so
        /// users are still told apart. "alex · Home Silo" signing out of
        /// Home Silo reads "alex".
        func name(besides serverNames: [String]) -> String {
            let separator = SiloUserNaming.separator
            guard name.count > baseName.count, name.hasPrefix(baseName) else { return name }
            var suffix = String(name.dropFirst(baseName.count))
            var numbering = ""
            if let range = suffix.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                numbering = String(suffix[range])
                suffix.removeSubrange(range)
            }
            guard suffix.hasPrefix(separator) else { return name }
            let named = Set(serverNames.map { $0.folding(options: .caseInsensitive, locale: nil) })
            let kept = suffix.dropFirst(separator.count).components(separatedBy: separator)
                .filter { !named.contains($0.folding(options: .caseInsensitive, locale: nil)) }
            return baseName + kept.map { separator + $0 }.joined() + numbering
        }
    }

    /// Index order.
    var users: [User] = []
    /// False before sign-in migration, or while the user index can't be
    /// read: the device then runs on per-server sessions as before.
    var isAvailable = false
    var linkedUserID: String?
    /// The user whose credential is selected now, if any.
    var currentUserID: String?
    /// The server active now.
    var currentServerID: String?

    static let empty = SiloUserDirectory()

    func user(_ id: String?) -> User? {
        guard let id else { return nil }
        return users.first { $0.id == id }
    }

    var currentUser: User? { user(currentUserID) }

    /// Every saved user other than `userID`.
    func otherUsers(than userID: String?) -> [User] {
        users.filter { $0.id != userID }
    }

    /// Users with a sign-in or pending legacy server on `serverID`.
    func users(onServer serverID: String) -> [User] {
        users.filter { $0.server(serverID) != nil }
    }
}

extension SiloUserDirectory {
    /// Builds the UI snapshot from the secret-free index snapshot, the saved
    /// servers, and this Apple TV user's launch state. A sign-in on a server
    /// that is no longer saved is left out, as launch leaves it out.
    init(
        snapshot: SiloUserDirectorySnapshot,
        servers entries: [ServerEntry],
        state: ProfileLaunchState,
        currentUserID: String?,
        currentServerID: String?
    ) {
        let entryByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serverNames = entryByID.mapValues(\.displayName)
        let names = SiloUserNaming.disambiguatedNames(in: snapshot, serverNames: serverNames)
        self.init(
            users: snapshot.users.map { user in
                let baseName = SiloUserNaming.displayName(for: user, in: snapshot, serverNames: serverNames)
                let isRenamed = SiloUserNaming.normalizedDisplayName(user.displayName) != nil
                let servers: [Server] = SignInTargetList.serverIDs(in: user).compactMap { serverID in
                    guard let entry = entryByID[serverID] else { return nil }
                    let key = user.signIns.first { $0.serverID == serverID }
                    let summary = key.flatMap { snapshot.signIns[$0] }
                    let username = summary?.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let knownUsername = (username?.isEmpty ?? true) ? nil : username
                    let differs = knownUsername.map {
                        $0.folding(options: .caseInsensitive, locale: nil)
                            != baseName.folding(options: .caseInsensitive, locale: nil)
                    } ?? false
                    return Server(
                        id: serverID,
                        name: entry.displayName,
                        address: entry.url,
                        key: key,
                        username: knownUsername,
                        showsUsername: knownUsername != nil && (isRenamed || differs),
                        isSignedIn: key == nil || summary?.isSignedIn == true,
                        isPendingLegacy: key == nil,
                        profiles: summary?.profiles ?? []
                    )
                }
                let last = state.lastServer(for: user.id).flatMap { id in servers.contains { $0.id == id } ? id : nil }
                return User(
                    id: user.id,
                    name: names[user.id] ?? baseName,
                    baseName: baseName,
                    isRenamed: isRenamed,
                    servers: servers,
                    lastServerID: last,
                    isLinked: state.linkedUserID == user.id
                )
            },
            isAvailable: true,
            linkedUserID: state.linkedUserID,
            currentUserID: currentUserID,
            currentServerID: currentServerID
        )
    }
}
