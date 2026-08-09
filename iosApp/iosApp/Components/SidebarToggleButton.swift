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

/// Leading sidebar button that opens the iPad overlay.
///
/// Renders nothing unless a toggle action is present in the environment —
/// i.e. only on iPad in the sidebar layout. Styled to match the circular
/// icon buttons used by `TabTopBarActions`.
struct SidebarToggleButton: View {
    @Environment(\.sidebarToggle) private var toggle

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
        }
    }
}
