import SwiftUI

/// Action that collapses or expands the iPad sidebar.
///
/// Published into the environment by `MainTabView` only when the app is in
/// the regular-width sidebar layout. Screens whose custom header replaces
/// the navigation bar (Home / Libraries / Recommendations) read this value
/// and render `SidebarToggleButton` when it is non-nil.
struct SidebarToggleEnvironmentKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var sidebarToggle: (() -> Void)? {
        get { self[SidebarToggleEnvironmentKey.self] }
        set { self[SidebarToggleEnvironmentKey.self] = newValue }
    }
}

struct ReservesSidebarToggleSpaceEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reservesSidebarToggleSpace: Bool {
        get { self[ReservesSidebarToggleSpaceEnvironmentKey.self] }
        set { self[ReservesSidebarToggleSpaceEnvironmentKey.self] = newValue }
    }
}

/// Leading sidebar button that opens the iPad overlay.
///
/// Renders the button only while the iPad sidebar is closed. While the overlay
/// is open, the sidebar layout can reserve the same footprint so neighboring
/// header content does not shift. Styled to match the circular icon buttons
/// used by `TabTopBarActions`.
struct SidebarToggleButton: View {
    @Environment(\.sidebarToggle) private var toggle
    @Environment(\.reservesSidebarToggleSpace) private var reservesSpace

    @ViewBuilder
    var body: some View {
        if let toggle {
            Button(action: toggle) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.continuumOnSurface)
                    .frame(width: ContinuumTheme.topBarIconHitSize, height: ContinuumTheme.topBarIconHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open sidebar")
        } else if reservesSpace {
            Color.clear
                .frame(
                    width: ContinuumTheme.topBarIconHitSize,
                    height: ContinuumTheme.topBarIconHitSize
                )
                .accessibilityHidden(true)
        }
    }
}
