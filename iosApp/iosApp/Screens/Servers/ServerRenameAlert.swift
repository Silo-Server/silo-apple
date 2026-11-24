import SwiftUI

/// Wording and saving shared by the rename prompts: the alert on iOS and the
/// Mac, ``TVServerRenameOverlay`` on Apple TV.
enum ServerRename {
    static let title: LocalizedStringResource = .serversRenamePromptTitle

    static func message(for entry: ServerEntry) -> LocalizedStringResource {
        #if os(macOS)
        // The Mac keeps names on the device: it has no iCloud store for them.
        guard let serverName = entry.serverName else { return .serversRenameLocalNote }
        return .serversRenameLocalNoteNamed(serverName)
        #else
        guard let serverName = entry.serverName else { return .serversRenameSyncNote }
        return .serversRenameSyncNoteNamed(serverName)
        #endif
    }

    static func placeholder(for entry: ServerEntry, locale: Locale) -> String {
        entry.serverName ?? AppLanguage.string(.serversRenamePlaceholder, locale: locale)
    }

    /// Saves `name` for `entry`; nil or blank goes back to the server's name.
    @MainActor
    static func save(_ name: String?, for entry: ServerEntry, router: AppRouter) {
        if !ServerRegistry.shared.rename(serverId: entry.id, to: name) {
            router.accountActionError = AppLanguage.string(.serversRenameSaveFailed)
        }
    }
}

#if !os(tvOS)
/// Asks for a new name for a saved server. Saving a blank name, or choosing
/// Use Server Name, goes back to the name the server advertises.
struct ServerRenameAlert: ViewModifier {
    @Binding var target: ServerEntry?

    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                Text(ServerRename.title),
                isPresented: Binding(
                    get: { target != nil },
                    set: { if !$0 { target = nil } }
                ),
                presenting: target
            ) { entry in
                TextField(ServerRename.placeholder(for: entry, locale: locale), text: $draft)
                Button(.commonSave) { ServerRename.save(draft, for: entry, router: router) }
                if entry.nickname != nil {
                    Button(.serversRenameUseServerName) { ServerRename.save(nil, for: entry, router: router) }
                }
                Button(.commonCancel, role: .cancel) {}
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
