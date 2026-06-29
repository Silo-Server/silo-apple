#if os(tvOS)
import SwiftUI

/// Series detail layout for tvOS. Cinematic hero at the top; seasons +
/// a horizontal episode rail + cast + facts below.
struct TVSeriesDetailView: View {
    let detail: ItemDetail
    /// Owning view model — lent to the on-view description-translation
    /// affordance so a refreshed (translated) detail re-renders in place.
    let viewModel: ItemDetailViewModel
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
    let isLoadingNextUpPlaybackDetail: Bool
    let didLoadNextUpPlaybackDetail: Bool
    let onSelectSeason: (Season) -> Void
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onEpisodeTap: (_ contentId: String) -> Void
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
                    logoUrl: detail.logoUrl,
                    backdropUrl: detail.backdropUrl,
                    eyebrow: TVHeroMetadata.eyebrow(from: detail),
                    sourceTokens: TVHeroMetadata.seriesSourceTokens(from: detail),
                    ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
                    overview: detail.overview,
                    tagline: detail.tagline,
                    factsLine: TVHeroMetadata.seriesFactsLine(from: detail),
                    starringText: TVHeroMetadata.starringText(from: detail),
                    actions: { actionColumn },
                    belowSynopsis: {
                        AnyView(
                            DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        )
                    }
                )

                VStack(alignment: .leading, spacing: 72) {
                    episodeSection
                    if let cast = detail.cast, !cast.isEmpty {
                        castSection(cast: cast)
                    }
                    detailsSection
                    similarSection
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
            if shouldShowVersionPlaceholder {
                TVVersionPillPlaceholder()
            } else if nextUpEpisode != nil {
                TVPlaybackSelectorRow(
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
                    action: { onPlayEpisode(nextUp.contentId, selectedFileId(for: nextUp), false) },
                    focused: $playFocused
                )
                if nextUp.userData?.isInProgress == true {
                    TVSecondaryPillButton(
                        icon: "backward.end.fill",
                        title: "Start Over",
                        action: { onPlayEpisode(nextUp.contentId, selectedFileId(for: nextUp), true) }
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
                accessibilityLabel: isWatched ? "Mark Series Unwatched" : "Mark Series Watched",
                action: onToggleWatched
            )
        }
    }

    /// Best "Play" target for the series: an in-progress episode if there
    /// is one, otherwise the first unwatched in the selected season, else
    /// the first episode we loaded.
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
            return "Resume S\(episode.seasonNumber) · E\(episode.episodeNumber)"
        }
        return "Play S\(episode.seasonNumber) · E\(episode.episodeNumber)"
    }

    // MARK: - Next-up version picker

    private var shouldShowVersionPlaceholder: Bool {
        nextUpEpisode != nil
            && (isLoadingNextUpPlaybackDetail || (!didLoadNextUpPlaybackDetail && nextUpPlaybackDetail == nil))
    }

    private func selectedFileId(for episode: EpisodeListItem) -> Int? {
        guard let selectedNextUpFileId else { return nil }
        if let versions = nextUpPlaybackDetail?.versions, !versions.isEmpty {
            return versions.contains(where: { $0.fileId == selectedNextUpFileId })
                ? selectedNextUpFileId
                : nil
        }
        guard (episode.files ?? []).contains(where: { $0.fileId == selectedNextUpFileId }) else { return nil }
        return selectedNextUpFileId
    }

    private var effectiveNextUpVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: nextUpPlaybackDetail?.versions ?? [],
            selectedFileId: selectedNextUpFileId,
            lastFileId: nextUpPlaybackDetail?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    // MARK: - Episodes + season selector

    @ViewBuilder
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            episodeSectionHeader
            if seasons.count > 1 {
                seasonRow
            }
            episodeBody
        }
    }

    private var episodeSectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            TVSectionHeader(
                label: selectedSeason.map { "Season \($0.seasonNumber)" } ?? "Episodes",
                title: "Episodes"
            )
            Spacer()
            if let count = selectedSeason?.episodeCount, count > 0 {
                Text("\(count) episode\(count == 1 ? "" : "s")")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.continuumSecondaryText)
            }
        }
    }

    private var seasonRow: some View {
        TVSeasonChipRow(
            seasons: seasons,
            selectedSeasonId: selectedSeason?.id,
            onSelect: onSelectSeason
        )
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
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.continuumSecondaryText)
        } else {
            TVEpisodeRail(
                episodes: episodes,
                onSelect: onEpisodeTap
            )
        }
    }

    // MARK: - More Like This

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(label: "Recommended", title: "More Like This")
            TVSimilarRail(
                contentId: detail.contentId,
                onSelect: onNavigateToItem
            )
        }
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(label: "Cast", title: "& Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(label: "Info", title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }

}

#endif
