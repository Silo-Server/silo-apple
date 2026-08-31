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
        case selector
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
    @State private var playbackSelectorFocused = false
    @State private var primaryViewportActive = false
    @State private var primaryFocusRegion: PrimaryFocusRegion = .outside
    @State private var browseHoldRequest = 0
    @State private var browseRestoreRequest = 0
    @State private var episodeRailFocusRequest = 0
    @State private var playbackSelectorFocusRequest = 0
    @State private var supportingRailFocusRequest = 0

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
    }

    // MARK: - Fixed series hero

    private var heroView: some View {
        TVDetailHero(
            title: heroTitle,
            seriesTitle: isShowingSeriesOverview ? nil : detail.title,
            logoUrl: detail.logoUrl,
            // Deliberately never switch to episode artwork. The series image
            // remains a stable visual anchor while episode details change.
            backdropUrl: detail.backdropUrl,
            eyebrow: nil,
            sourceTokens: heroSourceTokens,
            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
            overview: heroOverview,
            factsLine: heroFactsLine,
            starringText: isShowingSeriesOverview
                ? TVHeroMetadata.starringText(from: detail)
                : nil,
            playbackSummaryText: nil,
            backdropHeight: TVDetailLayout.heroHeight,
            heroHeight: 520,
            heroTopInset: 46,
            editorialContentWidth: isShowingSeriesOverview
                ? TVDetailLayout.heroContentWidth
                : 900,
            synopsisReservedHeight: isShowingSeriesOverview ? 0 : 96,
            extendsBackdropFadeBelowHero: true,
            actions: {
                if isShowingSeriesOverview {
                    showActionRow
                }
            },
            belowSynopsis: {
                if isShowingSeriesOverview {
                    belowSynopsis()
                }
            }
        )
    }

    private var heroTitle: String {
        guard !isShowingSeriesOverview else { return detail.title }
        return matchingPlaybackDetail?.title
            ?? displayedEpisode?.title
            ?? displayedEpisode.map { "Episode \($0.episodeNumber)" }
            ?? detail.title
    }

    private var heroOverview: String? {
        guard !isShowingSeriesOverview else { return detail.overview }
        return matchingPlaybackDetail?.overview ?? displayedEpisode?.overview
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
            playTitle: suggestedEpisode.map(showPlayTitle(for:)),
            playSubtitle: nil,
            onPlay: {
                guard let episode = suggestedEpisode else { return }
                onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
            },
            onStartOver: suggestedEpisode?.userData?.isInProgress == true
                ? {
                    guard let episode = suggestedEpisode else { return }
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
            rowFocused: $showActionRowFocused,
            stabilizesFocusMotion: true,
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
            playbackSelector
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
                            action: {
                                isShowingSeriesOverview = false
                                if selectedSeason?.id != season.id {
                                    onActivateEpisode(nil)
                                    onSelectSeason(season)
                                }
                            }
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
                guard focusedId != nil else { return }
                primaryFocusRegion = .mode
            }
        }
    }

    private var selectedModeId: String {
        isShowingSeriesOverview ? showModeId : (selectedSeason?.id ?? showModeId)
    }

    private func showSeriesOverview() {
        isShowingSeriesOverview = true
        onActivateEpisode(nil)
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
                baseCardWidth: 480,
                cardSpacing: 32,
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
        if effectiveNextUpVersion != nil {
            playbackSelectorFocusRequest &+= 1
        } else {
            supportingRailFocusRequest &+= 1
        }
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

        let previousRegion = primaryFocusRegion
        primaryFocusRegion = .episodes
        switch previousRegion {
        case .mode:
            browseHoldRequest &+= 1
        case .selector:
            browseRestoreRequest &+= 1
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
        playbackSelectorFocused
            || focusedEpisodeContentId != nil
            || focusedModeId != nil
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
                    focusRequest: playbackSelectorFocusRequest,
                    onFocusChange: notePlaybackSelectorFocus,
                    onMoveUp: focusEpisodeRail,
                    onMoveDown: focusSupportingRail,
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
        if isFocused {
            primaryFocusRegion = .selector
        }
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
