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
    @State private var isResolvingServer = false
    #if os(tvOS)
    @State private var removeTarget: ServerEntry?
    @FocusState private var focusedRow: TVRow?
    #endif

    var body: some View {
        #if os(tvOS)
        ZStack {
            tvOSContent
                .disabled(removeTarget != nil || isResolvingServer)

            if let entry = removeTarget {
                TVSettingsConfirmationOverlay(
                    title: .serversRemoveConfirmTitle,
                    message: .serversRemoveBodyAppleTv(entry.displayName),
                    confirmTitle: .serversRemoveConfirm,
                    cancel: { dismissRemoveConfirmation(for: entry) },
                    confirm: { remove(entry) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .background(SettingsBackdrop())
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: removeTarget)
        #else
        // Removing asks through the app's shared confirmation
        // (`AccountRemovalConfirmationModifier`), which names the accounts
        // and downloads that go with the server.
        contentList
            .disabled(isResolvingServer)
            .navigationTitle(Text(.serversTitle))
            .siloNavigationTitleDisplayMode(.inline)
        #endif
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(.serversManageEyebrow)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.siloSecondaryText)
                    Text(.serversManageTitle)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                    Text(.serversManageBody)
                        .font(.system(size: 20))
                        .foregroundColor(.siloSecondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                TVSettingsSectionHeader(.serversManageSavedHeader)

                if registry.sortedEntries.isEmpty {
                    TVSettingsFooter(.serversManageEmpty)
                } else {
                    ForEach(registry.sortedEntries) { entry in
                        tvOSRow(for: entry)
                    }
                }

                TVSettingsSectionHeader(.serversManageConnectionsHeader)

                Button {
                    router.navigate(to: .serverSetup)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 28)
                        Text(.serversAddServer)
                            .font(.system(size: 26))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedRow, equals: .add)

                TVSettingsFooter(.serversManageRemoveHint)
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
                    isActive: entry.id == registry.activeServerId
                )
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($focusedRow, equals: .server(entry.id))
            .accessibilityHint(
                Text(entry.id == registry.activeServerId
                    ? LocalizedStringResource.serversRowHintCurrent
                    : .serversRowHintSwitch)
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
            .accessibilityLabel(Text(.serversRemoveAudio(entry.displayName)))
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
            Section {
                ForEach(registry.sortedEntries) { entry in
                    row(for: entry)
                }
            } header: {
                Text(.serversSavedHeader)
                    .foregroundColor(.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Button {
                    router.resetToServerSetup()
                } label: {
                    Label(.serversAddServer, systemImage: "plus")
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
            HStack(spacing: 12) {
                MarqueeServerMark(server: entry, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.siloSubheadline)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(1)
                    Text(entry.url)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.id == registry.activeServerId, LocalRouteController.shared.isOnLocalNetwork {
                        LocalRouteStatusLine()
                            .font(.siloCaption)
                            .foregroundColor(.siloSecondaryText)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer()
                if entry.id == registry.activeServerId {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(entry.id == registry.activeServerId ? Text(.serversActive) : Text(verbatim: ""))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await router.confirmRemoveServer(entry.id) }
            } label: {
                Label(.serversRemove, systemImage: "trash")
            }
        }
    }
    #endif

    private func switchTo(_ entry: ServerEntry) {
        guard entry.id != registry.activeServerId else {
            refreshAuthState()
            return
        }
        isResolvingServer = true
        Task {
            guard await registry.switchTo(
                serverId: entry.id,
                resolveDestinationProfile: true
            ) else {
                isResolvingServer = false
                return
            }
            let state = await RestoredSessionAuthResolver.resolveValidated()
            isResolvingServer = false
            router.resetAfterServerResolution(to: state)
        }
    }

    #if os(tvOS)
    private func remove(_ entry: ServerEntry) {
        guard !isResolvingServer else { return }
        isResolvingServer = true
        let wasActive = entry.id == registry.activeServerId
        Task {
            // Every account on the server signs out first, deleting its downloads.
            let removed = await AccountSessions.removeServer(entry.id)
            isResolvingServer = false
            removeTarget = nil
            guard removed else {
                router.accountActionError = AppLanguage.string(.serversRemoveFailedToast)
                if wasActive { refreshAuthState() }
                return
            }
            if wasActive { refreshAuthState() }
        }
    }
    #endif

    /// Recompute auth state for the (possibly new) active server and
    /// drop any in-tab navigation that belonged to the previous server.
    private func refreshAuthState() {
        router.popToRoot()
        isResolvingServer = true
        Task {
            let state = await RestoredSessionAuthResolver.resolveValidated()
            isResolvingServer = false
            router.resetAfterServerResolution(to: state)
        }
    }
}

#if os(tvOS)
private struct TVServerSummaryLabel: View {
    let entry: ServerEntry
    let isActive: Bool

    var body: some View {
        HStack(spacing: 18) {
            // Its branding mark, else the Silo project icon (spec §4.1).
            MarqueeServerMark(server: entry, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
                Text(entry.url)
                    .font(.system(size: 19))
                    .opacity(0.62)
                    .lineLimit(1)
                if isActive, LocalRouteController.shared.isOnLocalNetwork {
                    LocalRouteStatusLine()
                        .font(.system(size: 19))
                        .opacity(0.62)
                }
            }

            Spacer(minLength: 16)

            if isActive {
                Text(.serversActive)
                    .font(.system(size: 19, weight: .semibold))
                    .opacity(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(isActive ? LocalizedStringResource.serversActive : .serversSaved))
    }
}
#endif

/// "Connected on your local network" under the active server while its
/// requests use the local route; the icon sits inline so the text starts
/// where the address above it does.
private struct LocalRouteStatusLine: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "house.fill")
                .imageScale(.small)
            Text(LocalRouteController.statusText)
        }
        .accessibilityElement(children: .combine)
    }
}
