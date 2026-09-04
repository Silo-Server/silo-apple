import SwiftUI

/// App-wide default `ButtonStyle` that suppresses the tvOS system focus
/// treatment (the large white "slab" halo SwiftUI paints around focused
/// buttons). Applied at the window root so every `Button` that does not
/// explicitly set its own style renders as just its label, with a quiet
/// press-scale tick — no stray focus chrome leaking in.
///
/// Individual components that need their own focus visuals should opt in
/// with a locally-scoped `ButtonStyle` (e.g. `TVPillButtonStyle`, or the
/// invisible focus host behind `TVCircleActionButton`) — never with
/// `.buttonStyle(.plain)` on tvOS,
/// which still triggers the system highlight on `Button` bounds.
struct SiloFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SiloFlatButtonStyle {
    /// App-wide flat style that does not add any platform focus chrome.
    static var siloFlat: SiloFlatButtonStyle { .init() }
}

// MARK: - Ghost chip button style (shared)

/// Translucent pill with a focus-aware outline. Used for utility actions
/// (Sign Out / Cancel) so they read as "secondary" next to the identity
/// tiles and primary buttons. Shared by `ProfileSelectionView` and
/// `CreateProfileView` (previously duplicated byte-for-byte in both).
struct GhostChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostChipBody(configuration: configuration)
    }
}

private struct GhostChipBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.siloBackground : Color.white.opacity(0.75))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(
                    isFocused ? Color.white : Color.white.opacity(0.08)
                )
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.clear : Color.white.opacity(0.22),
                    lineWidth: 1
                )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }
}
