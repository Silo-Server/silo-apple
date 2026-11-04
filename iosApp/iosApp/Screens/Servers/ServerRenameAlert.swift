import SwiftUI

/// Wording and saving shared by the rename prompts: the alert on iOS and the
/// Mac, ``TVServerRenameOverlay`` on Apple TV.
enum ServerRename {
    static let title = "Rename Server"

    static func message(for entry: ServerEntry) -> String {
        let scope = "Only you see this name. It syncs to your devices that use the same iCloud account."
        guard let serverName = entry.serverName else { return scope }
        return "The server's own name is \(serverName). \(scope)"
    }

    static func placeholder(for entry: ServerEntry) -> String {
        entry.serverName ?? "Server name"
    }

    /// Saves `name` for `entry`; nil or blank goes back to the server's name.
    @MainActor
    static func save(_ name: String?, for entry: ServerEntry, router: AppRouter) {
        if !ServerRegistry.shared.rename(serverId: entry.id, to: name) {
            router.accountActionError = "Silo couldn't save the server name. Please try again."
        }
    }
}

#if !os(tvOS)
/// Asks for a new name for a saved server. Saving a blank name, or choosing
/// Use Server Name, goes back to the name the server advertises.
struct ServerRenameAlert: ViewModifier {
    @Binding var target: ServerEntry?

    @Environment(AppRouter.self) private var router
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                ServerRename.title,
                isPresented: Binding(
                    get: { target != nil },
                    set: { if !$0 { target = nil } }
                ),
                presenting: target
            ) { entry in
                TextField(ServerRename.placeholder(for: entry), text: $draft)
                Button("Save") { ServerRename.save(draft, for: entry, router: router) }
                if entry.nickname != nil {
                    Button("Use Server Name") { ServerRename.save(nil, for: entry, router: router) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text(ServerRename.message(for: entry))
            }
            .onChange(of: target?.id) { _, _ in
                draft = target?.nickname ?? ""
            }
    }
}

extension View {
    /// Presents ``ServerRenameAlert`` while `target` is set.
    func serverRenameAlert(_ target: Binding<ServerEntry?>) -> some View {
        modifier(ServerRenameAlert(target: target))
    }
}
#endif
