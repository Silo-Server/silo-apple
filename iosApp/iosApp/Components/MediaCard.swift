import SwiftUI

/// Artwork shape for a `MediaCard`.
enum MediaCardAspect {
    /// 2:3 movie/series poster.
    case poster
    /// 1:1 tile for audiobook covers.
    case square
}

func mediaCardAccessibilityLabel(
    title: String,
    episodeBadge: String?,
    year: Int?,
    isWatched: Bool
) -> String {
    var components = [title]
    if let episodeBadge, !episodeBadge.isEmpty {
        components.append(episodeBadge)
    }
    if let year {
        components.append(String(year))
    }
    if isWatched {
        components.append("Watched")
    }
    return components.joined(separator: ", ")
}

func episodeRailAccessibilityLabel(
    seasonNumber: Int,
    episodeNumber: Int,
    title: String?,
    metadata: String?,
    isCurrent: Bool,
    isPlayed: Bool
) -> String {
    let seasonLabel = seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    var components = ["\(seasonLabel), Episode \(episodeNumber)"]
    if let title, !title.isEmpty {
        components.append(title)
    }
    if let metadata, !metadata.isEmpty {
        components.append(metadata)
    }
    if isCurrent {
        components.append("Now viewing")
    }
    if isPlayed {
        components.append("Watched")
    }
    return components.joined(separator: ", ")
}

/// A poster-style media card with title, year, and optional progress.
/// On tvOS the card uses `.buttonStyle(.card)` which gives proper focus lift,
/// parallax, and title reveal — no manual focus effects required.
struct MediaCard: View {
    let title: String
    let posterUrl: String
    var thumbhash: String? = nil
    var year: Int? = nil
    var progress: Double? = nil
    var userState: MediaItemUserState? = nil
    /// Data for the optional overlay badges (resolution, ratings, …).
    /// `nil` skips overlay rendering on this card — callers that
    /// don't have an `OverlaySummary` available (e.g. people /
    /// collection thumbnails) leave this off.
    var overlayData: OverlayData? = nil
    let action: () -> Void
    /// tvOS-only shortcut invoked by the remote's Play/Pause button while
    /// this card owns focus. Select continues to invoke `action`.
    var playAction: (() -> Void)? = nil
    /// tvOS-only: binding to the parent row's `@FocusState` so the parent
    /// can route default focus (`defaultFocus(_:_:priority: .userInitiated)`)
    /// to a specific card. Pass `nil` for callers that don't need row-level
    /// focus targeting.
    var focusedItemId: FocusState<String?>.Binding? = nil

    var contentId: String? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onSetWatched: ((Bool) async -> Bool)? = nil
    var aspect: MediaCardAspect = .poster
    /// Overrides the theme's default card width. Skyline's dense landing
    /// rows (§5.6) pass 208 so two rows + the marquee fit above the fold;
    /// the poster keeps its 2:3 ratio.
    var cardWidthOverride: CGFloat? = nil
    /// "S2 · E10" badge drawn over the bottom-leading corner of the poster
    /// for episodes rendered in a poster row (e.g. "Recently Released
    /// Episodes"). `nil` for movies / series / audiobooks.
    var episodeBadge: String? = nil
    /// Fires after a favorite/watchlist toggle from the card's context
    /// menu commits server-side, with the item's new state. Favorites /
    /// Watchlist grids use it to drop the card from the list in place.
    var onUserStateChanged: ((MediaItemUserState) -> Void)? = nil

    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @EnvironmentObject private var overlayStore: OverlayPrefsStore
    /// iOS 26 zoom transition namespace, shared from `MainTabView`. When
    /// present (and `contentId` is non-nil) the poster acts as the
    /// `.matchedTransitionSource` for the zoom into item detail. `nil` on
    /// tvOS/macOS or when unset, in which case the tap falls back to a plain
    /// push. (iOS branch only — tvOS uses focus-driven `.card` style.)
    @Environment(\.zoomNamespace) private var zoomNamespace
    #if !os(tvOS)
    @Environment(AppRouter.self) private var router
    /// Stable per-placement id for the zoom source. A bare `contentId` collides
    /// when the same item is visible in two rows (e.g. Continue Watching +
    /// Recently Added), making SwiftUI pick an ambiguous source; a per-instance
    /// id keeps each card's source unique and the tapped card's id is handed to
    /// the destination via `router.pendingZoomSourceID`.
    @State private var zoomInstanceID = UUID()
    #endif

    private var cardWidth: CGFloat {
        (cardWidthOverride ?? SiloTheme.posterCardWidth)
            * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        switch aspect {
        case .poster:
            cardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
        case .square:
            cardWidth
        }
    }

    var body: some View {
        #if os(tvOS)
        // tvOS: button label is just the poster (so .card style lifts the image),
        // then a title caption lives outside the button and reacts to focus via FocusState.
        FocusableMediaCard(
            title: title,
            year: year,
            episodeBadge: episodeBadge,
            captionStyle: uiCustomization.cardPresentation.caption,
            cardWidth: cardWidth,
            action: action,
            playAction: playAction,
            focusedItemId: focusedItemId,
            itemId: contentId,
            isWatched: isPlayed,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: optimisticSetWatched,
            personalItems: hasPersonalActions ? personalMenuItems : nil
        ) {
            posterImage
        }
        .onChange(of: userState) { _, _ in
            playedOverride = nil
            favoriteOverride = nil
            watchlistOverride = nil
        }
        #else
        iosCardButton
            .cardContextMenu(contextMenuItems)
            .onChange(of: userState) { _, _ in
                playedOverride = nil
                favoriteOverride = nil
                watchlistOverride = nil
            }
            .frame(width: cardWidth)
        #endif
    }

    #if !os(tvOS)
    private var iosCardButton: some View {
        Group {
            if let contentId {
                Button {
                    router.pendingZoomSourceID = zoomInstanceID.uuidString
                    router.navigate(to: .itemDetail(contentId: contentId))
                } label: {
                    cardContent
                        .zoomTransitionSource(id: zoomInstanceID.uuidString, in: zoomNamespace)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var contextMenuItems: CardContextMenuItems {
        CardContextMenuItems(
            isWatched: isPlayed,
            onSetWatched: optimisticSetWatched,
            personalItems: hasPersonalActions ? personalMenuItems : nil,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching
        )
    }
    #endif

    // MARK: - Favorite / watchlist context actions

    /// Only cards backed by a catalog item (a `contentId` plus server
    /// user state) get the favorite/watchlist menu — thumbnails without
    /// user state (people, collections, discover results) don't.
    private var hasPersonalActions: Bool {
        contentId != nil && userState != nil
    }

    private var isFavorite: Bool {
        favoriteOverride ?? (userState?.isFavorite == true)
    }

    private var isInWatchlist: Bool {
        watchlistOverride ?? (userState?.inWatchlist == true)
    }

    /// The caller's watched handler wrapped in the optimistic `playedOverride`
    /// flip: set the override, await the server, clear it on failure.
    private var optimisticSetWatched: ((Bool) async -> Bool)? {
        onSetWatched.map { handler in
            { played in
                playedOverride = played
                let succeeded = await handler(played)
                if !succeeded {
                    playedOverride = nil
                }
                return succeeded
            }
        }
    }

    private var personalMenuItems: PersonalListMenuItems {
        PersonalListMenuItems(
            isFavorite: isFavorite,
            inWatchlist: isInWatchlist,
            onToggleFavorite: togglePersonalFavorite,
            onToggleWatchlist: togglePersonalWatchlist
        )
    }

    private func togglePersonalFavorite() {
        guard let contentId else { return }
        PersonalListToggles.toggleFavorite(
            contentId: contentId,
            isFavorite: isFavorite,
            inWatchlist: isInWatchlist,
            write: { favoriteOverride = $0 },
            onCommit: publishUserState
        )
    }

    private func togglePersonalWatchlist() {
        guard let contentId else { return }
        PersonalListToggles.toggleWatchlist(
            contentId: contentId,
            isFavorite: isFavorite,
            inWatchlist: isInWatchlist,
            write: { watchlistOverride = $0 },
            onCommit: publishUserState
        )
    }

    /// Favorites / Watchlist grids drop the card in place from this.
    private func publishUserState(isFavorite: Bool, inWatchlist: Bool) {
        onUserStateChanged?(
            MediaItemUserState(played: isPlayed, isFavorite: isFavorite, inWatchlist: inWatchlist)
        )
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            posterImage
            if uiCustomization.cardPresentation.caption.showsTitle {
                titleText
            }
            if uiCustomization.cardPresentation.caption.showsMetadata {
                yearText
            }
        }
    }

    // MARK: - Subviews

    private var posterImage: some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(
                url: posterUrl,
                thumbhash: thumbhash,
                targetSize: CGSize(width: cardWidth, height: cardHeight),
                contentMode: .fill
            )
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))

            // Server / user-customized overlays (resolution, HDR, ratings, …)
            // sit under the watched check + progress bar so those built-in
            // affordances always win the same corner if they conflict.
            if let overlayData, overlayStore.enabled {
                CardOverlays(data: overlayData, prefs: overlayStore.prefs, variant: .poster)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
            }

            // Episode badge (e.g. "S2 · E10") for episodes shown as posters,
            // so new episodes of the same series stay distinguishable.
            if let episodeBadge {
                Text(episodeBadge)
                    .font(.siloCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, episodeBadgeHPadding)
                    .padding(.vertical, episodeBadgeVPadding)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(episodeBadgeInset)
                    .frame(width: cardWidth, height: cardHeight, alignment: .bottomLeading)
            }

            // Progress bar at bottom of poster (inside rounded corners)
            if let progress, progress > 0 {
                VStack {
                    Spacer()
                    ProgressBar(value: progress)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
            }

            // Watched indicator — white circle with check (Plezy style)
            if isPlayed {
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.siloOnSurface)
                            .frame(width: checkBadgeSize, height: checkBadgeSize)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                        Image(systemName: "checkmark")
                            .font(.system(size: checkIconSize, weight: .bold))
                            .foregroundColor(Color.siloBackground)
                    }
                }
                .padding(checkBadgePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            #if !os(tvOS)
            DownloadedBadgeOverlay(contentId: contentId, padding: checkBadgePadding)
            #endif
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    private var isPlayed: Bool {
        playedOverride ?? (userState?.played == true)
    }

    private var accessibilityDescription: String {
        mediaCardAccessibilityLabel(
            title: title,
            episodeBadge: episodeBadge,
            year: year,
            isWatched: isPlayed
        )
    }

    private var titleText: some View {
        Text(title)
            .font(.siloSubheadline)
            .foregroundColor(.siloOnSurface)
            // Reserve 2 lines of space so single- and multi-line titles
            // produce the same overall card height — keeps posters in a
            // row top-aligned when titles wrap.
            .lineLimit(2, reservesSpace: true)
    }

    @ViewBuilder
    private var yearText: some View {
        if let year {
            Text(String(year))
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
        }
    }

    // MARK: - Metric helpers

    private var checkBadgeSize: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 20
        #endif
    }

    private var checkIconSize: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 10
        #endif
    }

    private var checkBadgePadding: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 6
        #endif
    }

    private var episodeBadgeHPadding: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 8
        #endif
    }

    private var episodeBadgeVPadding: CGFloat {
        #if os(tvOS)
        return 7
        #else
        return 4
        #endif
    }

    private var episodeBadgeInset: CGFloat {
        #if os(tvOS)
        return 14
        #else
        return 6
        #endif
    }
}

// MARK: - Zoom transition source helper

extension View {
    /// Marks this view as the `.matchedTransitionSource` for the iOS 26
    /// poster → detail zoom, keyed on the item's `contentId`. No-ops when the
    /// namespace is `nil` (tvOS/macOS, or when the shared namespace is unset),
    /// so callers get a plain push with no crash. Shared by `MediaCard` and
    /// `EpisodeThumbCard` (both in this module).
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}

// MARK: - tvOS Focusable wrapper

#if os(tvOS)
/// Wraps a poster inside a `.card` button so the image gets the native focus
/// lift/parallax, and renders a title + year below that bolds/brightens on focus.
private struct FocusableMediaCard<Content: View>: View {
    let title: String
    let year: Int?
    let episodeBadge: String?
    let captionStyle: CardCaptionStyle
    let cardWidth: CGFloat
    let action: () -> Void
    let playAction: (() -> Void)?
    /// Parent row's focus tracking binding. When paired with `itemId`,
    /// the button binds via `.focused(_, equals: itemId)` so the row's
    /// `defaultFocus(... priority: .userInitiated)` can land focus here
    /// on d-pad entry.
    let focusedItemId: FocusState<String?>.Binding?
    let itemId: String?
    let isWatched: Bool
    let onRemoveFromContinueWatching: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?
    /// Favorite / watchlist toggles, built by the owning card. `nil`
    /// when the card has no catalog identity or user state.
    let personalItems: PersonalListMenuItems?
    @ViewBuilder var content: () -> Content

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            mediaButton

            if captionStyle.showsTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.siloSubheadline)
                        .foregroundStyle(
                            isFocused
                                ? Color.siloOnSurface
                                : Color.siloOnSurface.opacity(0.85)
                        )
                        // Single line, truncated — keeps poster cards a uniform
                        // height and the row short under the bottom-anchored marquee.
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .animation(.easeOut(duration: 0.15), value: isFocused)

                    if captionStyle.showsMetadata, let year {
                        Text(String(year))
                            .font(.siloCaption)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private var mediaButton: some View {
        let button = Button(action: action) {
            content()
        }
        .buttonStyle(.card)
        .focused($isFocused)
        .applyFocusBindingIfPresent(focusedItemId, id: itemId)
        .applyPlayPauseAction(playAction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)

        button.cardContextMenu(contextMenuItems)
    }

    private var contextMenuItems: CardContextMenuItems {
        CardContextMenuItems(
            isWatched: isWatched,
            onSetWatched: onSetWatched,
            personalItems: personalItems,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching
        )
    }

    private var accessibilityDescription: String {
        mediaCardAccessibilityLabel(
            title: title,
            episodeBadge: episodeBadge,
            year: year,
            isWatched: isWatched
        )
    }
}

#endif
