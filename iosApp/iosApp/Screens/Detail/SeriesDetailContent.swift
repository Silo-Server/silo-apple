#if !os(tvOS)
import SwiftUI

/// Phone series detail screen. Cinematic backdrop hero up top, then a
/// scrollable body of season chips + episode rail, cast, "About", and
/// the Details key/value list.
///
/// Mirrors `TVSeriesDetailView` semantically — same hero metadata, same
/// next-up Play action, same horizontal episode rail — sized for touch.
struct SeriesDetailContent<BelowOverview: View>: View {
    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodeFavoriteStates: [String: Bool]
    let episodeWatchlistStates: [String: Bool]
    let isLoadingEpisodes: Bool
    let hierarchyError: String?
    let onRetryHierarchy: () async -> Void
    let selectedNextUpFileId: Int?
    let selectedNextUpAudioTrackIndex: Int?
    let selectedNextUpSubtitleTrackIndex: Int?
    let nextUpWatchDetail: WatchDetail?
    let isLoadingSelectedEpisodePlayback: Bool
    let selectedEpisodeContentId: String?
    let onSelectSeason: (Season) -> Void
    /// `resumePosition` is the point the user was offered (nil for a
    /// restart or an episode without progress).
    let onPlayEpisode: (
        _ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool, _ resumePosition: Double?
    ) -> Void
    /// Reads the episode's current watch state from the server, so the
    /// resume prompt never offers a position another device has moved past.
    let refreshResumeState: (_ contentId: String) async -> DetailResumeState
    let onEpisodeTap: (String) -> Void
    let onSelectNextUpVersion: (Int?) -> Void
    let onSelectNextUpAudioTrack: (Int?) -> Void
    let onSelectNextUpSubtitleTrack: (Int?) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onSetSeasonWatched: (Season, Bool) async -> PersonalStateOutcome
    let onSetEpisodeWatched: (EpisodeListItem, Bool) async -> PersonalStateOutcome
    let onSetEpisodeFavorite: (String, Bool) async -> PersonalStateOutcome
    let onSetEpisodeWatchlist: (String, Bool) async -> PersonalStateOutcome
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    /// Play a local extra from the trailers rail. Routed separately from
    /// `onPlayEpisode` because extras have no resume point.
    let onPlayExtra: (String) -> Void
    /// Kick off the manual "Find Trailers" fetch.
    let onFindTrailers: () -> Void
    /// Copy for the fetch status pill, straight from the coordinator. `nil`
    /// hides the pill.
    let trailerStatusMessage: String?
    /// True while the fetch is still requesting or polling.
    let isFindingTrailers: Bool
    /// Called once a terminal status message has been on screen long enough.
    let onTrailerStatusShown: () -> Void
    /// Reference-backed scroll state observed only by the small parallax and
    /// pinned-chrome views, keeping the native ScrollView's body stable.
    let scrollState: PhoneDetailScrollState
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppRouter.self) private var router
    @State private var shuffleLauncher = ShuffleLauncher()
    @State private var hierarchyRetryTask: Task<Void, Never>?
    private struct PendingResume {
        let episode: EpisodeListItem
        let position: Double
    }
    @State private var pendingResume: PendingResume?
    /// The Play tap's in-flight watch-state read. A second tap replaces it.
    @State private var resumeLookupTask: Task<Void, Never>?
    @State private var isUpdatingWatched = false
    @State private var watchedUpdateFailed = false
    @State private var watchedNotice: PersonalStateNotice?
    /// Bumped when a season or episode watched change lands, so the success
    /// haptic confirms it after the context menu has closed.
    @State private var watchedAppliedCount = 0
    private struct PendingEpisodePlayRequest: Equatable {
        let seasonNumber: Int?
    }
    /// A tap can arrive before the first episode page finishes hydrating.
    /// Keep the primary control interactive from frame one and fulfill that
    /// intent as soon as the target episode is known.
    @State private var pendingEpisodePlayRequest: PendingEpisodePlayRequest?

    var body: some View {
        PhoneDetailPageSurface(
            backdropURL: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            enablesArtworkGlass: true,
            keepsSideSafeArea: true
        ) {
            PhoneDetailPageLayout(scrollState: scrollState) {
                VStack(alignment: .leading, spacing: heroToContentSpacing) {
                    hero()
                    belowFold
                }
                .padding(.bottom, 40)
            } paneHero: { height in
                hero(paneHeight: height)
            } paneContent: {
                VStack(alignment: .leading, spacing: 32) {
                    heroExtras
                        .padding(.horizontal, SiloTheme.safePadding)
                    belowFold
                }
                .padding(.bottom, 40)
            }
            #if os(iOS)
            .environment(\.watchPartyEpisodePreview) { [detail, seasons] episode in
                WatchPartySelectedItem(previewing: episode, series: detail, seasons: seasons)
            }
            #endif
        }
        .siloResumePlaybackAlert(
            isPresented: Binding(
                get: { pendingResume != nil },
                set: { if !$0 { pendingResume = nil } }
            ),
            stoppedAt: resumeTimestamp
        ) {
            guard let pendingResume else { return }
            let episode = pendingResume.episode
            onPlayEpisode(episode.contentId, playbackFileId(for: episode), false, pendingResume.position)
        } onRestart: {
            guard let episode = pendingResume?.episode else { return }
            onPlayEpisode(episode.contentId, playbackFileId(for: episode), true, nil)
        }
        .onDisappear {
            hierarchyRetryTask?.cancel()
            hierarchyRetryTask = nil
            resumeLookupTask?.cancel()
            resumeLookupTask = nil
            pendingEpisodePlayRequest = nil
        }
        .onChange(of: hierarchyError) { _, error in
            if error != nil { pendingEpisodePlayRequest = nil }
        }
        .onChange(of: nextUpEpisode?.contentId) { _, contentID in
            guard hierarchyError == nil,
                  let request = pendingEpisodePlayRequest, contentID != nil,
                  let episode = nextUpEpisode else { return }
            if let requestedSeason = request.seasonNumber,
               episode.seasonNumber != requestedSeason {
                pendingEpisodePlayRequest = nil
                return
            }
            pendingEpisodePlayRequest = nil
            handlePlayTap(for: episode)
        }
        .onChange(of: isLoadingEpisodes) { _, isLoading in
            guard !isLoading, nextUpEpisode == nil else { return }
            pendingEpisodePlayRequest = nil
        }
        .sensoryFeedback(.success, trigger: watchedAppliedCount)
        .sensoryFeedback(.error, trigger: watchedUpdateFailed) { _, failed in failed }
        .alert("Couldn't Update Watched Status", isPresented: $watchedUpdateFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please check your connection and try again.")
        }
        .personalStateNoticeAlert($watchedNotice)
        .shuffleFailureAlert(shuffleLauncher)
    }

    private var heroToContentSpacing: CGFloat {
        horizontalSizeClass == .regular ? 16 : 32
    }

    // MARK: - Hero

    private func hero(paneHeight: CGFloat? = nil) -> some View {
        PhoneDetailHero(
            title: detail.title,
            logoUrl: detail.logoUrl,
            posterUrl: detail.posterUrl,
            posterThumbhash: detail.posterThumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: PhoneHeroMetadata.eyebrow(from: detail),
            sourceTokens: PhoneHeroMetadata.seriesSourceTokens(from: detail),
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: PhoneHeroMetadata.seriesFactsLine(from: detail, seasons: seasons),
            ratings: detail.displayRatings,
            creditText: PhoneHeroMetadata.creditText(from: detail),
            overlayData: OverlayData.from(detail),
            enablesArtworkParallax: true,
            paneHeight: paneHeight,
            actions: { actionStack },
            // Match MovieDetailContent exactly through the playback controls:
            // Play/actions, show overview and credits, translation affordance,
            // then selectors. Seasons and episodes are the only series-only
            // extension and begin immediately after this shared hero.
            belowOverview: { heroExtras }
        )
    }

    /// Under the overview in one column; atop the content pane in a split.
    private var heroExtras: some View {
        VStack(spacing: 14) {
            belowOverview()
            playbackSelectorSlot
                .opacity(isLoadingEpisodes || nextUpEpisode != nil ? 1 : 0)
                .accessibilityHidden(!isLoadingEpisodes && nextUpEpisode == nil)
        }
    }

    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 14) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: nextUpEpisode.map(playButtonLabel)
                    ?? (isLoadingEpisodes ? "Loading episodes…" : "Play"),
                action: handlePrimaryPlayTap,
                fullWidth: true
            )
            .disabled(nextUpEpisode == nil && !isLoadingEpisodes)

            PhoneLabeledActionRow {
                PhoneLabeledAction(
                    icon: "heart",
                    iconActive: "heart.fill",
                    isActive: isFavorite,
                    label: "Favorite",
                    accessibilityLabelOverride: isFavorite
                        ? "Remove from Favorites" : "Add to Favorites",
                    action: onToggleFavorite
                )
                PhoneLabeledAction(
                    icon: "bookmark",
                    iconActive: "bookmark.fill",
                    isActive: inWatchlist,
                    label: "Watchlist",
                    accessibilityLabelOverride: inWatchlist
                        ? "Remove from Watchlist" : "Add to Watchlist",
                    action: onToggleWatchlist
                )
                PhoneLabeledAction(
                    icon: "checkmark.circle",
                    iconActive: "checkmark.circle.fill",
                    isActive: isNextUpEpisodeWatched,
                    label: "Watched",
                    accessibilityLabelOverride: isNextUpEpisodeWatched
                        ? "Mark Episode Unwatched" : "Mark Episode Watched",
                    action: toggleNextUpEpisodeWatched
                )
                .disabled(isUpdatingWatched || nextUpEpisode == nil)
                if DownloadManager.shared.downloadsEnabled {
                    SeriesDownloadButton(
                        detail: detail,
                        seasons: seasons,
                        selectedSeason: selectedSeason,
                        episode: nextUpEpisode,
                        // The version the page shows, including an automatic pick.
                        episodeFileId: nextUpEpisode.flatMap(playbackFileId(for:)) ?? effectiveNextUpVersion?.fileId
                    )
                }
                PhoneLabeledMenu(label: "More") {
                    overflowMenuItems
                }
            }

            AutoDownloadBanner(
                seriesId: detail.seriesId ?? detail.contentId,
                seriesTitle: detail.title,
                seasons: seasons
            )

            if let trailerStatusMessage {
                PhoneTrailerStatusPill(
                    message: trailerStatusMessage,
                    isFetching: isFindingTrailers,
                    onAutoDismiss: onTrailerStatusShown
                )
            }

        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: trailerStatusMessage)
    }

    /// A fixed-height selector slot is the anchor that keeps the whole page
    /// still while a centered episode fetches its version/audio/subtitle data.
    /// Three 44pt rows are the normal selector footprint. The skeleton uses
    /// the identical card geometry, so neither the overview nor the episode
    /// carousel moves between loading and loaded states.
    private var playbackSelectorSlot: some View {
        ZStack(alignment: .top) {
            PhonePlaybackSelectorSkeleton()
                .opacity(isLoadingSelectedEpisodePlayback || effectiveNextUpVersion == nil ? 1 : 0)

            if let effectiveNextUpVersion {
                PhonePlaybackSelectorRow(
                    versions: nextUpVersions,
                    currentVersion: effectiveNextUpVersion,
                    selectedVersionFileId: selectedNextUpFileId,
                    selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                    onSelectVersion: onSelectNextUpVersion,
                    onSelectAudioTrack: onSelectNextUpAudioTrack,
                    onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
                )
                .opacity(isLoadingSelectedEpisodePlayback ? 0 : 1)
                .allowsHitTesting(!isLoadingSelectedEpisodePlayback)
            }
        }
        .frame(minHeight: PhonePlaybackSelectorSkeleton.standardHeight, alignment: .top)
        .animation(
            .easeInOut(duration: 0.16),
            value: isLoadingSelectedEpisodePlayback
        )
        .accessibilityElement(children: isLoadingSelectedEpisodePlayback ? .ignore : .contain)
        .accessibilityLabel(isLoadingSelectedEpisodePlayback ? "Loading playback options" : "Playback options")
    }

    /// Menu contents for the action row's named "More" entry.
    @ViewBuilder
    private var overflowMenuItems: some View {
        if canShuffleSeries {
            Button {
                shuffleLauncher.start(ShuffleScopeRequest(kind: .series, id: detail.seriesId ?? detail.contentId), router: router)
            } label: {
                Label("Shuffle Series", systemImage: "shuffle")
            }
            .disabled(shuffleLauncher.isStarting)
        }
        if let season = shuffleSeason {
            Button {
                shuffleLauncher.start(ShuffleScopeRequest(kind: .season, id: season.contentId), router: router)
            } label: {
                Label("Shuffle \(season.downloadDisplayName)", systemImage: "shuffle")
            }
            .disabled(shuffleLauncher.isStarting)
        }
        if canShuffleSeries || shuffleSeason != nil {
            Divider()
        }
        #if os(iOS)
        if let episode = nextUpEpisode {
            WatchPartyMenuButton(contentId: episode.contentId, title: episode.title ?? "Episode", type: "episode",
                fileId: playbackFileId(for: episode), episode: episode)
        }
        #endif
        if let selectedSeason {
            Button {
                setSeasonWatched(selectedSeason, !(selectedSeason.userData?.played ?? false))
            } label: {
                Label(
                    "Mark \(selectedSeason.downloadDisplayName) \(selectedSeason.userData?.played == true ? "Unwatched" : "Watched")",
                    systemImage: selectedSeason.userData?.played == true ? "circle" : "checkmark.circle"
                )
            }
            .disabled(isUpdatingWatched || selectedSeason.episodeCount == 0)
        }
        Button(action: onToggleWatched) {
            Label(
                isWatched ? "Mark Series Unwatched" : "Mark Series Watched",
                systemImage: isWatched ? "circle" : "checkmark.circle"
            )
        }
        .disabled(isUpdatingWatched)
        Divider()
        Button(action: onFindTrailers) {
            Label("Find Trailers", systemImage: "film")
        }
        .disabled(isFindingTrailers)
    }

    private var canShuffleSeries: Bool {
        ShuffleFeatureStore.shared.supports(.series)
            && ShuffleAvailability.hasEnoughToShuffle(playableCount: seasons.reduce(0) { $0 + $1.episodeCount })
    }

    /// The selected season, when it has at least two episodes with files.
    private var shuffleSeason: Season? {
        guard let selectedSeason, ShuffleFeatureStore.shared.supports(.season),
              !isLoadingEpisodes else { return nil }
        let playable = episodes.filter {
            $0.seasonNumber == selectedSeason.seasonNumber && !($0.files ?? []).isEmpty
        }
        return ShuffleAvailability.hasEnoughToShuffle(playableCount: playable.count) ? selectedSeason : nil
    }

    private func handlePlayTap(for episode: EpisodeListItem) {
        resumeLookupTask?.cancel()
        resumeLookupTask = Task {
            let state = await refreshResumeState(episode.contentId)
            guard !Task.isCancelled else { return }
            resumeLookupTask = nil
            if let position = state.resumePosition(cached: episode.userData) {
                pendingResume = PendingResume(episode: episode, position: position)
            } else {
                onPlayEpisode(episode.contentId, playbackFileId(for: episode), false, nil)
            }
        }
    }

    private func handlePrimaryPlayTap() {
        guard let nextUpEpisode else {
            pendingEpisodePlayRequest = PendingEpisodePlayRequest(
                seasonNumber: selectedSeason?.seasonNumber
            )
            return
        }
        pendingEpisodePlayRequest = nil
        handlePlayTap(for: nextUpEpisode)
    }

    private func handleSeasonSelection(_ season: Season) {
        pendingEpisodePlayRequest = nil
        onSelectSeason(season)
    }

    private func setSeasonWatched(_ season: Season, _ played: Bool) {
        guard !isUpdatingWatched else { return }
        isUpdatingWatched = true
        Task {
            defer { isUpdatingWatched = false }
            reportWatchedOutcome(await onSetSeasonWatched(season, played))
        }
    }

    private var isNextUpEpisodeWatched: Bool {
        nextUpEpisode?.userData?.played ?? false
    }

    /// The action row's Watched button targets the episode the page is on.
    /// Pin it as the selection first: otherwise marking the fallback next-up
    /// episode watched would move the page to the following unwatched one.
    /// Pin unconditionally, because `selectedEpisodeContentId` already
    /// reports the fallback episode when nothing is explicitly selected.
    private func toggleNextUpEpisodeWatched() {
        guard let episode = nextUpEpisode else { return }
        handleEpisodeSelection(episode.contentId)
        setEpisodeWatched(episode, !isNextUpEpisodeWatched)
    }

    private func setEpisodeWatched(_ episode: EpisodeListItem, _ played: Bool) {
        guard !isUpdatingWatched else { return }
        isUpdatingWatched = true
        Task {
            defer { isUpdatingWatched = false }
            reportWatchedOutcome(await onSetEpisodeWatched(episode, played))
        }
    }

    private func reportWatchedOutcome(_ outcome: PersonalStateOutcome) {
        switch outcome {
        case .applied: watchedAppliedCount += 1
        case .skipped: break
        // An update requirement uses the shared notice, which names the update
        // instead of asking the viewer to check the connection.
        case .failed(nil): watchedUpdateFailed = true
        case .failed, .held: watchedNotice = PersonalStateNotice(outcome)
        }
    }

    private func handleEpisodeSelection(_ contentId: String) {
        pendingEpisodePlayRequest = nil
        onEpisodeTap(contentId)
    }

    /// Next-up episode for the series Play button: prefer one in
    /// progress, then the first unwatched in the selected season,
    /// then fall back to the first episode we have.
    private var nextUpEpisode: EpisodeListItem? {
        if let selectedEpisodeContentId,
           let selected = episodes.first(where: {
               $0.contentId == selectedEpisodeContentId
           }) {
            return selected
        }
        return episodes.preferredResumeEpisode()
    }

    /// "Resume S2·E5" when the tap offers to resume, else "Play S2·E5". The
    /// confirmation dialog still lets the user restart instead.
    private func playButtonLabel(for episode: EpisodeListItem) -> String {
        DetailPlayLabel.episode(episode)
    }

    private var resumeTimestamp: String {
        guard let pos = pendingResume?.position else { return "0:00" }
        return PlayerTimeFormatter.formatHMS(pos)
    }

    /// Version/audio/subtitle state belongs only to the currently selected
    /// episode. A centered Play tap on another card starts that episode using
    /// server defaults instead of leaking the selected episode's track ids.
    private func playbackFileId(for episode: EpisodeListItem) -> Int? {
        guard episode.contentId == nextUpEpisode?.contentId else { return nil }
        return selectedFileId(for: episode)
    }

    private func selectedFileId(for episode: EpisodeListItem) -> Int? {
        guard let selectedNextUpFileId else {
            return nil
        }
        if let versions = nextUpWatchDetail?.versions, !versions.isEmpty {
            return versions.contains(where: { $0.fileId == selectedNextUpFileId })
                ? selectedNextUpFileId
                : nil
        }
        guard (episode.files ?? []).contains(where: { $0.fileId == selectedNextUpFileId }) else { return nil }
        return selectedNextUpFileId
    }

    private var nextUpVersions: [FileVersion] {
        nextUpWatchDetail?.versions ?? []
    }

    private var effectiveNextUpVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: nextUpVersions,
            selectedFileId: selectedNextUpFileId,
            lastFileId: nextUpWatchDetail?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    // MARK: - Below the fold

    private var belowFold: some View {
        VStack(alignment: .leading, spacing: 36) {
            episodesSection
            if let cast = detail.cast, !cast.isEmpty {
                castSection(cast: cast)
            }
            trailersSection
            detailsSection
                .padding(.horizontal, SiloTheme.safePadding)
            similarSection
        }
    }

    // MARK: - Trailers & extras

    /// Hidden — header and all — when the series has neither remote videos
    /// nor local extras. The emptiness test lives here rather than only
    /// inside the rail so the surrounding VStack doesn't reserve a 36pt gap
    /// for a section that renders nothing.
    ///
    /// `allowRemote` is unconditionally true: iOS, iPadOS, and macOS hand
    /// remote trailers to the YouTube app through an external deep link.
    @ViewBuilder
    private var trailersSection: some View {
        let entries = TrailerRail.entries(
            videos: detail.videos,
            extras: detail.extras,
            allowRemote: true
        )
        if !entries.isEmpty {
            PhoneTrailersSection(entries: entries, onPlayExtra: onPlayExtra)
        }
    }

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        PhoneSimilarRail(
            contentId: detail.contentId,
            onSelect: onNavigateToItem
        )
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if seasons.isEmpty {
                HStack(spacing: 10) {
                    ForEach(0..<3) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.secondary.opacity(0.12))
                            .frame(width: 100, height: 36)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, SiloTheme.safePadding)
                .opacity(isLoadingEpisodes ? 1 : 0)
                .accessibilityHidden(!isLoadingEpisodes)
                .accessibilityLabel("Loading seasons")
            } else {
                PhoneSeasonChips(
                    seasons: seasons,
                    selected: selectedSeason,
                    onSelect: handleSeasonSelection,
                    onSetWatched: setSeasonWatched,
                    isUpdatingWatched: isUpdatingWatched
                )
            }

            PhoneSectionHeader(
                title: episodeSectionTitle,
                trailingText: episodeCountSubtitle
            )
            .padding(.horizontal, SiloTheme.safePadding)

            ZStack(alignment: .topLeading) {
                PhoneEpisodeRailSkeleton(captionStyleOverride: .titleMetadata)
                    .hidden()
                VStack(alignment: .leading, spacing: 14) {
                    if let hierarchyError {
                        HStack {
                            Text(hierarchyError)
                            Button("Retry") {
                                pendingEpisodePlayRequest = nil
                                hierarchyRetryTask?.cancel()
                                hierarchyRetryTask = Task { await onRetryHierarchy() }
                            }
                        }
                        .padding(.horizontal, SiloTheme.safePadding)
                    }

                    if hierarchyError == nil && !isLoadingEpisodes && seasons.isEmpty {
                        Text("No episodes available")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, SiloTheme.safePadding)
                    } else if hierarchyError == nil || !episodes.isEmpty {
                        PhoneEpisodeCarousel(
                            episodes: episodes,
                            isLoading: isLoadingEpisodes,
                            onSelect: handleEpisodeSelection,
                            onPlay: { contentId in
                                guard let episode = episodes.first(where: {
                                    $0.contentId == contentId
                                }) else { return }
                                handlePlayTap(for: episode)
                            },
                            currentContentId: nextUpEpisode?.contentId,
                            selectsCenteredEpisode: true,
                            captionStyleOverride: .titleMetadata,
                            onSetWatched: setEpisodeWatched,
                            isUpdatingWatched: isUpdatingWatched,
                            favoriteStates: episodeFavoriteStates,
                            watchlistStates: episodeWatchlistStates,
                            onSetFavorite: onSetEpisodeFavorite,
                            onSetWatchlist: onSetEpisodeWatchlist
                        )
                    }
                }
            }
        }
    }

    private var episodeSectionTitle: String {
        guard let selectedSeason else { return "Episodes" }
        return "\(selectedSeason.downloadDisplayName) Episodes"
    }

    private var episodeCountSubtitle: String? {
        guard let count = selectedSeason?.episodeCount, count > 0 else { return nil }
        return "\(count) episode\(count == 1 ? "" : "s")"
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Cast & Crew")
                .padding(.horizontal, SiloTheme.safePadding)
            PhoneCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Details")
            PhoneDetailFactsSection(detail: detail)
        }
    }
}
#endif
