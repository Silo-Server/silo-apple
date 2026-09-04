#if os(tvOS)
import SwiftUI

/// tvOS-only poster card. Uses the cached Nuke renderer so scrolling through
/// a large grid doesn't re-download posters as cells are reused.
///
/// `.buttonStyle(.card)` gives us native focus lift + parallax + shadow, so
/// we do not roll our own scale animation. A title caption lives below the
/// card and brightens on focus.
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
    var cardWidth: CGFloat = ContinuumTheme.posterCardWidth
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
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @EnvironmentObject private var overlayStore: OverlayPrefsStore

    private var resolvedCardWidth: CGFloat {
        cardWidth * uiCustomization.cardPresentation.posterSize.scale
    }

    private var cardHeight: CGFloat {
        switch aspect {
        case .poster:
            resolvedCardWidth * 1.5
        case .square:
            resolvedCardWidth
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            posterButton
                .personalListContextMenu(hasPersonalActions ? personalMenuItems : nil)
            if uiCustomization.cardPresentation.caption.showsTitle {
                caption
            }
        }
        .frame(width: resolvedCardWidth)
        .onChange(of: userState) { _, _ in
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
            ) == false {
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
            ) == false {
                watchlistOverride = !newValue // Revert on failure
            }
        }
    }

    @ViewBuilder
    private var posterButton: some View {
        switch focusTreatment {
        case .nativeCard:
            Button(action: action) { posterImage }
                .buttonStyle(.card)
                .focused($isFocused)
                .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
                .applyRailFocus(focusBinding, contentId: focusContentId)
                .applyTVCardPlayPauseAction(playAction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
        case .ring:
            Button(action: action) { posterImage }
                .buttonStyle(TVPosterRingButtonStyle())
                .focused($isFocused)
                .applyDefaultFocusIfNeeded(prefersDefaultFocus, namespace: defaultFocusNamespace)
                .applyRailFocus(focusBinding, contentId: focusContentId)
                .applyTVCardPlayPauseAction(playAction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
        }
    }

    // MARK: - Subviews

    private var posterImage: some View {
        ZStack(alignment: .topTrailing) {
            CachedAsyncImage(
                url: posterUrl,
                targetSize: CGSize(width: resolvedCardWidth, height: cardHeight),
                thumbhash: posterThumbhash,
                contentMode: .fill
            )
            .frame(width: resolvedCardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))

            if let overlayData, overlayStore.enabled {
                CardOverlays(data: overlayData, prefs: overlayStore.prefs, variant: .poster)
                    .frame(width: resolvedCardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius))
            }

            if userState?.played == true {
                watchedBadge
                    .padding(12)
            }
        }
        .frame(width: resolvedCardWidth, height: cardHeight)
        .overlay {
            // The `.ring` treatment supplies its own focus cue (the native
            // halo is suppressed in TVPosterRingButtonStyle), matching the
            // episode/cast cards.
            if focusTreatment == .ring {
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                    .stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: isFocused ? 4 : 0)
                    .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            }
        }
    }

    // Plex-style: centered title with year directly underneath in a
    // lighter weight + dimmer color. Single-line truncation keeps the
    // caption a uniform two-row block across the whole grid.
    private var caption: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.continuumPosterTitle)
                .foregroundColor(isFocused ? .continuumOnSurface : .continuumOnSurface.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: resolvedCardWidth, alignment: .center)
                .clipped()
                .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)

            if uiCustomization.cardPresentation.caption.showsMetadata,
               let secondLine = subtitle ?? year.map(String.init) {
                Text(secondLine)
                    .font(.continuumPosterMetadata)
                    .foregroundColor(.continuumSecondaryText)
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
                .fill(Color.continuumOnSurface)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.3), radius: 4)
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color.continuumBackground)
        }
    }

    private var accessibilityDescription: String {
        let secondLine = subtitle ?? year.map(String.init)
        var components = [title]
        if let secondLine {
            components.append(secondLine)
        }
        if userState?.played == true {
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

    /// Binds the inner button to a parent rail's `@FocusState` so the rail can
    /// route d-pad-entry default focus onto this specific card. No-op when the
    /// rail doesn't manage focus. Mirrors `MediaCard.applyRowFocus`.
    @ViewBuilder
    func applyRailFocus(_ binding: FocusState<String?>.Binding?, contentId: String?) -> some View {
        if let binding, let contentId {
            self.focused(binding, equals: contentId)
        } else {
            self
        }
    }
}

/// Poster focus style matching the episode/cast cards: scale + drop shadow
/// with the system halo suppressed. The white ring overlay on the poster
/// (driven by `isFocused`) is the focus cue.
private struct TVPosterRingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVPosterRingButtonBody(configuration: configuration)
    }
}

private struct TVPosterRingButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(isFocused ? 0.45 : 0.0),
                radius: isFocused ? 18 : 0,
                y: isFocused ? 8 : 0
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused && !reduceMotion ? 1.05 : 1.0
        return configuration.isPressed ? base * 0.97 : base
    }
}
#endif
