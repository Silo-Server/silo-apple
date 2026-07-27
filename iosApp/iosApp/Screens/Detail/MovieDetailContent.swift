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
struct MovieDetailContent<BelowOverview: View>: View {
    let detail: ItemDetail
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
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @State private var showResumeDialog = false
    /// Presents the DownloadActionButton's options sheet; lives here so the
    /// overflow menu can open it now that a plain tap downloads directly.
    @State private var showDownloadOptions = false

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
            belowOverview: belowOverview
        )
    }

    /// Play, then the named secondary actions, then the playback
    /// selectors. See `PhoneDetailActionRow` for why the circles went away.
    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 16) {
            PhoneRefinedPlayButton(
                icon: "play.fill",
                title: primaryPlayLabel,
                action: handlePlayTap
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
                    label: isWatched ? "Watched" : "Mark Seen",
                    accessibilityLabelOverride: isWatched
                        ? watchedLabelUnmark : watchedLabelMark,
                    action: onToggleWatched
                )
                if showsDownloadButton {
                    // Captioned style, so it reads as a peer of the actions
                    // beside it rather than the odd circle out. It still owns
                    // its own progress ring and state-derived caption.
                    DownloadActionButton(
                        detail: detail,
                        versions: availableVersions,
                        selectedVersionFileId: selectedVersionFileId,
                        showOptions: $showDownloadOptions,
                        style: .labeled
                    )
                }
                if hasOverflowMenu {
                    PhoneLabeledMenu(label: "More") {
                        overflowMenuItems
                    }
                }
            }

            if let effectiveVersion {
                playbackSelectors(for: effectiveVersion)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func playbackSelectors(for version: FileVersion) -> some View {
        PhonePlaybackSelectorRow(
            versions: availableVersions,
            currentVersion: version,
            selectedVersionFileId: selectedVersionFileId,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
            onSelectVersion: onSelectVersion,
            onSelectAudioTrack: onSelectAudioTrack,
            onSelectSubtitleTrack: onSelectSubtitleTrack
        )
    }

    private func handlePlayTap() {
        if hasResumeProgress {
            showResumeDialog = true
        } else {
            onPlay(false)
        }
    }
    /// Download is offered for movies and individual episodes once the
    /// server advertises the capability for this profile.
    private var showsDownloadButton: Bool {
        DownloadManager.shared.downloadsEnabled
            && (detail.type == "movie" || detail.type == "episode")
    }

    private var hasOverflowNavigation: Bool {
        detail.type == "episode" && detail.seriesId != nil
    }

    /// Downloads also earn the overflow menu: a plain tap on Download starts
    /// it, so the menu is what keeps the options sheet discoverable.
    private var hasOverflowMenu: Bool {
        hasOverflowNavigation || showsDownloadButton
    }
    /// Menu contents for the action row's named "More" entry.
    @ViewBuilder
    private var overflowMenuItems: some View {
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
        if showsDownloadButton {
            Button {
                showDownloadOptions = true
            } label: {
                Label("Download Options…", systemImage: "slider.horizontal.3")
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
            PhoneSectionHeader(title: "Cast & Crew")
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
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        PhoneSimilarRail(
            contentId: detail.contentId,
            onSelect: onNavigateToItem
        )
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Details")
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
