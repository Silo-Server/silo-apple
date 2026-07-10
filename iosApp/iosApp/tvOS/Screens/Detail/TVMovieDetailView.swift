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
    /// site (which owns the view model) and rendered under the synopsis.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Namespace private var detailFocusNamespace
    @FocusState private var playFocused: Bool
    /// True while focus sits anywhere inside the season chip row — drives the
    /// episode-section re-center in `detailFocusScroll`.
    @FocusState private var seasonRowFocused: Bool
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool

    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "detail-episode-section"
    private let heroScrollId = "detail-hero"

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
                        tagline: detail.tagline,
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

    // MARK: - More menu

    private var hasOverflowNavigation: Bool {
        detail.type == "episode" && detail.seriesId != nil
    }

    private var hasMoreMenu: Bool {
        hasOverflowNavigation
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(accessibilityLabel: "More options") {
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
                    currentContentId: detail.contentId
                )
            }
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
