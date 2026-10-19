import Foundation

/// "Sign in to…" (spec §5.4): the saved servers a sign-in can use, then Add
/// a New Server.
struct SignInTargetViewModel: Equatable {
    struct Row: Equatable, Identifiable {
        /// Registry server ID.
        let id: String
        let name: String
        let address: String
    }

    static let title = "Sign in to…"
    static let addNewServerTitle = "Add a New Server"

    let context: SignInContext
    let rows: [Row]

    /// `servers` in display order (`ServerRegistry.sortedEntries`).
    init(context: SignInContext, servers: [ServerEntry]) {
        self.context = context
        let ids = SignInTargetList.servers(for: context, in: servers.map(\.id))
        let byID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = ids.compactMap { id in
            byID[id].map { Row(id: $0.id, name: $0.displayName, address: $0.url) }
        }
    }
}
