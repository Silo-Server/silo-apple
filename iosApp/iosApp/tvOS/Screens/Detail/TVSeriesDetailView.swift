#if os(tvOS)
import SwiftUI

/// Single-page Series experience for tvOS. The series backdrop never changes,
/// episode focus updates the editorial details and selectors, and selecting an
/// episode hands focus to the matching Play control without leaving the page.
/// Playback remains attached to the explicit Play controls and the carousel's
/// context action.
struct TVSeriesDetailView: View {
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
    /// `nil` restores the suggested current episode.
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
    @Namespace private var detailFocusNamespace
    @FocusState private var playFocused: Bool
    @FocusState private var actionRowFocused: Bool
    @FocusState private var similarRailFocused: Bool
    @State private var focusedEpisodeContentId: String?
    @State private var playbackSelectorFocused = false
    @State private var seasonSelectorFocused = false
    @State private var seasonSelectorFocusRequest = 0
    @State private var episodeRailFocusRequest = 0
    @State private var primaryViewportActive = false
    @State private var supportingRailFocusRequest = 0

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
                    seasonRowFocused: seasonSelectorFocused,
                    actionRowFocused: actionRowFocused || playbackSelectorFocused,
                    episodeRailFocused: focusedEpisodeContentId != nil,
                    episodeSectionId: episodeSectionScrollId,
                    heroId: heroScrollId,
                    browseFocusKey: browseFocusKey,
                    usesSinglePrimaryMovement: true,
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
                    }
                }
            }
        }
    }

    // MARK: - Fixed series hero

    private var heroView: some View {
        TVEpisodeDetailHero(
            title: heroTitle,
            seriesTitle: detail.title,
            logoUrl: detail.logoUrl,
            // Deliberately never switch to episode artwork. The series image
            // remains a stable visual anchor while episode details change.
            backdropUrl: detail.backdropUrl,
            sourceTokens: heroSourceTokens,
            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
            overview: heroOverview,
            factsLine: heroFactsLine,
            actions: { actionColumn },
            belowSynopsis: { EmptyView() }
        )
    }

    private var heroTitle: String {
        return matchingPlaybackDetail?.title
            ?? displayedEpisode?.title
            ?? displayedEpisode.map { "Episode \($0.episodeNumber)" }
            ?? detail.title
    }

    private var heroOverview: String? {
        matchingPlaybackDetail?.overview ?? displayedEpisode?.overview ?? detail.overview
    }

    private var heroSourceTokens: [String] {
        guard let episode = displayedEpisode else { return [] }
        return TVHeroMetadata.episodeSourceTokens(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }

    private var heroFactsLine: [TVHeroFactToken] {
        guard let episode = displayedEpisode else { return [] }
        return TVHeroMetadata.episodeFactsLine(
            airDate: episode.airDate,
            runtime: episode.runtime
        )
    }

    // MARK: - Contextual episode actions

    private var actionColumn: some View {
        TVEpisodeHeroActions(
            selectors: { playbackSelector },
            primaryActions: { contextualActionRow }
        )
    }

    private var contextualActionRow: some View {
        TVDetailActionRow(
            playTitle: playbackEpisode.map(playTitle(for:)),
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
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            isWatched: isWatched,
            watchedLabelMark: "Mark Season Watched",
            watchedLabelUnmark: "Mark Season Unwatched",
            onToggleWatched: onToggleWatched,
            showsWatchedAction: selectedSeason != nil,
            focusResetKey: detail.contentId,
            initialFocusScope: .page,
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $actionRowFocused,
            stabilizesFocusMotion: true,
            moreMenu: { moreMenu }
        )
    }

    private func playTitle(for episode: EpisodeListItem) -> String {
        let verb = episode.userData?.isInProgress == true ? "Resume" : "Play"
        return "\(verb) S\(episode.seasonNumber):E\(episode.episodeNumber)"
    }

    // MARK: - Season modes and episode carousel

    private var episodeExperience: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.episodeBrowseSpacing) {
            TVSeasonSelectorRow(
                seasons: seasons,
                selectedSeason: selectedSeason,
                focusRequest: seasonSelectorFocusRequest,
                onSelect: selectSeason,
                onFocusChange: { seasonSelectorFocused = $0 },
                onMoveDown: focusEpisodeRail
            )
            episodeBody
            if let trailerFetchStatus {
                TVTrailerStatusPill(
                    message: trailerFetchStatus,
                    isFetching: isFetchingTrailers,
                    onAutoDismiss: onTrailerStatusShown
                )
            }
        }
    }

    private func selectSeason(_ season: Season) {
        onActivateEpisode(nil)
        onSelectSeason(season)
    }

    @ViewBuilder
    private var episodeBody: some View {
        if selectedSeason == nil && seasons.isEmpty {
            EmptyView()
        } else if isLoadingEpisodes {
            TVEpisodeRailPlaceholder(
                cardWidth: 480,
                cardSpacing: 32,
                hidesEpisodeTitle: true
            )
        } else if episodes.isEmpty {
            Text("No episodes available")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.continuumSecondaryText)
                .frame(height: 360, alignment: .topLeading)
        } else {
            TVEpisodeRail(
                episodes: episodes,
                onSelect: selectEpisode,
                onPlay: quickPlayEpisode,
                onFocusedEpisodeChange: focusEpisode,
                onSetWatched: onSetEpisodeWatched,
                onSetFavorite: onSetEpisodeFavorite,
                currentContentId: displayedEpisode?.contentId,
                currentContentIsFavorite: displayedEpisode.map {
                    episodeFavoriteStates[$0.contentId] ?? false
                } ?? false,
                favoriteStates: episodeFavoriteStates,
                baseCardWidth: 480,
                cardSpacing: 32,
                anchorsFocusedCard: true,
                onMoveUp: focusSelectedMode,
                onMoveDown: focusSupportingRail,
                focusRequest: episodeRailFocusRequest
            )
            // The body already owns a 100-point page inset. Let only this
            // Series carousel borrow the trailing inset so its third visible
            // large card and focus ring remain complete at every step.
            .padding(.trailing, -TVDetailLayout.horizontalInset)
        }
    }

    private func focusSelectedMode() {
        seasonSelectorFocusRequest &+= 1
    }

    private func focusEpisodeRail() {
        episodeRailFocusRequest &+= 1
    }

    private func focusSupportingRail() {
        supportingRailFocusRequest &+= 1
    }

    private func focusEpisode(_ contentId: String?) {
        focusedEpisodeContentId = contentId
        guard let contentId else { return }

        guard activeEpisodeContentId != contentId else { return }
        onActivateEpisode(contentId)
    }

    private func selectEpisode(_ contentId: String) {
        if activeEpisodeContentId != contentId {
            onActivateEpisode(contentId)
        }

        // Let the carousel finish handling Select before transferring its
        // single composite focus owner to the hero's native Play button.
        Task { @MainActor in
            await Task.yield()
            playFocused = true
        }
    }

    private func quickPlayEpisode(_ contentId: String) {
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
        playbackSelectorFocused
            || focusedEpisodeContentId != nil
            || seasonSelectorFocused
    }

    // MARK: - Episode playback selectors and contextual actions

    @ViewBuilder
    private var playbackSelector: some View {
        if playbackEpisode != nil {
            if effectiveNextUpVersion != nil {
                TVPlaybackSelectorRow(
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
                    showForcedSubtitles: matchingPlaybackDetail?.effectiveShowForcedSubtitles ?? false,
                    expandsAsGroup: true,
                    stabilizesFocusMotion: true,
                    pinsLeadingEdgeOnExpansion: true,
                    prefersVersionFocusOnEntry: true,
                    onFocusChange: notePlaybackSelectorFocus,
                    onSelectVersion: onSelectNextUpVersion,
                    onSelectAudioTrack: onSelectNextUpAudioTrack,
                    onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
                )
            } else if isLoadingNextUpPlaybackDetail
                        || !didLoadNextUpPlaybackDetail
                        || matchingPlaybackDetail == nil {
                TVPlaybackSelectorPlaceholder()
            } else {
                // A failed/empty playback-detail response keeps the exact
                // selector footprint instead of shifting the action row.
                TVPlaybackSelectorPlaceholder()
                    .opacity(0.58)
            }
        }
    }

    private func notePlaybackSelectorFocus(_ isFocused: Bool) {
        playbackSelectorFocused = isFocused
    }

    private var moreMenu: some View {
        Group {
            if supportsTrailerFetch {
                TVCircleMenuButton(
                    accessibilityLabel: "More options",
                    stabilizesFocusMotion: true
                ) {
                    Button(action: onFindTrailers) {
                        Label("Find Trailers", systemImage: "film.stack")
                    }
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
        displayedEpisode
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

#endif
