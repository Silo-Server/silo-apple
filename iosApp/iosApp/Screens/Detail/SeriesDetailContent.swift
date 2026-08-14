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
    @State private var showResumeDialog = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: heroToContentSpacing) {
                hero
                belowFold
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .continuumResumePlaybackAlert(
            isPresented: $showResumeDialog,
            stoppedAt: resumeTimestamp
        ) {
            guard let nextUp = nextUpEpisode else { return }
            onPlayEpisode(nextUp.contentId, selectedFileId(for: nextUp), false)
        } onRestart: {
            guard let nextUp = nextUpEpisode else { return }
            onPlayEpisode(nextUp.contentId, selectedFileId(for: nextUp), true)
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
            overlayData: OverlayData.from(detail),
            actions: { actionStack },
            belowOverview: belowOverview
        )
    }

    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 16) {
            if let nextUp = nextUpEpisode {
                PhoneRefinedPlayButton(
                    icon: "play.fill",
                    title: playButtonLabel(for: nextUp),
                    action: { handlePlayTap(for: nextUp) }
                )
            }

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
                    label: isWatched ? "Watched" : "Mark Seen",
                    accessibilityLabelOverride: isWatched
                        ? "Mark Series Unwatched" : "Mark Series Watched",
                    action: onToggleWatched
                )
                if DownloadManager.shared.downloadsEnabled {
                    // Season downloads and future-episode monitoring live
                    // behind this control; without it the series page has no
                    // download entry point at all.
                    SeriesDownloadMenuButton(
                        detail: detail,
                        seasons: seasons,
                        selectedSeason: selectedSeason,
                        style: .labeled
                    )
                }
                // The series page has no other overflow entries today; the
                // menu exists solely so the trailer fetch is reachable.
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

            if nextUpEpisode != nil, let effectiveNextUpVersion {
                nextUpSelectors(for: effectiveNextUpVersion)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: trailerStatusMessage)
    }

    /// Menu contents for the action row's named "More" entry.
    @ViewBuilder
    private var overflowMenuItems: some View {
        Button(action: onFindTrailers) {
            Label("Find Trailers", systemImage: "film")
        }
        .disabled(isFindingTrailers)
    }

    private func nextUpSelectors(for version: FileVersion) -> some View {
        PhonePlaybackSelectorRow(
            versions: nextUpVersions,
            currentVersion: version,
            selectedVersionFileId: selectedNextUpFileId,
            selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
            onSelectVersion: onSelectNextUpVersion,
            onSelectAudioTrack: onSelectNextUpAudioTrack,
            onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
        )
    }

    private func handlePlayTap(for episode: EpisodeListItem) {
        if episode.userData?.isInProgress == true {
            showResumeDialog = true
        } else {
            onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
        }
    }
    /// Next-up episode for the series Play button: prefer one in
    /// progress, then the first unwatched in the selected season,
    /// then fall back to the first episode we have.
    private var nextUpEpisode: EpisodeListItem? {
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
        guard let pos = nextUpResumePositionSeconds else { return "0:00" }
        return PlayerTimeFormatter.formatHMS(pos)
    }

    private var nextUpResumePositionSeconds: Double? {
        guard let pos = nextUpEpisode?.userData?.positionSeconds, pos > 30 else { return nil }
        if let dur = nextUpEpisode?.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
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
            PhoneSectionHeader(
                label: selectedSeason.map { "Season \($0.seasonNumber)" } ?? "Episodes",
                title: "Episodes",
                trailingText: episodeCountSubtitle
            )
            .padding(.horizontal, ContinuumTheme.safePadding)

            PhoneSeasonEpisodeBrowser(
                seasons: seasons,
                selectedSeason: selectedSeason,
                episodes: episodes,
                episodesBySeason: episodesBySeason,
                isLoadingEpisodes: isLoadingEpisodes,
                onSelectSeason: onSelectSeason,
                onSelectEpisode: onEpisodeTap
            )
        }
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
