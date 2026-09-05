#if os(tvOS)
import SwiftUI
import UIKit
import Nuke

/// Single-page Series experience for tvOS. `Show` and every season are
/// in-place modes: the series backdrop never changes, episode focus updates
/// the editorial details and selectors, and selecting an episode quick-plays
/// it without pushing a second detail page.
struct TVSeriesDetailView<BelowSynopsis: View>: View {
    private enum PrimaryFocusRegion {
        case outside
        case actions
        case mode
        case episodes
    }

    /// Stable data for one page in the full linear season rail. Page geometry
    /// is owned by the season list; only loaded season content is retained.
    private struct SeasonPageSnapshot {
        let seasonId: String
        let episodes: [EpisodeListItem]
        let currentContentId: String?
        let isLoading: Bool
    }

    /// Mutable observation storage that deliberately does not invalidate the
    /// large detail view every display frame. It records the native scroll
    /// view's presentation offset so a rapid reversal can stop the old motion
    /// exactly where it is before issuing the newest destination.
    private final class SeasonScrollTracker {
        var liveOffset: CGFloat = 0
    }

    /// One low-priority worker warms only the first visible cards of three
    /// nearby seasons. It owns its requests independently of Home prefetching.
    private final class SeasonArtworkWarmer {
        private let prefetcher: ImagePrefetcher = {
            let value = ImagePrefetcher(
                pipeline: ImagePipeline.shared,
                destination: .memoryCache,
                maxConcurrentRequestCount: 1
            )
            value.priority = .low
            return value
        }()
        private var urls: Set<URL> = []
        private var pixelSize: CGSize = .zero

        func update(urls requestedURLs: [URL], pixelSize requestedSize: CGSize) {
            if pixelSize != requestedSize {
                cancel()
                pixelSize = requestedSize
            }
            let next = Set(requestedURLs)
            let removed = urls.subtracting(next)
            prefetcher.stopPrefetching(with: removed.map {
                PosterImageCache.displayRequest(url: $0, pixelSize: pixelSize, priority: .low)
            })
            // Preserve destination-first ordering while deduplicating URLs.
            var added = Set<URL>()
            let requests = requestedURLs.filter {
                !urls.contains($0) && added.insert($0).inserted
            }.map {
                PosterImageCache.displayRequest(url: $0, pixelSize: pixelSize, priority: .low)
            }
            prefetcher.startPrefetching(with: requests)
            urls = next
        }

        func cancel() {
            prefetcher.stopPrefetching()
            urls.removeAll()
        }
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
        /// Marker view laid out behind the Cast section; its frame converted
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
            // Row-to-row focus changes share the same destination. Keep an
            // existing return trip running instead of restarting it on Up.
            guard !primaryOwnsViewport else { return }
            primaryOwnsViewport = true
            stopPageAnimation()
            guard let scrollView else { return }
            // Programmatic offsets still animate while native reveal is held.
            scrollView.isScrollEnabled = false
            let target = topOffset(in: scrollView)
            guard animated,
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

        /// Centers the Cast section after focus leaves the fixed top viewport.
        /// Runs in the same animator slot as the return trip so that an Up
        /// press mid-descent stops this motion where it is and the return
        /// starts from that exact offset.
        func revealSupporting(reduceMotion: Bool) {
            primaryOwnsViewport = false
            stopPageAnimation()
            guard let scrollView else { return }
            scrollView.isScrollEnabled = true
            guard let supportingAnchorView else { return }
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
                let visibleOffset = scrollView?.layer.presentation()?.bounds.origin
                pageAnimator.stopAnimation(false)
                pageAnimator.finishAnimation(at: .current)
                if let visibleOffset, let scrollView {
                    UIView.performWithoutAnimation {
                        scrollView.setContentOffset(visibleOffset, animated: false)
                    }
                }
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
    let episodesBySeason: [Int: [EpisodeListItem]]
    let activeEpisodeContentId: String?
    let episodeFavoriteStates: [String: Bool]
    let isLoadingEpisodes: Bool
    let selectedNextUpFileId: Int?
    let selectedNextUpAudioTrackIndex: Int?
    let selectedNextUpSubtitleTrackIndex: Int?
    let nextUpPlaybackDetail: ItemDetail?
    let isLoadingNextUpPlaybackDetail: Bool
    let didLoadNextUpPlaybackDetail: Bool
    var nextUpSubtitleOverrideCleared = false
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    let supportsTrailerFetch: Bool
    let onFindTrailers: () -> Void
    let trailerFetchStatus: String?
    let isFetchingTrailers: Bool
    let onTrailerStatusShown: () -> Void
    let onSelectSeason: (Season) -> Void
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
    @State private var focusedEpisodeContentId: String?
    @State private var primaryFocusRegion: PrimaryFocusRegion = .outside
    @State private var episodeRailFocusRequest = 0
    @State private var supportingRailFocusRequest = 0
    @State private var supportingRailFocusGeneration = 0
    @State private var supportingHandoffPending = false
    @State private var modeActivationTask: Task<Void, Never>?
    @State private var modeFocusAppearanceTask: Task<Void, Never>?
    @State private var presentedFocusedModeId: String?
    @State private var queuedSeasonId: String?
    @State private var queuedSeasonTask: Task<Void, Never>?
    @State private var lastSeasonActivationTime: TimeInterval?
    @State private var lastSeasonFocusTime: TimeInterval?
    @State private var seasonTransitionDuration = 0.46
    @State private var seasonArtworkWarmer = SeasonArtworkWarmer()
    @Environment(\.displayScale) private var displayScale
    @State private var seasonTransitionInFlight = false
    @State private var seasonTransitionTargetId: String?
    @State private var seasonTransitionGeneration = 0
    @State private var seasonTransitionTask: Task<Void, Never>?
    @State private var visibleSeasonId: String?
    @State private var seasonPageSnapshots: [String: SeasonPageSnapshot] = [:]
    @State private var seasonPageScrollPosition = ScrollPosition(x: 0)
    @State private var seasonPageViewportWidth: CGFloat = 0
    @State private var seasonScrollTracker = SeasonScrollTracker()
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
                        TVSeriesPageScrollResolver { scrollView in
                            pageScrollCoordinator.attach(scrollView)
                        }
                    }
                }
                .ignoresSafeArea()
                .focusScope(detailFocusNamespace)
                .defaultFocus($playFocused, true, priority: .userInitiated)
                .onChange(of: showActionRowFocused) { _, focused in
                    guard focused else { return }
                    cancelSupportingHandoff()
                    primaryFocusRegion = .actions
                    pageScrollCoordinator.enterPrimary(animated: true, reduceMotion: reduceMotion)
                }
                .tvActionPopoverHost()
            }
        }
        .onAppear {
            if activeEpisodeContentId != nil {
                isShowingSeriesOverview = false
            }
            synchronizeCurrentSeasonPage()
        }
        .onChange(of: activeEpisodeContentId) { _, contentId in
            if contentId != nil {
                isShowingSeriesOverview = false
            }
        }
        .onChange(of: seasonPageReadinessKey) { _, _ in
            if seasonTransitionInFlight {
                startSeasonScrollIfReady()
            } else {
                synchronizeCurrentSeasonPage()
            }
        }
        .onChange(of: seasonArtworkWarmKey, initial: true) { _, _ in
            seasonArtworkWarmer.update(
                urls: seasonArtworkWarmURLs,
                pixelSize: seasonArtworkPixelSize
            )
        }
        .onDisappear {
            queuedSeasonTask?.cancel()
            queuedSeasonTask = nil
            queuedSeasonId = nil
            lastSeasonActivationTime = nil
            lastSeasonFocusTime = nil
            seasonArtworkWarmer.cancel()
            modeActivationTask?.cancel()
            modeActivationTask = nil
            modeFocusAppearanceTask?.cancel()
            modeFocusAppearanceTask = nil
            presentedFocusedModeId = nil
            seasonTransitionTask?.cancel()
            seasonTransitionTask = nil
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                seasonPageSnapshots.removeAll(keepingCapacity: false)
                visibleSeasonId = nil
                seasonPageScrollPosition = ScrollPosition(x: 0)
                seasonScrollTracker.liveOffset = 0
            }
            cancelSupportingHandoff()
            pageScrollCoordinator.detach()
            seasonTransitionInFlight = false
            seasonTransitionTargetId = nil
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
            smoothlyChangingEpisodeBody
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
                    ForEach(seasons) { season in
                        TVSeriesModeTab(
                            title: seasonLabel(season),
                            isSelected: selectedModeId == season.id,
                            rendersFocusedAppearance: presentedFocusedModeId == season.id,
                            action: { activateSeason(season) }
                        )
                        .id(season.id)
                        .focused($focusedModeId, equals: season.id)
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
            .onChange(of: selectedModeId) { _, newId in
                // A click activates immediately, before the focus-paint dwell
                // finishes. Promote that one focused tab without allowing an
                // independently cached highlight to survive on the old tab.
                if focusedModeId == newId {
                    modeFocusAppearanceTask?.cancel()
                    modeFocusAppearanceTask = nil
                    presentedFocusedModeId = newId
                }
                // Native focus already scrolls the tab row during remote
                // navigation. Recentring on every activation competes with
                // that motion, particularly across a long season list.
                guard focusedModeId == nil else { return }
                withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onChange(of: focusedModeId) { _, focusedId in
                updateModeFocusAppearance(for: focusedId)
                guard let focusedId else {
                    modeActivationTask?.cancel()
                    modeActivationTask = nil
                    return
                }
                cancelSupportingHandoff()
                let previousRegion = primaryFocusRegion
                primaryFocusRegion = .mode
                if previousRegion == .outside {
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
        queuedSeasonId
            ?? seasonTransitionTargetId
            ?? visibleSeasonId
            ?? selectedSeason?.id
            ?? noSeasonModeId
    }

    private func showSeriesOverview() {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        isShowingSeriesOverview = true
        onActivateEpisode(nil)
    }

    private func activateSeason(_ season: Season, followsRapidFocus: Bool = false) {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        guard season.id != selectedModeId else { return }
        isShowingSeriesOverview = false
        let now = ProcessInfo.processInfo.systemUptime
        let isBurst = followsRapidFocus || queuedSeasonTask != nil
            || lastSeasonActivationTime.map { now - $0 < 0.18 } == true
        lastSeasonActivationTime = now
        queuedSeasonTask?.cancel()
        queuedSeasonTask = nil

        if isBurst {
            // Rolling quiet window: each new click replaces the pending
            // destination. The current slide can finish; obsolete seasons
            // never create their own animation or artwork warm-up.
            queuedSeasonId = season.id
            queuedSeasonTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, queuedSeasonId == season.id else { return }
                queuedSeasonTask = nil
                queuedSeasonId = nil
                performSeasonActivation(season, isBurst: true)
            }
        } else {
            queuedSeasonId = nil
            performSeasonActivation(season, isBurst: false)
        }
    }

    private func performSeasonActivation(_ season: Season, isBurst: Bool) {
        seasonTransitionDuration = isBurst ? 0.30 : 0.46
        if seasonTransitionInFlight {
            guard season.id != seasonTransitionTargetId else { return }
            retargetSeasonTransition(to: season)
            return
        }
        guard visibleSeasonId != season.id else {
            return
        }
        beginSeasonTransition(to: season)
    }

    private func beginSeasonTransition(to season: Season) {
        let currentPage = currentSeasonPageSnapshot
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            seasonPageSnapshots[currentPage.seasonId] = currentPage
            visibleSeasonId = currentPage.seasonId
        }

        seasonTransitionTask?.cancel()
        seasonTransitionTask = nil
        seasonTransitionGeneration &+= 1
        seasonTransitionInFlight = true
        seasonTransitionTargetId = season.id
        onActivateEpisode(nil)
        onSelectSeason(season)
        startMountedSeasonScrollIfAvailable(to: season.id)
    }

    private func retargetSeasonTransition(to season: Season) {
        // Stop the current native animation at its presentation offset before
        // giving it a new destination. Without this freeze, several opposing
        // setContentOffset animations can finish out of order under rapid taps.
        seasonTransitionTask?.cancel()
        seasonTransitionTask = nil
        freezeSeasonScrollAtLiveOffset()
        seasonTransitionGeneration &+= 1
        seasonTransitionTargetId = season.id
        onActivateEpisode(nil)
        onSelectSeason(season)
        startMountedSeasonScrollIfAvailable(to: season.id)
    }

    private func startSeasonScrollIfReady() {
        guard seasonTransitionInFlight,
              seasonTransitionTask == nil,
              let targetId = seasonTransitionTargetId,
              selectedSeason?.id == targetId,
              let targetSeason = seasons.first(where: { $0.id == targetId }),
              !isLoadingEpisodes,
              seasonPageViewportWidth > 0 else { return }

        // The selected season publishes before its episode request completes.
        // Do not move the old page toward a loading placeholder or stale rows;
        // the complete incoming rail must be mounted before native scrolling.
        guard episodes.isEmpty || episodes.allSatisfy({
            $0.seasonNumber == targetSeason.seasonNumber
        }) else { return }

        let incomingPage = currentSeasonPageSnapshot
        guard incomingPage.seasonId == targetId,
              let destinationOffset = seasonPageOffset(
                for: targetId,
                pageWidth: seasonPageViewportWidth
              ) else { return }

        var mountTransaction = Transaction(animation: nil)
        mountTransaction.disablesAnimations = true
        withTransaction(mountTransaction) {
            // Populate the target's permanent slot before the rail moves. The
            // old and new seasons now coexist as literal neighbours in one
            // HStack, rather than swapping through a temporary side page.
            seasonPageSnapshots[targetId] = incomingPage
        }
        startSeasonScroll(
            to: targetId,
            destinationOffset: destinationOffset,
            waitsForPageMount: true
        )
    }

    private func startMountedSeasonScrollIfAvailable(to targetId: String) {
        guard let targetSeason = seasons.first(where: { $0.id == targetId }),
              let mountedPage = availableSeasonPage(for: targetSeason),
              let destinationOffset = seasonPageOffset(
                for: targetId,
                pageWidth: seasonPageViewportWidth
              ) else { return }
        if seasonPageSnapshots[targetId] == nil {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                seasonPageSnapshots[targetId] = mountedPage
            }
        }
        startSeasonScroll(
            to: targetId,
            destinationOffset: destinationOffset,
            waitsForPageMount: false
        )
    }

    private func startSeasonScroll(
        to targetId: String,
        destinationOffset: CGFloat,
        waitsForPageMount: Bool
    ) {
        guard seasonTransitionInFlight,
              seasonTransitionTargetId == targetId,
              seasonTransitionTask == nil else { return }

        let generation = seasonTransitionGeneration
        let duration = seasonTransitionDuration
        seasonTransitionTask = Task { @MainActor in
            await Task.yield()
            if waitsForPageMount && !reduceMotion {
                try? await Task.sleep(for: .milliseconds(17))
            }
            guard !Task.isCancelled,
                  generation == seasonTransitionGeneration else { return }

            withAnimation(
                reduceMotion
                    ? nil
                    : .timingCurve(0.4, 0, 0.2, 1, duration: duration)
            ) {
                seasonPageScrollPosition = ScrollPosition(x: destinationOffset)
            }

            if !reduceMotion {
                try? await Task.sleep(for: .seconds(duration + 0.02))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  generation == seasonTransitionGeneration else { return }
            finishSeasonTransition()
        }
    }

    private func finishSeasonTransition() {
        guard let completedSeasonId = seasonTransitionTargetId else {
            seasonTransitionInFlight = false
            seasonTransitionTask = nil
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Stay on the real destination page. There is deliberately no
            // recenter, page deletion, or content replacement after scrolling.
            visibleSeasonId = completedSeasonId
            if let offset = seasonPageOffset(
                for: completedSeasonId,
                pageWidth: seasonPageViewportWidth
            ) {
                // Programmatic native scrolling can still be completing an
                // older animation when direction reverses. Pin the final
                // content offset to the latest requested season so the rail
                // and selected tab can never settle on different pages.
                seasonPageScrollPosition = ScrollPosition(x: offset)
                seasonScrollTracker.liveOffset = offset
            }
        }
        seasonTransitionInFlight = false
        seasonTransitionTargetId = nil
        seasonTransitionTask = nil
    }

    /// Season pills behave like tvOS tabs: resting focus activates one without
    /// requiring a second Select press. A short dwell prevents a fast sweep to
    /// Season 4 from loading Seasons 1–3 along the way; clicking remains instant.
    private func scheduleModeActivation(for modeId: String) {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        let followsRapidFocus = lastSeasonFocusTime.map { now - $0 < 0.18 } == true
        lastSeasonFocusTime = now
        guard modeId != selectedModeId else { return }
        if queuedSeasonId != nil, let season = seasons.first(where: { $0.id == modeId }) {
            // Extend an already-open gate on the actual focus event, before
            // the ordinary focus dwell can let an obsolete target escape.
            activateSeason(season, followsRapidFocus: true)
            return
        }

        modeActivationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled,
                  focusedModeId == modeId,
                  modeId != selectedModeId else { return }

            if let season = seasons.first(where: { $0.id == modeId }) {
                activateSeason(season, followsRapidFocus: followsRapidFocus)
            }
        }
    }

    private var seasonArtworkPixelSize: CGSize {
        let scale = uiCustomization.cardPresentation.posterSize.scale * displayScale
        return CGSize(
            width: SiloTheme.thumbnailCardWidth * scale,
            height: SiloTheme.thumbnailCardHeight * scale
        )
    }

    private var seasonArtworkWarmURLs: [URL] {
        guard !seasons.isEmpty,
              let center = seasons.firstIndex(where: {
                  $0.id == (seasonTransitionTargetId ?? visibleSeasonId ?? selectedSeason?.id)
              }) else { return [] }
        let lower = min(max(center - 1, 0), max(seasons.count - 3, 0))
        let upper = min(lower + 3, seasons.count)
        let indices = [center] + (lower..<upper).filter { $0 != center }
        return indices.flatMap { index -> [URL] in
            let season = seasons[index]
            let pageEpisodes = availableSeasonPage(for: season)?.episodes ?? []
            return pageEpisodes.prefix(4).compactMap { episode in
                episode.stillUrl.flatMap(URL.init(string:))
            }
        }
    }

    private var seasonArtworkWarmKey: String {
        "\(seasonArtworkPixelSize.width)x\(seasonArtworkPixelSize.height):"
            + seasonArtworkWarmURLs.map(\.absoluteString).joined(separator: "|")
    }

    private var seasonPageReadinessKey: String {
        let seasonId = selectedSeason?.id ?? noSeasonModeId
        let loadingState = isLoadingEpisodes ? "loading" : "ready"
        let episodeIds = episodes.map(\.contentId).joined(separator: "|")
        return "\(seasonId):\(loadingState):\(episodeIds)"
    }

    private var currentSeasonPageSnapshot: SeasonPageSnapshot {
        SeasonPageSnapshot(
            seasonId: selectedSeason?.id ?? noSeasonModeId,
            episodes: episodes,
            currentContentId: displayedEpisode?.contentId,
            isLoading: isLoadingEpisodes
        )
    }

    private func synchronizeCurrentSeasonPage() {
        guard !seasonTransitionInFlight else { return }
        let page = currentSeasonPageSnapshot
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            seasonPageSnapshots[page.seasonId] = page
            visibleSeasonId = page.seasonId
            if let offset = seasonPageOffset(
                for: page.seasonId,
                pageWidth: seasonPageViewportWidth
            ) {
                seasonPageScrollPosition = ScrollPosition(x: offset)
                seasonScrollTracker.liveOffset = offset
            }
        }
    }

    /// The fixed season tabs select between full-width episode pages. The
    /// inner episode carousel remains unchanged; this native outer ScrollView
    /// moves the complete old and new season rails together as one page.
    private var smoothlyChangingEpisodeBody: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let viewportWidth = width + TVDetailLayout.horizontalInset

            ScrollView(.horizontal, showsIndicators: false) {
                // Mount season pages as they approach the viewport instead
                // of building every cached season's complete episode strip.
                // Each mounted episode row keeps its eager, finite focus graph.
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(seasons) { season in
                        seasonRailPage(
                            for: season,
                            contentWidth: width,
                            pageWidth: viewportWidth
                        )
                        // Each eager episode strip may draw beyond its own
                        // scroll viewport. Keep that overflow inside this
                        // season's page while the outer pager slides it.
                        .clipped()
                        .id(season.id)
                        // Keep cached artwork visible during a slide, but
                        // admit new image work only for the settled season.
                        .environment(
                            \.tvArtworkLoadingEnabled,
                            !seasonTransitionInFlight && queuedSeasonId == nil
                                && season.id == (visibleSeasonId ?? selectedSeason?.id)
                        )
                        // Only the page currently inside the viewport may
                        // participate in tvOS focus. Cached rails elsewhere on
                        // the giant strip remain visual neighbours, not rival
                        // focus destinations.
                        .disabled(
                            season.id != (visibleSeasonId ?? selectedSeason?.id)
                        )
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition($seasonPageScrollPosition)
            .scrollTargetBehavior(.paging)
            .scrollDisabled(true)
            .frame(
                width: viewportWidth,
                height: episodeRailReservedHeight,
                alignment: .topLeading
            )
            .clipped()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, liveOffset in
                seasonScrollTracker.liveOffset = liveOffset
            }
            .onAppear {
                updateSeasonPageViewportWidth(viewportWidth)
            }
            .onChange(of: viewportWidth) { _, newWidth in
                updateSeasonPageViewportWidth(newWidth)
            }
        }
        .frame(height: episodeRailReservedHeight, alignment: .topLeading)
    }

    /// Every real season owns one permanent, page-width position in a single
    /// linear rail. Unloaded positions stay lightweight, while the current and
    /// target episode carousels remain attached to their actual season slots.
    @ViewBuilder
    private func seasonRailPage(
        for season: Season,
        contentWidth: CGFloat,
        pageWidth: CGFloat
    ) -> some View {
        if let page = availableSeasonPage(for: season) {
            seasonEpisodeBody(page)
                .frame(
                    width: contentWidth,
                    height: episodeRailReservedHeight,
                    alignment: .topLeading
                )
                .frame(
                    width: pageWidth,
                    height: episodeRailReservedHeight,
                    alignment: .topLeading
                )
        } else if !seasonTransitionInFlight, selectedSeason?.id == season.id {
            seasonEpisodeBody(currentSeasonPageSnapshot)
                .frame(
                    width: contentWidth,
                    height: episodeRailReservedHeight,
                    alignment: .topLeading
                )
                .frame(
                    width: pageWidth,
                    height: episodeRailReservedHeight,
                    alignment: .topLeading
                )
        } else {
            Color.clear
                .frame(
                    width: pageWidth,
                    height: episodeRailReservedHeight,
                    alignment: .topLeading
                )
        }
    }

    private func availableSeasonPage(for season: Season) -> SeasonPageSnapshot? {
        if let snapshot = seasonPageSnapshots[season.id] {
            return snapshot
        }
        guard let cachedEpisodes = episodesBySeason[season.seasonNumber] else {
            return nil
        }
        let suggestedContentId = cachedEpisodes.first(where: {
            $0.userData?.isInProgress == true
        })?.contentId ?? cachedEpisodes.first(where: {
            !($0.userData?.played ?? false)
        })?.contentId ?? cachedEpisodes.first?.contentId
        return SeasonPageSnapshot(
            seasonId: season.id,
            episodes: cachedEpisodes,
            currentContentId: suggestedContentId,
            isLoading: false
        )
    }

    private func updateSeasonPageViewportWidth(_ width: CGFloat) {
        guard width > 0, width != seasonPageViewportWidth else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            seasonPageViewportWidth = width
            let seasonId = visibleSeasonId ?? selectedSeason?.id
            let offset = seasonId.flatMap {
                seasonPageOffset(for: $0, pageWidth: width)
            } ?? 0
            seasonPageScrollPosition = ScrollPosition(x: offset)
            seasonScrollTracker.liveOffset = offset
        }
        startSeasonScrollIfReady()
    }

    private func freezeSeasonScrollAtLiveOffset() {
        guard seasonPageViewportWidth > 0 else { return }
        let lastOffset = CGFloat(max(seasons.count - 1, 0))
            * seasonPageViewportWidth
        let liveOffset = min(
            max(seasonScrollTracker.liveOffset, 0),
            lastOffset
        )
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            seasonPageScrollPosition = ScrollPosition(x: liveOffset)
        }
    }

    private func seasonPageOffset(
        for seasonId: String,
        pageWidth: CGFloat
    ) -> CGFloat? {
        guard pageWidth > 0,
              let index = seasons.firstIndex(where: { $0.id == seasonId }) else {
            return nil
        }
        return CGFloat(index) * pageWidth
    }

    @ViewBuilder
    private func seasonEpisodeBody(_ snapshot: SeasonPageSnapshot) -> some View {
        if snapshot.isLoading {
            TVEpisodeRailPlaceholder(
                cardWidth: SiloTheme.thumbnailCardWidth
                    * uiCustomization.cardPresentation.posterSize.scale,
                cardHeightRatio: SiloTheme.thumbnailCardHeight
                    / SiloTheme.thumbnailCardWidth,
                cardSpacing: 40,
                hidesEpisodeTitle: true
            )
        } else if snapshot.episodes.isEmpty {
            Text("No episodes available")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.siloSecondaryText)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            TVEpisodeRail(
                episodes: snapshot.episodes,
                onSelect: quickPlayEpisode,
                onPlay: quickPlayEpisode,
                onFocusedEpisodeChange: focusEpisode,
                onSetWatched: onSetEpisodeWatched,
                onSetFavorite: onSetEpisodeFavorite,
                currentContentId: snapshot.currentContentId,
                currentContentIsFavorite: snapshot.currentContentId.map {
                    episodeFavoriteStates[$0] ?? false
                } ?? false,
                favoriteStates: episodeFavoriteStates,
                seriesId: detail.contentId,
                seriesTitle: detail.title,
                baseCardWidth: SiloTheme.thumbnailCardWidth,
                cardHeightRatio: SiloTheme.thumbnailCardHeight
                    / SiloTheme.thumbnailCardWidth,
                cardSpacing: 40,
                anchorsFocusedCard: true,
                onMoveUp: focusSelectedMode,
                onMoveDown: focusPlaybackSelector,
                focusRequest: episodeRailFocusRequest
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
        cancelSupportingHandoff()
        focusedModeId = selectedModeId
    }

    private func focusPlaybackSelector() {
        focusSupportingRail()
    }

    private func focusSupportingRail() {
        // The focus engine snapshots scroll eligibility before delivering the
        // episode rail's move command. Unlock now, then request Cast on the
        // next main-loop turn so its first focus update receives native reveal.
        guard !supportingHandoffPending else { return }
        supportingHandoffPending = hasCast
        pageScrollCoordinator.releasePrimary()
        primaryFocusRegion = .outside
        // Reveal before asking the child to claim focus, so the focus engine
        // sees the incoming row in the page's destination geometry.
        if hasCast {
            pageScrollCoordinator.revealSupporting(reduceMotion: reduceMotion)
        }
        supportingRailFocusGeneration &+= 1
        let generation = supportingRailFocusGeneration
        DispatchQueue.main.async {
            guard supportingRailFocusGeneration == generation,
                  primaryFocusRegion == .outside else { return }
            supportingRailFocusRequest &+= 1
        }
    }

    private func cancelSupportingHandoff() {
        supportingHandoffPending = false
        supportingRailFocusGeneration &+= 1
    }

    private func focusEpisode(_ contentId: String?) {
        let previousContentId = focusedEpisodeContentId
        focusedEpisodeContentId = contentId
        guard let contentId else { return }
        // A repeated report from the departing card is not a reversal.
        guard !supportingHandoffPending || contentId != previousContentId else { return }
        cancelSupportingHandoff()

        let previousRegion = primaryFocusRegion
        primaryFocusRegion = .episodes
        switch previousRegion {
        case .mode, .actions:
            pageScrollCoordinator.enterPrimary(
                animated: false,
                reduceMotion: reduceMotion
            )
        case .outside:
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
        isShowingSeriesOverview = false
        onActivateEpisode(contentId)
        let episode = episodes.first(where: { $0.contentId == contentId })
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
           let active = episodes.first(where: { $0.contentId == activeEpisodeContentId }) {
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

    private var similarSection: some View {
        TVSimilarRail(
            contentId: detail.contentId,
            title: "Recommended Series",
            onSelect: onNavigateToItem,
            focusRequest: !hasCast && trailerEntries.isEmpty
                ? supportingRailFocusRequest
                : 0
        )
    }

    private var trailersSection: some View {
        TVTrailersRail(
            entries: trailerEntries,
            onSelect: onSelectTrailer,
            focusScale: 1.0,
            focusRequest: hasCast ? 0 : supportingRailFocusRequest
        )
    }

    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(
                cast: cast,
                onTap: onPersonTap,
                focusRequest: supportingRailFocusRequest,
                focusRequestIsActive: supportingHandoffPending,
                onFocusRequestFailed: cancelSupportingHandoff,
                onFocus: {
                    cancelSupportingHandoff()
                    primaryFocusRegion = .outside
                    if pageScrollCoordinator.primaryOwnsViewport {
                        pageScrollCoordinator.releasePrimary()
                    }
                }
            )
        }
        .padding(.top, 20)
        .background {
            TVSeriesAnchorResolver { anchorView in
                pageScrollCoordinator.supportingAnchorView = anchorView
            }
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

/// Resolves the UIKit scroll view that directly owns the Series page. The
/// marker sits behind the root vertical content, so its nearest scroll-view
/// ancestor is never one of the nested horizontal rails.
private struct TVSeriesPageScrollResolver: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ResolverView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfNeeded()
    }

    final class ResolverView: UIView {
        var onResolve: ((UIScrollView) -> Void)?
        private weak var resolvedScrollView: UIScrollView?
        private var resolutionScheduled = false

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolveIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfNeeded()
        }

        func resolveIfNeeded() {
            if let resolvedScrollView {
                onResolve?(resolvedScrollView)
                return
            }
            guard !resolutionScheduled else { return }
            resolutionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resolutionScheduled = false
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? UIScrollView {
                        self.resolvedScrollView = scrollView
                        self.onResolve?(scrollView)
                        return
                    }
                    ancestor = view.superview
                }
            }
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
