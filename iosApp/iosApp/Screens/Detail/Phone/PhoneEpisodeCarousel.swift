#if !os(tvOS)
import SwiftUI

/// The Series page's episode carousel, including loading and empty states.
struct PhoneEpisodeCarousel: View {
    let episodes: [EpisodeListItem]
    let isLoading: Bool
    let onSelect: (String) -> Void
    var onPlay: ((String) -> Void)? = nil
    var currentContentId: String? = nil
    var selectsCenteredEpisode = false
    var captionStyleOverride: CardCaptionStyle? = nil
    var onSetWatched: ((EpisodeListItem, Bool) -> Void)? = nil
    var isUpdatingWatched = false
    var favoriteStates: [String: Bool] = [:]
    var watchlistStates: [String: Bool] = [:]
    var onSetFavorite: ((String, Bool) async -> Bool)? = nil
    var onSetWatchlist: ((String, Bool) async -> Bool)? = nil

    /// The last real page height is retained while a new season is loading.
    /// Without this, replacing the carousel with a small spinner collapses the
    /// detail stack and changes the vertical scroll offset under the user's
    /// finger.
    @State private var settledContentHeight: CGFloat = 0

    var body: some View {
        Group {
            if isLoading, episodes.isEmpty {
                PhoneEpisodeRailSkeleton(captionStyleOverride: captionStyleOverride)
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SiloTheme.safePadding)
                    .padding(.vertical, 12)
            } else {
                PhoneEpisodeRail(
                    episodes: episodes,
                    onSelect: onSelect,
                    onPlay: onPlay,
                    currentContentId: currentContentId,
                    selectsCenteredEpisode: selectsCenteredEpisode,
                    captionStyleOverride: captionStyleOverride,
                    onSetWatched: onSetWatched,
                    isUpdatingWatched: isUpdatingWatched,
                    favoriteStates: favoriteStates,
                    watchlistStates: watchlistStates,
                    onSetFavorite: onSetFavorite,
                    onSetWatchlist: onSetWatchlist
                )
            }
        }
        .frame(
            minHeight: isLoading && episodes.isEmpty && settledContentHeight > 0
                ? settledContentHeight
                : nil,
            alignment: .top
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            guard !isLoading, !episodes.isEmpty, height > 0 else { return }
            settledContentHeight = height
        }
        .animation(.easeInOut(duration: 0.16), value: isLoading && episodes.isEmpty)
    }
}

#endif
