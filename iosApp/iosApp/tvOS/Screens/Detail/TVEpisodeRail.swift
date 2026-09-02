#if os(tvOS)
import SwiftUI

private enum EpisodeHomeHoverMetrics {
    static let scale: CGFloat = 1.08

    static func leadingInset(for cardWidth: CGFloat) -> CGFloat {
        cardWidth * (scale - 1) / 2 + 2
    }
}

/// Horizontal rail of episode cards for the tvOS series/season/episode
/// detail screens. The caller owns Select semantics: legacy season/episode
/// pages can still navigate, while the Series overview launches playback
/// directly and uses focus changes to update its in-place episode state.
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
    /// Series can exactly reuse Home's 360×200 thumbnail aspect while legacy
    /// episode pages retain their existing 16:9 geometry.
    var cardHeightRatio: CGFloat = 9 / 16
    var cardSpacing: CGFloat = 54
    var anchorsFocusedCard = false
    /// Composite Series rails own horizontal movement, so their vertical exit
    /// destinations are handed back to the parent explicitly.
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    /// Non-zero changes hand focus back to the composite Series episode rail.
    var focusRequest = 0

    @FocusState private var focusedCardId: String?
    @FocusState private var anchoredRailFocused: Bool
    @State private var anchoredIndex = 0
    @State private var anchoredScrollPosition = ScrollPosition(x: 0)
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
    /// labels and the active index drives one native ScrollView position,
    /// eliminating competing focus owners while leaving scrolling to SwiftUI.
    private var anchoredRail: some View {
        GeometryReader { geometry in
            anchoredButton(viewportWidth: geometry.size.width)
                .onAppear {
                    seedAnchoredIndex(viewportWidth: geometry.size.width)
                }
                .onChange(of: episodeIdentityKey) { _, _ in
                    seedAnchoredIndex(viewportWidth: geometry.size.width)
                }
                .onChange(of: currentContentId) { _, _ in
                    guard !anchoredRailFocused else { return }
                    seedAnchoredIndex(viewportWidth: geometry.size.width)
                }
                .onChange(of: focusRequest) { _, request in
                    guard request > 0 else { return }
                    seedAnchoredIndex(viewportWidth: geometry.size.width)
                    anchoredRailFocused = true
                }
        }
        .frame(height: anchoredRailHeight)
        .focusSection()
        .onChange(of: anchoredRailFocused) { _, isFocused in
            onFocusedEpisodeChange?(isFocused ? anchoredEpisode?.contentId : nil)
        }
        .onChange(of: anchoredIndex) { _, _ in
            guard anchoredRailFocused else { return }
            onFocusedEpisodeChange?(anchoredEpisode?.contentId)
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
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardSpacing) {
                    ForEach(Array(episodes.enumerated()), id: \.element.contentId) { index, episode in
                        let isHovered = anchoredRailFocused && index == anchoredIndex
                        EpisodeCardLabel(
                            episode: episode,
                            isPlayed: anchoredIsPlayed(episode),
                            isCurrent: currentContentId == episode.contentId,
                            cardWidth: anchoredCardWidth,
                            stillHeight: anchoredStillHeight,
                            stillCornerRadius: 18,
                            captionStyle: uiCustomization.cardPresentation.caption,
                            focusOverride: isHovered,
                            hidesEpisodeTitle: true,
                            usesHomeHoverEffect: true,
                            showsFocusOutline: false,
                            showsCurrentOutline: false
                        )
                        .zIndex(isHovered ? 1 : 0)
                    }
                }
                // The active card scales around its center. Reserve exactly
                // that new left half-width (plus the focus stroke) inside the
                // hard rail crop so its rounded edge remains visible.
                .padding(
                    .leading,
                    EpisodeHomeHoverMetrics.leadingInset(for: anchoredCardWidth)
                )
                .padding(
                    .trailing,
                    anchoredTrailingInset(viewportWidth: viewportWidth)
                )
                .padding(.vertical, 12)
            }
            .scrollPosition($anchoredScrollPosition)
            .scrollDisabled(true)
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
        .onMoveCommand { direction in
            handleAnchoredMove(direction, viewportWidth: viewportWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(anchoredAccessibilityLabel)
        .accessibilityValue("Episode \(anchoredIndex + 1) of \(max(episodes.count, 1))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                moveAnchoredSelection(by: 1, viewportWidth: viewportWidth)
            case .decrement:
                moveAnchoredSelection(by: -1, viewportWidth: viewportWidth)
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
        anchoredCardWidth * cardHeightRatio
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

    private func anchoredContentOffset(
        for index: Int,
        viewportWidth: CGFloat
    ) -> CGFloat {
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
        return min(CGFloat(index) * step, maximumOffset)
    }

    /// Adds only the extra scrollable width needed to preserve the rail's
    /// existing stepped trailing boundary. SwiftUI can then clamp concrete
    /// scroll positions natively without changing the final card grouping.
    private func anchoredTrailingInset(viewportWidth: CGFloat) -> CGFloat {
        guard !episodes.isEmpty else { return 0 }
        let leadingInset = EpisodeHomeHoverMetrics.leadingInset(for: anchoredCardWidth)
        let contentWidth = CGFloat(episodes.count) * anchoredCardWidth
            + CGFloat(max(episodes.count - 1, 0)) * cardSpacing
        let naturalMaximumOffset = max(
            0,
            leadingInset + contentWidth - viewportWidth
        )
        let desiredMaximumOffset = anchoredContentOffset(
            for: episodes.count - 1,
            viewportWidth: viewportWidth
        )
        return max(0, desiredMaximumOffset - naturalMaximumOffset)
    }

    private func seedAnchoredIndex(viewportWidth: CGFloat) {
        let seededIndex: Int
        if let currentContentId,
           let index = episodes.firstIndex(where: { $0.contentId == currentContentId }) {
            seededIndex = index
        } else {
            seededIndex = min(anchoredIndex, max(episodes.count - 1, 0))
        }

        // A newly inserted season page inherits the outer pan transaction.
        // Seeding its internal episode offset inside that same animation made
        // the cards briefly travel the opposite way while the page itself was
        // moving correctly. Mount at the resolved index with no animation;
        // user-driven episode moves retain their normal smooth transition.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            anchoredIndex = seededIndex
            anchoredScrollPosition.scrollTo(
                x: anchoredContentOffset(
                    for: seededIndex,
                    viewportWidth: viewportWidth
                )
            )
        }
    }

    private func handleAnchoredMove(
        _ direction: MoveCommandDirection,
        viewportWidth: CGFloat
    ) {
        switch direction {
        case .left:
            moveAnchoredSelection(by: -1, viewportWidth: viewportWidth)
        case .right:
            moveAnchoredSelection(by: 1, viewportWidth: viewportWidth)
        case .up:
            onMoveUp?()
        case .down:
            onMoveDown?()
        default:
            break
        }
    }

    private func moveAnchoredSelection(
        by delta: Int,
        viewportWidth: CGFloat
    ) {
        let nextIndex = anchoredIndex + delta
        guard episodes.indices.contains(nextIndex) else { return }

        // Keep focus/selection state out of the scroll animation transaction.
        // That prevents hero metadata and every card from inheriting the
        // carousel's animation while the native ScrollView moves its content.
        anchoredIndex = nextIndex
        let targetOffset = anchoredContentOffset(
            for: nextIndex,
            viewportWidth: viewportWidth
        )
        if reduceMotion {
            anchoredScrollPosition.scrollTo(x: targetOffset)
        } else {
            withAnimation(.smooth(duration: 0.30, extraBounce: 0)) {
                anchoredScrollPosition.scrollTo(x: targetOffset)
            }
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
/// Its active still supplies the Home-style hover while the rail remains the
/// sole focus owner.
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

    /// The composite Series rail cannot use a native `.card` button per cell
    /// without reintroducing competing focus-scroll owners. Reproduce Home's
    /// artwork-only lift on the active still while leaving legacy rails exactly
    /// as they were.
    @ViewBuilder
    func episodeHomeHoverEffect(
        enabled: Bool,
        isFocused: Bool,
        reduceMotion: Bool,
        cornerRadius: CGFloat
    ) -> some View {
        if enabled {
            self
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    Color.clear,
                                    Color.black.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(isFocused ? 1 : 0)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isFocused ? 0.45 : 0),
                                    Color.white.opacity(isFocused ? 0.10 : 0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isFocused ? 1.5 : 0
                        )
                }
                .scaleEffect(
                    isFocused && !reduceMotion ? EpisodeHomeHoverMetrics.scale : 1,
                    // Grow evenly around the artwork instead of adding all of
                    // the focused width on its trailing side.
                    anchor: .center
                )
                .brightness(isFocused ? 0.035 : 0)
                .shadow(
                    color: .black.opacity(isFocused ? 0.62 : 0.2),
                    radius: isFocused ? 26 : 8,
                    y: isFocused ? 14 : 4
                )
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.30, extraBounce: 0),
                    value: isFocused
                )
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
    var usesHomeHoverEffect = false
    var showsFocusOutline = true
    var showsCurrentOutline = true

    @Environment(\.isFocused) private var environmentIsFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFocused: Bool {
        focusOverride ?? environmentIsFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            still
            if captionStyle.showsTitle {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(episodeNumberLabel)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(Color.continuumOnSurface.opacity(0.62))
                            .fixedSize(horizontal: true, vertical: false)
                        if hidesEpisodeTitle, let compactEpisodeTitle {
                            Text("·")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.continuumOnSurface.opacity(0.48))
                                .fixedSize(horizontal: true, vertical: false)
                            Text(compactEpisodeTitle)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(titleColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !hidesEpisodeTitle {
                            Spacer(minLength: 8)
                        }
                    }
                    // Season tabs keep their label inside the moving control
                    // and never animate its layout independently. Apply that
                    // same rule only to the compact Series episode caption.
                    .frame(
                        width: hidesEpisodeTitle ? cardWidth : nil,
                        height: hidesEpisodeTitle ? 28 : nil,
                        alignment: .topLeading
                    )
                    .clipped()
                    .transaction { transaction in
                        guard hidesEpisodeTitle else { return }
                        transaction.animation = nil
                        transaction.disablesAnimations = true
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

    private var episodeNumberLabel: String {
        "EPISODE \(episode.episodeNumber)"
    }

    private var compactEpisodeTitle: String? {
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
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
                    thumbhash: episode.stillThumbhash,
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
        .tvFocusRing(
            isFocused: showsFocusOutline && isFocused,
            cornerRadius: stillCornerRadius
        )
        .overlay(
            RoundedRectangle(cornerRadius: stillCornerRadius)
                .stroke(
                    Color.white.opacity(showsCurrentOutline && isCurrent && !isFocused ? 0.7 : 0),
                    lineWidth: showsCurrentOutline && isCurrent && !isFocused ? 2 : 0
                )
        )
        // Home lifts only the artwork button, not its caption. Doing the same
        // here keeps caption geometry and carousel offsets perfectly stable.
        // Match the rail's 0.30-second smooth curve so the hover transfers at
        // exactly the same rate as the episode slide instead of snapping early.
        .episodeHomeHoverEffect(
            enabled: usesHomeHoverEffect,
            isFocused: isFocused,
            reduceMotion: reduceMotion,
            cornerRadius: stillCornerRadius
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
    var cardHeightRatio: CGFloat = 9 / 16
    var cardSpacing: CGFloat = 54
    var hidesEpisodeTitle = false
    private var stillHeight: CGFloat { cardWidth * cardHeightRatio }

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
