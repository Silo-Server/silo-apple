#if os(tvOS)
import SwiftUI
import UIKit

/// Single-page Series experience for tvOS. `Show` and every season are
/// in-place modes: the series backdrop never changes, episode focus updates
/// the editorial details and selectors, and selecting an episode quick-plays
/// it without pushing a second detail page.
struct TVSeriesDetailView<BelowSynopsis: View>: View {
    private enum PrimaryFocusRegion {
        case outside
        case mode
        case episodes
        case supporting
    }

    /// Owns only the outer vertical UIScrollView. Locking this concrete scroll
    /// view leaves every nested horizontal season/episode rail fully native.
    ///
    /// Every page-level trip — the return to the hero and the descent that
    /// centers the Cast section — runs through this one animator slot. A new
    /// trip stops the current one at its presentation position first, so a
    /// rapid reversal in either direction continues from where the page
    /// visibly is instead of letting two animations race to the finish.
    private final class PageScrollCoordinator {
        weak var scrollView: UIScrollView?
        /// Marker view laid out behind the first supporting section; its frame converted
        /// into the scroll view gives the centering target in content space.
        weak var supportingAnchorView: UIView?
        private var pageAnimator: UIViewPropertyAnimator?
        private var animationGeneration = 0
        private(set) var primaryOwnsViewport = false

        func attach(_ scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }
            stopPageAnimation()
            self.scrollView = scrollView
            if primaryOwnsViewport {
                pinTopAndLock()
            }
        }

        func enterPrimary(animated: Bool, reduceMotion: Bool) {
            primaryOwnsViewport = true
            // Moves between rows inside the fixed viewport (Season row <->
            // Episodes) ask for `animated: false` because the page should
            // already be resting at the top. On a double Up from Cast the
            // first press's return trip is still mid-flight; jumping now is
            // the snap. Finish that trip as an animation from wherever the
            // page visibly is instead.
            let continuesInFlightTrip = pageAnimator?.state == .active
            stopPageAnimation()
            guard let scrollView else { return }

            scrollView.isScrollEnabled = true
            let target = topOffset(in: scrollView)
            guard animated || continuesInFlightTrip,
                  !reduceMotion,
                  abs(scrollView.contentOffset.y - target.y) > 0.5 else {
                scrollView.setContentOffset(target, animated: false)
                scrollView.isScrollEnabled = false
                return
            }

            animatePage(to: target) { [weak self, weak scrollView] in
                guard let self, self.primaryOwnsViewport, let scrollView else { return }
                scrollView.setContentOffset(
                    self.topOffset(in: scrollView),
                    animated: false
                )
                scrollView.isScrollEnabled = false
            }
        }

        /// Centers the first supporting section after focus leaves the top viewport.
        /// Runs in the same animator slot as the return trip so that an Up
        /// press mid-descent stops this motion where it is and the return
        /// starts from that exact offset.
        func revealSupporting(reduceMotion: Bool) {
            primaryOwnsViewport = false
            stopPageAnimation()
            guard let scrollView, let supportingAnchorView else { return }

            scrollView.isScrollEnabled = true
            let target = centeredOffset(for: supportingAnchorView, in: scrollView)
            guard !reduceMotion,
                  abs(scrollView.contentOffset.y - target.y) > 0.5 else {
                scrollView.setContentOffset(target, animated: false)
                return
            }

            // No settle write here. The model offset is already at `target`
            // once the animation block runs, so the focus engine's own reveal
            // for the Cast card sees it as visible and stays quiet, while a
            // later move on to Trailers or Similar must be allowed to win.
            animatePage(to: target) {}
        }

        func releasePrimary() {
            primaryOwnsViewport = false
            stopPageAnimation()
            scrollView?.isScrollEnabled = true
        }

        func detach() {
            primaryOwnsViewport = false
            stopPageAnimation()
            scrollView?.isScrollEnabled = true
            scrollView = nil
        }

        private func animatePage(to target: CGPoint, onSettle: @escaping () -> Void) {
            guard let scrollView else { return }
            animationGeneration &+= 1
            let generation = animationGeneration
            let timing = UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.4, y: 0),
                controlPoint2: CGPoint(x: 0.2, y: 1)
            )
            let animator = UIViewPropertyAnimator(
                duration: 0.55,
                timingParameters: timing
            )
            pageAnimator = animator
            animator.addAnimations { [weak scrollView] in
                scrollView?.setContentOffset(target, animated: false)
            }
            animator.addCompletion { [weak self] _ in
                guard let self, self.animationGeneration == generation else { return }
                self.pageAnimator = nil
                onSettle()
            }
            animator.startAnimation()
        }

        private func pinTopAndLock() {
            guard let scrollView else { return }
            scrollView.setContentOffset(topOffset(in: scrollView), animated: false)
            scrollView.isScrollEnabled = false
        }

        private func stopPageAnimation() {
            animationGeneration &+= 1
            guard let pageAnimator else { return }
            self.pageAnimator = nil
            if pageAnimator.state == .active {
                pageAnimator.stopAnimation(false)
                pageAnimator.finishAnimation(at: .current)
            } else {
                pageAnimator.stopAnimation(true)
            }
        }

        private func topOffset(in scrollView: UIScrollView) -> CGPoint {
            CGPoint(
                x: scrollView.contentOffset.x,
                y: -scrollView.adjustedContentInset.top
            )
        }

        /// Equivalent of `scrollTo(id, anchor: .center)` for the anchor view,
        /// clamped to the scrollable range like the SwiftUI proxy does.
        private func centeredOffset(for anchor: UIView, in scrollView: UIScrollView) -> CGPoint {
            let rect = scrollView.convert(anchor.bounds, from: anchor)
            let viewportHeight = scrollView.bounds.height
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(
                minY,
                scrollView.contentSize.height
                    + scrollView.adjustedContentInset.bottom
                    - viewportHeight
            )
            let centered = rect.midY - viewportHeight / 2
            return CGPoint(
                x: scrollView.contentOffset.x,
                y: min(max(centered, minY), maxY)
            )
        }
    }

    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodeWindow: SeriesEpisodeWindow
    let carouselLoadFailed: Bool
    let onLoadMoreEpisodes: (Int) -> Void
    let activeEpisodeContentId: String?
    let episodeFavoriteStates: [String: Bool]
    let isLoadingEpisodes: Bool
    let selectedNextUpFileId: Int?
    let selectedNextUpAudioTrackIndex: Int?
    let selectedNextUpSubtitleTrackIndex: Int?
    let nextUpPlaybackDetail: ItemDetail?
    var nextUpSubtitleOverrideCleared = false
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    let supportsTrailerFetch: Bool
    let onFindTrailers: () -> Void
    let trailerFetchStatus: String?
    let isFetchingTrailers: Bool
    let onTrailerStatusShown: () -> Void
    let onSelectSeason: (Season) async -> String?
    /// `nil` restores the show overview and its suggested next episode.
    let onActivateEpisode: (_ contentId: String?) -> Void
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
    let onSelectNextUpVersion: (Int?) -> Void
    let onSelectNextUpAudioTrack: (Int?) -> Void
    let onSelectNextUpSubtitleTrack: (Int?) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Namespace private var detailFocusNamespace
    @Namespace private var modeFocusNamespace
    @FocusState private var playFocused: Bool
    @FocusState private var showActionRowFocused: Bool
    @FocusState private var focusedModeId: String?
    @State private var isShowingSeriesOverview = true
    @State private var primaryFocusRegion: PrimaryFocusRegion = .outside
    @State private var episodeRailFocusRequest = 0
    @State private var episodeRailFocusTarget: String?
    @State private var supportingRailFocusRequest = 0
    @State private var supportingRailFocusGeneration = 0
    @State private var modeActivationTask: Task<Void, Never>?
    @State private var modeFocusAppearanceTask: Task<Void, Never>?
    @State private var presentedFocusedModeId: String?
    @State private var hasPositionedModeRow = false
    @State private var seasonSelection = SeriesSeasonSelection()
    @State private var episodeScrollTarget: String?
    @State private var episodeScrollRequest = 0
    @State private var pageScrollCoordinator = PageScrollCoordinator()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let noSeasonModeId = "series-season-none"
    private let episodeSectionScrollId = "series-episode-section"
    private let castSectionScrollId = "series-cast-section"
    private let heroScrollId = "series-hero"
    private let similarSectionScrollId = "series-similar-section"

    var body: some View {
        TVDetailPageSurface(backdropURL: detail.backdropUrl) {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroView
                            .id(heroScrollId)

                        VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                            episodeExperience
                                .id(episodeSectionScrollId)
                            if let cast = detail.cast, !cast.isEmpty {
                                castSection(cast: cast)
                                    .id(castSectionScrollId)
                            }
                            trailersSection
                            similarSection
                                .id(similarSectionScrollId)
                            detailsSection
                        }
                        .padding(.horizontal, TVDetailLayout.horizontalInset)
                        .padding(.bottom, TVDetailLayout.pageBottomPadding)
                    }
                    .background {
                        TVDetailScrollViewResolver { scrollView in
                            pageScrollCoordinator.attach(scrollView)
                        }
                    }
                }
                .ignoresSafeArea()
                .focusScope(detailFocusNamespace)
                .defaultFocus($playFocused, true, priority: .userInitiated)
                .detailFocusScroll(
                    proxy: scrollProxy,
                    seasonRowFocused: false,
                    actionRowFocused: showActionRowFocused,
                    episodeSectionId: episodeSectionScrollId,
                    heroId: heroScrollId
                )
                .tvActionPopoverHost()
            }
        }
        .onAppear {
            if activeEpisodeContentId != nil {
                isShowingSeriesOverview = false
            }
        }
        .onChange(of: activeEpisodeContentId) { _, contentId in
            if contentId != nil {
                isShowingSeriesOverview = false
            }
        }
        .onDisappear {
            modeActivationTask?.cancel()
            modeActivationTask = nil
            modeFocusAppearanceTask?.cancel()
            modeFocusAppearanceTask = nil
            presentedFocusedModeId = nil
            seasonSelection.cancel()
            pageScrollCoordinator.detach()
        }
    }

    // MARK: - Fixed series hero

    private var heroView: some View {
        TVDetailHero(
            // Show and Season browsing share one title identity. Episode
            // focus changes the bounded synopsis/metadata only, never the
            // logo or title block that determines the page geometry.
            title: detail.title,
            seriesTitle: nil,
            logoUrl: detail.logoUrl,
            // Deliberately never switch to episode artwork. The series image
            // remains a stable visual anchor while episode details change.
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: nil,
            sourceTokens: heroSourceTokens,
            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
            overview: heroOverview,
            factsLine: heroFactsLine,
            // Series cast is intentionally painted once across Show, Season,
            // and episode focus. Episode credits are almost always identical;
            // retaining this value avoids a blank/load/change flash in the
            // bottom-locked disclosure block.
            starringText: TVHeroMetadata.starringText(from: detail),
            playbackSummary: TVPlaybackSelectionSummary.make(
                currentVersion: effectiveNextUpVersion,
                selectedVersionFileId: selectedNextUpFileId,
                selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                subtitleMode: nextUpSubtitleOverrideCleared
                    ? nil
                    : matchingPlaybackDetail?.effectiveSubtitleMode,
                subtitleSignature: nextUpSubtitleOverrideCleared
                    ? nil
                    : matchingPlaybackDetail?.effectiveSubtitleTrackSignature,
                preferredSubtitleLanguage: profilePrefsStore.preferredSubtitleLanguage,
                showForcedSubtitles: matchingPlaybackDetail?.effectiveShowForcedSubtitles ?? false
            ),
            backdropHeight: TVDetailLayout.heroHeight,
            // The hero shares the standard height and title inset with Movie
            // so the first viewport bottoms out on the episode rail: the season
            // row lands at ~690 and the rail finishes just above the bottom
            // safe area with Cast & Crew fully below the fold.
            heroHeight: TVDetailLayout.heroHeight,
            editorialContentWidth: TVDetailLayout.heroContentWidth,
            // Raise only the controls by 20 points. The 112-point synopsis slot
            // remains unchanged, so episode copy still renders three full lines.
            editorialReservedHeight: 435,
            metadataReservedHeight: 36,
            // Three 26-point synopsis lines plus their line spacing must fit
            // inside the fixed slot; 88 clipped the selected episode's final
            // line even though the synopsis itself was correctly line-limited.
            synopsisReservedHeight: 112,
            creditReservedHeight: 28,
            actionSpacing: 4,
            extendsBackdropFadeBelowHero: true,
            actions: {
                showActionRow
            },
            belowSynopsis: {
                if isShowingSeriesOverview {
                    belowSynopsis()
                }
            }
        )
    }

    private var heroOverview: String? {
        guard !isShowingSeriesOverview else { return detail.overview }
        let episodeTitle = matchingPlaybackDetail?.title
            ?? displayedEpisode?.title
            ?? displayedEpisode.map { "Episode \($0.episodeNumber)" }
        let overview = matchingPlaybackDetail?.overview ?? displayedEpisode?.overview
        switch (episodeTitle, overview) {
        case let (.some(title), .some(line)) where !title.isEmpty && !line.isEmpty:
            return "\(title) · \(line)"
        case let (.some(title), _):
            return title
        case let (_, .some(line)):
            return line
        default:
            return nil
        }
    }

    private var heroSourceTokens: [String] {
        guard !isShowingSeriesOverview, let episode = displayedEpisode else {
            return TVHeroMetadata.seriesSourceTokens(from: detail)
        }
        let season = episode.seasonNumber == 0 ? "Specials" : "Season \(episode.seasonNumber)"
        return [season, "Episode \(episode.episodeNumber)"]
    }

    private var heroFactsLine: [TVHeroFactToken] {
        guard !isShowingSeriesOverview, let episode = displayedEpisode else {
            return TVHeroMetadata.seriesFactsLine(from: detail)
        }
        var facts: [TVHeroFactToken] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            facts.append(.text(airDate))
        }
        if let runtime = episode.runtime, runtime > 0 {
            facts.append(.text(runtimeLabel(runtime)))
        }
        return facts
    }

    // MARK: - Show mode actions

    private var showActionRow: some View {
        TVDetailActionRow(
            playTitle: playbackEpisode.map(showPlayTitle(for:)),
            playSubtitle: nil,
            onPlay: {
                guard let episode = playbackEpisode else { return }
                onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
            },
            onStartOver: playbackEpisode?.userData?.isInProgress == true
                ? {
                    guard let episode = playbackEpisode else { return }
                    onPlayEpisode(episode.contentId, selectedFileId(for: episode), true)
                }
                : nil,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            focusResetKey: detail.contentId,
            initialFocusScope: .page,
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $showActionRowFocused,
            stabilizesFocusMotion: true,
            primaryButtonWidth: 340,
            playbackSelectors: {
                // Keep all three triggers mounted while a newly focused
                // episode's playback detail loads. They disable themselves
                // until a valid version arrives, preserving every x-position.
                TVPlaybackActionSelectors(
                    versions: nextUpVersions,
                    currentVersion: effectiveNextUpVersion,
                    selectedVersionFileId: selectedNextUpFileId,
                    selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                    subtitleMode: nextUpSubtitleOverrideCleared
                        ? nil
                        : matchingPlaybackDetail?.effectiveSubtitleMode,
                    subtitleSignature: nextUpSubtitleOverrideCleared
                        ? nil
                        : matchingPlaybackDetail?.effectiveSubtitleTrackSignature,
                    showForcedSubtitles: matchingPlaybackDetail?.effectiveShowForcedSubtitles
                        ?? false,
                    onSelectVersion: onSelectNextUpVersion,
                    onSelectAudioTrack: onSelectNextUpAudioTrack,
                    onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
                )
            },
            moreMenu: { moreMenu }
        )
    }

    private func showPlayTitle(for episode: EpisodeListItem) -> String {
        let verb = episode.userData?.isInProgress == true ? "Resume" : "Play"
        return "\(verb) S\(episode.seasonNumber):E\(episode.episodeNumber)"
    }

    // MARK: - Show / Season modes and episode carousel

    private var episodeExperience: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeRow
            episodeBody
            if carouselLoadFailed {
                Text("Couldn't load more episodes. Press again to retry.")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            if let trailerFetchStatus {
                TVTrailerStatusPill(
                    message: trailerFetchStatus,
                    isFetching: isFetchingTrailers,
                    onAutoDismiss: onTrailerStatusShown
                )
            }
        }
    }

    private var modeRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(SeriesEpisodeWindow.orderedSeasons(seasons)) { season in
                        TVSeriesModeTab(
                            title: seasonLabel(season),
                            isSelected: selectedModeId == season.id,
                            rendersFocusedAppearance: presentedFocusedModeId == season.id,
                            action: { activateSeason(season) }
                        )
                        .id(season.id)
                        .focused($focusedModeId, equals: season.id)
                        .onMoveCommand { direction in
                            guard direction == .down else { return }
                            if !isLoadingEpisodes, let episode = displayedEpisode {
                                episodeRailFocusTarget = episode.contentId
                                episodeRailFocusRequest &+= 1
                            } else {
                                focusSupportingRail()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .focusScope(modeFocusNamespace)
            .focusSection()
            .defaultFocus(
                $focusedModeId,
                selectedModeId,
                priority: .userInitiated
            )
            .onAppear {
                guard selectedSeason != nil else { return }
                proxy.scrollTo(selectedModeId, anchor: .center)
                hasPositionedModeRow = true
            }
            .onChange(of: selectedModeId) { _, newId in
                // A click activates immediately, before the focus-paint dwell
                // finishes. Promote that one focused tab without allowing an
                // independently cached highlight to survive on the old tab.
                if focusedModeId == newId {
                    modeFocusAppearanceTask?.cancel()
                    modeFocusAppearanceTask = nil
                    presentedFocusedModeId = newId
                }
                guard selectedSeason != nil else { return }
                if hasPositionedModeRow {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(newId, anchor: .center)
                    hasPositionedModeRow = true
                }
            }
            .onChange(of: focusedModeId) { _, focusedId in
                updateModeFocusAppearance(for: focusedId)
                guard let focusedId else {
                    modeActivationTask?.cancel()
                    modeActivationTask = nil
                    if primaryFocusRegion == .mode {
                        primaryFocusRegion = .outside
                        pageScrollCoordinator.releasePrimary()
                    }
                    return
                }
                let previousRegion = primaryFocusRegion
                primaryFocusRegion = .mode
                if previousRegion == .outside || previousRegion == .supporting {
                    pageScrollCoordinator.enterPrimary(
                        animated: true,
                        reduceMotion: reduceMotion
                    )
                } else if previousRegion != .mode {
                    pageScrollCoordinator.enterPrimary(
                        animated: false,
                        reduceMotion: reduceMotion
                    )
                }
                scheduleModeActivation(for: focusedId)
            }
        }
    }

    /// Own the row's focus paint in one place so rapid lateral input can show
    /// at most one white pill. The short dwell still filters the sub-frame
    /// focus offer produced by a downward gesture into the episode rail.
    private func updateModeFocusAppearance(for modeId: String?) {
        modeFocusAppearanceTask?.cancel()
        modeFocusAppearanceTask = nil
        presentedFocusedModeId = nil

        guard let modeId else { return }
        if modeId == selectedModeId {
            presentedFocusedModeId = modeId
            return
        }

        modeFocusAppearanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled, focusedModeId == modeId else { return }
            presentedFocusedModeId = modeId
            modeFocusAppearanceTask = nil
        }
    }

    /// The season pill stays selected while the hero shows series info, since
    /// the rail below still lists that season's episodes.
    private var selectedModeId: String {
        selectedSeason?.id ?? noSeasonModeId
    }

    private func showSeriesOverview() {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        seasonSelection.cancel()
        isShowingSeriesOverview = true
        onActivateEpisode(nil)
    }

    private func activateSeason(_ season: Season) {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        isShowingSeriesOverview = false
        onActivateEpisode(nil)
        seasonSelection.select(season, load: onSelectSeason) { contentId in
            episodeScrollTarget = contentId
            onActivateEpisode(contentId)
            episodeScrollRequest &+= 1
        }
    }

    /// Season pills behave like tvOS tabs: resting focus activates one without
    /// requiring a second Select press. A short dwell prevents a fast sweep to
    /// Season 4 from loading Seasons 1–3 along the way; clicking remains instant.
    private func scheduleModeActivation(for modeId: String) {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        guard modeId != (seasonSelection.latestSeasonId ?? selectedModeId) else { return }

        modeActivationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled,
                  focusedModeId == modeId else { return }

            if let season = seasons.first(where: { $0.id == modeId }) {
                activateSeason(season)
            }
        }
    }

    /// One lazy native focus row spans the loaded season window. Season
    /// chips scroll this row rather than mounting a second horizontal pager.
    @ViewBuilder
    private var episodeBody: some View {
        let carouselEpisodes = episodeWindow.episodes
        if isLoadingEpisodes && carouselEpisodes.isEmpty {
            TVEpisodeRailPlaceholder(
                cardWidth: SiloTheme.thumbnailCardWidth
                    * uiCustomization.cardPresentation.posterSize.scale,
                cardHeightRatio: SiloTheme.thumbnailCardHeight / SiloTheme.thumbnailCardWidth,
                cardSpacing: 40,
                hidesEpisodeTitle: true
            )
            .frame(height: episodeRailReservedHeight)
        } else if carouselEpisodes.isEmpty {
            Text("No episodes available")
                .font(.system(size: 22))
                .foregroundStyle(Color.siloSecondaryText)
                .frame(maxWidth: .infinity, minHeight: episodeRailReservedHeight, alignment: .topLeading)
        } else {
            TVEpisodeRail(
                episodes: carouselEpisodes,
                onSelect: quickPlayEpisode,
                onPlay: quickPlayEpisode,
                onFocusedEpisodeChange: focusEpisode,
                onSetWatched: onSetEpisodeWatched,
                onSetFavorite: onSetEpisodeFavorite,
                currentContentId: displayedEpisode?.contentId,
                currentContentIsFavorite: displayedEpisode.map {
                    episodeFavoriteStates[$0.contentId] ?? false
                } ?? false,
                favoriteStates: episodeFavoriteStates,
                baseCardWidth: SiloTheme.thumbnailCardWidth,
                cardHeightRatio: SiloTheme.thumbnailCardHeight / SiloTheme.thumbnailCardWidth,
                cardSpacing: 40,
                anchorsFocusedCard: true,
                onMoveUp: focusSelectedMode,
                onMoveDown: focusSupportingRail,
                focusRequest: episodeRailFocusRequest,
                focusTargetContentId: episodeRailFocusTarget,
                scrollRequest: episodeScrollRequest,
                scrollTargetContentId: episodeScrollTarget,
                isSelectingSeason: primaryFocusRegion == .mode,
                onRequestPrevious: episodeWindow.previousSeason == nil ? nil : { onLoadMoreEpisodes(-1) },
                onRequestNext: episodeWindow.nextSeason == nil ? nil : { onLoadMoreEpisodes(1) }
            )
            .padding(.trailing, -TVDetailLayout.horizontalInset)
        }
    }

    private var episodeRailReservedHeight: CGFloat {
        let width = SiloTheme.thumbnailCardWidth
            * uiCustomization.cardPresentation.posterSize.scale
        let stillHeight = width
            * (SiloTheme.thumbnailCardHeight / SiloTheme.thumbnailCardWidth)
        return stillHeight
            + (uiCustomization.cardPresentation.caption.showsTitle ? 46 : 0)
            + 24
    }

    private func focusSelectedMode() {
        focusedModeId = selectedModeId
    }

    private func focusSupportingRail() {
        guard primaryFocusRegion != .supporting else { return }
        // The focus engine snapshots scroll eligibility before delivering the
        // episode rail's move command. Unlock now, then request Cast on the
        // next main-loop turn so its first focus update receives native reveal.
        pageScrollCoordinator.releasePrimary()
        primaryFocusRegion = .outside
        supportingRailFocusGeneration &+= 1
        let generation = supportingRailFocusGeneration
        DispatchQueue.main.async {
            guard supportingRailFocusGeneration == generation,
                  primaryFocusRegion == .outside else { return }
            supportingRailFocusRequest &+= 1
        }
    }

    private func focusEpisode(_ contentId: String?) {
        // Lazy row updates can briefly clear focus during fast lateral input.
        // Keep the viewport pinned until a real destination claims focus.
        guard let contentId else { return }
        seasonSelection.cancel()

        // Cancel a queued Episodes -> Cast handoff if focus has already moved
        // back into the fixed top viewport before the next focus update.
        supportingRailFocusGeneration &+= 1
        let previousRegion = primaryFocusRegion
        primaryFocusRegion = .episodes
        switch previousRegion {
        case .mode:
            pageScrollCoordinator.enterPrimary(
                animated: false,
                reduceMotion: reduceMotion
            )
        case .outside, .supporting:
            pageScrollCoordinator.enterPrimary(
                animated: true,
                reduceMotion: reduceMotion
            )
        case .episodes:
            break
        }

        isShowingSeriesOverview = false
        guard activeEpisodeContentId != contentId else { return }
        onActivateEpisode(contentId)
    }

    private func quickPlayEpisode(_ contentId: String) {
        seasonSelection.cancel()
        isShowingSeriesOverview = false
        onActivateEpisode(contentId)
        let episode = episodeWindow.episodes.first(where: { $0.contentId == contentId })
        onPlayEpisode(
            contentId,
            episode.flatMap { selectedFileId(for: $0) },
            false
        )
    }

    private enum MoreAction: String {
        case overview, favorite, watched, trailers
    }

    private var moreMenu: some View {
        TVCircleMenuButton(
            title: "More",
            accessibilityLabel: "More options",
            stabilizesFocusMotion: true,
            items: {
                var items: [TVActionPopoverItem] = []
                if !isShowingSeriesOverview {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.overview.rawValue,
                        title: "Show Series Info",
                        systemImage: "info.circle"
                    ))
                }
                items.append(TVActionPopoverItem(
                    id: MoreAction.favorite.rawValue,
                    title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                ))
                if selectedSeason != nil {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.watched.rawValue,
                        title: isWatched ? "Mark Season Unwatched" : "Mark Season Watched",
                        systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                    ))
                }
                if supportsTrailerFetch {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.trailers.rawValue,
                        title: "Find Trailers",
                        systemImage: "film.stack"
                    ))
                }
                return items
            },
            onSelect: { item in
                switch MoreAction(rawValue: item.id) {
                case .overview: showSeriesOverview()
                case .favorite: onToggleFavorite()
                case .watched: onToggleWatched()
                case .trailers: onFindTrailers()
                case .none: break
                }
            }
        )
    }

    // MARK: - Episode state and version selection

    private var suggestedEpisode: EpisodeListItem? {
        if let inProgress = episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return episodes.first
    }

    private var displayedEpisode: EpisodeListItem? {
        if let activeEpisodeContentId,
           let active = episodeWindow.episodes.first(where: { $0.contentId == activeEpisodeContentId }) {
            return active
        }
        return suggestedEpisode
    }

    private var playbackEpisode: EpisodeListItem? {
        isShowingSeriesOverview ? suggestedEpisode : displayedEpisode
    }

    private var matchingPlaybackDetail: ItemDetail? {
        guard let playbackEpisode,
              nextUpPlaybackDetail?.contentId == playbackEpisode.contentId else {
            return nil
        }
        return nextUpPlaybackDetail
    }

    private var nextUpVersions: [FileVersion] {
        matchingPlaybackDetail?.versions ?? []
    }

    private var effectiveNextUpVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: nextUpVersions,
            selectedFileId: selectedNextUpFileId,
            lastFileId: matchingPlaybackDetail?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private func selectedFileId(for episode: EpisodeListItem) -> Int? {
        // Never carry a file choice from the previously focused episode into
        // a quick Play that arrives before the new playback detail is ready.
        guard matchingPlaybackDetail?.contentId == episode.contentId,
              let selectedNextUpFileId else { return nil }
        return nextUpVersions.contains(where: { $0.fileId == selectedNextUpFileId })
            ? selectedNextUpFileId
            : nil
    }

    private func seasonLabel(_ season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return "Specials" }
        return "Season \(season.seasonNumber)"
    }

    private func runtimeLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: - Supporting rails

    private func supportingRailDidFocus(centerFirstSection: Bool) {
        primaryFocusRegion = .supporting
        if centerFirstSection {
            pageScrollCoordinator.revealSupporting(reduceMotion: reduceMotion)
        } else {
            pageScrollCoordinator.releasePrimary()
        }
    }

    private var similarSection: some View {
        TVSimilarRail(
            contentId: detail.contentId,
            title: "Recommended Series",
            onSelect: onNavigateToItem,
            focusRequest: !hasCast && trailerEntries.isEmpty ? supportingRailFocusRequest : 0,
            onFocusChange: { focused in
                guard focused else { return }
                supportingRailDidFocus(centerFirstSection: !hasCast && trailerEntries.isEmpty)
            }
        )
        .background {
            if !hasCast && trailerEntries.isEmpty {
                TVSeriesAnchorResolver { pageScrollCoordinator.supportingAnchorView = $0 }
            }
        }
    }

    private var trailersSection: some View {
        TVTrailersRail(
            entries: trailerEntries,
            onSelect: onSelectTrailer,
            focusScale: 1.0,
            focusRequest: hasCast ? 0 : supportingRailFocusRequest,
            onFocusChange: { focused in
                guard focused else { return }
                supportingRailDidFocus(centerFirstSection: !hasCast)
            }
        )
        .background {
            if !hasCast && !trailerEntries.isEmpty {
                TVSeriesAnchorResolver { pageScrollCoordinator.supportingAnchorView = $0 }
            }
        }
    }

    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(
                cast: cast,
                onTap: onPersonTap,
                focusRequest: supportingRailFocusRequest,
                onFocusChange: { focused in
                    guard focused else { return }
                    supportingRailDidFocus(centerFirstSection: true)
                }
            )
        }
        .padding(.top, 20)
        .background {
            TVSeriesAnchorResolver { pageScrollCoordinator.supportingAnchorView = $0 }
        }
    }

    private var hasCast: Bool {
        !(detail.cast?.isEmpty ?? true)
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }
}

/// Invisible marker laid out behind a page section. Its UIView frame is what
/// the page coordinator converts into scroll content space to center that
/// section without going through the SwiftUI scroll proxy.
private struct TVSeriesAnchorResolver: UIViewRepresentable {
    let onResolve: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        onResolve(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        onResolve(uiView)
    }
}

/// Stable Show/Season tab used only by the combined Series page. It changes
/// fill and outline on focus without scaling, so neighboring tabs never move.
private struct TVSeriesModeTab: View {
    let title: String
    let isSelected: Bool
    let rendersFocusedAppearance: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 24)
                .frame(height: 52)
        }
        .buttonStyle(
            TVSeriesModeTabStyle(
                isSelected: isSelected,
                rendersFocusedAppearance: rendersFocusedAppearance
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TVSeriesModeTabStyle: ButtonStyle {
    let isSelected: Bool
    let rendersFocusedAppearance: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeriesModeTabBody(
            configuration: configuration,
            isSelected: isSelected,
            rendersFocusedAppearance: rendersFocusedAppearance
        )
    }
}

private struct TVSeriesModeTabBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let rendersFocusedAppearance: Bool

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
            .shadow(
                color: Color.black.opacity(rendersFocusedAppearance ? 0.28 : 0),
                radius: rendersFocusedAppearance ? 10 : 0,
                y: rendersFocusedAppearance ? 4 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .focusEffectDisabled()
            .animation(
                .easeOut(duration: SiloTheme.fastDuration),
                value: rendersFocusedAppearance
            )
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isSelected)
    }
}
#endif
