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

    private let cardSpacing: CGFloat = 54
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
                .padding(.vertical, 12)
            }
            .focusSection()
            .applyCurrentEpisodeDefaultFocus(
                prefersCurrentContentFocus ? currentContentId : nil,
                binding: $focusedCardId
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
                    withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func applyCurrentEpisodeDefaultFocus(
        _ contentId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let contentId {
            defaultFocus(binding, contentId, priority: .userInitiated)
        } else {
            self
        }
    }
}

struct TVEpisodeCard: View {
    let episode: EpisodeListItem
    var isCurrent: Bool = false
    var captionStyle: CardCaptionStyle = .titleMetadata
    let onSelect: () -> Void
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var initialIsFavorite = false
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil

    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    private let cardWidth: CGFloat = 480
    private var stillHeight: CGFloat { cardWidth * 9 / 16 }
    private let stillCornerRadius: CGFloat = 18

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
        .buttonStyle(TVCardFocusButtonStyle())
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
        episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: episodeMetadataLine,
            isCurrent: isCurrent,
            isPlayed: isPlayed
        )
    }

    private var episodeMetadataLine: String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            if runtime >= 60 {
                parts.append("\(runtime / 60)h \(runtime % 60)m")
            } else {
                parts.append("\(runtime)m")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
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
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(episodeNumberLabel)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(Color.continuumOnSurface.opacity(0.62))
                        if isCurrent {
                            nowViewingTag
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(episode.title ?? "Episode \(episode.episodeNumber)")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if captionStyle.showsMetadata,
                           let runtime = episode.runtime,
                           runtime > 0 {
                            Text(formatRuntime(runtime))
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.continuumSecondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private var titleColor: Color {
        if isCurrent { return .continuumOnSurface }
        return isFocused ? .continuumOnSurface : Color.continuumOnSurface.opacity(0.92)
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

    private var episodeNumberLabel: String {
        "EPISODE \(episode.episodeNumber)"
    }

    private var episodeMetadataLine: String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(formatRuntime(runtime))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var still: some View {
        ZStack(alignment: .bottom) {
            Color.continuumSurfaceElevated
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
                    .foregroundColor(.continuumSecondaryText)
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
                progressBar(fraction: progress)
            }
        }
        .frame(width: cardWidth, height: stillHeight)
        .clipShape(RoundedRectangle(cornerRadius: stillCornerRadius))
        .tvFocusRing(isFocused: isFocused, cornerRadius: stillCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: stillCornerRadius)
                .stroke(
                    Color.white.opacity(isCurrent && !isFocused ? 0.7 : 0),
                    lineWidth: isCurrent && !isFocused ? 2 : 0
                )
        )
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

    private func progressBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(height: 5)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(fraction), height: 5)
            }
        }
        .frame(height: 5)
    }

    private var progressFraction: Double? {
        guard let userData = episode.userData,
              let pos = userData.positionSeconds,
              let dur = userData.durationSeconds,
              dur > 0, pos > 0, pos < dur
        else { return nil }
        return pos / dur
    }

    private func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

#endif
