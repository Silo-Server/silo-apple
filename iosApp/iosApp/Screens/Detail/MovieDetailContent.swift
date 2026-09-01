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
    let seasonEpisodesBySeason: [Int: [EpisodeListItem]]
    let isLoadingEpisodes: Bool
    let episodeSeriesPosterUrl: String?
    let episodeSeriesPosterThumbhash: String?
    let episodeSeriesLogoUrl: String?
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
    /// Play a local extra from the trailers rail. Routed separately from
    /// `onPlay` because extras are never downloadable and have no resume
    /// point — see `ItemDetailView` for why they skip the offline/cast gates.
    let onPlayExtra: (String) -> Void
    /// Kick off the manual "Find Trailers" fetch (movies only).
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
    /// Presents the DownloadActionButton's options sheet; lives here so the
    /// overflow menu can open it now that a plain tap downloads directly.
    @State private var showDownloadOptions = false

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
            isPresented: $showResumeDialog,
            stoppedAt: resumeTimestamp
        ) {
            onPlay(false)
        } onRestart: {
            onPlay(true)
        }
    }

    private var heroToContentSpacing: CGFloat {
        horizontalSizeClass == .regular ? 16 : 32
    }

    // MARK: - Hero

    private var hero: some View {
        let posterArtwork = heroPosterArtwork
        return PhoneDetailHero(
            title: detail.title,
            seriesTitle: detail.type == "episode" ? detail.seriesTitle : nil,
            logoUrl: detail.type == "episode"
                ? (episodeSeriesLogoUrl ?? detail.logoUrl)
                : detail.logoUrl,
            posterUrl: posterArtwork.url,
            posterThumbhash: posterArtwork.thumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: detail.type == "episode" ? nil : PhoneHeroMetadata.eyebrow(from: detail),
            sourceTokens: PhoneHeroMetadata.movieSourceTokens(from: detail),
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: PhoneHeroMetadata.movieFactsLine(from: detail, version: effectiveVersion),
            creditText: PhoneHeroMetadata.creditText(from: detail),
            overlayData: OverlayData.from(detail),
            actions: { actionStack },
            belowOverview: {
                VStack(spacing: 14) {
                    belowOverview()
                    if let effectiveVersion {
                        playbackSelectors(for: effectiveVersion)
                    }
                }
            }
        )
    }

    /// Episodes carry wide stills as their own artwork. The portrait slot
    /// instead follows the episode hierarchy: its season poster, then the
    /// parent series poster. Browsing another season below the hero does not
    /// change this because the lookup stays anchored to `detail.seasonNumber`.
    private var heroPosterArtwork: (url: String?, thumbhash: String?) {
        guard detail.type == "episode" else {
            return (detail.posterUrl, detail.posterThumbhash)
        }

        if let seasonNumber = detail.seasonNumber,
           let season = seasons.first(where: { $0.seasonNumber == seasonNumber }),
           let url = nonEmptyArtworkURL(season.posterUrl) {
            return (url, season.posterThumbhash)
        }

        if let url = nonEmptyArtworkURL(episodeSeriesPosterUrl) {
            return (url, episodeSeriesPosterThumbhash)
        }

        return (nil, nil)
    }

    private func nonEmptyArtworkURL(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Play, then the named secondary actions, then the playback
    /// selectors. See `PhoneDetailActionRow` for why the circles went away.
    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 14) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: primaryPlayLabel,
                action: handlePlayTap,
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
                        ? watchedLabelUnmark : watchedLabelMark,
                    action: onToggleWatched
                )
                if showsDownloadButton {
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
    /// it, so the menu is what keeps the options sheet discoverable. Movies
    /// always earn it, because "Find Trailers" is the only entry point to the
    /// trailer fetch.
    private var hasOverflowMenu: Bool {
        hasOverflowNavigation || showsDownloadButton || detail.type == "movie"
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
        if detail.type == "movie" {
            Button(action: onFindTrailers) {
                Label("Find Trailers", systemImage: "film")
            }
            .disabled(isFindingTrailers)
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

            trailersSection

            detailsSection
                .padding(.horizontal, ContinuumTheme.safePadding)

            if showsSimilarRail {
                similarSection
            }
        }
    }

    // MARK: - Trailers & extras

    /// Hidden — header and all — when the item has neither remote videos nor
    /// local extras. The emptiness test lives here rather than only inside
    /// the rail so the surrounding VStack doesn't reserve a 36pt gap for a
    /// section that renders nothing.
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

    // MARK: - Episode rail (episode detail page)

    private var showsEpisodeRail: Bool {
        detail.type == "episode"
            && (!seasons.isEmpty || !seasonEpisodes.isEmpty || isLoadingEpisodes)
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !seasons.isEmpty {
                PhoneSeasonChips(
                    seasons: seasons,
                    selected: selectedSeason,
                    onSelect: onSelectSeason
                )
            }

            PhoneSectionHeader(title: "\(episodeRailEyebrow) Episodes")
                .padding(.horizontal, ContinuumTheme.safePadding)

            PhoneSeasonEpisodeBrowser(
                seasons: seasons,
                selectedSeason: selectedSeason,
                episodes: seasonEpisodes,
                episodesBySeason: seasonEpisodesBySeason,
                isLoadingEpisodes: isLoadingEpisodes,
                onSelectSeason: onSelectSeason,
                onSelectEpisode: onEpisodeTap,
                currentContentId: detail.contentId,
                showsSeasonSelector: false
            )
        }
    }

    private var episodeRailEyebrow: String {
        if let seasonNumber = selectedSeason?.seasonNumber ?? detail.seasonNumber,
           seasonNumber > 0 {
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
