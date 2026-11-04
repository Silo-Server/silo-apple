#if os(macOS)
import SwiftUI

/// The Mac's grouped sidebar: Home, then collapsible Libraries, Discover, and
/// Your Stuff groups. Group expansion is remembered per device.
struct MacSidebar: View {
    let sections: [MacSidebarSection]
    /// Row matching the page in view; nil when the page belongs to no row.
    let highlight: MainTabDestinationID?
    let onSelect: (MainTabDestinationID) -> Void

    @Environment(AppRouter.self) private var router
    /// Shared session cache, so the avatar never flashes its fallback.
    private let profileStore = CurrentProfileStore.shared

    @AppStorage("mac.sidebar.librariesExpanded") private var librariesExpanded = true
    @AppStorage("mac.sidebar.discoverExpanded") private var discoverExpanded = true
    @AppStorage("mac.sidebar.yourStuffExpanded") private var yourStuffExpanded = true

    /// macOS fills the selected row with the accent only while the list has
    /// focus in the key window; the list's environment does not report it.
    @FocusState private var isListFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        List(selection: Binding<MainTabDestinationID?>(
            get: { highlight },
            set: { value in
                guard let value else { return }
                onSelect(value)
            }
        )) {
            ForEach(sections) { section in
                if let title = section.title {
                    Section(isExpanded: expansion(for: section.id)) {
                        rows(for: section)
                    } header: {
                        Text(title)
                            .font(.siloCaption)
                            .textCase(.uppercase)
                            .tracking(SiloTheme.macSidebarHeadingTracking)
                    }
                } else {
                    rows(for: section)
                }
            }
        }
        .listStyle(.sidebar)
        .focused($isListFocused)
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .background(Color.siloSidebarCanvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            SiloWordmarkView(width: SiloTheme.macSidebarWordmarkWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SiloTheme.padding)
                .padding(.vertical, SiloTheme.spacing)
                // Opaque, so rows scrolling underneath do not show through.
                .background(Color.siloSidebarCanvas)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProfileAvatarMenu(
                profile: profileStore.profile,
                showsName: true,
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { onSelect(.app(.requests)) },
                onSwitchProfile: { router.switchProfile() },
                onSignOut: { router.signOutAndReset() }
            )
            .menuIndicator(.hidden)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.smallPadding)
            .background(Color.siloSidebarCanvas)
            .overlay(alignment: .top) {
                Divider().overlay(Color.siloDivider)
            }
            .task { await profileStore.refresh() }
        }
    }

    private func rows(for section: MacSidebarSection) -> some View {
        ForEach(section.items) { destination in
            let isSelected = highlight == destination.id
            MacSidebarRow(
                destination: destination,
                isSelected: isSelected,
                isOnAccentHighlight: isSelected && isListFocused && controlActiveState == .key
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // The list reports a click only when the selection changes, so the
            // row handles its own click: the highlighted row returns to its root.
            .onTapGesture { onSelect(destination.id) }
            .tag(destination.id)
        }
    }

    private func expansion(for id: MacSidebarSectionID) -> Binding<Bool> {
        switch id {
        case .home: return .constant(true)
        case .libraries: return $librariesExpanded
        case .discover: return $discoverExpanded
        case .yourStuff: return $yourStuffExpanded
        }
    }
}

/// One sidebar row. While the sidebar has keyboard focus in the key window,
/// macOS fills the selected row with the app accent, which is near white, and
/// repaints its label white. That row draws its label and icon in black
/// instead. The highlight without focus is dark, so rows keep their usual
/// colors there.
private struct MacSidebarRow: View {
    let destination: MainTabDestination
    let isSelected: Bool
    /// True while the row sits on the accent-filled selection highlight.
    let isOnAccentHighlight: Bool

    var body: some View {
        if isOnAccentHighlight {
            // The group keeps the list from repainting the text white.
            content
                .foregroundStyle(Color.black)
                .compositingGroup()
        } else {
            content
        }
    }

    private var content: some View {
        HStack {
            Label {
                Text(destination.title)
            } icon: {
                // Styled inside the label, or the sidebar label style whitens it.
                if isOnAccentHighlight {
                    icon.foregroundStyle(Color.black)
                } else {
                    icon
                }
            }
            if destination.id == .app(.search) {
                Spacer()
                Text("⌘K")
                    .font(.siloSmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: Image {
        Image(systemName: isSelected ? destination.selectedIcon : destination.icon)
    }
}
#endif
