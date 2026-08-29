#if os(tvOS)
import SwiftUI

/// Persistent video-detail layout for tvOS. Movies use the supplied detail as
/// their playback target. Series-family pages keep this same view mounted as
/// the active series, season, or episode changes; container pages supply the
/// next playable episode separately through `playbackDetail`.
struct TVMovieDetailView<BelowSynopsis: View>: View {
    let detail: ItemDetail
    var playbackDetail: ItemDetail? = nil
    var playTitleOverride: String? = nil
    var isLoadingPlaybackDetail = false
    var didLoadPlaybackDetail = true
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// True once the user explicitly resets subtitles to "Auto" this visit.
    /// The server override was just cleared, but `detail.effectiveSubtitle*`
    /// still describes the old manual pick until the next refetch — suppress
    /// it so the "Auto: …" preview doesn't echo the cleared selection.
    var subtitleOverrideCleared: Bool = false
    let seasons: [Season]
    let selectedSeason: Season?
    let seasonEpisodes: [EpisodeListItem]
    let episodeFavoriteStates: [String: Bool]
    let isLoadingEpisodes: Bool
    /// Merged remote-video + local-extra rail, already shaped by the call
    /// site (which owns the YouTube-app availability probe that decides
    /// whether remote cards exist at all). Empty hides the rail.
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    /// Whether the manual "Find Trailers" action can be offered — false on
    /// episode pages and when the YouTube app is unavailable.
    let supportsTrailerFetch: Bool
    let onFindTrailers: () -> Void
    /// Copy from the fetch coordinator; nil while idle.
    let trailerFetchStatus: String?
    let isFetchingTrailers: Bool
    /// Called once a terminal fetch message has been on screen long enough.
    let onTrailerStatusShown: () -> Void
    let onPlay: (_ startFromBeginning: Bool) -> Void
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let onSelectSeason: (Season) -> Void
    var onFocusedSeasonChange: ((Season?) -> Void)? = nil
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    let onEpisodeTap: (String) -> Void
    var onFocusedEpisodeChange: ((String?) -> Void)? = nil
    var onPlayFocusedEpisode: ((String) -> Void)? = nil
    var currentEpisodeContentId: String? = nil
    var prefersCurrentEpisodeFocus = false
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the synopsis.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Namespace private var detailFocusNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var playFocused: Bool
    /// True while focus sits anywhere inside the season chip row — drives the
    /// episode-section re-center in `detailFocusScroll`.
    @FocusState private var seasonRowFocused: Bool
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool
    @State private var versionSelectorFocused = false
    /// High-priority only for page entry; later focus reevaluations should
    /// respect the active season or episode row.
    @State private var prefersPageEntryPlay = true
    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "detail-episode-section"
    private let heroScrollId = "detail-hero"
    @State private var focusedEpisodeContentId: String?
    @State private var heroRevealOpacity = 1.0
    @State private var episodeRailRevealOpacity = 1.0

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TVDetailLayoutMetrics.firstSectionSpacing) {
                    TVDetailHero(
                        title: detail.title,
                        seriesTitle: heroSeriesTitle,
                        logoUrl: detail.logoUrl,
                        backdropUrl: detail.backdropUrl,
                        eyebrow: heroEyebrow,
                        sourceTokens: heroSourceTokens,
                        ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
                        overview: detail.overview,
                        factsLine: heroFactsLine,
                        starringText: TVHeroMetadata.starringText(from: detail),
                        actions: { actionColumn },
                        belowSynopsis: belowSynopsis
                    )
                    .id(heroScrollId)
                    .opacity(heroRevealOpacity)
                    .onChange(of: detail.contentId) { _, _ in
                        revealHeroMetadata()
                    }

                    VStack(alignment: .leading, spacing: 72) {
                        if showsEpisodeRail {
                            episodesSection
                                .id(episodeSectionScrollId)
                        }
                        if let cast = detail.cast, !cast.isEmpty {
                            castSection(cast: cast)
                        }
                        trailersSection
                        detailsSection
                        if showsSimilarRail {
                            similarSection
                        }
                    }
                    .padding(.horizontal, ContinuumTheme.safePadding)
                    .padding(.bottom, 160)
                }
            }
            .ignoresSafeArea()
            .focusScope(detailFocusNamespace)
            .defaultFocus(
                $playFocused,
                true,
                priority: prefersPageEntryPlay ? .userInitiated : .automatic
            )
            .detailFocusScroll(
                proxy: scrollProxy,
                seasonRowFocused: seasonRowFocused,
                actionRowFocused: actionRowFocused,
                episodeSectionId: episodeSectionScrollId,
                heroId: heroScrollId
            )
            .onPlayPauseCommand(perform: playFocusedEpisodeOrCurrent)
        }
    }

    // MARK: - Hero actions

    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionRow
            if shouldShowVersionPlaceholder {
                TVVersionPillPlaceholder()
            } else if let effectivePlaybackDetail {
                TVPlaybackSelectorRow(
                    versions: availableVersions,
                    currentVersion: currentVersion,
                    selectedVersionFileId: selectedVersionFileId,
                    selectedAudioTrackIndex: selectedAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                    subtitleMode: subtitleOverrideCleared
                        ? nil
                        : effectivePlaybackDetail.effectiveSubtitleMode,
                    subtitleSignature: subtitleOverrideCleared
                        ? nil
                        : effectivePlaybackDetail.effectiveSubtitleTrackSignature,
                    showForcedSubtitles: effectivePlaybackDetail.effectiveShowForcedSubtitles ?? false,
                    onSelectVersion: onSelectVersion,
                    onSelectAudioTrack: onSelectAudioTrack,
                    onSelectSubtitleTrack: onSelectSubtitleTrack,
                    onVersionFocusChanged: setVersionSelectorFocused
                )
            }
            if let trailerFetchStatus {
                // Non-focusable readout, so it adds no stop to the action
                // column's focus traversal.
                TVTrailerStatusPill(
                    message: trailerFetchStatus,
                    isFetching: isFetchingTrailers,
                    onAutoDismiss: onTrailerStatusShown
                )
            }
        }
        .onChange(of: playFocused) { _, isFocused in
            if isFocused {
                prefersPageEntryPlay = false
            }
        }
    }

    private func setVersionSelectorFocused(_ isFocused: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            versionSelectorFocused = isFocused
        }
    }

    private var actionRow: some View {
        TVDetailActionRow(
            playTitle: primaryPlayLabel,
            onPlay: { onPlay(false) },
            onStartOver: hasResumeProgress ? { onPlay(true) } : nil,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            isWatched: isWatched,
            watchedLabelMark: watchedLabelMark,
            watchedLabelUnmark: watchedLabelUnmark,
            onToggleWatched: onToggleWatched,
            initialFocusScope: isSeriesFamily
                ? .season(key: selectedSeason?.contentId)
                : .page,
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $actionRowFocused,
            routesVersionUpToPlay: versionSelectorFocused,
            moreMenu: {
                if hasMoreMenu {
                    moreMenu
                }
            }
        )
    }

    // MARK: - More menu

    private var hasOverflowNavigation: Bool {
        (detail.type == "season" || detail.type == "episode")
            && detail.seriesId != nil
    }

    /// The ellipsis now also appears on movie pages, which previously had
    /// no overflow entries at all — "Find Trailers" is the first.
    private var hasMoreMenu: Bool {
        hasOverflowNavigation || supportsTrailerFetch
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(accessibilityLabel: "More options") {
            if supportsTrailerFetch {
                Button(action: onFindTrailers) {
                    Label("Find Trailers", systemImage: "film.stack")
                }
            }
            if let seriesId = detail.seriesId,
               let seasonNumber = detail.seasonNumber,
               seasonNumber > 0 {
                Button {
                    onNavigateToItem("\(seriesId)-S\(seasonNumber)")
                } label: {
                    Label("Go to Season", systemImage: "square.stack")
                }
            }
            if let seriesId = detail.seriesId {
                Button {
                    onNavigateToItem(seriesId)
                } label: {
                    Label("Go to Series", systemImage: "tv")
                }
            }
        }
    }

    private var watchedLabelMark: String {
        switch detail.type {
        case "series": "Mark Series Watched"
        case "season": "Mark Season Watched"
        case "episode": "Mark Episode Watched"
        default: "Mark as Watched"
        }
    }

    private var watchedLabelUnmark: String {
        switch detail.type {
        case "series": "Mark Series Unwatched"
        case "season": "Mark Season Unwatched"
        case "episode": "Mark Episode Unwatched"
        default: "Mark as Unwatched"
        }
    }

    private var resumePositionSeconds: Double? {
        guard let playback = effectivePlaybackDetail,
              let pos = playback.userData?.positionSeconds,
              pos > 30 else { return nil }
        if let dur = playback.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
    }

    private var hasResumeProgress: Bool { resumePositionSeconds != nil }

    private var primaryPlayLabel: String? {
        if let playTitleOverride { return playTitleOverride }
        guard effectivePlaybackDetail != nil else { return nil }
        guard let pos = resumePositionSeconds else { return "Play" }
        return "Resume \(PlayerTimeFormatter.formatHMS(pos))"
    }

    private var shouldShowVersionPlaceholder: Bool {
        primaryPlayLabel != nil
            && (isLoadingPlaybackDetail
                || (!didLoadPlaybackDetail && effectivePlaybackDetail == nil))
    }

    // MARK: - Episodes (episode detail page)

    private var showsEpisodeRail: Bool {
        isSeriesFamily
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(label: episodeRailEyebrow, title: "Episodes")
            if seasons.count > 1 {
                TVSeasonChipRow(
                    seasons: seasons,
                    selectedSeasonId: selectedSeason?.id,
                    onSelect: onSelectSeason,
                    onFocusedSeasonChange: onFocusedSeasonChange
                )
                // Container binding — true while any chip has focus, driving
                // the episode-section re-center in `detailFocusScroll`.
                .focused($seasonRowFocused)
            }
            if seasonEpisodes.isEmpty, isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().tint(.continuumOnSurface).padding()
                    Spacer()
                }
                .frame(height: 330)
            } else if seasonEpisodes.isEmpty {
                Text("No episodes available")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.continuumSecondaryText)
            } else {
                ZStack(alignment: .topTrailing) {
                    TVEpisodeRail(
                        episodes: seasonEpisodes,
                        onSelect: onEpisodeTap,
                        onFocusedEpisodeChange: {
                            focusedEpisodeContentId = $0
                            onFocusedEpisodeChange?($0)
                        },
                        onSetWatched: onSetEpisodeWatched,
                        onSetFavorite: onSetEpisodeFavorite,
                        currentContentId: currentEpisodeContentId
                            ?? (detail.type == "episode" ? detail.contentId : nil),
                        currentContentIsFavorite: detail.type == "episode" ? isFavorite : false,
                        favoriteStates: episodeFavoriteStates,
                        prefersCurrentContentFocus: prefersCurrentEpisodeFocus
                    )
                    .disabled(isLoadingEpisodes)
                    .opacity(isLoadingEpisodes ? 0.55 : episodeRailRevealOpacity)
                    .onChange(of: episodeRailIdentity) { _, _ in
                        revealEpisodeRail()
                    }

                    if isLoadingEpisodes {
                        HStack(spacing: 12) {
                            ProgressView().tint(.continuumOnSurface)
                            Text("Loading season")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.continuumOnSurface.opacity(0.82))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 28)
                    }
                }
                .padding(.horizontal, -ContinuumTheme.safePadding)
            }
        }
    }

    private var episodeRailIdentity: String {
        let first = seasonEpisodes.first?.contentId ?? "none"
        let last = seasonEpisodes.last?.contentId ?? "none"
        return "\(first)|\(last)|\(seasonEpisodes.count)"
    }

    private func revealHeroMetadata() {
        guard !reduceMotion else {
            heroRevealOpacity = 1
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            heroRevealOpacity = 0.88
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                heroRevealOpacity = 1
            }
        }
    }

    private func revealEpisodeRail() {
        guard !reduceMotion else {
            episodeRailRevealOpacity = 1
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            episodeRailRevealOpacity = 0.82
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                episodeRailRevealOpacity = 1
            }
        }
    }

    /// Siri Remote Play/Pause is a page-level shortcut. A different episode
    /// highlighted in the rail wins; every other focus zone plays the episode
    /// represented by this detail page and preserves its selector overrides.
    private func playFocusedEpisodeOrCurrent() {
        if let focusedEpisodeContentId {
            onPlayFocusedEpisode?(focusedEpisodeContentId)
        } else if primaryPlayLabel != nil {
            onPlay(false)
        }
    }

    private var episodeRailEyebrow: String {
        // Track the chip selection — the rail can show a different season
        // than the episode's own once the viewer switches in place.
        if let season = selectedSeason {
            return season.seasonNumber > 0
                ? "Season \(season.seasonNumber)"
                : (season.title ?? "Specials")
        }
        if let seasonNumber = detail.seasonNumber, seasonNumber > 0 {
            return "Season \(seasonNumber)"
        }
        return "This Season"
    }

    // MARK: - More Like This

    /// Hide on episode pages — viewers want the next episode, not
    /// tangentially related titles. The episode rail above already
    /// serves browsing.
    private var showsSimilarRail: Bool {
        detail.type == "movie" || detail.type == "series"
    }

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        TVSimilarRail(
            contentId: detail.contentId,
            onSelect: onNavigateToItem
        )
    }

    // MARK: - Trailers & More

    private var trailersSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // the item has neither remote videos nor local extras.
        TVTrailersRail(entries: trailerEntries, onSelect: onSelectTrailer)
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }

    // MARK: - Version data

    private var availableVersions: [FileVersion] {
        effectivePlaybackDetail?.versions ?? []
    }

    private var currentVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: availableVersions,
            selectedFileId: selectedVersionFileId,
            lastFileId: effectivePlaybackDetail?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private var effectivePlaybackDetail: ItemDetail? {
        playbackDetail ?? (detail.type == "movie" || detail.type == "episode" ? detail : nil)
    }

    private var isSeriesFamily: Bool {
        detail.type == "series" || detail.type == "season" || detail.type == "episode"
    }

    private var heroSeriesTitle: String? {
        detail.type == "episode" ? detail.seriesTitle : nil
    }

    private var heroEyebrow: String? {
        switch detail.type {
        case "episode": nil
        case "season": detail.seriesTitle
        default: TVHeroMetadata.eyebrow(from: detail)
        }
    }

    private var heroSourceTokens: [String] {
        if detail.type == "series" {
            return TVHeroMetadata.seriesSourceTokens(from: detail)
        }
        if detail.type == "season" {
            var tokens: [String] = []
            if let count = detail.episodeCount, count > 0 {
                tokens.append("\(count) Episode\(count == 1 ? "" : "s")")
            } else if !seasonEpisodes.isEmpty {
                tokens.append("\(seasonEpisodes.count) Episode\(seasonEpisodes.count == 1 ? "" : "s")")
            }
            if let genres = detail.genres, !genres.isEmpty {
                tokens.append(contentsOf: genres.prefix(2))
            }
            return tokens
        }
        return TVHeroMetadata.movieSourceTokens(from: detail)
    }

    private var heroFactsLine: [TVHeroFactToken] {
        if detail.type == "series" {
            return TVHeroMetadata.seriesFactsLine(from: detail)
        }
        if detail.type == "season" {
            return []
        }
        return TVHeroMetadata.movieFactsLine(from: detail, version: currentVersion)
    }
}
#endif
