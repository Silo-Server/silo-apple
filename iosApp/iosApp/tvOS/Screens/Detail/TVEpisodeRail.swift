#if os(tvOS)
import SwiftUI

/// Horizontal rail of episode cards for the tvOS series/season/episode
/// detail screens. Pressing Select on a card navigates to the episode
/// detail page where the user can pick a version, mark watched, and
/// start playback — the rail is a browsing surface, not a direct play
/// launcher.
///
/// Pass `currentContentId` to highlight the episode currently represented
/// by the surrounding detail experience. The rail scrolls that card to the
/// horizontal center on first appearance, while d-pad entry remains fully
/// spatial so focus lands beneath the control the user moved down from.
struct TVEpisodeRail: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    var onFocusedEpisodeChange: ((String?) -> Void)? = nil
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil
    /// When non-nil, the matching card is visually highlighted and anchored
    /// at first appearance.
    var currentContentId: String? = nil
    var currentContentIsFavorite = false
    var favoriteStates: [String: Bool] = [:]
    var prefersCurrentContentFocus = false

    private let cardSpacing: CGFloat = 36
    @FocusState private var focusedCardId: String?
    @State private var uiCustomization = UICustomizationPreferences.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(episodes) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            isCurrent: currentContentId == episode.contentId,
                            posterSize: uiCustomization.cardPresentation.posterSize,
                            captionStyle: uiCustomization.cardPresentation.caption,
                            onSelect: { onSelect(episode.contentId) },
                            onSetWatched: onSetWatched,
                            initialIsFavorite: currentContentId == episode.contentId
                                ? currentContentIsFavorite
                                : favoriteStates[episode.contentId] ?? false,
                            onSetFavorite: onSetFavorite
                        )
                        .id(episode.contentId)
                        .focused($focusedCardId, equals: episode.contentId)
                    }
                }
                .padding(.vertical, 32)
                .padding(.horizontal, SiloTheme.safePadding)
            }
            .focusSection()
            .applyDefaultFocusIfPresent(
                $focusedCardId,
                id: prefersCurrentContentFocus ? currentContentId : nil
            )
            .scrollClipDisabled()
            .onChange(of: focusedCardId) { _, contentId in
                onFocusedEpisodeChange?(contentId)
            }
            .onDisappear {
                onFocusedEpisodeChange?(nil)
            }
            .onAppear {
                guard let id = currentContentId else { return }
                // Run on next tick so the LazyHStack has instantiated the
                // target cell before we try to anchor on it.
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: SiloTheme.normalDuration)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

struct TVEpisodeCard: View {
    let episode: EpisodeListItem
    var isCurrent: Bool = false
    var posterSize: CardPosterSize = .standard
    var captionStyle: CardCaptionStyle = .titleMetadata
    let onSelect: () -> Void
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var initialIsFavorite = false
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil

    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    private var cardWidth: CGFloat { 460 * posterSize.scale }
    private var stillHeight: CGFloat { cardWidth * 9 / 16 }
    private let stillCornerRadius: CGFloat = 10

    var body: some View {
        let button = Button(action: onSelect) {
            EpisodeCardLabel(
                episode: episode,
                isPlayed: isPlayed,
                isCurrent: isCurrent,
                cardWidth: cardWidth,
                stillHeight: stillHeight,
                stillCornerRadius: stillCornerRadius,
                captionStyle: captionStyle
            )
        }
        .buttonStyle(TVRailCardFocusStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)

        Group {
            if onSetWatched != nil || onSetFavorite != nil {
                button.contextMenu { contextActions }
            } else {
                button
            }
        }
        .onChange(of: episode.userData?.played) { _, refreshedValue in
            guard let playedOverride, refreshedValue == playedOverride else { return }
            self.playedOverride = nil
        }
        .onChange(of: initialIsFavorite) { _, refreshedValue in
            guard let favoriteOverride, refreshedValue == favoriteOverride else { return }
            self.favoriteOverride = nil
        }
    }

    private var isPlayed: Bool {
        playedOverride ?? episode.userData?.played ?? false
    }

    private var isFavorite: Bool {
        favoriteOverride ?? initialIsFavorite
    }

    private var accessibilityDescription: String {
        EpisodeRailFormatting.accessibilityDescription(
            for: episode,
            isCurrent: isCurrent,
            isPlayed: isPlayed
        )
    }

    @ViewBuilder
    private var contextActions: some View {
        if let onSetWatched {
            Button {
                let played = !isPlayed
                playedOverride = played
                Task {
                    if await onSetWatched(episode.contentId, played) == false {
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

        if let onSetFavorite {
            Button {
                let newValue = !isFavorite
                favoriteOverride = newValue
                Task {
                    if await onSetFavorite(episode.contentId, newValue) == false {
                        favoriteOverride = nil
                    }
                }
            } label: {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
        }
    }
}

private struct EpisodeCardLabel: View {
    let episode: EpisodeListItem
    let isPlayed: Bool
    let isCurrent: Bool
    let cardWidth: CGFloat
    let stillHeight: CGFloat
    let stillCornerRadius: CGFloat
    let captionStyle: CardCaptionStyle

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            still
            if captionStyle.showsTitle {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                            Text(EpisodeRailFormatting.cardNumberLabel(for: episode))
                                .font(.system(size: 18, weight: .bold))
                                .tracking(2.0)
                                .foregroundStyle(Color.siloOnSurface.opacity(0.55))
                        if isCurrent {
                            nowViewingTag
                        }
                    }

                    Text(EpisodeRailFormatting.title(for: episode))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(titleColor)
                        // Allow up to two lines for long titles, but don't reserve
                        // the second line — a single-line title (the common case)
                        // was leaving a full empty line of dead space above the
                        // description.
                        .lineLimit(2)

                    if captionStyle.showsMetadata {
                        if let metadataLine = EpisodeRailFormatting.metadataLine(for: episode) {
                            Text(metadataLine)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(Color.siloSecondaryText)
                                .lineLimit(1)
                        }

                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(Color.siloSecondaryText)
                                .lineLimit(3, reservesSpace: true)
                                .lineSpacing(3)
                                .padding(.top, 4)
                        }
                    }
                }
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var titleColor: Color {
        if isCurrent { return .siloOnSurface }
        return isFocused ? .siloOnSurface : Color.siloOnSurface.opacity(0.92)
    }

    private var nowViewingTag: some View {
        Text("NOW VIEWING")
            .font(.system(size: 14, weight: .heavy))
            .tracking(1.6)
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white))
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            Color.siloSurfaceElevated
                .frame(width: cardWidth, height: stillHeight)

            if let url = episode.stillUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: cardWidth, height: stillHeight),
                    contentMode: .fill
                )
                .frame(width: cardWidth, height: stillHeight)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundColor(.siloSecondaryText)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if isPlayed {
                Color.black.opacity(0.35)
                    .frame(width: cardWidth, height: stillHeight)
            }

            if isPlayed {
                VStack {
                    HStack {
                        Spacer()
                        watchedBadge.padding(12)
                    }
                    Spacer()
                }
                .frame(width: cardWidth, height: stillHeight)
            }

            if let progress = progressFraction {
                ProgressBar.episodeStill(fraction: progress, height: 5)
            }
        }
        .frame(width: cardWidth, height: stillHeight)
        .clipShape(RoundedRectangle(cornerRadius: stillCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: stillCornerRadius)
                .stroke(borderColor, lineWidth: borderWidth)
        )
    }

    private var borderColor: Color {
        if isFocused { return Color.white.opacity(0.9) }
        if isCurrent { return Color.white.opacity(0.7) }
        return .clear
    }

    private var borderWidth: CGFloat {
        if isFocused { return 3 }
        if isCurrent { return 2 }
        return 0
    }

    private var watchedBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.3), radius: 3)
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.black)
        }
    }

    private var progressFraction: Double? {
        EpisodeRailFormatting.progressFraction(for: episode)
    }
}

/// Custom style so the system doesn't paint its default focus halo over
/// the card. Scale + drop shadow only; the white overlay ring on the
/// still / thumbnail (driven by `isFocused` in the label) is the focus
/// cue. Shared by the episode and trailer rails.
struct TVRailCardFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVRailCardFocusStyleBody(configuration: configuration)
    }
}

private struct TVRailCardFocusStyleBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(isFocused ? 0.45 : 0.3),
                radius: isFocused ? 18 : 8,
                y: isFocused ? 8 : 4
            )
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused ? 1.04 : 1.0
        return configuration.isPressed ? base * 0.97 : base
    }
}
#endif
