import SwiftUI

/// Toggle button for marking an item as favorite.
/// Plezy style: white icon, no accent color.
struct FavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    #if os(tvOS)
    private let iconSize: CGFloat = 28
    private let buttonSize: CGFloat = 72
    #else
    private let iconSize: CGFloat = 20
    private let buttonSize: CGFloat = 44
    #endif

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: iconSize))
                .foregroundColor(.siloOnSurface)
                .frame(width: buttonSize, height: buttonSize)
                .background(Circle().fill(Color.siloSurfaceElevated))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
        }
        #if os(tvOS)
        .buttonStyle(CircularFocusButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
    }
}

#if os(tvOS)
/// Focus style for circular icon buttons — scales gently without the
/// rectangular lift effect that `.card` applies (which doesn't suit circles).
struct CircularFocusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CircularFocusButtonBody(configuration: configuration)
    }
}

private struct CircularFocusButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .shadow(color: isFocused ? .white.opacity(0.35) : .clear, radius: isFocused ? 16 : 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif
