#if os(tvOS)
import SwiftUI

/// Movie / episode detail layout for tvOS. The hero fills the top of the
/// viewport; the scrollable body underneath contains cast, a full
/// overview, and facts. A pre-Play selector row beneath the primary
/// actions exposes Edition / Version / Audio / Subtitles, each auto-hiding
/// when there is no real choice.
struct TVMovieDetailView<BelowSynopsis: View>: View {
    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// True once the user explicitly resets subtitles to "Auto" this visit.
    /// The server override was just cleared, but `detail.effectiveSubtitle*`
    /// still describes the old manual pick until the next refetch — suppress
    /// it so the "Auto: …" preview doesn't echo the cleared selection.
    var subtitleOverrideCleared: Bool = false
    let seasons: [Season]
    let selectedSeason: Season?
    let seasonEpisodes: [EpisodeListItem]
    let episodeFavoriteStates: [String: Bool]
    let isLoadingEpisodes: Bool
    /// Merged remote-video + local-extra rail, already shaped by the call
    /// site (which owns the YouTube-app availability probe that decides
    /// whether remote cards exist at all). Empty hides the rail.
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    /// Whether the manual "Find Trailers" action can be offered — false on
    /// episode pages and when the YouTube app is unavailable.
    let supportsTrailerFetch: Bool
    let onFindTrailers: () -> Void
    /// Copy from the fetch coordinator; nil while idle.
    let trailerFetchStatus: String?
    let isFetchingTrailers: Bool
    /// Called once a terminal fetch message has been on screen long enough.
    let onTrailerStatusShown: () -> Void
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
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the synopsis.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var detailFocusNamespace
    @FocusState private var playFocused: Bool
    /// True while focus sits anywhere inside the season chip row — drives the
    /// episode-section re-center in `detailFocusScroll`.
    @FocusState private var seasonRowFocused: Bool
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool
    /// The first default-focus evaluation can run before the pushed page's
    /// button is registered, leaving focus on the geometrically higher
    /// synopsis. Reevaluate the scoped default once Play has been laid out.
    @State private var didResetInitialPlayFocus = false

    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "detail-episode-section"
    private let heroScrollId = "detail-hero"
    @State private var focusedEpisodeContentId: String?

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 48) {
                    TVDetailHero(
                        title: detail.title,
                        seriesTitle: detail.type == "episode" ? detail.seriesTitle : nil,
                        logoUrl: detail.logoUrl,
                        backdropUrl: detail.backdropUrl,
                        eyebrow: detail.type == "episode" ? nil : TVHeroMetadata.eyebrow(from: detail),
                        sourceTokens: TVHeroMetadata.movieSourceTokens(from: detail),
                        ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
                        overview: detail.overview,
                        factsLine: TVHeroMetadata.movieFactsLine(from: detail, version: currentVersion),
                        starringText: TVHeroMetadata.starringText(from: detail),
                        actions: { actionColumn },
                        belowSynopsis: belowSynopsis
                    )
                    .id(heroScrollId)

                    VStack(alignment: .leading, spacing: 72) {
                        if showsEpisodeRail {
                            episodesSection
                                .id(episodeSectionScrollId)
                        }
                        if let cast = detail.cast, !cast.isEmpty {
                            castSection(cast: cast)
                        }
                        trailersSection
                        detailsSection
                        if showsSimilarRail {
                            similarSection
                        }
                    }
                    .padding(.horizontal, ContinuumTheme.safePadding)
                    .padding(.bottom, 160)
                }
            }
            .ignoresSafeArea()
            .focusScope(detailFocusNamespace)
            .defaultFocus($playFocused, true, priority: .userInitiated)
            .detailFocusScroll(
                proxy: scrollProxy,
                seasonRowFocused: seasonRowFocused,
                actionRowFocused: actionRowFocused,
                episodeSectionId: episodeSectionScrollId,
                heroId: heroScrollId
            )
            .onPlayPauseCommand(perform: playFocusedEpisodeOrCurrent)
        }
    }

    // MARK: - Hero actions

    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionRow
            TVPlaybackSelectorRow(
                versions: availableVersions,
                currentVersion: currentVersion,
                selectedVersionFileId: selectedVersionFileId,
                selectedAudioTrackIndex: selectedAudioTrackIndex,
                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                subtitleMode: subtitleOverrideCleared ? nil : detail.effectiveSubtitleMode,
                subtitleSignature: subtitleOverrideCleared ? nil : detail.effectiveSubtitleTrackSignature,
                showForcedSubtitles: detail.effectiveShowForcedSubtitles ?? false,
                onSelectVersion: onSelectVersion,
                onSelectAudioTrack: onSelectAudioTrack,
                onSelectSubtitleTrack: onSelectSubtitleTrack
            )
            if let trailerFetchStatus {
                // Non-focusable readout, so it adds no stop to the action
                // column's focus traversal.
                TVTrailerStatusPill(
                    message: trailerFetchStatus,
                    isFetching: isFetchingTrailers,
                    onAutoDismiss: onTrailerStatusShown
                )
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 36) {
            TVPrimaryPillButton(
                icon: "play.fill",
                title: primaryPlayLabel,
                action: { onPlay(false) },
                focused: $playFocused
            )
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > 0 && proxy.size.height > 0
            } action: { isLaidOut in
                guard isLaidOut else { return }
                resetInitialPlayFocus()
            }

            if hasResumeProgress {
                TVSecondaryPillButton(
                    icon: "backward.end.fill",
                    title: "Start Over",
                    action: { onPlay(true) }
                )
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
                accessibilityLabel: isWatched ? watchedLabelUnmark : watchedLabelMark,
                action: onToggleWatched
            )

            if hasMoreMenu {
                moreMenu
            }
        }
        // Container binding — flips true when any button in the row has
        // focus, driving the scroll-to-top in `detailFocusScroll`.
        .focused($actionRowFocused)
        // Mirror of the selector row's full-width focus section: the subtitle
        // pill below can extend past the last circle button, and an Up press
        // from that overhang would otherwise skip this row for the synopsis.
        // Full-width bounds put the row under every selector pill so Up lands
        // on the nearest action button. Buttons stay left-aligned.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func resetInitialPlayFocus() {
        guard !didResetInitialPlayFocus else { return }
        didResetInitialPlayFocus = true
        resetFocus(in: detailFocusNamespace)
    }

    // MARK: - More menu

    private var hasOverflowNavigation: Bool {
        detail.type == "episode" && detail.seriesId != nil
    }

    /// The ellipsis now also appears on movie pages, which previously had
    /// no overflow entries at all — "Find Trailers" is the first.
    private var hasMoreMenu: Bool {
        hasOverflowNavigation || supportsTrailerFetch
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(accessibilityLabel: "More options") {
            if supportsTrailerFetch {
                Button(action: onFindTrailers) {
                    Label("Find Trailers", systemImage: "film.stack")
                }
            }
            if let seriesId = detail.seriesId,
               let seasonNumber = detail.seasonNumber,
               seasonNumber > 0 {
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

    private var watchedLabelMark: String {
        detail.type == "episode" ? "Mark Episode Watched" : "Mark as Watched"
    }

    private var watchedLabelUnmark: String {
        detail.type == "episode" ? "Mark Episode Unwatched" : "Mark as Unwatched"
    }

    private var resumePositionSeconds: Double? {
        guard let pos = detail.userData?.positionSeconds, pos > 30 else { return nil }
        if let dur = detail.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
    }

    private var hasResumeProgress: Bool { resumePositionSeconds != nil }

    private var primaryPlayLabel: String {
        guard let pos = resumePositionSeconds else { return "Play" }
        return "Resume \(PlayerTimeFormatter.formatHMS(pos))"
    }

    // MARK: - Episodes (episode detail page)

    private var showsEpisodeRail: Bool {
        detail.type == "episode" && !seasonEpisodes.isEmpty
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(label: episodeRailEyebrow, title: "Episodes")
            if seasons.count > 1 {
                TVSeasonChipRow(
                    seasons: seasons,
                    selectedSeasonId: selectedSeason?.id,
                    onSelect: onSelectSeason
                )
                // Container binding — true while any chip has focus, driving
                // the episode-section re-center in `detailFocusScroll`.
                .focused($seasonRowFocused)
            }
            if isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().tint(.continuumOnSurface).padding()
                    Spacer()
                }
            } else {
                TVEpisodeRail(
                    episodes: seasonEpisodes,
                    onSelect: onEpisodeTap,
                    onFocusedEpisodeChange: { focusedEpisodeContentId = $0 },
                    onSetWatched: onSetEpisodeWatched,
                    onSetFavorite: onSetEpisodeFavorite,
                    currentContentId: detail.contentId,
                    currentContentIsFavorite: isFavorite,
                    favoriteStates: episodeFavoriteStates,
                    prefersCurrentContentFocus: true
                )
                .padding(.horizontal, -ContinuumTheme.safePadding)
            }
        }
    }

    /// Siri Remote Play/Pause is a page-level shortcut. A different episode
    /// highlighted in the rail wins; every other focus zone plays the episode
    /// represented by this detail page and preserves its selector overrides.
    private func playFocusedEpisodeOrCurrent() {
        guard detail.type == "episode" else { return }
        if let focusedEpisodeContentId,
           focusedEpisodeContentId != detail.contentId {
            onEpisodeTap(focusedEpisodeContentId)
        } else {
            onPlay(false)
        }
    }

    private var episodeRailEyebrow: String {
        // Track the chip selection — the rail can show a different season
        // than the episode's own once the viewer switches in place.
        if let season = selectedSeason {
            return season.seasonNumber > 0
                ? "Season \(season.seasonNumber)"
                : (season.title ?? "Specials")
        }
        if let seasonNumber = detail.seasonNumber, seasonNumber > 0 {
            return "Season \(seasonNumber)"
        }
        return "This Season"
    }

    // MARK: - More Like This

    /// Hide on episode pages — viewers want the next episode, not
    /// tangentially related titles. The episode rail above already
    /// serves browsing.
    private var showsSimilarRail: Bool {
        detail.type != "episode"
    }

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        TVSimilarRail(
            contentId: detail.contentId,
            onSelect: onNavigateToItem
        )
    }

    // MARK: - Trailers & More

    private var trailersSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // the item has neither remote videos nor local extras.
        TVTrailersRail(entries: trailerEntries, onSelect: onSelectTrailer)
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }

    // MARK: - Version data

    private var availableVersions: [FileVersion] {
        detail.versions ?? []
    }

    private var currentVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: availableVersions,
            selectedFileId: selectedVersionFileId,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }
}
#endif
