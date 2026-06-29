#if !os(tvOS)
import SwiftUI

/// Phone movie / episode detail screen. Cinematic backdrop hero up
/// top, then a scrollable body of episode rail (when applicable),
/// cast, "About", and the Details key/value list.
///
/// Mirrors `TVMovieDetailView` semantically — same hero metadata,
/// same primary play + circle action row, same single consolidated
/// version selector — but every element is sized and laid out for
/// touch on a phone.
struct MovieDetailContent: View {
    let detail: ItemDetail
    /// Owning view model — lent to the on-view description-translation
    /// affordance so a refreshed (translated) detail re-renders in place.
    let viewModel: ItemDetailViewModel
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    let seasons: [Season]
    let selectedSeason: Season?
    let seasonEpisodes: [EpisodeListItem]
    let isLoadingEpisodes: Bool
    let onPlay: (_ startFromBeginning: Bool) -> Void
    let onSelectVersion: (Int?) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let onSelectSeason: (Season) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    let onEpisodeTap: (String) -> Void

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
            onPlay(false)
        } onRestart: {
            onPlay(true)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        PhoneDetailHero(
            title: detail.title,
            seriesTitle: detail.type == "episode" ? detail.seriesTitle : nil,
            logoUrl: detail.logoUrl,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: detail.type == "episode" ? nil : PhoneHeroMetadata.eyebrow(from: detail),
            sourceTokens: PhoneHeroMetadata.movieSourceTokens(from: detail),
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: PhoneHeroMetadata.movieFactsLine(from: detail, version: effectiveVersion),
            overlayData: OverlayData.from(detail),
            actions: { actionStack },
            belowOverview: {
                AnyView(
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                )
            }
        )
    }

    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 12) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: primaryPlayLabel,
                action: handlePlayTap,
                fullWidth: true
            )
            circleRow
            if let effectiveVersion {
                PhonePlaybackSelectorRow(
                    versions: availableVersions,
                    currentVersion: effectiveVersion,
                    selectedVersionFileId: selectedVersionFileId,
                    selectedAudioTrackIndex: selectedAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                    onSelectVersion: onSelectVersion,
                    onSelectAudioTrack: onSelectAudioTrack,
                    onSelectSubtitleTrack: onSelectSubtitleTrack
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func handlePlayTap() {
        if hasResumeProgress {
            showResumeDialog = true
        } else {
            onPlay(false)
        }
    }

    /// Centered cluster of secondary toggles. The full-width Play sits
    /// above; circle toggles balance under it horizontally.
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
                accessibilityLabel: isWatched ? watchedLabelUnmark : watchedLabelMark,
                action: onToggleWatched
            )

            if hasOverflowNavigation {
                overflowMenu
            }
        }
    }

    private var hasOverflowNavigation: Bool {
        detail.type == "episode" && detail.seriesId != nil
    }

    @ViewBuilder
    private var overflowMenu: some View {
        PhoneCircleMenuButton(accessibilityLabel: "More options") {
            if let seriesId = detail.seriesId,
               let seasonNumber = detail.seasonNumber, seasonNumber > 0 {
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

    // MARK: - Below the fold

    private var belowFold: some View {
        VStack(alignment: .leading, spacing: 36) {
            if showsEpisodeRail {
                episodesSection
            }

            if let cast = detail.cast, !cast.isEmpty {
                castSection(cast: cast)
            }

            detailsSection
                .padding(.horizontal, ContinuumTheme.safePadding)

            if showsSimilarRail {
                similarSection
            }
        }
    }

    // MARK: - Episode rail (episode detail page)

    private var showsEpisodeRail: Bool {
        detail.type == "episode" && !seasonEpisodes.isEmpty
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(label: episodeRailEyebrow, title: "Episodes")
                .padding(.horizontal, ContinuumTheme.safePadding)

            if seasons.count > 1 {
                PhoneSeasonChips(
                    seasons: seasons,
                    selected: selectedSeason,
                    onSelect: onSelectSeason
                )
            }

            if isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().tint(.continuumOnSurface).padding()
                    Spacer()
                }
            } else {
                PhoneEpisodeRail(
                    episodes: seasonEpisodes,
                    onSelect: onEpisodeTap,
                    currentContentId: detail.contentId
                )
            }
        }
    }

    private var episodeRailEyebrow: String {
        if let seasonNumber = detail.seasonNumber, seasonNumber > 0 {
            return "Season \(seasonNumber)"
        }
        return "This Season"
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

    // MARK: - More Like This

    /// Hide the similar rail on episode pages — viewers usually want
    /// the next episode, not a tangentially related title; the season
    /// episode rail above already serves browsing.
    private var showsSimilarRail: Bool {
        detail.type != "episode"
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

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(label: "Info", title: "Details")
            PhoneDetailFactsSection(detail: detail)
        }
    }

    // MARK: - Resume / play helpers

    private var resumePositionSeconds: Double? {
        guard let pos = detail.userData?.positionSeconds, pos > 30 else { return nil }
        if let dur = detail.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
    }

    private var hasResumeProgress: Bool { resumePositionSeconds != nil }

    /// Play button label. For episodes we surface the S/E so the user
    /// can confirm which sibling they're about to start; movies and
    /// other one-off items just read "Play".
    private var primaryPlayLabel: String {
        if detail.type == "episode",
           let season = detail.seasonNumber,
           let episode = detail.episodeNumber {
            if season == 0 { return "Play E\(episode)" }
            return "Play S\(season)·E\(episode)"
        }
        return "Play"
    }

    private var resumeTimestamp: String {
        guard let pos = resumePositionSeconds else { return "0:00" }
        return PlayerTimeFormatter.formatHMS(pos)
    }

    private var watchedLabelMark: String {
        detail.type == "episode" ? "Mark Episode Watched" : "Mark as Watched"
    }

    private var watchedLabelUnmark: String {
        detail.type == "episode" ? "Mark Episode Unwatched" : "Mark as Unwatched"
    }

    // MARK: - Versions

    private var availableVersions: [FileVersion] {
        detail.versions ?? []
    }

    private var effectiveVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: availableVersions,
            selectedFileId: selectedVersionFileId,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }
}
#endif
