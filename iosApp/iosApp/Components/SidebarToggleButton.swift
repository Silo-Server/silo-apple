import SwiftUI

extension EnvironmentValues {
    /// Action that collapses or expands the iPad sidebar.
    ///
    /// Published into the environment by `MainTabView` only when the app is in
    /// the regular-width sidebar layout. Screens whose custom header replaces
    /// the navigation bar (Home / Libraries / Recommendations) read this value
    /// and render `SidebarToggleButton` when it is non-nil.
    @Entry var sidebarToggle: SidebarToggleAction? = nil
    @Entry var reservesSidebarToggleSpace = false
}

/// Every toggle does the same thing, so instances compare equal and a new
/// closure on each layout pass never redraws the screens that read it.
struct SidebarToggleAction: Equatable {
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
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
            Button(action: toggle.perform) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open sidebar")
        } else if reservesSpace {
            Color.clear
                .frame(
                    width: SiloTheme.topBarIconHitSize,
                    height: SiloTheme.topBarIconHitSize
                )
                .accessibilityHidden(true)
        }
    }
}
