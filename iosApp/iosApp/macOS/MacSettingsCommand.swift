#if os(macOS)
import SwiftUI

extension Notification.Name {
    /// Posted by the app menu's "Settings…" item. The signed-in shell opens
    /// Settings; on the sign-in and profile screens nothing listens.
    static let siloOpenSettings = Notification.Name("siloOpenSettings")
}

/// The standard "Settings…" item in the app menu, with its ⌘, shortcut.
struct MacSettingsCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .siloOpenSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
