import SwiftUI

/// Stable action order across Home, catalog grids, and episode rails. Hosts
/// retain platform-specific playback/navigation actions ahead of this group.
struct MediaStateMenuItems: View {
    let isWatched: Bool
    let isFavorite: Bool
    let inWatchlist: Bool
    var watchedSubject: String? = nil
    var isUpdating = false
    var onToggleWatched: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil
    var onToggleWatchlist: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onToggleWatched {
                Button(action: onToggleWatched) {
                    Label(watchedTitle, systemImage: isWatched ? "circle" : "checkmark.circle")
                }
            }
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Label(
                        isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorite ? "heart.slash" : "heart"
                    )
                }
            }
            if let onToggleWatchlist {
                Button(action: onToggleWatchlist) {
                    Label(
                        inWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                        systemImage: inWatchlist ? "bookmark.slash" : "bookmark"
                    )
                }
            }
        }
        .disabled(isUpdating)
    }

    private var watchedTitle: String {
        let subject = watchedSubject ?? "as"
        return isWatched ? "Mark \(subject) Unwatched" : "Mark \(subject) Watched"
    }
}

extension View {
    @ViewBuilder
    func mediaStateContextMenu(_ items: MediaStateMenuItems?) -> some View {
        if let items {
            contextMenu { items }
        } else {
            self
        }
    }
}
