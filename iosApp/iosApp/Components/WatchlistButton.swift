import SwiftUI

/// Toggle button for adding/removing an item from the watchlist.
/// Plezy style: white icon, no accent color.
struct WatchlistButton: View {
    let inWatchlist: Bool
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
            Image(systemName: inWatchlist ? "bookmark.fill" : "bookmark")
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
        .accessibilityLabel(inWatchlist ? "Remove from watchlist" : "Add to watchlist")
    }
}
