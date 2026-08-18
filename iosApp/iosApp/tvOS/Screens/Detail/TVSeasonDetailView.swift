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
    let episodeFavoriteStates: [String: Bool]
    let isLoadingEpisodes: Bool
    let selectedNextUpFileId: Int?
    let selectedNextUpAudioTrackIndex: Int?
    let selectedNextUpSubtitleTrackIndex: Int?
    let nextUpPlaybackDetail: ItemDetail?
    /// True once the user explicitly resets subtitles to "Auto" this visit.
    /// The server override was just cleared, but the next-up detail's
    /// `effectiveSubtitle*` still describes the old manual pick until the
    /// next refetch — suppress it so the "Auto: …" preview doesn't echo the
    /// cleared selection.
    var nextUpSubtitleOverrideCleared: Bool = false
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onEpisodeTap: (_ contentId: String) -> Void
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
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

    @Environment(\.resetFocus) private var resetFocus
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
    private let episodeSectionScrollId = "season-episode-section"
    private let heroScrollId = "season-hero"
    /// Reevaluate the page-entry default only once, after the asynchronously
    /// supplied Play button has joined the laid-out focus graph.
    @State private var didResetInitialPlayFocus = false
    @State private var initialFocusSeasonKey: String?

    var body: some View {
        ScrollViewReader { scrollProxy in
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
                        factsLine: [],
                        starringText: HeroMetadata.starringText(from: detail),
                        actions: { actionColumn },
                        belowSynopsis: belowSynopsis
                    )
                    .id(heroScrollId)

                    VStack(alignment: .leading, spacing: 72) {
                        episodeSection
                            .id(episodeSectionScrollId)
                        if let cast = detail.cast, !cast.isEmpty {
                            TVDetailCastRail(cast: cast, onTap: onPersonTap)
                        }
                        detailsSection
                    }
                    .padding(.horizontal, SiloTheme.safePadding)
                    .padding(.bottom, 160)
                }
            }
            .ignoresSafeArea()
            .focusScope(detailFocusNamespace)
            .defaultFocus($playFocused, true, priority: .userInitiated)
            .onChange(of: selectedSeason?.contentId, initial: true) { _, seasonKey in
                guard let seasonKey else { return }
                if initialFocusSeasonKey == nil {
                    initialFocusSeasonKey = seasonKey
                } else if initialFocusSeasonKey != seasonKey {
                    didResetInitialPlayFocus = true
                }
            }
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
            if nextUpEpisode != nil {
                TVPlaybackSelectorRow(
                    versions: nextUpVersions,
                    currentVersion: effectiveNextUpVersion,
                    selectedVersionFileId: selectedNextUpFileId,
                    selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                    subtitleMode: nextUpSubtitleOverrideCleared ? nil : nextUpPlaybackDetail?.effectiveSubtitleMode,
                    subtitleSignature: nextUpSubtitleOverrideCleared ? nil : nextUpPlaybackDetail?.effectiveSubtitleTrackSignature,
                    showForcedSubtitles: nextUpPlaybackDetail?.effectiveShowForcedSubtitles ?? false,
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
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.width > 0 && proxy.size.height > 0
                } action: { isLaidOut in
                    guard isLaidOut else { return }
                    resetInitialPlayFocus()
                }
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
        guard let seasonKey = selectedSeason?.contentId else { return }
        if initialFocusSeasonKey == nil {
            initialFocusSeasonKey = seasonKey
        }
        guard initialFocusSeasonKey == seasonKey else { return }
        didResetInitialPlayFocus = true
        resetFocus(in: detailFocusNamespace)
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
        EpisodeRailFormatting.nextUp(in: episodes)
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
                // Container binding — true while any chip has focus, driving
                // the episode-section re-center in `detailFocusScroll`.
                .focused($seasonRowFocused)
            }
            if isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().tint(.siloOnSurface).padding()
                    Spacer()
                }
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.siloSecondaryText)
            } else {
                TVEpisodeRail(
                    episodes: episodes,
                    onSelect: onEpisodeTap,
                    onSetWatched: onSetEpisodeWatched,
                    onSetFavorite: onSetEpisodeFavorite,
                    currentContentId: nextUpEpisode?.contentId,
                    currentContentIsFavorite: nextUpEpisode.map {
                        episodeFavoriteStates[$0.contentId] ?? false
                    } ?? false,
                    favoriteStates: episodeFavoriteStates
                )
            }
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
