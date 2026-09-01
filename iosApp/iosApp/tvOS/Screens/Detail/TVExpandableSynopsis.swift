#if os(tvOS)
import SwiftUI

/// The hero's overview as an expand-in-place control. Clamped to 3 lines;
/// Select expands to the full overview and back.
/// This is the detail page's only text focus stop — reachable by pressing Up
/// from the action row — and it is actionable, so it never feels "stuck".
struct TVExpandableSynopsis: View {
    let overview: String

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let maxWidth: CGFloat = TVDetailLayout.heroContentWidth

    var body: some View {
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 12) {
                Text(overview)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(.white.opacity(0.92))
                    .lineSpacing(4)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVSynopsisButtonStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.normalDuration), value: expanded)
    }
}

/// No chrome at rest; on focus a faint fill cue so the user knows it's
/// actionable. Suppresses the system halo (matches the page idiom).
private struct TVSynopsisButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVSynopsisButtonStyleBody(configuration: configuration)
    }
}

private struct TVSynopsisButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous)
                    .fill(Color.continuumSurfaceElevated.opacity(isFocused ? 0.55 : 0))
            )
            .padding(.horizontal, -20)
            .padding(.vertical, -14)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }
}
#endif
