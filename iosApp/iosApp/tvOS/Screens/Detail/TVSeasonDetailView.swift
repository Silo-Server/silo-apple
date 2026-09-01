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

    @Namespace private var detailFocusNamespace
    @FocusState private var playFocused: Bool
    /// True while focus sits anywhere inside the season chip row — drives the
    /// episode-section re-center in `detailFocusScroll`.
    @FocusState private var seasonRowFocused: Bool
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared

    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "season-episode-section"
    private let heroScrollId = "season-hero"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 48) {
                    TVDetailHero(
                        title: detail.title,
                        seriesTitle: nil,
                        logoUrl: nil,
                        backdropUrl: detail.backdropUrl,
                        backdropThumbhash: detail.backdropThumbhash,
                        eyebrow: detail.seriesTitle,
                        sourceTokens: sourceTokens,
                        ratingChip: nil,
                        overview: detail.overview,
                        factsLine: [],
                        starringText: TVHeroMetadata.starringText(from: detail),
                        playbackSummary: TVPlaybackSelectionSummary.make(
                            currentVersion: effectiveNextUpVersion,
                            selectedVersionFileId: selectedNextUpFileId,
                            selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                            selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                            subtitleMode: nextUpSubtitleOverrideCleared
                                ? nil
                                : nextUpPlaybackDetail?.effectiveSubtitleMode,
                            subtitleSignature: nextUpSubtitleOverrideCleared
                                ? nil
                                : nextUpPlaybackDetail?.effectiveSubtitleTrackSignature,
                            preferredSubtitleLanguage: profilePrefsStore.preferredSubtitleLanguage,
                            showForcedSubtitles: nextUpPlaybackDetail?.effectiveShowForcedSubtitles
                                ?? false
                        ),
                        actions: { actionColumn },
                        belowSynopsis: belowSynopsis
                    )
                    .id(heroScrollId)

                    VStack(alignment: .leading, spacing: 72) {
                        episodeSection
                            .id(episodeSectionScrollId)
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
        actionRow
    }

    private var nextUpVersions: [FileVersion] {
        nextUpPlaybackDetail?.versions ?? []
    }

    private var actionRow: some View {
        TVDetailActionRow(
            playTitle: nextUpEpisode.map {
                $0.userData?.isInProgress == true ? "Resume" : "Play"
            },
            playSubtitle: nextUpEpisode.map(playButtonSubtitle(for:)),
            onPlay: {
                guard let nextUp = nextUpEpisode else { return }
                onPlayEpisode(nextUp.contentId, selectedNextUpFileId, false)
            },
            onStartOver: nextUpEpisode?.userData?.isInProgress == true
                ? {
                    guard let nextUp = nextUpEpisode else { return }
                    onPlayEpisode(nextUp.contentId, selectedNextUpFileId, true)
                }
                : nil,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            focusResetKey: detail.contentId,
            initialFocusScope: .season(key: selectedSeason?.contentId),
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $actionRowFocused,
            playbackSelectors: {
                if nextUpEpisode != nil {
                    TVPlaybackActionSelectors(
                        versions: nextUpVersions,
                        currentVersion: effectiveNextUpVersion,
                        selectedVersionFileId: selectedNextUpFileId,
                        selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                        selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                        subtitleMode: nextUpSubtitleOverrideCleared
                            ? nil
                            : nextUpPlaybackDetail?.effectiveSubtitleMode,
                        subtitleSignature: nextUpSubtitleOverrideCleared
                            ? nil
                            : nextUpPlaybackDetail?.effectiveSubtitleTrackSignature,
                        showForcedSubtitles: nextUpPlaybackDetail?.effectiveShowForcedSubtitles
                            ?? false,
                        onSelectVersion: onSelectNextUpVersion,
                        onSelectAudioTrack: onSelectNextUpAudioTrack,
                        onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
                    )
                }
            },
            moreMenu: { moreMenu }
        )
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(accessibilityLabel: "More options") {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
            }
            Button(action: onToggleWatched) {
                Label(
                    isWatched ? "Mark Season Unwatched" : "Mark Season Watched",
                    systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                )
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

    private var nextUpEpisode: EpisodeListItem? {
        if let inProgress = episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return episodes.first
    }

    private func playButtonSubtitle(for episode: EpisodeListItem) -> String {
        "S\(episode.seasonNumber):E\(episode.episodeNumber)"
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
