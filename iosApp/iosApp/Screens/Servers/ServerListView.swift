import SwiftUI

/// Picker + management UI for the set of saved Silo servers.
///
/// Shared between iOS and tvOS with minor platform-specific tweaks:
/// - iOS: Navigation `List` with swipe-to-delete and long-press rename.
/// - tvOS: focus-aware tile row; rename via an on-screen alert.
///
/// Switching a server asks the `AppRouter` to re-evaluate auth state so
/// the user lands on login or profile-select for the new server (or on
/// home if tokens are still valid there).
struct ServerListView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var renameTarget: ServerEntry?
    @State private var renameInput: String = ""
    @State private var removeTarget: ServerEntry?
    #if os(tvOS)
    @FocusState private var focusedRow: TVRow?
    #endif

    var body: some View {
        #if os(tvOS)
        tvOSContent
            .continuumBackground()
            .fullScreenCover(item: $renameTarget) { entry in
                TVServerRenameSheet(entry: entry)
            }
            .alert(
                "Remove this server?",
                isPresented: Binding(
                    get: { removeTarget != nil },
                    set: { if !$0 { removeTarget = nil } }
                ),
                presenting: removeTarget
            ) { entry in
                Button("Remove", role: .destructive) {
                    remove(entry)
                }
                Button("Cancel", role: .cancel) { removeTarget = nil }
            } message: { entry in
                Text("Sign-in credentials for \(entry.displayName) will be forgotten on this device.")
            }
        #else
        contentList
            .navigationTitle("Servers")
            .continuumNavigationTitleDisplayMode(.inline)
            .continuumBackground()
            .continuumScrollContentBackgroundHidden()
            .alert(
                "Rename server",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { entry in
                #if !os(tvOS)
                TextField("Name", text: $renameInput)
                #endif
                Button("Save") {
                    registry.rename(serverId: entry.id, userOverrideName: renameInput)
                    renameTarget = nil
                }
                if entry.userOverrideName != nil {
                    Button("Reset to server-provided name", role: .destructive) {
                        registry.rename(serverId: entry.id, userOverrideName: nil)
                        renameTarget = nil
                    }
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { _ in
                Text("Override the server-provided name with a label just for this device.")
            }
            .alert(
                "Remove this server?",
                isPresented: Binding(
                    get: { removeTarget != nil },
                    set: { if !$0 { removeTarget = nil } }
                ),
                presenting: removeTarget
            ) { entry in
                Button("Remove", role: .destructive) {
                    let wasActive = entry.id == registry.activeServerId
                    Task {
                        await registry.remove(serverId: entry.id)
                        await MainActor.run {
                            removeTarget = nil
                            // Removing the active server leaves the app
                            // pointed at a fallback (or none). Re-enter
                            // the auth state machine so the user lands
                            // in the right place instead of on a stale
                            // main-app screen.
                            if wasActive { refreshAuthState() }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { removeTarget = nil }
            } message: { entry in
                Text("Sign-in credentials for \(entry.displayName) will be forgotten on this device.")
            }
        #endif
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONNECTION")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.continuumSecondaryText)
                    Text("Manage Servers")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                    Text("Switch between saved Silo servers or add another connection.")
                        .font(.system(size: 20))
                        .foregroundColor(.continuumSecondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                TVSettingsSectionHeader("SAVED SERVERS")

                if registry.sortedEntries.isEmpty {
                    TVSettingsFooter("No servers have been saved on this Apple TV.")
                } else {
                    ForEach(registry.sortedEntries) { entry in
                        tvOSRow(for: entry)
                    }
                }

                TVSettingsSectionHeader("CONNECTIONS")

                Button {
                    router.navigate(to: .serverSetup)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 28)
                        Text("Add Server")
                            .font(.system(size: 26))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedRow, equals: .add)

                TVSettingsFooter("Press and hold a saved server to rename or remove it. Selecting the active server refreshes its sign-in state.")
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, ContinuumTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 64)
        .defaultFocus($focusedRow, defaultTVRow)
    }

    private var defaultTVRow: TVRow {
        registry.sortedEntries.first.map { .server($0.id) } ?? .add
    }

    private func tvOSRow(for entry: ServerEntry) -> some View {
        Button {
            switchTo(entry)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: entry.id == registry.activeServerId
                      ? "checkmark.circle.fill"
                      : "server.rack")
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 26, weight: .medium))
                        .lineLimit(1)
                    Text(entry.url)
                        .font(.system(size: 19))
                        .opacity(0.62)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if entry.id == registry.activeServerId {
                    Text("Active")
                        .font(.system(size: 19, weight: .semibold))
                        .opacity(0.72)
                }
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .focused($focusedRow, equals: .server(entry.id))
        .contextMenu {
            Button {
                renameTarget = entry
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                removeTarget = entry
            } label: {
                Label("Remove Server", systemImage: "trash")
            }
        }
    }

    private enum TVRow: Hashable {
        case server(String)
        case add
    }
    #endif

    private var contentList: some View {
        List {
            Section {
                ForEach(registry.sortedEntries) { entry in
                    row(for: entry)
                }
            } header: {
                Text("Saved servers")
                    .foregroundColor(.continuumSecondaryText)
            }
            .listRowBackground(Color.continuumSurfaceElevated)

            Section {
                Button {
                    router.resetToServerSetup()
                } label: {
                    Label("Add Server", systemImage: "plus")
                        .foregroundColor(.continuumOnSurface)
                }
            }
            .listRowBackground(Color.continuumSurfaceElevated)
        }
        .continuumGroupedListStyle()
    }

    @ViewBuilder
    private func row(for entry: ServerEntry) -> some View {
        Button {
            switchTo(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.id == registry.activeServerId
                      ? "checkmark.circle.fill"
                      : "server.rack")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.continuumOnSurface)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.continuumSubheadline)
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(1)
                    Text(entry.url)
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameInput = entry.userOverrideName ?? entry.fetchedName ?? ""
                renameTarget = entry
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                removeTarget = entry
            } label: {
                Label("Remove Server", systemImage: "trash")
            }
        }
        #if !os(tvOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removeTarget = entry
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                renameInput = entry.userOverrideName ?? entry.fetchedName ?? ""
                renameTarget = entry
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.continuumOnSurface)
        }
        #endif
    }

    private func switchTo(_ entry: ServerEntry) {
        guard entry.id != registry.activeServerId else {
            // Already active: re-evaluate in case tokens expired and
            // the UI just needs to catch up.
            refreshAuthState()
            return
        }
        Task {
            await registry.switchTo(serverId: entry.id)
            await MainActor.run { refreshAuthState() }
        }
    }

    private func remove(_ entry: ServerEntry) {
        let wasActive = entry.id == registry.activeServerId
        Task {
            await registry.remove(serverId: entry.id)
            await MainActor.run {
                removeTarget = nil
                if wasActive { refreshAuthState() }
            }
        }
    }

    /// Recompute auth state for the (possibly new) active server and
    /// drop any in-tab navigation that belonged to the previous server.
    private func refreshAuthState() {
        router.popToRoot()
        let auth = AuthService.shared
        if !auth.hasServer {
            router.authState = .needsServerSetup
        } else if !auth.isLoggedIn {
            router.authState = .needsLogin
        } else if !auth.hasProfile {
            router.authState = .needsProfile
        } else {
            router.authState = .authenticated
        }
    }
}

#if os(tvOS)
private struct TVServerRenameSheet: View {
    let entry: ServerEntry

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focusedField: Field?

    init(entry: ServerEntry) {
        self.entry = entry
        _name = State(initialValue: entry.userOverrideName ?? entry.fetchedName ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SERVER")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.continuumSecondaryText)
                    Text("Rename Server")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                    Text("Override the server-provided name with a label just for this Apple TV.")
                        .font(.system(size: 21))
                        .foregroundColor(.continuumSecondaryText)
                }

                TextField("Server Name", text: $name)
                    .textContentType(.name)
                    .font(.system(size: 26))
                    .focused($focusedField, equals: .name)

                HStack(spacing: 18) {
                    Button("Cancel") { dismiss() }
                    Button("Save") {
                        ServerRegistry.shared.rename(serverId: entry.id, userOverrideName: name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if entry.userOverrideName != nil {
                        Button("Use Server Name", role: .destructive) {
                            ServerRegistry.shared.rename(serverId: entry.id, userOverrideName: nil)
                            dismiss()
                        }
                    }
                }
            }
            .frame(maxWidth: 900, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 80)
            .background(Color.continuumBackground.ignoresSafeArea())
            .defaultFocus($focusedField, .name)
            .onExitCommand { dismiss() }
        }
    }

    private enum Field: Hashable {
        case name
    }
}
#endif
