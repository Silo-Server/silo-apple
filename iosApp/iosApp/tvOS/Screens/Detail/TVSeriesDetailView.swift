#if os(tvOS)
import SwiftUI

/// Single-page Series experience for tvOS. `Show` and every season are
/// in-place modes: the series backdrop never changes, episode focus updates
/// the editorial details and selectors, and selecting an episode quick-plays
/// it without pushing a second detail page.
struct TVSeriesDetailView<BelowSynopsis: View>: View {
    private enum PrimaryFocusRegion {
        case outside
        case mode
        case episodes
    }

    /// A frozen copy of the visible season rail. Keeping the outgoing page
    /// separate from the live incoming rail lets one signed progress value move
    /// both pages, so reversing direction can never reuse a stale transition.
    private struct SeasonPageSnapshot {
        let seasonId: String
        let episodes: [EpisodeListItem]
        let currentContentId: String?
        let isLoading: Bool
    }

    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
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
    @FocusState private var similarRailFocused: Bool
    @FocusState private var focusedModeId: String?
    @State private var isShowingSeriesOverview = true
    @State private var focusedEpisodeContentId: String?
    @State private var primaryViewportActive = false
    @State private var primaryFocusRegion: PrimaryFocusRegion = .outside
    @State private var browseHoldRequest = 0
    @State private var browseRestoreRequest = 0
    @State private var episodeRailFocusRequest = 0
    @State private var supportingRailFocusRequest = 0
    @State private var modeActivationTask: Task<Void, Never>?
    @State private var seasonTransitionMovesForward = true
    @State private var seasonTransitionInFlight = false
    @State private var seasonTransitionTargetId: String?
    @State private var pendingSeasonActivationId: String?
    @State private var seasonTransitionGeneration = 0
    @State private var seasonTransitionTask: Task<Void, Never>?
    @State private var outgoingSeasonPage: SeasonPageSnapshot?
    @State private var seasonPanProgress: CGFloat = 1
    @State private var uiCustomization = UICustomizationPreferences.shared
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let showModeId = "series-show-overview"
    private let episodeSectionScrollId = "series-episode-section"
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
                            }
                            trailersSection
                            similarSection
                                .focused($similarRailFocused)
                                .id(similarSectionScrollId)
                            detailsSection
                        }
                        .padding(.horizontal, TVDetailLayout.horizontalInset)
                        .padding(.bottom, TVDetailLayout.pageBottomPadding)
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
                    heroId: heroScrollId,
                    browseFocusKey: browseFocusKey,
                    browseHoldRequest: browseHoldRequest,
                    browseRestoreRequest: browseRestoreRequest,
                    similarRailFocused: similarRailFocused,
                    similarSectionId: similarSectionScrollId
                )
                .task(id: hasPrimaryFocus) {
                    let focused = hasPrimaryFocus
                    if focused {
                        primaryViewportActive = true
                    } else {
                        // Keep the first viewport active across the short gap
                        // between one programmatic focus owner releasing and
                        // the next one accepting the same remote gesture.
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        primaryViewportActive = false
                        primaryFocusRegion = .outside
                    }
                }
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
        .onChange(of: selectedSeason?.id) { _, seasonId in
            startSeasonPanIfReady(for: seasonId)
        }
        .onDisappear {
            modeActivationTask?.cancel()
            modeActivationTask = nil
            seasonTransitionTask?.cancel()
            seasonTransitionTask = nil
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoingSeasonPage = nil
                seasonPanProgress = 1
            }
            seasonTransitionInFlight = false
            seasonTransitionTargetId = nil
            pendingSeasonActivationId = nil
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
            // Keep the mode/season row at its approved fixed anchor. The hero
            // stays 620 points tall even when the controls move independently.
            heroHeight: 620,
            heroTopInset: 46,
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
                    TVSeriesModeTab(
                        title: "Show",
                        isSelected: isShowingSeriesOverview,
                        action: showSeriesOverview
                    )
                    .id(showModeId)
                    .focused($focusedModeId, equals: showModeId)

                    ForEach(seasons) { season in
                        TVSeriesModeTab(
                            title: seasonLabel(season),
                            isSelected: !isShowingSeriesOverview && selectedSeason?.id == season.id,
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
                withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onChange(of: focusedModeId) { _, focusedId in
                guard let focusedId else {
                    modeActivationTask?.cancel()
                    modeActivationTask = nil
                    return
                }
                primaryFocusRegion = .mode
                scheduleModeActivation(for: focusedId)
            }
        }
    }

    private var selectedModeId: String {
        isShowingSeriesOverview ? showModeId : (selectedSeason?.id ?? showModeId)
    }

    private func showSeriesOverview() {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        pendingSeasonActivationId = nil
        isShowingSeriesOverview = true
        onActivateEpisode(nil)
    }

    private func activateSeason(_ season: Season) {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        isShowingSeriesOverview = false
        if seasonTransitionInFlight {
            // A reversal must not mutate the direction of the page that is
            // already moving. Retain only the viewer's latest destination and
            // begin it after the current page settles.
            pendingSeasonActivationId = season.id == seasonTransitionTargetId
                ? nil
                : season.id
            return
        }
        guard selectedSeason?.id != season.id else {
            pendingSeasonActivationId = nil
            return
        }
        beginSeasonTransition(to: season)
    }

    private func beginSeasonTransition(to season: Season) {
        pendingSeasonActivationId = nil
        if let targetIndex = seasons.firstIndex(where: { $0.id == season.id }),
           let currentId = selectedSeason?.id,
           let currentIndex = seasons.firstIndex(where: { $0.id == currentId }) {
            seasonTransitionMovesForward = targetIndex > currentIndex
        }

        outgoingSeasonPage = SeasonPageSnapshot(
            seasonId: selectedSeason?.id ?? "series-season-none",
            episodes: episodes,
            currentContentId: displayedEpisode?.contentId,
            isLoading: isLoadingEpisodes
        )
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            seasonPanProgress = 0
        }

        seasonTransitionTask?.cancel()
        seasonTransitionGeneration &+= 1
        seasonTransitionInFlight = true
        seasonTransitionTargetId = season.id
        onActivateEpisode(nil)
        onSelectSeason(season)
    }

    private func startSeasonPanIfReady(for seasonId: String?) {
        guard seasonTransitionInFlight,
              seasonId == seasonTransitionTargetId,
              outgoingSeasonPage != nil else { return }

        seasonTransitionTask?.cancel()
        let generation = seasonTransitionGeneration
        seasonTransitionTask = Task { @MainActor in
            // Allow the newly selected season rail to mount at its settled
            // internal episode offset before the full-width page starts moving.
            await Task.yield()
            if !reduceMotion {
                // Give the incoming episode render surface one display frame
                // to paint before moving it, avoiding a small first-frame hitch.
                try? await Task.sleep(for: .milliseconds(17))
            }
            guard !Task.isCancelled,
                  generation == seasonTransitionGeneration else { return }

            withAnimation(
                reduceMotion
                    ? nil
                    : .timingCurve(0.4, 0, 0.2, 1, duration: 0.46)
            ) {
                seasonPanProgress = 1
            }

            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(480))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  generation == seasonTransitionGeneration else { return }
            finishSeasonTransition()
        }
    }

    private func finishSeasonTransition() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingSeasonPage = nil
            seasonPanProgress = 1
        }
        seasonTransitionInFlight = false
        seasonTransitionTargetId = nil
        seasonTransitionTask = nil

        guard let pendingId = pendingSeasonActivationId else { return }
        pendingSeasonActivationId = nil
        guard pendingId != selectedSeason?.id,
              let pendingSeason = seasons.first(where: { $0.id == pendingId }) else { return }
        beginSeasonTransition(to: pendingSeason)
    }

    /// Season pills behave like tvOS tabs: resting focus activates one without
    /// requiring a second Select press. A short dwell prevents a fast sweep to
    /// Season 4 from loading Seasons 1–3 along the way; clicking remains instant.
    private func scheduleModeActivation(for modeId: String) {
        modeActivationTask?.cancel()
        modeActivationTask = nil
        guard modeId != selectedModeId else { return }

        modeActivationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled,
                  focusedModeId == modeId,
                  modeId != selectedModeId else { return }

            if modeId == showModeId {
                showSeriesOverview()
            } else if let season = seasons.first(where: { $0.id == modeId }) {
                activateSeason(season)
            }
        }
    }

    /// Holds the episode area to one measured Home-card footprint while each
    /// season behaves as a full-width carousel page. Only this viewport moves;
    /// the season tabs, controls, and every lower section remain fixed. The
    /// episode rail owns its own crop, so this wrapper must not cut off the
    /// trailing page inset the rail deliberately borrows.
    private var smoothlyChangingEpisodeBody: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let viewportWidth = width + TVDetailLayout.horizontalInset
            let leftClipCanvasWidth = viewportWidth * 2
            let direction: CGFloat = seasonTransitionMovesForward ? 1 : -1

            ZStack(alignment: .topLeading) {
                if let outgoingSeasonPage {
                    snapshotEpisodeBody(outgoingSeasonPage)
                        .id(outgoingSeasonPage.seasonId)
                        .frame(
                            width: width,
                            height: episodeRailReservedHeight,
                            alignment: .topLeading
                        )
                        // Preserve the rail's existing layout width, then
                        // widen only the temporary raster surface so its
                        // borrowed trailing inset is never cropped.
                        .frame(
                            width: viewportWidth,
                            height: episodeRailReservedHeight,
                            alignment: .topLeading
                        )
                        // The outgoing tab page is immutable. Rasterize it
                        // once before the existing page offset so episode art
                        // and its number/title cannot render on separate paths.
                        .drawingGroup(opaque: false, colorMode: .nonLinear)
                        .offset(x: -direction * seasonPanProgress * viewportWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                liveEpisodePage
                    .frame(
                        width: width,
                        height: episodeRailReservedHeight,
                        alignment: .topLeading
                    )
                    .frame(
                        width: viewportWidth,
                        height: episodeRailReservedHeight,
                        alignment: .topLeading
                    )
                    .lockEpisodeCaptionsForSeasonTabSwitch(
                        outgoingSeasonPage != nil
                    )
                    .offset(
                        x: outgoingSeasonPage == nil
                            ? 0
                            : direction * (1 - seasonPanProgress) * viewportWidth
                    )
            }
            // Retain the settled rail's leading crop, but put the matching
            // right crop a full page beyond the visible display. Cards can
            // then cross the screen's trailing edge without a transient cut.
            .frame(
                width: leftClipCanvasWidth,
                height: episodeRailReservedHeight,
                alignment: .topLeading
            )
            .clipped()
        }
        .frame(height: episodeRailReservedHeight, alignment: .topLeading)
    }

    private var liveEpisodePage: some View {
        ZStack(alignment: .topLeading) {
            episodeBody
                .id(isLoadingEpisodes ? "loading" : "ready")
                // The season-page slide already supplies the transition.
                // Avoid fading its episode paint at the same time, which
                // briefly dimmed the cards and added competing composition.
                .transition(outgoingSeasonPage == nil ? .opacity : .identity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion || outgoingSeasonPage != nil
                ? nil
                : .easeInOut(duration: 0.18),
            value: isLoadingEpisodes
        )
    }

    @ViewBuilder
    private func snapshotEpisodeBody(_ snapshot: SeasonPageSnapshot) -> some View {
        if snapshot.isLoading {
            TVEpisodeRailPlaceholder(
                cardWidth: ContinuumTheme.thumbnailCardWidth
                    * uiCustomization.cardPresentation.posterSize.scale,
                cardHeightRatio: ContinuumTheme.thumbnailCardHeight
                    / ContinuumTheme.thumbnailCardWidth,
                cardSpacing: 40,
                hidesEpisodeTitle: true
            )
        } else if snapshot.episodes.isEmpty {
            Text("No episodes available")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.continuumSecondaryText)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            TVEpisodeRail(
                episodes: snapshot.episodes,
                onSelect: { _ in },
                currentContentId: snapshot.currentContentId,
                baseCardWidth: ContinuumTheme.thumbnailCardWidth,
                cardHeightRatio: ContinuumTheme.thumbnailCardHeight
                    / ContinuumTheme.thumbnailCardWidth,
                cardSpacing: 40,
                anchorsFocusedCard: true
            )
            .padding(.trailing, -TVDetailLayout.horizontalInset)
        }
    }

    private var episodeRailReservedHeight: CGFloat {
        let width = ContinuumTheme.thumbnailCardWidth
            * uiCustomization.cardPresentation.posterSize.scale
        let stillHeight = width
            * (ContinuumTheme.thumbnailCardHeight / ContinuumTheme.thumbnailCardWidth)
        return stillHeight
            + (uiCustomization.cardPresentation.caption.showsTitle ? 46 : 0)
            + 24
    }

    @ViewBuilder
    private var episodeBody: some View {
        if selectedSeason == nil && seasons.isEmpty {
            EmptyView()
        } else if isLoadingEpisodes {
            TVEpisodeRailPlaceholder(
                cardWidth: ContinuumTheme.thumbnailCardWidth
                    * uiCustomization.cardPresentation.posterSize.scale,
                cardHeightRatio: ContinuumTheme.thumbnailCardHeight
                    / ContinuumTheme.thumbnailCardWidth,
                cardSpacing: 40,
                hidesEpisodeTitle: true
            )
        } else if episodes.isEmpty {
            Text("No episodes available")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.continuumSecondaryText)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            TVEpisodeRail(
                episodes: episodes,
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
                baseCardWidth: ContinuumTheme.thumbnailCardWidth,
                cardHeightRatio: ContinuumTheme.thumbnailCardHeight
                    / ContinuumTheme.thumbnailCardWidth,
                cardSpacing: 40,
                anchorsFocusedCard: true,
                onMoveUp: focusSelectedMode,
                onMoveDown: focusPlaybackSelector,
                focusRequest: episodeRailFocusRequest
            )
            // The body already owns a 100-point page inset. Let only this
            // Series carousel borrow the trailing inset so its third visible
            // large card and focus ring remain complete at every step.
            .padding(.trailing, -TVDetailLayout.horizontalInset)
        }
    }

    private func focusSelectedMode() {
        focusedModeId = selectedModeId
    }

    private func focusPlaybackSelector() {
        // Selectors now live in the persistent hero action row. Preserve the
        // carousel's existing Down exit by handing off to the next supporting
        // rail instead of leaving a dead lower focus target.
        supportingRailFocusRequest &+= 1
    }

    private func focusSupportingRail() {
        supportingRailFocusRequest &+= 1
    }

    private func focusEpisode(_ contentId: String?) {
        focusedEpisodeContentId = contentId
        guard let contentId else { return }

        let previousRegion = primaryFocusRegion
        primaryFocusRegion = .episodes
        switch previousRegion {
        case .mode:
            browseHoldRequest &+= 1
        case .outside, .episodes:
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

    private var browseFocusKey: String? {
        primaryViewportActive ? "series-primary" : nil
    }

    private var hasPrimaryFocus: Bool {
        focusedEpisodeContentId != nil
            || focusedModeId != nil
    }

    private var moreMenu: some View {
        TVCircleMenuButton(
            accessibilityLabel: "More options",
            stabilizesFocusMotion: true
        ) {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
            }
            if selectedSeason != nil {
                Button(action: onToggleWatched) {
                    Label(
                        isWatched ? "Mark Season Unwatched" : "Mark Season Watched",
                        systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
            }
            if supportsTrailerFetch {
                Button(action: onFindTrailers) {
                    Label("Find Trailers", systemImage: "film.stack")
                }
            }
        }
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
                focusRequest: supportingRailFocusRequest
            )
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

private extension View {
    /// During a Series season-tab page switch only, flatten the incoming page
    /// before its existing offset animates. Outside that short transition the
    /// live episode carousel is returned unchanged.
    @ViewBuilder
    func lockEpisodeCaptionsForSeasonTabSwitch(_ isSwitching: Bool) -> some View {
        if isSwitching {
            drawingGroup(opaque: false, colorMode: .nonLinear)
        } else {
            self
        }
    }
}

/// Stable Show/Season tab used only by the combined Series page. It changes
/// fill and outline on focus without scaling, so neighboring tabs never move.
private struct TVSeriesModeTab: View {
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
        .buttonStyle(TVSeriesModeTabStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TVSeriesModeTabStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeriesModeTabBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct TVSeriesModeTabBody: View {
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
            .shadow(
                color: Color.black.opacity(rendersFocusedAppearance ? 0.28 : 0),
                radius: rendersFocusedAppearance ? 10 : 0,
                y: rendersFocusedAppearance ? 4 : 0
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
                // Ignore that sub-frame transient without delaying the current
                // selected season or changing normal lateral navigation.
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
#endif
