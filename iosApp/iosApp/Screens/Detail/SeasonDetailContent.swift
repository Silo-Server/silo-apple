#if !os(tvOS)
import SwiftUI

/// Phone season detail screen. Scoped to a single season of a series:
/// the hero's eyebrow carries the parent-series title, the title line
/// is the season's own ("Season 2" / "Specials"), and the body shows
/// just this season's episode rail plus cast, details, and about.
///
/// Mirrors `TVSeasonDetailView` semantically — same next-up Play
/// targeting, same season-level Mark Watched fan-out — sized for
/// touch on a phone.
struct SeasonDetailContent<BelowOverview: View>: View {
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
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onEpisodeTap: (String) -> Void
    let onSelectSeason: (Season) -> Void
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
            onPlayEpisode(nextUp.contentId, selectedNextUpFileId, false)
        } onRestart: {
            guard let nextUp = nextUpEpisode else { return }
            onPlayEpisode(nextUp.contentId, selectedNextUpFileId, true)
        }
    }

    private var heroToContentSpacing: CGFloat {
        MobileDetailLayout.supportsExpandedPresentation && horizontalSizeClass == .regular
            ? 16
            : 32
    }

    // MARK: - Hero

    private var hero: some View {
        PhoneDetailHero(
            title: detail.title,
            seriesTitle: nil,
            logoUrl: nil,
            posterUrl: detail.posterUrl,
            posterThumbhash: detail.posterThumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: detail.seriesTitle,
            sourceTokens: PhoneHeroMetadata.seasonSourceTokens(
                from: detail,
                episodeCount: episodes.count
            ),
            ratingChip: nil,
            overview: detail.overview,
            factsLine: [],
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
            onPlayEpisode(episode.contentId, selectedNextUpFileId, false)
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
                accessibilityLabel: isWatched ? "Mark Season Unwatched" : "Mark Season Watched",
                action: onToggleWatched
            )

            if DownloadManager.shared.downloadsEnabled {
                SeriesDownloadMenuButton(
                    detail: detail,
                    seasons: seasons,
                    selectedSeason: selectedSeason ?? seasons.first(where: { $0.seasonNumber == detail.seasonNumber })
                )
            }

            if let seriesId = detail.seriesId {
                PhoneCircleMenuButton(accessibilityLabel: "More options") {
                    Button {
                        onNavigateToItem(seriesId)
                    } label: {
                        Label("Go to Series", systemImage: "tv")
                    }
                }
            }
        }
    }

    private var nextUpEpisode: EpisodeListItem? {
        if let inProgress = episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return episodes.first
    }

    /// Show "Play E5" — the user picks resume vs. restart in the
    /// confirmation dialog the button presents.
    private func playButtonLabel(for episode: EpisodeListItem) -> String {
        "Play E\(episode.episodeNumber)"
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
            detailsSection.padding(.horizontal, ContinuumTheme.safePadding)
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(label: "This Season", title: "Episodes")
                .padding(.horizontal, ContinuumTheme.safePadding)

            PhoneSeasonEpisodeBrowser(
                seasons: seasons,
                selectedSeason: selectedSeason,
                episodes: episodes,
                episodesBySeason: episodesBySeason,
                isLoadingEpisodes: isLoadingEpisodes,
                onSelectSeason: onSelectSeason,
                onSelectEpisode: onEpisodeTap,
                allowsSeasonPaging: false
            )
        }
    }

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Cast & Crew")
                .padding(.horizontal, ContinuumTheme.safePadding)
            PhoneCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Details")
            PhoneDetailFactsSection(detail: detail)
        }
    }
}
#endif
