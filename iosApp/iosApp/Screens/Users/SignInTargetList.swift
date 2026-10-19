import Foundation

/// What the server step of a sign-in shows (spec §5.4).
enum SignInServerStep: Equatable, Sendable {
    /// Straight to today's server setup: no server is saved.
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
    /// The saved servers "Sign in to…" lists, in the order given. Sign in
    /// again has no list.
    static func servers(for context: SignInContext, in savedServerIDs: [String]) -> [String] {
        switch context {
        case .firstRun, .addAccount:
            return savedServerIDs
        case .signInAgain:
            return []
        }
    }

    static func step(for context: SignInContext, in savedServerIDs: [String]) -> SignInServerStep {
        if case .signInAgain(let key) = context {
            return .signIn(serverID: key.serverID)
        }
        let servers = servers(for: context, in: savedServerIDs)
        return servers.isEmpty ? .serverSetup : .list(serverIDs: servers)
    }
}
