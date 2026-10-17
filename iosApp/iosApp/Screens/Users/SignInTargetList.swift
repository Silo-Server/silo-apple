import Foundation

/// What the server step of a sign-in shows (spec §5.4).
enum SignInServerStep: Equatable, Sendable {
    /// Straight to today's server setup: no saved server can take this
    /// sign-in.
    case serverSetup
    /// "Sign in to…" with these saved servers, in this order, followed by
    /// Add a New Server.
    case list(serverIDs: [String])
    /// No server step: the sign-in screen for this server opens directly.
    case signIn(serverID: String)
}

/// The server step every sign-in starts with. There is no way past it
/// without a server.
enum SignInTargetList {
    /// The saved servers "Sign in to…" lists, in the order given. Add Server
    /// leaves out every server the user already has, pending legacy servers
    /// included. Sign in again has no list.
    static func servers(
        for context: SignInContext,
        in savedServerIDs: [String],
        directory: SiloUserDirectorySnapshot
    ) -> [String] {
        switch context {
        case .firstRun, .addUser:
            return savedServerIDs
        case .addServer(let userID):
            // A user removed meanwhile has no servers to leave out.
            guard let user = directory.user(withID: userID) else { return savedServerIDs }
            let existing = Set(serverIDs(in: user))
            return savedServerIDs.filter { !existing.contains($0) }
        case .signInAgain:
            return []
        }
    }

    static func step(
        for context: SignInContext,
        in savedServerIDs: [String],
        directory: SiloUserDirectorySnapshot
    ) -> SignInServerStep {
        if case .signInAgain(_, let key) = context {
            return .signIn(serverID: key.serverID)
        }
        let servers = servers(for: context, in: savedServerIDs, directory: directory)
        return servers.isEmpty ? .serverSetup : .list(serverIDs: servers)
    }

    /// Every server in the user: its sign-ins oldest first, then its pending
    /// legacy servers. Each server appears once.
    static func serverIDs(in user: SiloUser) -> [String] {
        var seen = Set<String>()
        return (user.signIns.map(\.serverID) + (user.pendingLegacyServerIDs ?? []))
            .filter { seen.insert($0).inserted }
    }
}
