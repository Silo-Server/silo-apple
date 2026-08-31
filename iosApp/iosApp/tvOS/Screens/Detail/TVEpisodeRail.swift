#if os(tvOS)
import SwiftUI

/// Shared season picker for every tvOS episode-browsing surface. The row orders
/// Specials before numbered seasons and owns its native focus restoration so
/// callers do not duplicate it.
struct TVSeasonSelectorRow: View {
    let seasons: [Season]
    let selectedSeason: Season?
    var focusRequest = 0
    let onSelect: (Season) -> Void
    var onFocusChange: ((Bool) -> Void)?
    var onMoveDown: (() -> Void)?

    @Namespace private var focusNamespace
    @FocusState private var focusedSeasonId: String?

    var body: some View {
        selector
        .frame(height: 60, alignment: .leading)
        .onChange(of: focusRequest) { _, _ in
            focusedSeasonId = selectedSeasonId
        }
        .onChange(of: focusedSeasonId) { _, focusedId in
            onFocusChange?(focusedId != nil)
        }
    }

    private var selector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(orderedSeasons) { season in
                        TVSeasonSelectorTab(
                            title: seasonLabel(season),
                            isSelected: selectedSeason?.id == season.id,
                            action: {
                                guard selectedSeason?.id != season.id else { return }
                                onSelect(season)
                            }
                        )
                        .id(season.id)
                        .focused($focusedSeasonId, equals: season.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .focusScope(focusNamespace)
            .focusSection()
            .defaultFocus(
                $focusedSeasonId,
                selectedSeasonId,
                priority: .userInitiated
            )
            .onMoveCommand { direction in
                guard direction == .down else { return }
                onMoveDown?()
            }
            .onChange(of: selectedSeasonId) { _, newId in
                withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
        }
    }

    private var orderedSeasons: [Season] {
        seasons.filter { $0.seasonNumber == 0 }
            + seasons.filter { $0.seasonNumber != 0 }
    }

    private var selectedSeasonId: String {
        selectedSeason?.id ?? orderedSeasons.first?.id ?? ""
    }

    private func seasonLabel(_ season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return "Specials" }
        return "Season \(season.seasonNumber)"
    }
}

private struct TVSeasonSelectorTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 24)
                .frame(height: 52)
        }
        .buttonStyle(TVSeasonSelectorTabStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TVSeasonSelectorTabStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeasonSelectorTabBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct TVSeasonSelectorTabBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused
    @State private var rendersFocusedAppearance = false

    var body: some View {
        configuration.label
            .foregroundColor(rendersFocusedAppearance ? .black : .white)
            .background(
                Capsule().fill(
                    rendersFocusedAppearance
                        ? Color.white
                        : (isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.05))
                )
            )
            .overlay(
                Capsule().stroke(
                    Color.white.opacity(
                        rendersFocusedAppearance ? 1 : (isSelected ? 0.70 : 0.30)
                    ),
                    lineWidth: rendersFocusedAppearance ? 3 : (isSelected ? 2 : 1.5)
                )
                .padding(rendersFocusedAppearance ? -4 : 0)
            )
            .shadow(
                color: Color.white.opacity(rendersFocusedAppearance ? 0.34 : 0),
                radius: rendersFocusedAppearance ? 12 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .focusEffectDisabled()
            .animation(
                .easeOut(duration: ContinuumTheme.fastDuration),
                value: rendersFocusedAppearance
            )
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isSelected)
            .task(id: isFocused) {
                guard isFocused else {
                    rendersFocusedAppearance = false
                    return
                }
                if isSelected {
                    rendersFocusedAppearance = true
                    return
                }
                // A downward Siri Remote gesture can briefly offer focus to a
                // neighboring pill before entering the episode composite.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, isFocused else { return }
                rendersFocusedAppearance = true
            }
            .onChange(of: isSelected) { _, selected in
                if selected && isFocused {
                    rendersFocusedAppearance = true
                }
            }
    }
}

/// Horizontal rail of episode cards for the tvOS series/season/episode
/// detail screens. The caller owns Select semantics: legacy season/episode
/// pages and the Series overview navigate to episode detail, while focus
/// changes can still update the surrounding in-place episode state.
///
/// Pass `currentContentId` to highlight the episode currently represented
/// by the surrounding detail experience. Legacy rails center that card on
/// first appearance. Series can instead pin focused cards to the leading
/// carousel slot until the content reaches its trailing scroll boundary.
struct TVEpisodeRail: View {
    let episodes: [EpisodeListItem]
    let onSelect: (String) -> Void
    /// Optional Play action surfaced by the long-press context menu. Series
    /// supplies this even though its normal Select action also plays, keeping
    /// the context menu explicit and useful alongside watched-state actions.
    var onPlay: ((String) -> Void)? = nil
    var onFocusedEpisodeChange: ((String?) -> Void)? = nil
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil
    /// When non-nil, the matching card is visually highlighted and anchored
    /// at first appearance.
    var currentContentId: String? = nil
    var currentContentIsFavorite = false
    var favoriteStates: [String: Bool] = [:]
    var prefersCurrentContentFocus = false
    /// Series opts into a larger carousel card. The default keeps the
    /// approved 480-point geometry on existing season/episode pages.
    var baseCardWidth: CGFloat = 480
    var cardSpacing: CGFloat = 54
    var anchorsFocusedCard = false
    /// Composite Series rails own horizontal movement, so their vertical exit
    /// destinations are handed back to the parent explicitly.
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    /// Non-zero changes hand focus to the composite episode rail.
    var focusRequest = 0

    @FocusState private var focusedCardId: String?
    @FocusState private var anchoredRailFocused: Bool
    @State private var anchoredIndex = 0
    @State private var anchoredPlayedOverrides: [String: Bool] = [:]
    @State private var anchoredFavoriteOverrides: [String: Bool] = [:]
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if anchorsFocusedCard {
            anchoredRail
        } else {
            legacyRail
        }
    }

    private var legacyRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(episodes) { episode in
                        TVEpisodeCard(
                            episode: episode,
                            isCurrent: currentContentId == episode.contentId,
                            baseCardWidth: baseCardWidth,
                            posterSize: uiCustomization.cardPresentation.posterSize,
                            captionStyle: uiCustomization.cardPresentation.caption,
                            onSelect: { onSelect(episode.contentId) },
                            onPlay: onPlay,
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
                .scrollTargetLayout()
                .padding(.vertical, 12)
            }
            .applyEpisodeScrollTargetBehavior(anchorsFocusedCard)
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
                        proxy.scrollTo(id, anchor: anchorsFocusedCard ? .leading : .center)
                    }
                }
            }
        }
    }

    /// Series uses one focus owner for the entire rail. Cards are passive
    /// labels and the active index drives a single render offset, eliminating
    /// the competing native focus-scroll animation that caused the bump.
    private var anchoredRail: some View {
        GeometryReader { geometry in
            anchoredButton(viewportWidth: geometry.size.width)
        }
        .frame(height: anchoredRailHeight)
        .focusSection()
        .onAppear(perform: seedAnchoredIndex)
        .onChange(of: episodeIdentityKey) { _, _ in
            seedAnchoredIndex()
        }
        .onChange(of: currentContentId) { _, _ in
            guard !anchoredRailFocused else { return }
            seedAnchoredIndex()
        }
        .onChange(of: anchoredRailFocused) { _, isFocused in
            onFocusedEpisodeChange?(isFocused ? anchoredEpisode?.contentId : nil)
        }
        .onChange(of: anchoredIndex) { _, _ in
            guard anchoredRailFocused else { return }
            onFocusedEpisodeChange?(anchoredEpisode?.contentId)
        }
        .onChange(of: focusRequest) { _, request in
            guard request > 0 else { return }
            seedAnchoredIndex()
            anchoredRailFocused = true
        }
        .onDisappear {
            onFocusedEpisodeChange?(nil)
        }
    }

    @ViewBuilder
    private func anchoredButton(viewportWidth: CGFloat) -> some View {
        let button = Button {
            if let contentId = anchoredEpisode?.contentId {
                onSelect(contentId)
            }
        } label: {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(Array(episodes.enumerated()), id: \.element.contentId) { index, episode in
                        let isActive = anchoredRailFocused && anchoredIndex == index
                        EpisodeCardLabel(
                            episode: episode,
                            isPlayed: anchoredIsPlayed(episode),
                            isCurrent: currentContentId == episode.contentId,
                            cardWidth: anchoredCardWidth,
                            stillHeight: anchoredStillHeight,
                            stillCornerRadius: 18,
                            captionStyle: uiCustomization.cardPresentation.caption,
                            focusOverride: false,
                            hidesEpisodeTitle: true,
                            showsCurrentOutline: false
                        )
                        .scaleEffect(
                            isActive && !reduceMotion ? 1.035 : 1,
                            anchor: .bottomLeading
                        )
                        .shadow(
                            color: .black.opacity(isActive ? 0.45 : 0),
                            radius: isActive ? 18 : 0,
                            y: isActive ? 8 : 0
                        )
                        .zIndex(isActive ? 1 : 0)
                        .animation(
                            .easeOut(duration: ContinuumTheme.fastDuration),
                            value: anchoredRailFocused
                        )
                    }
                }
                .padding(.vertical, 12)
                .offset(x: -anchoredContentOffset(viewportWidth: viewportWidth))

                // The ring is independent of every moving card. It remains in
                // the leading slot while content can scroll, then moves only
                // when the rail clamps at its trailing boundary.
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        Color.white.opacity(anchoredRailFocused ? 0.9 : 0.7),
                        lineWidth: anchoredRailFocused ? 3 : 2
                    )
                    .frame(width: anchoredCardWidth, height: anchoredStillHeight)
                    .scaleEffect(
                        anchoredRailFocused && !reduceMotion ? 1.035 : 1,
                        anchor: .bottomLeading
                    )
                    .offset(
                        x: anchoredHighlightOffset(viewportWidth: viewportWidth),
                        y: 12
                    )
                    .animation(
                        .easeOut(duration: ContinuumTheme.fastDuration),
                        value: anchoredRailFocused
                    )
            }
            .frame(
                width: viewportWidth,
                height: anchoredRailHeight,
                alignment: .topLeading
            )
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(TVAnchoredEpisodeButtonStyle())
        .focused($anchoredRailFocused)
        .onMoveCommand(perform: handleAnchoredMove)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(anchoredAccessibilityLabel)
        .accessibilityValue("Episode \(anchoredIndex + 1) of \(max(episodes.count, 1))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                moveAnchoredSelection(by: 1)
            case .decrement:
                moveAnchoredSelection(by: -1)
            @unknown default:
                break
            }
        }

        if onPlay != nil || onSetWatched != nil || onSetFavorite != nil {
            button.contextMenu { anchoredContextActions }
        } else {
            button
        }
    }

    private var anchoredCardWidth: CGFloat {
        baseCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }

    private var anchoredStillHeight: CGFloat {
        anchoredCardWidth * 9 / 16
    }

    private var anchoredRailHeight: CGFloat {
        anchoredStillHeight
            + (uiCustomization.cardPresentation.caption.showsTitle ? 46 : 0)
            + 24
    }

    private var anchoredEpisode: EpisodeListItem? {
        guard episodes.indices.contains(anchoredIndex) else { return episodes.first }
        return episodes[anchoredIndex]
    }

    private var episodeIdentityKey: String {
        episodes.map(\.contentId).joined(separator: "|")
    }

    private func anchoredContentOffset(viewportWidth: CGFloat) -> CGFloat {
        guard !episodes.isEmpty else { return 0 }
        let step = anchoredCardWidth + cardSpacing
        let contentWidth = CGFloat(episodes.count) * anchoredCardWidth
            + CGFloat(max(episodes.count - 1, 0)) * cardSpacing
        let minimumTrailingOffset = max(0, contentWidth - viewportWidth)
        // Keep the hard rail crop, but stop its terminal position on the next
        // complete card step. The final group can then show a full card at
        // both edges while the last episode remains entirely visible; any
        // remainder becomes harmless trailing breathing room.
        let maximumOffset = ceil(minimumTrailingOffset / step) * step
        return min(CGFloat(anchoredIndex) * step, maximumOffset)
    }

    private func anchoredHighlightOffset(viewportWidth: CGFloat) -> CGFloat {
        let selectedCardX = CGFloat(anchoredIndex) * (anchoredCardWidth + cardSpacing)
        return selectedCardX - anchoredContentOffset(viewportWidth: viewportWidth)
    }

    private func seedAnchoredIndex() {
        if let currentContentId,
           let index = episodes.firstIndex(where: { $0.contentId == currentContentId }) {
            anchoredIndex = index
        } else {
            anchoredIndex = min(anchoredIndex, max(episodes.count - 1, 0))
        }
    }

    private func handleAnchoredMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            moveAnchoredSelection(by: -1)
        case .right:
            moveAnchoredSelection(by: 1)
        case .up:
            onMoveUp?()
        case .down:
            onMoveDown?()
        default:
            break
        }
    }

    private func moveAnchoredSelection(by delta: Int) {
        let nextIndex = anchoredIndex + delta
        guard episodes.indices.contains(nextIndex) else { return }
        withAnimation(
            reduceMotion
                ? nil
                : .smooth(duration: 0.30, extraBounce: 0)
        ) {
            anchoredIndex = nextIndex
        }
    }

    private func anchoredIsPlayed(_ episode: EpisodeListItem) -> Bool {
        anchoredPlayedOverrides[episode.contentId]
            ?? episode.userData?.played
            ?? false
    }

    private func anchoredIsFavorite(_ episode: EpisodeListItem) -> Bool {
        anchoredFavoriteOverrides[episode.contentId]
            ?? favoriteStates[episode.contentId]
            ?? (currentContentId == episode.contentId && currentContentIsFavorite)
    }

    private var anchoredAccessibilityLabel: String {
        guard let episode = anchoredEpisode else { return "Episodes" }
        return episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: anchoredMetadataLine(for: episode),
            isCurrent: currentContentId == episode.contentId,
            isPlayed: anchoredIsPlayed(episode)
        )
    }

    private func anchoredMetadataLine(for episode: EpisodeListItem) -> String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(runtime >= 60
                ? "\(runtime / 60)h \(runtime % 60)m"
                : "\(runtime)m")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var anchoredContextActions: some View {
        if let episode = anchoredEpisode {
            if let onPlay {
                Button {
                    onPlay(episode.contentId)
                } label: {
                    Label(
                        "Play S\(episode.seasonNumber):E\(episode.episodeNumber)",
                        systemImage: "play.fill"
                    )
                }
            }

            if let onSetWatched {
                Button {
                    let played = !anchoredIsPlayed(episode)
                    anchoredPlayedOverrides[episode.contentId] = played
                    Task {
                        if await onSetWatched(episode.contentId, played) == false {
                            anchoredPlayedOverrides[episode.contentId] = nil
                        }
                    }
                } label: {
                    Label(
                        anchoredIsPlayed(episode) ? "Mark as Unwatched" : "Mark as Watched",
                        systemImage: anchoredIsPlayed(episode) ? "circle" : "checkmark.circle"
                    )
                }
            }

            if let onSetFavorite {
                Button {
                    let isFavorite = !anchoredIsFavorite(episode)
                    anchoredFavoriteOverrides[episode.contentId] = isFavorite
                    Task {
                        if await onSetFavorite(episode.contentId, isFavorite) == false {
                            anchoredFavoriteOverrides[episode.contentId] = nil
                        }
                    }
                } label: {
                    Label(
                        anchoredIsFavorite(episode) ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: anchoredIsFavorite(episode) ? "heart.slash" : "heart"
                    )
                }
            }
        }
    }
}

/// Suppresses tvOS's native lift/scroll behavior for the composite carousel.
/// Its active card supplies the only visible ring.
private struct TVAnchoredEpisodeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.96 : 1)
            .focusEffectDisabled()
            .animation(
                .easeOut(duration: ContinuumTheme.fastDuration),
                value: configuration.isPressed
            )
    }
}

private extension View {
    @ViewBuilder
    func applyEpisodeScrollTargetBehavior(_ enabled: Bool) -> some View {
        if enabled {
            scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }

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
    var baseCardWidth: CGFloat = 480
    var posterSize: CardPosterSize = .standard
    var captionStyle: CardCaptionStyle = .titleMetadata
    let onSelect: () -> Void
    var onPlay: ((String) -> Void)? = nil
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> Bool)? = nil
    var initialIsFavorite = false
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> Bool)? = nil

    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?

    private var cardWidth: CGFloat { baseCardWidth * posterSize.scale }
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
            if onPlay != nil || onSetWatched != nil || onSetFavorite != nil {
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
        if let onPlay {
            Button {
                onPlay(episode.contentId)
            } label: {
                Label("Play S\(episode.seasonNumber):E\(episode.episodeNumber)", systemImage: "play.fill")
            }
        }

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
    var focusOverride: Bool? = nil
    var hidesEpisodeTitle = false
    var showsCurrentOutline = true

    @Environment(\.isFocused) private var environmentIsFocused

    private var isFocused: Bool {
        focusOverride ?? environmentIsFocused
    }

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

                    if !hidesEpisodeTitle {
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
                    Color.white.opacity(showsCurrentOutline && isCurrent && !isFocused ? 0.7 : 0),
                    lineWidth: showsCurrentOutline && isCurrent && !isFocused ? 2 : 0
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

/// Reserves the approved 480-point episode-card geometry while an uncached
/// season loads. Keeping artwork and caption blocks in the tree prevents the
/// lower detail sections from jumping when real episodes arrive.
struct TVEpisodeRailPlaceholder: View {
    var cardWidth: CGFloat = 480
    var cardSpacing: CGFloat = 54
    var hidesEpisodeTitle = false
    private var stillHeight: CGFloat { cardWidth * 9 / 16 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cardSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 18) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.continuumSurfaceElevated)
                            .frame(width: cardWidth, height: stillHeight)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 112, height: 15)
                        if !hidesEpisodeTitle {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.28))
                                .frame(width: 310, height: 22)
                        }
                    }
                    .frame(width: cardWidth, alignment: .leading)
                }
            }
            .padding(.vertical, 12)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityHidden(true)
    }
}

#endif
