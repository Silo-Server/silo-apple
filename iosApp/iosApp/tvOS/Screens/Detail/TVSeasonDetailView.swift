#if os(tvOS)
import SwiftUI

/// Season detail layout for tvOS. Scoped to a single season of a series:
/// the hero's eyebrow carries the parent-series title, the title line is
/// the season's own ("Season 2" / "Specials"), and the below-fold body
/// shows just this season's episode rail plus cast, details, and about.
///
/// Play button targets the next-up episode *within this season* (resume
/// if an episode is in progress, otherwise the first unwatched one).
/// Mark Watched targets the season, which the server fans out to every
/// leaf episode.
struct TVSeasonDetailView<BelowSynopsis: View>: View {
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
    let nextUpPlaybackDetail: ItemDetail?
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onEpisodeTap: (_ contentId: String) -> Void
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
    /// site (which owns the view model) and rendered under the synopsis.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Namespace private var detailFocusNamespace
    @FocusState private var playFocused: Bool
    /// Season whose next-up Play button has already auto-claimed focus. Keyed on
    /// the season (not a bare Bool) so we auto-focus Play once per season: the
    /// first async next-up resolve AND an in-place season switch — same view
    /// instance, `selectedSeason` mutates — both re-focus Play, while never
    /// yanking focus back within the same season once the viewer moves on.
    @State private var autoFocusedSeasonKey: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                TVDetailHero(
                    title: detail.title,
                    seriesTitle: nil,
                    logoUrl: nil,
                    backdropUrl: detail.backdropUrl,
                    eyebrow: detail.seriesTitle,
                    sourceTokens: sourceTokens,
                    ratingChip: nil,
                    overview: detail.overview,
                    tagline: detail.tagline,
                    factsLine: [],
                    starringText: TVHeroMetadata.starringText(from: detail),
                    actions: { actionColumn },
                    belowSynopsis: belowSynopsis
                )

                VStack(alignment: .leading, spacing: 72) {
                    episodeSection
                    if let cast = detail.cast, !cast.isEmpty {
                        castSection(cast: cast)
                    }
                    detailsSection
                }
                .padding(.horizontal, ContinuumTheme.safePadding)
                .padding(.bottom, 160)
            }
        }
        .ignoresSafeArea()
        .focusScope(detailFocusNamespace)
        .defaultFocus($playFocused, true, priority: .userInitiated)
        .onChange(of: nextUpEpisode?.contentId) { _, newValue in
            guard newValue != nil else { return }
            let seasonKey = selectedSeason?.contentId ?? ""
            guard autoFocusedSeasonKey != seasonKey else { return }
            autoFocusedSeasonKey = seasonKey
            playFocused = true
        }
    }

    // MARK: - Hero actions

    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionRow
            if nextUpEpisode != nil {
                TVPlaybackSelectorRow(
                    versions: nextUpVersions,
                    currentVersion: effectiveNextUpVersion,
                    selectedVersionFileId: selectedNextUpFileId,
                    selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                    subtitleMode: nextUpPlaybackDetail?.effectiveSubtitleMode,
                    subtitleSignature: nextUpPlaybackDetail?.effectiveSubtitleTrackSignature,
                    onSelectVersion: onSelectNextUpVersion,
                    onSelectAudioTrack: onSelectNextUpAudioTrack,
                    onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
                )
            }
        }
    }

    private var nextUpVersions: [FileVersion] {
        nextUpPlaybackDetail?.versions ?? []
    }

    private var actionRow: some View {
        HStack(spacing: 36) {
            if let nextUp = nextUpEpisode {
                TVPrimaryPillButton(
                    icon: "play.fill",
                    title: playButtonLabel(for: nextUp),
                    action: { onPlayEpisode(nextUp.contentId, selectedNextUpFileId, false) },
                    focused: $playFocused
                )
                if nextUp.userData?.isInProgress == true {
                    TVSecondaryPillButton(
                        icon: "backward.end.fill",
                        title: "Start Over",
                        action: { onPlayEpisode(nextUp.contentId, selectedNextUpFileId, true) }
                    )
                }
            }

            TVCircleActionButton(
                icon: "heart",
                iconActive: "heart.fill",
                isActive: isFavorite,
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                action: onToggleFavorite
            )

            TVCircleActionButton(
                icon: "bookmark",
                iconActive: "bookmark.fill",
                isActive: inWatchlist,
                accessibilityLabel: inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                action: onToggleWatchlist
            )

            TVCircleActionButton(
                icon: "checkmark.circle",
                iconActive: "checkmark.circle.fill",
                isActive: isWatched,
                accessibilityLabel: isWatched ? "Mark Season Unwatched" : "Mark Season Watched",
                action: onToggleWatched
            )

            if hasMoreMenu {
                moreMenu
            }
        }
    }

    private var hasMoreMenu: Bool {
        detail.seriesId != nil
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(accessibilityLabel: "More options") {
            if let seriesId = detail.seriesId {
                Button {
                    onNavigateToItem(seriesId)
                } label: {
                    Label("Go to Series", systemImage: "tv")
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

    private func playButtonLabel(for episode: EpisodeListItem) -> String {
        if episode.userData?.isInProgress == true {
            return "Resume E\(episode.episodeNumber)"
        }
        return "Play E\(episode.episodeNumber)"
    }

    private var effectiveNextUpVersion: FileVersion? {
        let versions = nextUpPlaybackDetail?.versions ?? []
        if let selectedNextUpFileId,
           let selected = versions.first(where: { $0.fileId == selectedNextUpFileId }) {
            return selected
        }
        if let lastFileId = nextUpPlaybackDetail?.userData?.lastFileId,
           let lastVersion = versions.first(where: { $0.fileId == lastFileId }) {
            return lastVersion
        }
        return versions.first
    }

    // MARK: - Source row tokens

    private var sourceTokens: [String] {
        var tokens: [String] = []
        if let count = detail.episodeCount, count > 0 {
            tokens.append("\(count) Episode\(count == 1 ? "" : "s")")
        } else if !episodes.isEmpty {
            tokens.append("\(episodes.count) Episode\(episodes.count == 1 ? "" : "s")")
        }
        if let genres = detail.genres, !genres.isEmpty {
            tokens.append(contentsOf: genres.prefix(2))
        }
        return tokens
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(label: "This Season", title: "Episodes")
            if seasons.count > 1 {
                TVSeasonChipRow(
                    seasons: seasons,
                    selectedSeasonId: selectedSeason?.id,
                    onSelect: onSelectSeason
                )
            }
            if isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().tint(.continuumOnSurface).padding()
                    Spacer()
                }
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.continuumSecondaryText)
            } else {
                TVEpisodeRail(
                    episodes: episodes,
                    onSelect: onEpisodeTap,
                    currentContentId: nextUpEpisode?.contentId
                )
            }
        }
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }
}
#endif
