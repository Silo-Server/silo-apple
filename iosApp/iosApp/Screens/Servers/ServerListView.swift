import SwiftUI

/// Manage Servers: every server saved on this device, whoever signs in to
/// it (Settings › Server). Choose a Server lists one user's servers instead.
///
/// Shared between iOS and tvOS with minor platform-specific tweaks:
/// - iOS: Navigation `List` with swipe-to-delete.
/// - tvOS: focusable read-only server summary with a separate remove action.
///
/// Picking a server opens the current user's sign-in there, or starts Add
/// Server for it. Removing one works as Sign Out & Remove Server (spec
/// §5.6): its confirmation names everyone signed in to it, and is shown by
/// the app's presenter (`SignInPromptPresenter`).
struct ServerListView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var isResolvingServer = false
    #if os(tvOS)
    @FocusState private var focusedRow: TVRow?
    /// The server whose trash button opened the confirmation.
    @State private var removingServerID: String?
    #endif

    var body: some View {
        #if os(tvOS)
        tvOSContent
            .disabled(isResolvingServer)
            .background(SettingsBackdrop())
            .task { await router.users.reloadDirectory() }
            .onChange(of: router.removalRequest == nil) { _, closed in
                guard closed, let id = removingServerID, serverIDs.contains(id) else { return }
                claimFocus(.remove(id))
            }
            .onChange(of: serverIDs) { before, after in
                guard let id = removingServerID, !after.contains(id) else { return }
                removingServerID = nil
                claimFocus(TVFocusNeighbor.replacement(for: id, before: before, after: after).map(TVRow.server) ?? .add)
            }
        #else
        contentList
            .disabled(isResolvingServer)
            .navigationTitle("Servers")
            .siloNavigationTitleDisplayMode(.inline)
            .task { await router.users.reloadDirectory() }
        #endif
    }

    #if os(tvOS)
    private var serverIDs: [String] { registry.sortedEntries.map(\.id) }

    private var tvOSContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONNECTION")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.siloSecondaryText)
                    Text("Manage Servers")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                    Text("Every Silo server saved on this Apple TV, for every user.")
                        .font(.system(size: 20))
                        .foregroundColor(.siloSecondaryText)
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
                    Task { await router.users.startAddServer(router: router) }
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

                TVSettingsFooter("Select the trash icon to remove a saved server. Removing it signs out everyone who uses it on this Apple TV.")
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 64)
        .defaultFocus($focusedRow, defaultTVRow)
    }

    private var defaultTVRow: TVRow {
        registry.sortedEntries.first.map { .server($0.id) } ?? .add
    }

    private func tvOSRow(for entry: ServerEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                guard entry.id != registry.activeServerId else { return }
                switchTo(entry)
            } label: {
                TVServerSummaryLabel(
                    entry: entry,
                    isActive: entry.id == registry.activeServerId,
                    userNames: router.users.directory.users(onServer: entry.id).map(\.name)
                )
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($focusedRow, equals: .server(entry.id))
            .accessibilityHint(
                entry.id == registry.activeServerId
                    ? "Current server. Server names are managed by the server administrator"
                    : "Switch to this server. Server names are managed by the server administrator"
            )

            Button {
                removingServerID = entry.id
                requestRemoval(of: entry)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 49)
            }
            .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
            .frame(width: 92)
            .focused($focusedRow, equals: .remove(entry.id))
            .accessibilityLabel("Remove \(entry.displayName)")
        }
    }

    private enum TVRow: Hashable {
        case server(String)
        case remove(String)
        case add
    }

    /// Back on the trash button after Cancel, or on the row that took the
    /// removed server's place.
    private func claimFocus(_ row: TVRow) {
        Task { @MainActor in
            await Task.yield()
            focusedRow = row
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(80))
                guard focusedRow == nil else { return }
                focusedRow = row
            }
        }
    }
    #endif

    #if !os(tvOS)
    private var contentList: some View {
        List {
            Section {
                ForEach(registry.sortedEntries) { entry in
                    row(for: entry)
                }
            } header: {
                Text("Saved servers")
                    .foregroundColor(.siloSecondaryText)
            } footer: {
                Text("Removing a server signs out everyone who uses it on this device.")
                    .foregroundColor(.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Button {
                    Task { await router.users.startAddServer(router: router) }
                } label: {
                    Label("Add Server", systemImage: "plus")
                        .foregroundColor(.siloOnSurface)
                }
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
    }

    @ViewBuilder
    private func row(for entry: ServerEntry) -> some View {
        Button {
            switchTo(entry)
        } label: {
            ServerRowLabel(entry: entry, isActive: entry.id == registry.activeServerId)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestRemoval(of: entry)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
    #endif

    /// A server the current user has opens; one it doesn't starts Add
    /// Server for it (`SiloUserCoordinator.beginSignIn(forServer:)`).
    private func switchTo(_ entry: ServerEntry) {
        guard entry.id != registry.activeServerId else {
            refreshAuthState()
            return
        }
        isResolvingServer = true
        Task {
            await router.users.beginSignIn(forServer: entry.id, router: router)
            isResolvingServer = false
        }
    }

    /// Asks first: removing the server signs out everyone on it and removes
    /// a user whose only server it was, then follows the launch rules when
    /// it was the one in use (spec §5.6, §6.2).
    private func requestRemoval(of entry: ServerEntry) {
        guard !isResolvingServer else { return }
        Task { await router.users.requestRemoval(.server(entry.id), router: router) }
    }

    /// Recompute auth state for the active server and drop any in-tab
    /// navigation that belonged to it.
    private func refreshAuthState() {
        router.popToRoot()
        isResolvingServer = true
        Task {
            await router.users.reopenCurrent(router: router)
            isResolvingServer = false
        }
    }
}
