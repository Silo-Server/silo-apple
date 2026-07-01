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
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @State private var showResumeDialog = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
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

    // MARK: - Hero

    private var hero: some View {
        PhoneDetailHero(
            title: detail.title,
            seriesTitle: nil,
            logoUrl: detail.logoUrl,
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
        VStack(spacing: 12) {
            if let nextUp = nextUpEpisode {
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: playButtonLabel(for: nextUp),
                    action: { handlePlayTap(for: nextUp) },
                    fullWidth: true
                )
            }
            circleRow
            if nextUpEpisode != nil, let effectiveNextUpVersion {
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
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func handlePlayTap(for episode: EpisodeListItem) {
        if episode.userData?.isInProgress == true {
            showResumeDialog = true
        } else {
            onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
        }
    }

    private var circleRow: some View {
        HStack(spacing: 14) {
            PhoneCircleActionButton(
                icon: "heart",
                iconActive: "heart.fill",
                isActive: isFavorite,
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                action: onToggleFavorite
            )

            PhoneCircleActionButton(
                icon: "bookmark",
                iconActive: "bookmark.fill",
                isActive: inWatchlist,
                accessibilityLabel: inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                action: onToggleWatchlist
            )

            PhoneCircleActionButton(
                icon: "checkmark.circle",
                iconActive: "checkmark.circle.fill",
                isActive: isWatched,
                accessibilityLabel: isWatched ? "Mark Series Unwatched" : "Mark Series Watched",
                action: onToggleWatched
            )

            if DownloadManager.shared.downloadsEnabled {
                SeriesDownloadMenuButton(
                    detail: detail,
                    seasons: seasons,
                    selectedSeason: selectedSeason
                )
            }
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
            detailsSection
                .padding(.horizontal, ContinuumTheme.safePadding)
            similarSection
        }
    }

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(label: "Recommended", title: "More Like This")
                .padding(.horizontal, ContinuumTheme.safePadding)
            PhoneSimilarRail(
                contentId: detail.contentId,
                onSelect: onNavigateToItem
            )
        }
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

            if seasons.count > 1 {
                PhoneSeasonChips(
                    seasons: seasons,
                    selected: selectedSeason,
                    onSelect: onSelectSeason
                )
            }

            episodeBody
        }
    }

    private var episodeCountSubtitle: String? {
        guard let count = selectedSeason?.episodeCount, count > 0 else { return nil }
        return "\(count) episode\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var episodeBody: some View {
        if selectedSeason == nil && seasons.isEmpty {
            EmptyView()
        } else if isLoadingEpisodes {
            HStack {
                Spacer()
                ProgressView().tint(.continuumOnSurface).padding()
                Spacer()
            }
        } else if episodes.isEmpty {
            Text("No episodes available")
                .font(.continuumCaption)
                .foregroundColor(.continuumSecondaryText)
                .padding(.horizontal, ContinuumTheme.safePadding)
        } else {
            PhoneEpisodeRail(
                episodes: episodes,
                onSelect: onEpisodeTap
            )
        }
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(label: "Cast", title: "& Crew")
                .padding(.horizontal, ContinuumTheme.safePadding)
            PhoneCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(label: "Info", title: "Details")
            PhoneDetailFactsSection(detail: detail)
        }
    }
}
#endif
