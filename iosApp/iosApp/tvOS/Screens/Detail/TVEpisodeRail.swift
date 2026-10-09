#if os(tvOS)
import SwiftUI

private enum EpisodeHomeHoverMetrics {
    static let scale: CGFloat = 1.08

    static func leadingInset(for cardWidth: CGFloat) -> CGFloat {
        cardWidth * (scale - 1) / 2 + 2
    }
}

/// Horizontal rail of episode cards. Series uses the anchored layout: the
/// focused card is pinned to the leading slot, and Select quick-plays. The
/// Watch Party picker uses the plain native-focus layout.
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
    var favoriteStates: [String: Bool] = [:]
    var watchlistStates: [String: Bool] = [:]
    /// Card width before the poster-size scale.
    var baseCardWidth: CGFloat = 480
    /// Still aspect ratio for the anchored layout.
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
    /// The plain rail centers the current card once. Returning from a pushed
    /// page re-runs onAppear and must not scroll away from the focused card.
    @State private var hasCenteredCurrent = false
    /// Re-entering the plain rail returns to the card the viewer last focused.
    @State private var lastFocusedCardId: String?
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

    private var legacyEntryContentId: String? {
        if let lastFocusedCardId, episodes.contains(where: { $0.contentId == lastFocusedCardId }) {
            return lastFocusedCardId
        }
        return currentContentId
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
                .padding(.vertical, 12)
            }
            .focusSection()
            // Entering the row lands on the last focused card, else the
            // current episode.
            .defaultFocus($focusedCardId, legacyEntryContentId, priority: .userInitiated)
            .scrollClipDisabled()
            .onChange(of: focusedCardId) { _, contentId in
                if let contentId { lastFocusedCardId = contentId }
                onFocusedEpisodeChange?(contentId)
            }
            .onDisappear {
                onFocusedEpisodeChange?(nil)
            }
            .onAppear {
                guard !hasCenteredCurrent, let id = currentContentId else { return }
                hasCenteredCurrent = true
                // Next tick, so the LazyHStack has made the card first.
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .center)
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
            initialIsFavorite: favoriteStates[episode.contentId] ?? false,
            onSetFavorite: onSetFavorite,
            onSetWatchlist: onSetWatchlist,
            initialInWatchlist: watchlistStates[episode.contentId] ?? false,
            cardHeightRatio: cardHeightRatio,
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
                    moveAnchoredScroll(to: index, viewportWidth: geometry.size.width, timing: .season)
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
                        moveAnchoredScroll(to: index, viewportWidth: geometry.size.width, timing: .episode)
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

    private var anchoredRailHeight: CGFloat {
        Self.anchoredHeight(
            cardWidth: anchoredCardWidth,
            cardHeightRatio: cardHeightRatio,
            showsTitle: uiCustomization.cardPresentation.caption.showsTitle
        )
    }

    /// Height of the anchored rail: still, optional caption, and vertical
    /// padding. Series reserves the same height while a season loads.
    static func anchoredHeight(cardWidth: CGFloat, cardHeightRatio: CGFloat, showsTitle: Bool) -> CGFloat {
        cardWidth * cardHeightRatio + (showsTitle ? 46 : 0) + 24
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
        targetContentId: String? = nil
    ) {
        let target = targetContentId ?? focusedCardId ?? currentContentId
        let episode = episodes.first(where: { $0.contentId == target })
            ?? episodes.first(where: { $0.contentId == anchoredContentId })
            ?? episodes.first
        guard let episode,
              let index = episodes.firstIndex(where: { $0.contentId == episode.contentId }) else { return }
        anchoredContentId = episode.contentId
        moveAnchoredScroll(to: index, viewportWidth: viewportWidth, timing: nil)
    }

    /// Focus can only reach loaded cards, so ask for the neighbouring season
    /// as soon as focus lands on either end of the loaded window.
    private func requestEpisodesNearBoundary(at index: Int) {
        if index == 0 { onRequestPrevious?() }
        if index == episodes.count - 1 { onRequestNext?() }
    }

    /// `timing` nil (or Reduce Motion) jumps without animating.
    private func moveAnchoredScroll(
        to index: Int,
        viewportWidth: CGFloat,
        timing: SeriesSeasonScroll.Timing?
    ) {
        scrollViewport.move(
            to: anchoredContentOffset(for: index, viewportWidth: viewportWidth),
            maximumOffset: anchoredContentOffset(for: episodes.count - 1, viewportWidth: viewportWidth),
            timing: reduceMotion ? nil : timing
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

    /// Reproduce Home's artwork-only lift for the anchored episode buttons.
    /// Plain rails use `TVCardFocusButtonStyle`.
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
                isCurrent: isCurrent,
                cardWidth: cardWidth,
                stillHeight: stillHeight,
                stillCornerRadius: stillCornerRadius,
                captionStyle: captionStyle,
                usesAnchoredStyle: usesAnchoredStyle
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
        if let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) {
            parts.append(runtime)
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
    let isCurrent: Bool
    let cardWidth: CGFloat
    let stillHeight: CGFloat
    let stillCornerRadius: CGFloat
    let captionStyle: CardCaptionStyle
    /// The Series carousel's look: compact caption, Home's artwork-only lift,
    /// and no focus or current outline.
    let usesAnchoredStyle: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hidesEpisodeTitle: Bool { usesAnchoredStyle }
    private var showsOutlines: Bool { !usesAnchoredStyle }

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
                               let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) {
                                Text(runtime)
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

    private var still: some View {
        ZStack(alignment: .bottom) {
            Color.siloSurfaceElevated
                .frame(width: cardWidth, height: stillHeight)

            AsyncImageView(
                url: episode.stillUrl ?? "",
                thumbhash: episode.stillThumbhash,
                targetSize: CGSize(width: cardWidth, height: stillHeight),
                contentMode: .fill,
                placeholderStyle: .artwork,
                placeholderSymbol: ArtworkPlaceholderSymbol.television
            )
            .frame(width: cardWidth, height: stillHeight)

            if isPlayed {
                Color.black.opacity(0.35)
                    .frame(width: cardWidth, height: stillHeight)

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
            isFocused: showsOutlines && isFocused,
            cornerRadius: stillCornerRadius
        )
        .overlay(
            RoundedRectangle(cornerRadius: stillCornerRadius)
                .stroke(
                    Color.white.opacity(showsOutlines && isCurrent && !isFocused ? 0.7 : 0),
                    lineWidth: showsOutlines && isCurrent && !isFocused ? 2 : 0
                )
        )
        // Home lifts only the artwork button, not its caption. Doing the same
        // here keeps caption geometry and carousel offsets perfectly stable.
        // Match the rail's 0.30-second smooth curve so the hover transfers at
        // exactly the same rate as the episode slide instead of snapping early.
        .episodeHomeHoverEffect(
            enabled: usesAnchoredStyle,
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
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.6))
            Rectangle()
                .fill(Color.white)
                .frame(width: cardWidth * CGFloat(fraction))
        }
        .frame(width: cardWidth, height: 5)
    }

    private var progressFraction: Double? {
        guard let userData = episode.userData,
              let pos = userData.positionSeconds,
              let dur = userData.durationSeconds,
              dur > 0, pos > 0, pos < dur
        else { return nil }
        return pos / dur
    }
}

/// Reserves the anchored rail's card geometry while a season loads so lower
/// sections don't jump when real episodes arrive.
struct TVEpisodeRailPlaceholder: View {
    let cardWidth: CGFloat
    let cardHeightRatio: CGFloat
    let cardSpacing: CGFloat
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
                    }
                    .frame(width: cardWidth, alignment: .leading)
                }
            }
            .padding(.vertical, 12)
        }
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityHidden(true)
    }
}

#endif
