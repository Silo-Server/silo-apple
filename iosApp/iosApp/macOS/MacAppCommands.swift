#if os(macOS)
import SwiftUI

/// What the menu bar can do in the key window's signed-in shell. The shell
/// publishes it with `focusedSceneValue`, so each command acts on the window
/// in front. On the sign-in and profile screens nothing publishes it and the
/// commands are disabled.
struct MacShellActions {
    struct Destination: Identifiable {
        let id: MainTabDestinationID
        let title: String
    }

    /// A page is pushed over the sidebar destination.
    let canGoBack: Bool
    /// Playback has the window. Commands that would leave the player
    /// without saying so are disabled; Back stays, since it says so.
    let isPlayerOnScreen: Bool
    /// The sidebar's rows by group, in sidebar order.
    let destinationGroups: [[Destination]]
    let goBack: () -> Void
    let select: (MainTabDestinationID) -> Void
    let openSettings: () -> Void
}

extension FocusedValues {
    @Entry var macShellActions: MacShellActions?
}

/// The app's menu bar additions: Settings… (⌘,), the system's Show/Hide
/// Sidebar (⌃⌘S), and in the View menu Back (⌘[), Search (⌘K), and the
/// sidebar's rows on ⌘1 to ⌘9.
struct MacAppCommands: Commands {
    @FocusedValue(\.macShellActions) private var shell

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(title(.menuMacSettings)) { shell?.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!canLeavePage)
        }

        // The player keeps the sidebar hidden; its key monitor takes ⌃⌘S
        // for cycling subtitles before the menu sees the key.
        SidebarCommands()

        CommandGroup(after: .sidebar) {
            Divider()

            Button(title(.commonBack)) { shell?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(shell?.canGoBack != true)

            Button(title(.menuMacSearch)) { shell?.select(.app(.search)) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!canLeavePage)

            ForEach(Array(numberedGroups.enumerated()), id: \.offset) { _, group in
                Divider()
                ForEach(group, id: \.destination.id) { entry in
                    destinationButton(entry)
                }
            }
        }
    }

    /// Menu commands sit outside the root view's `\.locale`, so their titles
    /// resolve through `AppLanguage`; reading the observable language makes the
    /// menu rebuild when it changes.
    @MainActor private func title(_ resource: LocalizedStringResource) -> String {
        _ = AppLanguagePreferences.shared.displayed
        return AppLanguage.string(resource)
    }

    /// Settings, Search and the sidebar rows would replace the page in view;
    /// over the player that would end playback.
    private var canLeavePage: Bool {
        guard let shell else { return false }
        return !shell.isPlayerOnScreen
    }

    private struct NumberedDestination {
        let destination: MacShellActions.Destination
        /// 1 to 9 for the first nine rows; nil after that.
        let number: Int?
    }

    /// The sidebar rows by group, numbered in order. Search has its own
    /// item and shortcut, so it takes no number.
    private var numberedGroups: [[NumberedDestination]] {
        var next = 1
        return (shell?.destinationGroups ?? []).compactMap { group in
            let entries = group
                .filter { $0.id != .app(.search) }
                .map { destination -> NumberedDestination in
                    defer { next += 1 }
                    return NumberedDestination(destination: destination, number: next <= 9 ? next : nil)
                }
            return entries.isEmpty ? nil : entries
        }
    }

    @ViewBuilder
    private func destinationButton(_ entry: NumberedDestination) -> some View {
        let button = Button(entry.destination.title) { shell?.select(entry.destination.id) }
            .disabled(!canLeavePage)
        if let number = entry.number {
            button.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        } else {
            button
        }
    }
}
#endif
