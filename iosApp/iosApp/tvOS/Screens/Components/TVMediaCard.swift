#if os(tvOS)
import SwiftUI

/// tvOS poster card on the cached Nuke renderer. `.nativeCard` uses the system
/// `.card` lift and parallax; `.ring` uses a white ring and scale to match the
/// episode and cast rails. A caption below brightens on focus.
struct TVMediaCard: View {
    let title: String
    let posterUrl: String
    var posterThumbhash: String? = nil
    var year: Int? = nil
    /// Optional second caption line rendered in place of the year (same
    /// type treatment) — e.g. "Book 3" on audiobook series rails.
    var subtitle: String? = nil
    var userState: MediaItemUserState? = nil
    /// Data for optional overlay badges. `nil` skips overlay rendering;
    /// callers without per-item OverlaySummary should leave it off.
    var overlayData: OverlayData? = nil
    let action: () -> Void
    /// Remote Play/Pause shortcut. When nil, the card does not intercept the
    /// command (used for non-playable containers such as series).
    var playAction: (() -> Void)? = nil
    /// Width of the poster. Defaults to the theme's standard poster size.
    /// Override with a smaller value in space-constrained grids (e.g. the
    /// Library tab where the alphabet rail forces cards to shrink).
    var cardWidth: CGFloat = SiloTheme.posterCardWidth
    var aspect: MediaCardAspect = .poster
    var prefersDefaultFocus: Bool = false
    var defaultFocusNamespace: Namespace.ID? = nil
    /// Focus visual. `.nativeCard` keeps tvOS's `.card` lift + parallax
    /// (library grids, search). `.ring` matches the white-ring + scale
    /// treatment of the episode and cast rails so the detail-page
    /// "Recommended / More Like This" rail reads consistently with its
    /// neighbours instead of using the subtler native lift.
    var focusTreatment: FocusTreatment = .nativeCard
    /// Optional external focus hook so a parent rail can make this card a
    /// `.defaultFocus` target on d-pad entry. The focusable element is the
    /// inner Button, so the binding is applied there — a `.focused` on the
    /// card's outer VStack silently no-ops. Mirrors `MediaCard.focusedItemId`.
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusContentId: String? = nil
    /// Catalog identity for the long-press favorite/watchlist menu.
    /// `nil` (or a nil `userState`) leaves the card without a menu.
    var contentId: String? = nil

    enum FocusTreatment {
        case nativeCard
        case ring
    }

    @FocusState private var isFocused: Bool
    @State private var actionFeedback = MediaActionFeedback()
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @EnvironmentObject private var overlayStore: OverlayPrefsStore

    private var resolvedCardWidth: CGFloat { artworkSize.width }
    private var cardHeight: CGFloat { artworkSize.height }
    private var artworkSize: CGSize { Self.artworkSize(cardWidth: cardWidth, aspect: aspect) }

    /// The size a card of `cardWidth` draws its artwork at, at the current
    /// card-size setting.
    static func artworkSize(cardWidth: CGFloat, aspect: MediaCardAspect) -> CGSize {
        let width = cardWidth * UICustomizationPreferences.shared.cardPresentation.posterSize.scale
        switch aspect {
        case .poster: return CGSize(width: width, height: width * 1.5)
        case .square: return CGSize(width: width, height: width)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            posterButton
                .mediaStateContextMenu(hasPersonalActions ? stateMenu : nil)
            if uiCustomization.cardPresentation.caption.showsTitle {
                caption
            }
        }
        .frame(width: resolvedCardWidth)
        .mediaActionFeedback(actionFeedback)
        .onChange(of: userState) { _, _ in
            playedOverride = nil
            favoriteOverride = nil
            watchlistOverride = nil
        }
    }

    // MARK: - Favorite / watchlist context actions

    private var hasPersonalActions: Bool {
        contentId != nil && userState != nil
    }

    private var isFavorite: Bool {
        favoriteOverride ?? (userState?.isFavorite == true)
    }

    private var isInWatchlist: Bool {
        watchlistOverride ?? (userState?.inWatchlist == true)
    }

    private var isPlayed: Bool { playedOverride ?? (userState?.played == true) }

    private var stateMenu: MediaStateMenuItems {
        MediaStateMenuItems(
            isWatched: isPlayed,
            isFavorite: isFavorite,
            inWatchlist: isInWatchlist,
            isUpdating: actionFeedback.isUpdating,
            onToggleWatched: aspect != .square ? toggleWatched : nil,
            onToggleFavorite: togglePersonalFavorite,
            onToggleWatchlist: togglePersonalWatchlist
        )
    }

    private func toggleWatched() {
        guard let contentId else { return }
        let played = !isPlayed
        let previous = playedOverride
        actionFeedback.perform {
            playedOverride = played
            let outcome = await MediaCardWatchedSync.setWatched(contentId: contentId, played: played)
            if outcome != .applied { playedOverride = previous }
            return outcome
        }
    }

    private func togglePersonalFavorite() {
        guard let contentId else { return }
        let newValue = !isFavorite
        let watchlist = isInWatchlist
        let previous = favoriteOverride
        actionFeedback.perform {
            favoriteOverride = newValue
            let outcome = await PersonalListSync.setFavorite(
                contentId: contentId, isFavorite: newValue, inWatchlist: watchlist
            )
            if outcome != .applied { favoriteOverride = previous }
            return outcome
        }
    }

    private func togglePersonalWatchlist() {
        guard let contentId else { return }
        let newValue = !isInWatchlist
        let favorite = isFavorite
        let previous = watchlistOverride
        actionFeedback.perform {
            watchlistOverride = newValue
            let outcome = await PersonalListSync.setWatchlist(
                contentId: contentId, isFavorite: favorite, inWatchlist: newValue
            )
            if outcome != .applied { watchlistOverride = previous }
            return outcome
        }
    }

    @ViewBuilder
    private var posterButton: some View {
        switch focusTreatment {
        case .nativeCard:
            wired(Button(action: action) { posterImage }.buttonStyle(.card))
        case .ring:
            // The ring is the focus cue; the style suppresses the system halo.
            wired(
                Button(action: action) {
                    posterImage.tvFocusRing(
                        isFocused: isFocused,
                        cornerRadius: SiloTheme.cornerRadius,
                        lineWidth: 4
                    )
                }
                .buttonStyle(TVCardFocusButtonStyle(
                    unfocusedShadowOpacity: 0,
                    unfocusedShadowRadius: 0,
                    unfocusedShadowY: 0
                ))
            )
        }
    }

    /// Focus and accessibility wiring, attached directly to the styled
    /// Button: a `.focused` on a wrapping container silently no-ops.
    private func wired(_ button: some View) -> some View {
        button
            .focused($isFocused)
            .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
            .tvFocused(focusBinding, equals: focusContentId)
            .applyTVCardPlayPauseAction(playAction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    private var posterImage: some View {
        ZStack(alignment: .topTrailing) {
            AsyncImageView(
                url: posterUrl,
                thumbhash: posterThumbhash,
                targetSize: CGSize(width: resolvedCardWidth, height: cardHeight),
                contentMode: .fill
            )
            .frame(width: resolvedCardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))

            if let overlayData, overlayStore.enabled {
                CardOverlays(data: overlayData, prefs: overlayStore.prefs, variant: .poster)
                    .frame(width: resolvedCardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
            }

            if isPlayed {
                watchedBadge
                    .padding(12)
            }
        }
        .frame(width: resolvedCardWidth, height: cardHeight)
    }

    // Plex-style: centered title with year directly underneath in a
    // lighter weight + dimmer color. Single-line truncation keeps the
    // caption a uniform two-row block across the whole grid.
    private var caption: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.siloPosterTitle)
                .foregroundColor(isFocused ? .siloOnSurface : .siloOnSurface.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: resolvedCardWidth, alignment: .center)
                .clipped()
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)

            if uiCustomization.cardPresentation.caption.showsMetadata,
               let secondLine = subtitle ?? year.map(String.init) {
                Text(secondLine)
                    .font(.siloPosterMetadata)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: resolvedCardWidth, alignment: .center)
                    .clipped()
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: resolvedCardWidth, alignment: .center)
    }

    private var watchedBadge: some View {
        ZStack {
            Circle()
                .fill(Color.siloOnSurface)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.3), radius: 4)
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color.siloBackground)
        }
    }

    private var accessibilityDescription: String {
        let secondLine = subtitle ?? year.map(String.init)
        var components = [title]
        if let secondLine {
            components.append(secondLine)
        }
        if isPlayed {
            components.append("Watched")
        }
        return components.joined(separator: ", ")
    }
}

private extension View {
    @ViewBuilder
    func applyTVCardPlayPauseAction(_ action: (() -> Void)?) -> some View {
        if let action {
            self.onPlayPauseCommand(perform: action)
        } else {
            self
        }
    }
}
#endif
