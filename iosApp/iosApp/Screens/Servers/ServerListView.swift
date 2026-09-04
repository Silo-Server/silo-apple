import SwiftUI

/// Picker + management UI for the set of saved Silo servers.
///
/// Shared between iOS and tvOS with minor platform-specific tweaks:
/// - iOS: Navigation `List` with swipe-to-delete.
/// - tvOS: focusable read-only server summary with a separate remove action.
///
/// Switching a server asks the `AppRouter` to re-evaluate auth state so
/// the user lands on login or profile-select for the new server (or on
/// home if tokens are still valid there).
struct ServerListView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var removeTarget: ServerEntry?
    #if os(tvOS)
    @FocusState private var focusedRow: TVRow?
    #endif

    var body: some View {
        #if os(tvOS)
        ZStack {
            tvOSContent
                .disabled(removeTarget != nil)

            if let entry = removeTarget {
                TVSettingsConfirmationOverlay(
                    title: "Remove this server?",
                    message: "Sign-in credentials for \(entry.displayName) will be forgotten on this device.",
                    confirmTitle: "Remove",
                    cancel: { dismissRemoveConfirmation(for: entry) },
                    confirm: { remove(entry) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .background(SettingsBackdrop())
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: removeTarget)
        #else
        contentList
            .navigationTitle("")
            .continuumNavigationTitleDisplayMode(.inline)
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
                    Text("Manage saved Silo servers or add another connection.")
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

                TVSettingsFooter("Select the trash icon to remove a saved server.")
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
        HStack(spacing: 12) {
            Button {
                guard entry.id != registry.activeServerId else { return }
                switchTo(entry)
            } label: {
                TVServerSummaryLabel(
                    entry: entry,
                    isActive: entry.id == registry.activeServerId
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
                removeTarget = entry
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

    private func dismissRemoveConfirmation(for entry: ServerEntry) {
        removeTarget = nil
        Task { @MainActor in
            await Task.yield()
            focusedRow = .remove(entry.id)
        }
    }
    #endif

    #if !os(tvOS)
    private var contentList: some View {
        List {
            SettingsPageHeader(
                title: "Servers",
                subtitle: "Manage saved Silo connections for this device.",
                systemImage: "server.rack",
                tint: .teal
            )
            .settingsPageHeaderRow()

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
        .settingsListChrome()
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removeTarget = entry
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
    #endif

    private func switchTo(_ entry: ServerEntry) {
        guard entry.id != registry.activeServerId else {
            refreshAuthState()
            return
        }
        Task {
            guard await registry.switchTo(
                serverId: entry.id,
                resolveDestinationProfile: true
            ) else { return }
            await MainActor.run { refreshAuthState() }
        }
    }

    private func remove(_ entry: ServerEntry) {
        let wasActive = entry.id == registry.activeServerId
        Task {
            guard await registry.remove(
                serverId: entry.id,
                resolveFallbackProfile: wasActive
            ) else { return }
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
        // A server switch can land back on `.authenticated`, which the
        // router's same-value guard drops — so the identity boundary for an
        // engaged PiP video is enforced here, before the reassignment.
        PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
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
private struct TVServerSummaryLabel: View {
    let entry: ServerEntry
    let isActive: Bool

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
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

            if isActive {
                Text("Active")
                    .font(.system(size: 19, weight: .semibold))
                    .opacity(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Active" : "Saved")
    }
}
#endif
