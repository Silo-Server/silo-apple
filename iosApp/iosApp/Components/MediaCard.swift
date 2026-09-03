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
    episodeLabel: String?,
    year: Int?,
    isWatched: Bool
) -> String {
    var components = [title]
    if let episodeLabel, !episodeLabel.isEmpty {
        components.append(episodeLabel)
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
    /// Secondary caption line drawn in place of the year — episode cards pass
    /// "S01E02 · Pilot" so the code and episode title sit under the series
    /// name. Always one line; see `EpisodeCardCaption`.
    var subtitle: String? = nil
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
    var contextPlayTitle: String? = nil
    var contextDetailTitle: String? = nil
    var onOpenContextDetail: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onSetWatched: ((Bool) async -> Bool)? = nil
    var aspect: MediaCardAspect = .poster
    /// Overrides the theme's default card width. Skyline's dense landing
    /// rows (§5.6) pass 208 so two rows + the marquee fit above the fold;
    /// the poster keeps its 2:3 ratio.
    var cardWidthOverride: CGFloat? = nil
    /// Episode context retained for the card's accessibility label. Episode
    /// numbers are intentionally not drawn over poster artwork.
    var episodeAccessibilityLabel: String? = nil
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
    @Environment(\.itemDetailBrowseSource) private var detailBrowseSource
    /// Stable per-placement id for the zoom source. A bare `contentId` collides
    /// when the same item is visible in two rows (e.g. Continue Watching +
    /// Recently Added), making SwiftUI pick an ambiguous source; a per-instance
    /// id keeps each card's source unique and the tapped card's id is handed to
    /// the destination via `router.pendingZoomSourceID`.
    @State private var zoomInstanceID = UUID()
    #endif

    private var cardWidth: CGFloat {
        (cardWidthOverride ?? ContinuumTheme.posterCardWidth)
            * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        switch aspect {
        case .poster:
            cardWidth * (ContinuumTheme.posterCardHeight / ContinuumTheme.posterCardWidth)
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
            subtitle: subtitle,
            episodeAccessibilityLabel: episodeAccessibilityLabel,
            captionStyle: uiCustomization.cardPresentation.caption,
            cardWidth: cardWidth,
            action: action,
            playAction: playAction,
            focusedItemId: focusedItemId,
            itemId: contentId,
            isWatched: isPlayed,
            contextPlayTitle: contextPlayTitle,
            contextDetailTitle: contextDetailTitle,
            onOpenContextDetail: onOpenContextDetail,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: onSetWatched.map { handler in
                { played in
                    playedOverride = played
                    let succeeded = await handler(played)
                    if !succeeded {
                        playedOverride = nil
                    }
                    return succeeded
                }
            },
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
        Group {
            if hasIOSContextActions {
                iosCardButton.contextMenu {
                    iosContextActions
                }
            } else {
                iosCardButton
            }
        }
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
                    router.presentItemDetail(
                        contentId: contentId,
                        browseSource: detailBrowseSource
                    )
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

    private var hasIOSContextActions: Bool {
        hasPersonalActions || onSetWatched != nil || onRemoveFromContinueWatching != nil
    }

    /// Same action set (and ordering) as the tvOS `FocusableMediaCard` menu:
    /// watched toggle, favorite/watchlist, then the destructive remove.
    @ViewBuilder
    private var iosContextActions: some View {
        if let onSetWatched {
            Button {
                let played = !isPlayed
                Task { @MainActor in
                    playedOverride = played
                    let succeeded = await onSetWatched(played)
                    if !succeeded {
                        playedOverride = nil
                    }
                }
            } label: {
                Label(
                    isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isPlayed ? "circle" : "checkmark.circle"
                )
            }
        }

        if hasPersonalActions {
            personalMenuItems
        }

        if let onRemoveFromContinueWatching {
            Button(role: .destructive) {
                onRemoveFromContinueWatching()
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
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
        let newValue = !isFavorite
        let watchlist = isInWatchlist
        favoriteOverride = newValue
        Task {
            if await PersonalListSync.setFavorite(
                contentId: contentId, isFavorite: newValue, inWatchlist: watchlist
            ) {
                onUserStateChanged?(
                    MediaItemUserState(played: isPlayed, isFavorite: newValue, inWatchlist: watchlist)
                )
            } else {
                favoriteOverride = !newValue // Revert on failure
            }
        }
    }

    private func togglePersonalWatchlist() {
        guard let contentId else { return }
        let newValue = !isInWatchlist
        let favorite = isFavorite
        watchlistOverride = newValue
        Task {
            if await PersonalListSync.setWatchlist(
                contentId: contentId, isFavorite: favorite, inWatchlist: newValue
            ) {
                onUserStateChanged?(
                    MediaItemUserState(played: isPlayed, isFavorite: favorite, inWatchlist: newValue)
                )
            } else {
                watchlistOverride = !newValue // Revert on failure
            }
        }
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
                .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))

            // Server / user-customized overlays (resolution, HDR, ratings, …)
            // sit under the watched check + progress bar so those built-in
            // affordances always win the same corner if they conflict.
            if let overlayData, overlayStore.enabled {
                CardOverlays(data: overlayData, prefs: overlayStore.prefs, variant: .poster)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
            }

            // Progress bar at bottom of poster (inside rounded corners)
            if let progress, progress > 0 {
                VStack {
                    Spacer()
                    ProgressBar(value: progress)
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
            }

            // Watched indicator — white circle with check (Plezy style)
            if isPlayed {
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.continuumOnSurface)
                            .frame(width: checkBadgeSize, height: checkBadgeSize)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                        Image(systemName: "checkmark")
                            .font(.system(size: checkIconSize, weight: .bold))
                            .foregroundColor(Color.continuumBackground)
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
            episodeLabel: episodeAccessibilityLabel,
            year: year,
            isWatched: isPlayed
        )
    }

    private var titleText: some View {
        Text(title)
            .font(.continuumSubheadline)
            .foregroundColor(.continuumOnSurface)
            // Reserve 2 lines of space so single- and multi-line titles
            // produce the same overall card height — keeps posters in a
            // row top-aligned when titles wrap.
            .lineLimit(2, reservesSpace: true)
    }

    @ViewBuilder
    private var yearText: some View {
        if let secondLine = subtitle ?? year.map(String.init) {
            Text(secondLine)
                .font(.continuumCaption)
                .foregroundColor(.continuumSecondaryText)
                // One line, tail-truncated: an episode title must never wrap
                // and push the row below it.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardWidth, alignment: .leading)
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
    /// Replaces the year on the metadata line when present.
    let subtitle: String?
    let episodeAccessibilityLabel: String?
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
    let contextPlayTitle: String?
    let contextDetailTitle: String?
    let onOpenContextDetail: (() -> Void)?
    let onRemoveFromContinueWatching: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?
    /// Favorite / watchlist toggles, built by the owning card. `nil`
    /// when the card has no catalog identity or user state.
    let personalItems: PersonalListMenuItems?
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if let focusedItemId, let itemId {
            card(focusedItemId: focusedItemId, itemId: itemId, standaloneFocused: nil)
        } else {
            TVStandaloneCardFocus { binding in
                card(focusedItemId: nil, itemId: nil, standaloneFocused: binding)
            }
        }
    }

    private func card(
        focusedItemId: FocusState<String?>.Binding?,
        itemId: String?,
        standaloneFocused: FocusState<Bool>.Binding?
    ) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            mediaButton(
                focusedItemId: focusedItemId,
                itemId: itemId,
                standaloneFocused: standaloneFocused
            )

            if captionStyle.showsTitle {
                TVMediaCardCaption(
                    title: title,
                    secondLine: subtitle ?? year.map(String.init),
                    showsMetadata: captionStyle.showsMetadata,
                    cardWidth: cardWidth,
                    focusedItemId: focusedItemId,
                    itemId: itemId,
                    standaloneFocused: standaloneFocused
                )
            }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder
    private func mediaButton(
        focusedItemId: FocusState<String?>.Binding?,
        itemId: String?,
        standaloneFocused: FocusState<Bool>.Binding?
    ) -> some View {
        let button = Button(action: action) {
            content()
        }
        .buttonStyle(.card)
        .applyCardFocus(
            focusedItemId,
            itemId: itemId,
            standaloneBinding: standaloneFocused
        )
        .applyPlayPauseAction(playAction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)

        mediaButtonWithContext(button)
    }

    @ViewBuilder
    private func mediaButtonWithContext<ButtonContent: View>(_ button: ButtonContent) -> some View {
        if hasContextActions {
            button.contextMenu {
                contextActions
            }
        } else {
            button
        }
    }

    private var hasContextActions: Bool {
        (contextPlayTitle != nil && playAction != nil)
            || onOpenContextDetail != nil
            || onSetWatched != nil
            || onRemoveFromContinueWatching != nil
            || personalItems != nil
    }

    private var accessibilityDescription: String {
        mediaCardAccessibilityLabel(
            title: title,
            episodeLabel: episodeAccessibilityLabel,
            year: year,
            isWatched: isWatched
        )
    }

    @ViewBuilder
    private var contextActions: some View {
        if let contextPlayTitle, let playAction {
            Button(action: playAction) {
                Label(contextPlayTitle, systemImage: "play.fill")
            }
        }

        if let contextDetailTitle, let onOpenContextDetail {
            Button(action: onOpenContextDetail) {
                Label(contextDetailTitle, systemImage: "info.circle")
            }
        }

        if let onSetWatched {
            Button {
                Task { @MainActor in
                    _ = await onSetWatched(!isWatched)
                }
            } label: {
                Label(
                    isWatched ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle"
                )
            }
        }

        if let personalItems {
            personalItems
        }

        if let onRemoveFromContinueWatching {
            Button(role: .destructive) {
                onRemoveFromContinueWatching()
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }
}

/// Only cards outside a managed row need their own focus state. Keeping this
/// dynamic property out of row cards avoids invalidating their full button
/// and context-menu bodies when the shared focus environment changes.
private struct TVStandaloneCardFocus<Content: View>: View {
    @FocusState private var isFocused: Bool
    @ViewBuilder var content: (FocusState<Bool>.Binding) -> Content

    var body: some View {
        content($isFocused)
    }
}

/// Only the caption reads focus. The native card button owns its lift and
/// parallax without rebuilding its artwork and menu when a caption brightens.
private struct TVMediaCardCaption: View {
    let title: String
    let secondLine: String?
    let showsMetadata: Bool
    let cardWidth: CGFloat
    let focusedItemId: FocusState<String?>.Binding?
    let itemId: String?
    let standaloneFocused: FocusState<Bool>.Binding?

    private var isFocused: Bool {
        guard let focusedItemId, let itemId else { return standaloneFocused?.wrappedValue ?? false }
        return focusedItemId.wrappedValue == itemId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.continuumPosterTitle)
                .foregroundStyle(
                    isFocused
                        ? Color.continuumOnSurface
                        : Color.continuumOnSurface.opacity(0.85)
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardWidth, alignment: .leading)
                .clipped()
                .animation(.easeOut(duration: 0.15), value: isFocused)

            if showsMetadata, let secondLine {
                Text(secondLine)
                    .font(.continuumPosterMetadata)
                    .foregroundStyle(Color.continuumSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: cardWidth, alignment: .leading)
                    .clipped()
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }
}

private extension View {
    @ViewBuilder
    func applyPlayPauseAction(_ action: (() -> Void)?) -> some View {
        if let action {
            self.onPlayPauseCommand(perform: action)
        } else {
            self
        }
    }

    /// Use exactly one focus binding: the parent row's item ID when managed,
    /// otherwise the card's local Boolean for standalone grids.
    @ViewBuilder
    func applyCardFocus(
        _ binding: FocusState<String?>.Binding?,
        itemId: String?,
        standaloneBinding: FocusState<Bool>.Binding?
    ) -> some View {
        if let binding, let itemId {
            self.focused(binding, equals: itemId)
        } else if let standaloneBinding {
            self.focused(standaloneBinding)
        } else {
            self
        }
    }
}
#endif
