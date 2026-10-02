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
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> PersonalStateOutcome)? = nil
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> PersonalStateOutcome)? = nil
    var onSetWatchlist: ((_ contentId: String, _ inWatchlist: Bool) async -> PersonalStateOutcome)? = nil
    /// When non-nil, the matching card is visually highlighted and anchored
    /// at first appearance.
    var currentContentId: String? = nil
    var currentContentIsFavorite = false
    var favoriteStates: [String: Bool] = [:]
    var watchlistStates: [String: Bool] = [:]
    var prefersCurrentContentFocus = false
    /// Series opts into a larger carousel card. The default keeps the
    /// approved 480-point geometry on existing season/episode pages.
    var baseCardWidth: CGFloat = 480
    /// Series can exactly reuse Home's 360×200 thumbnail aspect while legacy
    /// episode pages retain their existing 16:9 geometry.
    var cardHeightRatio: CGFloat = 9 / 16
    var cardSpacing: CGFloat = 54
    var anchorsFocusedCard = false
    /// Explicit season-chip jumps scroll the existing carousel without
    /// taking focus from the chip. Loaded edges extend the same episode row.
    var scrollRequest = 0
    var scrollTargetContentId: String? = nil
    /// Non-zero changes move the selected card to `selectionTargetContentId`
    /// without moving focus into or out of the row.
    var selectionRequest = 0
    var selectionTargetContentId: String? = nil
    var isSelectingSeason = false
    var onRequestPrevious: (() -> Void)? = nil
    var onRequestNext: (() -> Void)? = nil

    private struct SeasonScrollUpdate: Equatable {
        let request: Int
        let episodeIds: [String]
    }
    @State private var appliedScrollRequest = 0
    @State private var scrollViewport = ScrollViewport()
    @State private var focusTrace = TVEpisodeRailFocusTrace()

    /// Own the actual viewport for both card moves and season jumps. Binding a
    /// second SwiftUI ScrollPosition replays its stale point when pages change.
    private final class ScrollViewport: NSObject {
        weak var scrollView: UIScrollView?
        private var intendedOffset: CGFloat?
        private var maximumOffset: CGFloat = 0
        private var motion: SeriesSeasonScroll?
        private var displayLink: CADisplayLink?

        func attach(_ scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            if let intendedOffset { setOffset(intendedOffset) }
        }

        func move(to offset: CGFloat, maximumOffset: CGFloat, timing: SeriesSeasonScroll.Timing?) {
            self.maximumOffset = maximumOffset
            stopScroll()
            guard let scrollView else { setOffset(offset); return }
            guard let timing else { setOffset(offset); return }
            motion = SeriesSeasonScroll(
                startOffset: scrollView.contentOffset.x,
                targetOffset: offset,
                startedAt: CACurrentMediaTime(),
                timing: timing
            )
            let link = CADisplayLink(target: self, selector: #selector(advanceScroll))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        /// Page changes shift coordinates, including any in-flight card move,
        /// without starting another animation or changing its completion time.
        func rebase(by shift: CGFloat, maximumOffset: CGFloat) {
            self.maximumOffset = maximumOffset
            motion?.rebase(by: shift)
            if let offset = intendedOffset ?? scrollView?.contentOffset.x {
                setOffset(offset + shift)
            }
        }

        private func setOffset(_ offset: CGFloat) {
            // Use the new model geometry; UIScrollView.contentSize can still
            // describe the old lazy page during insertion or eviction.
            let offset = SeriesSeasonScroll.clampedOffset(offset, maximumOffset: maximumOffset)
            intendedOffset = offset
            guard let scrollView else { return }
            scrollView.setContentOffset(
                CGPoint(x: offset, y: scrollView.contentOffset.y), animated: false
            )
        }

        /// Lazy layout and the focus engine's own reveal can both write the
        /// content offset. The rail owns the anchored position, so reconcile
        /// those writes with the latest target instead of settling twice.
        func reconcileOffset() {
            guard motion == nil, let intendedOffset, let scrollView,
                  abs(scrollView.contentOffset.x - intendedOffset) > 0.5 else { return }
            setOffset(intendedOffset)
        }

        /// Lands an in-flight season jump at its target. Focus entering the
        /// row mid-jump must find the anchored card where it will rest, not
        /// wherever the animation happened to be.
        func finishScroll() {
            guard let motion else { return }
            stopScroll()
            setOffset(motion.targetOffset)
        }

        @objc private func advanceScroll(_ link: CADisplayLink) {
            guard let motion, scrollView != nil else { stopScroll(); return }
            setOffset(motion.offset(at: link.timestamp))
            if motion.isComplete(at: link.timestamp) { stopScroll() }
        }

        func stopScroll() {
            displayLink?.invalidate()
            displayLink = nil
            motion = nil
        }
    }

    @FocusState private var focusedCardId: String?
    @Namespace private var anchoredFocusScope
    /// The card the anchored row is positioned on: the focused card while the
    /// row has focus, otherwise the last one it selected or scrolled to.
    @State private var anchoredContentId: String?
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
                        episodeCard(episode)
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
                    withAnimation(.easeOut(duration: SiloTheme.normalDuration)) {
                        proxy.scrollTo(id, anchor: anchorsFocusedCard ? .leading : .center)
                    }
                }
            }
        }
    }

    private func episodeCard(_ episode: EpisodeListItem) -> TVEpisodeCard {
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
            onSetFavorite: onSetFavorite,
            onSetWatchlist: onSetWatchlist,
            initialInWatchlist: watchlistStates[episode.contentId] ?? false,
            cardHeightRatio: anchorsFocusedCard ? cardHeightRatio : 9 / 16,
            usesAnchoredStyle: anchorsFocusedCard
        )
    }

    /// Native per-card focus: the focus engine moves between episode buttons
    /// and in and out of the row, and the rail only positions the focused card
    /// at the leading slot. Entering the row lands on the anchored episode.
    private var anchoredRail: some View {
        GeometryReader { geometry in
            anchoredCards(viewportWidth: geometry.size.width)
                .onAppear {
                    seedAnchoredSelection(viewportWidth: geometry.size.width)
                }
                .task(id: SeasonScrollUpdate(request: scrollRequest, episodeIds: episodeIdentityKey)) {
                    // Resolve the current target after the new page layout mounts.
                    await Task.yield()
                    guard !Task.isCancelled,
                          scrollRequest > 0, scrollRequest != appliedScrollRequest,
                          let scrollTargetContentId,
                          let index = episodes.firstIndex(where: { $0.contentId == scrollTargetContentId })
                    else { return }
                    appliedScrollRequest = scrollRequest
                    anchoredContentId = episodes[index].contentId
                    scrollToSelectedSeason(at: index, viewportWidth: geometry.size.width)
                }
                .onChange(of: episodeIdentityKey) { oldIds, newIds in
                    // Paging changes coordinates, not the user's selection.
                    // Preserve the visible position when seasons are prepended
                    // or evicted; appends must not restart an ongoing card slide.
                    let id = focusedCardId ?? anchoredContentId
                    let oldIndex = id.flatMap { oldIds.firstIndex(of: $0) }
                    let newIndex = id.flatMap { newIds.firstIndex(of: $0) }
                    let shift: CGFloat
                    if let oldIndex, let newIndex {
                        shift = CGFloat(newIndex - oldIndex) * (anchoredCardWidth + cardSpacing)
                    } else {
                        shift = 0
                    }
                    // Even a tail-only eviction can shrink the valid range.
                    scrollViewport.rebase(
                        by: shift,
                        maximumOffset: anchoredContentOffset(
                            for: episodes.count - 1, viewportWidth: geometry.size.width
                        )
                    )
                }
                .onChange(of: currentContentId) { _, _ in
                    // The season chip owns an explicit animated request.
                    // Its metadata update must not snap to the same target
                    // before that request gets a chance to run.
                    guard focusedCardId == nil, !isSelectingSeason else { return }
                    seedAnchoredSelection(viewportWidth: geometry.size.width)
                }
                .onChange(of: selectionRequest) { _, request in
                    guard request > 0, let selectionTargetContentId,
                          episodes.contains(where: { $0.contentId == selectionTargetContentId }) else { return }
                    if focusedCardId != nil {
                        // Moving the focused card also reports it as the active episode.
                        focusedCardId = selectionTargetContentId
                    } else {
                        seedAnchoredSelection(
                            viewportWidth: geometry.size.width,
                            targetContentId: selectionTargetContentId
                        )
                    }
                }
                .onChange(of: focusedCardId) { oldId, contentId in
                    focusTrace.railFocusChanged(contentId != nil)
                    if let contentId,
                       let index = episodes.firstIndex(where: { $0.contentId == contentId }) {
                        if let oldId, let oldIndex = episodes.firstIndex(where: { $0.contentId == oldId }) {
                            focusTrace.recordMove(index - oldIndex)
                        }
                        anchoredContentId = contentId
                        moveAnchoredScroll(to: index, viewportWidth: geometry.size.width, animated: true)
                        requestEpisodesNearBoundary(at: index)
                    }
                    onFocusedEpisodeChange?(contentId)
                }
        }
        .frame(height: anchoredRailHeight)
        .onChange(of: isSelectingSeason) { _, ownsFocus in
            if !ownsFocus {
                scrollViewport.finishScroll()
            }
        }
        .onDisappear {
            scrollViewport.stopScroll()
            scrollViewport.scrollView = nil
            focusTrace.stop()
            onFocusedEpisodeChange?(nil)
        }
    }

    /// The pinned card sits at the leading slot, so its predecessor is off
    /// screen. A lazy stack only keeps cards inside its scroll view's bounds,
    /// and focus can only reach loaded cards, so the scroll view extends one
    /// card step past the visible leading edge. A mask keeps the visible crop.
    private var anchoredLookbehind: CGFloat {
        anchoredCardWidth + cardSpacing
    }

    private func anchoredCards(viewportWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: cardSpacing) {
                ForEach(episodes) { episode in
                    episodeCard(episode)
                        .focused($focusedCardId, equals: episode.contentId)
                        .zIndex(focusedCardId == episode.contentId ? 1 : 0)
                }
            }
            .background {
                TVDetailScrollViewResolver { scrollViewport.attach($0) }
            }
            // Preserve the existing crop, hover clearance and trailing boundary.
            .padding(
                .leading,
                anchoredLookbehind + EpisodeHomeHoverMetrics.leadingInset(for: anchoredCardWidth)
            )
            .padding(
                .trailing,
                anchoredTrailingInset(viewportWidth: viewportWidth)
            )
            .padding(.vertical, 12)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x
        } action: { _, _ in
            scrollViewport.reconcileOffset()
        }
        .scrollClipDisabled()
        .frame(width: viewportWidth + anchoredLookbehind, height: anchoredRailHeight)
        .padding(.leading, -anchoredLookbehind)
        .frame(
            width: viewportWidth,
            height: anchoredRailHeight,
            alignment: .topLeading
        )
        .mask(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { focusTrace.railFrame = $0 }
        .focusSection()
        .defaultFocus($focusedCardId, anchoredContentId ?? currentContentId, priority: .userInitiated)
        .focusScope(anchoredFocusScope)
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

    private var episodeIdentityKey: [String] {
        episodes.map(\.contentId)
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

    private func seedAnchoredSelection(
        viewportWidth: CGFloat,
        targetContentId: String? = nil,
        animated: Bool = false
    ) {
        let target = targetContentId ?? focusedCardId ?? currentContentId
        let episode = episodes.first(where: { $0.contentId == target })
            ?? episodes.first(where: { $0.contentId == anchoredContentId })
            ?? episodes.first
        guard let episode,
              let index = episodes.firstIndex(where: { $0.contentId == episode.contentId }) else { return }
        anchoredContentId = episode.contentId
        moveAnchoredScroll(to: index, viewportWidth: viewportWidth, animated: animated)
    }

    /// Focus can only reach loaded cards, so ask for the neighbouring season
    /// as soon as focus lands on either end of the loaded window.
    private func requestEpisodesNearBoundary(at index: Int) {
        if index == 0 { onRequestPrevious?() }
        if index == episodes.count - 1 { onRequestNext?() }
    }

    private func scrollToSelectedSeason(at index: Int, viewportWidth: CGFloat) {
        scrollViewport.move(
            to: anchoredContentOffset(for: index, viewportWidth: viewportWidth),
            maximumOffset: anchoredContentOffset(for: episodes.count - 1, viewportWidth: viewportWidth),
            timing: reduceMotion ? nil : .season
        )
    }

    private func moveAnchoredScroll(to index: Int, viewportWidth: CGFloat, animated: Bool) {
        scrollViewport.move(
            to: anchoredContentOffset(for: index, viewportWidth: viewportWidth),
            maximumOffset: anchoredContentOffset(for: episodes.count - 1, viewportWidth: viewportWidth),
            timing: animated && !reduceMotion ? .episode : nil
        )
    }
}

/// The anchored card draws its own Home-style lift in `EpisodeCardLabel`.
private struct TVAnchoredEpisodeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.96 : 1)
            .focusEffectDisabled()
            .animation(
                .easeOut(duration: SiloTheme.fastDuration),
                value: configuration.isPressed
            )
    }
}

private extension View {
    @ViewBuilder
    func applyEpisodeButtonStyle(anchored: Bool) -> some View {
        if anchored {
            buttonStyle(TVAnchoredEpisodeButtonStyle())
        } else {
            buttonStyle(TVCardFocusButtonStyle())
        }
    }

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

    /// Reproduce Home's artwork-only lift for the anchored episode buttons.
    /// Legacy rails retain their existing native `.card` appearance.
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
    var onSetWatched: ((_ contentId: String, _ played: Bool) async -> PersonalStateOutcome)? = nil
    var initialIsFavorite = false
    var onSetFavorite: ((_ contentId: String, _ isFavorite: Bool) async -> PersonalStateOutcome)? = nil
    var onSetWatchlist: ((_ contentId: String, _ inWatchlist: Bool) async -> PersonalStateOutcome)? = nil

    var initialInWatchlist = false
    var cardHeightRatio: CGFloat = 9 / 16
    /// The Series carousel's look: compact caption, Home's artwork-only
    /// lift, and no focus or current outline.
    var usesAnchoredStyle = false

    @State private var actionFeedback = MediaActionFeedback()
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?

    private var cardWidth: CGFloat { baseCardWidth * posterSize.scale }
    private var stillHeight: CGFloat { cardWidth * cardHeightRatio }
    private let stillCornerRadius: CGFloat = 18

    var body: some View {
        let button = Button(action: onSelect) {
            EpisodeCardLabel(
                episode: episode,
                isPlayed: isPlayed,
                hidesStill: EpisodeSpoilerPreferences.shared.settings.hidesImage(
                    for: EpisodeWatchState(episode.userData, playedOverride: playedOverride), isEpisodeStill: episode.stillIsEpisodeStill
                ),
                isCurrent: isCurrent,
                cardWidth: cardWidth,
                stillHeight: stillHeight,
                stillCornerRadius: stillCornerRadius,
                captionStyle: captionStyle,
                hidesEpisodeTitle: usesAnchoredStyle,
                usesHomeHoverEffect: usesAnchoredStyle,
                showsFocusOutline: !usesAnchoredStyle,
                showsCurrentOutline: !usesAnchoredStyle
            )
        }
        .applyEpisodeButtonStyle(anchored: usesAnchoredStyle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)

        Group {
            if onPlay != nil || onSetWatched != nil || onSetFavorite != nil || onSetWatchlist != nil {
                button.contextMenu { contextActions }
            } else {
                button
            }
        }
        .mediaActionFeedback(actionFeedback)
        .onChange(of: episode.userData?.played) { _, refreshedValue in
            guard let playedOverride, refreshedValue == playedOverride else { return }
            self.playedOverride = nil
        }
        .onChange(of: initialIsFavorite) { _, refreshedValue in
            guard let favoriteOverride, refreshedValue == favoriteOverride else { return }
            self.favoriteOverride = nil
        }
        .onChange(of: initialInWatchlist) { _, refreshedValue in
            guard let watchlistOverride, refreshedValue == watchlistOverride else { return }
            self.watchlistOverride = nil
        }
    }

    private var inWatchlist: Bool {
        watchlistOverride ?? initialInWatchlist
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
        WatchPartyMenuButton(contentId: episode.contentId, title: episode.title ?? "Episode", type: "episode")
        if let onPlay {
            Button {
                onPlay(episode.contentId)
            } label: {
                // Verbatim so year-numbered seasons don't render as "S2,021".
                Label {
                    Text(verbatim: "Play S\(episode.seasonNumber):E\(episode.episodeNumber)")
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
        }

        MediaStateMenuItems(
            isWatched: isPlayed,
            isFavorite: isFavorite,
            inWatchlist: inWatchlist,
            watchedSubject: "Episode",
            isUpdating: actionFeedback.isUpdating,
            onToggleWatched: onSetWatched.map { update in
                {
                    let value = !isPlayed
                    let previous = playedOverride
                    actionFeedback.perform {
                        playedOverride = value
                        let outcome = await update(episode.contentId, value)
                        if outcome != .applied { playedOverride = previous }
                        return outcome
                    }
                }
            },
            onToggleFavorite: onSetFavorite.map { update in
                {
                    let value = !isFavorite
                    let previous = favoriteOverride
                    actionFeedback.perform {
                        favoriteOverride = value
                        let outcome = await update(episode.contentId, value)
                        if outcome != .applied { favoriteOverride = previous }
                        return outcome
                    }
                }
            },
            onToggleWatchlist: onSetWatchlist.map { update in
                {
                    let value = !inWatchlist
                    let previous = watchlistOverride
                    actionFeedback.perform {
                        watchlistOverride = value
                        let outcome = await update(episode.contentId, value)
                        if outcome != .applied { watchlistOverride = previous }
                        return outcome
                    }
                }
            }
        )
    }
}

private struct EpisodeCardLabel: View {
    let episode: EpisodeListItem
    let isPlayed: Bool
    /// Spoiler protection: blur the still of an episode the profile has not
    /// started.
    var hidesStill = false
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
                    if hidesEpisodeTitle, let compactEpisodeTitle {
                        // Keep the compact Series caption inside the moving
                        // control without animating its layout independently.
                        Text(compactEpisodeTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: cardWidth, height: 28, alignment: .topLeading)
                            .clipped()
                            .transaction { transaction in
                                transaction.animation = nil
                                transaction.disablesAnimations = true
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
                                    .foregroundStyle(Color.siloSecondaryText)
                                    .lineLimit(1)
                            }
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

    /// "S01E02 · Pilot" — the same code Home puts on episode cards, so the
    /// Series carousel makes each episode's position obvious at a glance.
    private var compactEpisodeTitle: String? {
        let code = EpisodeCardCaption.code(
            season: episode.seasonNumber,
            episode: episode.episodeNumber
        )
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return code }
        return "\(code) · \(title)"
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
            Color.siloSurfaceElevated
                .frame(width: cardWidth, height: stillHeight)

            if let url = episode.stillUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: cardWidth, height: stillHeight),
                    thumbhash: episode.stillThumbhash,
                    contentMode: .fill
                )
                .frame(width: cardWidth, height: stillHeight)
                .episodeSpoilerBlur(hidesStill)
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
                            .fill(Color.siloSurfaceElevated)
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
