#if os(tvOS)
import SwiftUI

/// Movie / episode detail layout for tvOS. The hero fills the top of the
/// viewport; the scrollable body underneath contains cast, a full
/// overview, and facts. A pre-Play selector row beneath the primary
/// actions exposes Edition / Version / Audio / Subtitles, each auto-hiding
/// when there is no real choice.
struct TVMovieDetailView<BelowSynopsis: View>: View {
    let detail: ItemDetail
    /// Series-level supporting content retained while an episode changes its
    /// hero. This keeps the cast/trailer/recommendation continuum stable.
    let supportingDetail: ItemDetail?
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
    let onPlayEpisodeShortcut: (String) -> Void
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the synopsis.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Namespace private var detailFocusNamespace
    @FocusState private var playFocused: Bool
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool
    /// Whole recommendation rail focus, used only to keep its heading and
    /// focused poster comfortably framed during native vertical reveal.
    @FocusState private var similarRailFocused: Bool
    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "detail-episode-section"
    private let heroScrollId = "detail-hero"
    private let similarSectionScrollId = "detail-similar-section"
    @State private var focusedEpisodeContentId: String?
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared

    var body: some View {
        TVDetailPageSurface(backdropURL: detail.backdropUrl) {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        TVDetailHero(
                            title: detail.title,
                            seriesTitle: episodeSeriesTitle,
                            logoUrl: heroLogoUrl,
                            backdropUrl: detail.backdropUrl,
                            backdropThumbhash: detail.backdropThumbhash,
                            eyebrow: nil,
                            sourceTokens: TVHeroMetadata.movieSourceTokens(from: detail),
                            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
                            overview: detail.overview,
                            factsLine: TVHeroMetadata.movieFactsLine(from: detail, version: currentVersion),
                            starringText: TVHeroMetadata.starringText(from: detail),
                            playbackSummary: TVPlaybackSelectionSummary.make(
                                currentVersion: currentVersion,
                                selectedVersionFileId: selectedVersionFileId,
                                selectedAudioTrackIndex: selectedAudioTrackIndex,
                                selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                                subtitleMode: subtitleOverrideCleared
                                    ? nil
                                    : detail.effectiveSubtitleMode,
                                subtitleSignature: subtitleOverrideCleared
                                    ? nil
                                    : detail.effectiveSubtitleTrackSignature,
                                preferredSubtitleLanguage: profilePrefsStore.preferredSubtitleLanguage,
                                showForcedSubtitles: detail.effectiveShowForcedSubtitles ?? false
                            ),
                            actions: { actionColumn },
                            belowSynopsis: belowSynopsis
                        )
                        .id(heroScrollId)

                        VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                            if showsEpisodeRail {
                                episodesSection
                                    .id(episodeSectionScrollId)
                            }
                            if let cast = supportingCast, !cast.isEmpty {
                                castSection(cast: cast)
                            }
                            trailersSection
                            if showsSimilarRail {
                                similarSection
                                    .focused($similarRailFocused)
                                    .id(similarSectionScrollId)
                            }
                            detailsSection
                        }
                        .padding(.horizontal, TVDetailLayout.horizontalInset)
                        .padding(.bottom, TVDetailLayout.pageBottomPadding)
                    }
                }
                .ignoresSafeArea()
                .focusScope(detailFocusNamespace)
                .defaultFocus($playFocused, true, priority: .userInitiated)
                .detailFocusScroll(
                    proxy: scrollProxy,
                    seasonRowFocused: false,
                    actionRowFocused: actionRowFocused,
                    episodeSectionId: episodeSectionScrollId,
                    heroId: heroScrollId,
                    similarRailFocused: similarRailFocused,
                    similarSectionId: similarSectionScrollId
                )
                .onPlayPauseCommand(perform: playFocusedEpisodeOrCurrent)
            }
        }
    }

    // MARK: - Hero actions

    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionRow
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
        TVDetailActionRow(
            playTitle: primaryPlayLabel,
            playSubtitle: nil,
            onPlay: { onPlay(false) },
            onStartOver: hasResumeProgress ? { onPlay(true) } : nil,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            focusResetKey: detail.contentId,
            initialFocusScope: .page,
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $actionRowFocused,
            stabilizesFocusMotion: true,
            primaryButtonWidth: 340,
            playbackSelectors: {
                TVPlaybackActionSelectors(
                    versions: availableVersions,
                    currentVersion: currentVersion,
                    selectedVersionFileId: selectedVersionFileId,
                    selectedAudioTrackIndex: selectedAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                    subtitleMode: subtitleOverrideCleared
                        ? nil
                        : detail.effectiveSubtitleMode,
                    subtitleSignature: subtitleOverrideCleared
                        ? nil
                        : detail.effectiveSubtitleTrackSignature,
                    showForcedSubtitles: detail.effectiveShowForcedSubtitles ?? false,
                    onSelectVersion: onSelectVersion,
                    onSelectAudioTrack: onSelectAudioTrack,
                    onSelectSubtitleTrack: onSelectSubtitleTrack
                )
            },
            moreMenu: { moreMenu }
        )
    }

    // MARK: - More menu

    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(
            accessibilityLabel: "More options",
            stabilizesFocusMotion: true
        ) {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
            }
            Button(action: onToggleWatched) {
                Label(
                    isWatched ? watchedLabelUnmark : watchedLabelMark,
                    systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
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

    /// Episode payloads do not consistently carry parent-series artwork.
    /// The already-loaded supporting series is authoritative for the logo and
    /// hierarchy title, while ordinary movie pages keep their own artwork.
    private var heroLogoUrl: String? {
        guard detail.type == "episode" else { return detail.logoUrl }
        return supportingDetail?.logoUrl ?? detail.logoUrl
    }

    private var episodeSeriesTitle: String? {
        guard detail.type == "episode" else { return nil }
        return supportingDetail?.title ?? detail.seriesTitle
    }

    // MARK: - Episodes (episode detail page)

    private var showsEpisodeRail: Bool {
        detail.type == "episode" && !seasonEpisodes.isEmpty
    }

    private var supportingCast: [CastMember]? {
        if detail.type == "episode",
           let cast = supportingDetail?.cast,
           !cast.isEmpty {
            return cast
        }
        return detail.cast
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            HStack(alignment: .firstTextBaseline) {
                TVSectionHeader(title: episodeSectionTitle)
                Spacer()
                Text("Current season")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.continuumSecondaryText)
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
            onPlayEpisodeShortcut(focusedEpisodeContentId)
        } else {
            onPlay(false)
        }
    }

    private var episodeSectionTitle: String {
        if let season = selectedSeason {
            let label = season.seasonNumber > 0
                ? "Season \(season.seasonNumber)"
                : (season.title ?? "Specials")
            return "\(label) Episodes"
        }
        if let seasonNumber = detail.seasonNumber, seasonNumber > 0 {
            return "Season \(seasonNumber) Episodes"
        }
        return "Episodes"
    }

    // MARK: - More Like This

    private var showsSimilarRail: Bool {
        true
    }

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        TVSimilarRail(
            contentId: detail.type == "episode" ? (detail.seriesId ?? detail.contentId) : detail.contentId,
            title: detail.type == "episode" ? "Recommended Series" : "Related Movies",
            onSelect: onNavigateToItem
        )
    }

    // MARK: - Trailers & More

    private var trailersSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // the item has neither remote videos nor local extras.
        TVTrailersRail(
            entries: trailerEntries,
            onSelect: onSelectTrailer,
            focusScale: 1.0
        )
    }

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
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
