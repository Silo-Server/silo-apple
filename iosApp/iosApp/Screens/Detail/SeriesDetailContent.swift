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
    let episodesBySeason: [Int: [EpisodeListItem]]
    let isLoadingEpisodes: Bool
    let selectedNextUpFileId: Int?
    let selectedNextUpAudioTrackIndex: Int?
    let selectedNextUpSubtitleTrackIndex: Int?
    let nextUpWatchDetail: WatchDetail?
    let isLoadingSelectedEpisodePlayback: Bool
    let selectedEpisodeContentId: String?
    let onSelectSeason: (Season) -> Void
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onEpisodeTap: (String) -> Void
    let onSelectNextUpVersion: (Int?) -> Void
    let onSelectNextUpAudioTrack: (Int?) -> Void
    let onSelectNextUpSubtitleTrack: (Int?) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    /// Play a local extra from the trailers rail. Routed separately from
    /// `onPlayEpisode` because extras are never downloadable and have no
    /// resume point — see `ItemDetailView` for why they skip the
    /// offline/cast gates.
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
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingResumeEpisode: EpisodeListItem?
    private struct PendingEpisodePlayRequest: Equatable {
        let seasonNumber: Int?
    }
    /// A tap can arrive before the first episode page finishes hydrating.
    /// Keep the primary control interactive from frame one and fulfill that
    /// intent as soon as the target episode is known.
    @State private var pendingEpisodePlayRequest: PendingEpisodePlayRequest?

    var body: some View {
        PhoneDetailPageSurface(backdropURL: detail.backdropUrl) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: heroToContentSpacing) {
                    hero
                    belowFold
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
        }
        .continuumResumePlaybackAlert(
            isPresented: Binding(
                get: { pendingResumeEpisode != nil },
                set: { if !$0 { pendingResumeEpisode = nil } }
            ),
            stoppedAt: resumeTimestamp
        ) {
            guard let episode = pendingResumeEpisode else { return }
            onPlayEpisode(episode.contentId, playbackFileId(for: episode), false)
        } onRestart: {
            guard let episode = pendingResumeEpisode else { return }
            onPlayEpisode(episode.contentId, playbackFileId(for: episode), true)
        }
        .onChange(of: nextUpEpisode?.contentId) { _, contentID in
            guard let request = pendingEpisodePlayRequest, contentID != nil,
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
    }

    private var heroToContentSpacing: CGFloat {
        horizontalSizeClass == .regular ? 16 : 32
    }

    // MARK: - Hero

    private var hero: some View {
        PhoneDetailHero(
            title: detail.title,
            seriesTitle: nil,
            logoUrl: detail.logoUrl,
            posterUrl: detail.posterUrl,
            posterThumbhash: detail.posterThumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: PhoneHeroMetadata.eyebrow(from: detail),
            sourceTokens: PhoneHeroMetadata.seriesSourceTokens(from: detail),
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: PhoneHeroMetadata.seriesFactsLine(from: detail),
            creditText: PhoneHeroMetadata.creditText(from: detail),
            overlayData: OverlayData.from(detail),
            actions: { actionStack },
            // Match MovieDetailContent exactly through the playback controls:
            // Play/actions, show overview and credits, translation affordance,
            // then selectors. Seasons and episodes are the only series-only
            // extension and begin immediately after this shared hero.
            belowOverview: {
                VStack(spacing: 14) {
                    belowOverview()
                    if nextUpEpisode != nil {
                        playbackSelectorSlot
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 14) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: nextUpEpisode.map(playButtonLabel) ?? "Play",
                action: handlePrimaryPlayTap,
                fullWidth: true
            )

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
                    isActive: isWatched,
                    label: "Watched",
                    accessibilityLabelOverride: isWatched
                        ? "Mark Series Unwatched" : "Mark Series Watched",
                    action: onToggleWatched
                )
                if DownloadManager.shared.downloadsEnabled {
                    SeriesDownloadMenuButton(
                        detail: detail,
                        seasons: seasons,
                        selectedSeason: selectedSeason,
                        style: .labeled
                    )
                }
                PhoneLabeledMenu(label: "More") {
                    overflowMenuItems
                }
            }

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
        Button(action: onFindTrailers) {
            Label("Find Trailers", systemImage: "film")
        }
        .disabled(isFindingTrailers)
    }

    private func handlePlayTap(for episode: EpisodeListItem) {
        if episode.userData?.isInProgress == true {
            pendingResumeEpisode = episode
        } else {
            onPlayEpisode(episode.contentId, playbackFileId(for: episode), false)
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
        if let inProgress = episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return episodes.first
    }

    /// Show "Play S2·E5" — the user can decide resume vs. restart in
    /// the confirmation dialog the button presents.
    private func playButtonLabel(for episode: EpisodeListItem) -> String {
        "Play S\(episode.seasonNumber)·E\(episode.episodeNumber)"
    }

    private var resumeTimestamp: String {
        guard let pos = resumePositionSeconds(for: pendingResumeEpisode) else { return "0:00" }
        return PlayerTimeFormatter.formatHMS(pos)
    }

    private func resumePositionSeconds(for episode: EpisodeListItem?) -> Double? {
        guard let pos = episode?.userData?.positionSeconds, pos > 30 else { return nil }
        if let dur = episode?.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
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
                .padding(.horizontal, ContinuumTheme.safePadding)
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
            if !seasons.isEmpty {
                PhoneSeasonChips(
                    seasons: seasons,
                    selected: selectedSeason,
                    onSelect: handleSeasonSelection
                )
            }

            PhoneSectionHeader(
                title: episodeSectionTitle,
                trailingText: episodeCountSubtitle
            )
            .padding(.horizontal, ContinuumTheme.safePadding)

            PhoneSeasonEpisodeBrowser(
                seasons: seasons,
                selectedSeason: selectedSeason,
                episodes: episodes,
                episodesBySeason: episodesBySeason,
                isLoadingEpisodes: isLoadingEpisodes,
                onSelectSeason: handleSeasonSelection,
                onSelectEpisode: handleEpisodeSelection,
                onPlayEpisode: { contentId in
                    guard let episode = episodes.first(where: {
                        $0.contentId == contentId
                    }) else { return }
                    handlePlayTap(for: episode)
                },
                currentContentId: nextUpEpisode?.contentId,
                selectsCenteredEpisode: true,
                showsSeasonSelector: false,
                forcesEpisodeCarousel: true,
                episodeCaptionStyleOverride: .titleMetadata
            )
        }
    }

    private var episodeSectionTitle: String {
        guard let selectedSeason else { return "Episodes" }
        let seasonLabel = selectedSeason.seasonNumber == 0
            ? (selectedSeason.title ?? "Specials")
            : "Season \(selectedSeason.seasonNumber)"
        return "\(seasonLabel) Episodes"
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
                .padding(.horizontal, ContinuumTheme.safePadding)
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
