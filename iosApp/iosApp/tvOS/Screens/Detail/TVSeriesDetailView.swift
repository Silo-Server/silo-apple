#if os(tvOS)
import SwiftUI

/// Series detail layout for tvOS. Cinematic hero at the top; seasons +
/// a horizontal episode rail + cast + facts below.
struct TVSeriesDetailView<BelowSynopsis: View>: View {
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
    let isLoadingNextUpPlaybackDetail: Bool
    let didLoadNextUpPlaybackDetail: Bool
    /// True once the user explicitly resets subtitles to "Auto" this visit.
    /// The server override was just cleared, but the next-up detail's
    /// `effectiveSubtitle*` still describes the old manual pick until the
    /// next refetch — suppress it so the "Auto: …" preview doesn't echo the
    /// cleared selection.
    var nextUpSubtitleOverrideCleared: Bool = false
    /// Merged remote-video + local-extra rail, already shaped by the call
    /// site (which owns the YouTube-app availability probe that decides
    /// whether remote cards exist at all). Empty hides the rail.
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    /// Whether the manual "Find Trailers" action can be offered. The caller
    /// also requires the YouTube app because tvOS has no browser fallback.
    let supportsTrailerFetch: Bool
    let onFindTrailers: () -> Void
    /// Copy from the fetch coordinator; nil while idle.
    let trailerFetchStatus: String?
    let isFetchingTrailers: Bool
    /// Called once a terminal fetch message has been on screen long enough.
    let onTrailerStatusShown: () -> Void
    let onSelectSeason: (Season) -> Void
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onEpisodeTap: (_ contentId: String) -> Void
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
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
    /// True while focus sits anywhere inside the season chip row. Used to
    /// scroll the episode section to the same centered framing the focus
    /// engine produces when the (taller) episode rail itself is focused —
    /// otherwise landing on the short chip row only reveals the chips and
    /// leaves the episodes below the fold.
    @FocusState private var seasonRowFocused: Bool
    /// True while focus sits anywhere in the hero's primary action row
    /// (Play / Start Over / circle buttons). Backing up into it restores the
    /// page-entry framing by scrolling the hero back to the top.
    @FocusState private var actionRowFocused: Bool
    @FocusState private var similarRailFocused: Bool

    var body: some View {
        TVDetailPageSurface(backdropURL: detail.backdropUrl) {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroView
                            .id(heroScrollId)

                        VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                            episodeSection
                                .id(episodeSectionScrollId)
                            if let cast = detail.cast, !cast.isEmpty {
                                castSection(cast: cast)
                            }
                            trailersSection
                            similarSection
                                .focused($similarRailFocused)
                                .id(similarSectionScrollId)
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
            }
        }
    }

    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "series-episode-section"
    private let heroScrollId = "series-hero"
    private let similarSectionScrollId = "series-similar-section"

    private var heroView: some View {
        TVDetailHero(
            title: detail.title,
            seriesTitle: nil,
            logoUrl: detail.logoUrl,
            backdropUrl: detail.backdropUrl,
            eyebrow: nil,
            sourceTokens: TVHeroMetadata.seriesSourceTokens(from: detail),
            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: TVHeroMetadata.seriesFactsLine(from: detail),
            starringText: TVHeroMetadata.starringText(from: detail),
            playbackSummaryText: playbackSummaryText,
            actions: { actionColumn },
            belowSynopsis: belowSynopsis
        )
    }

    // MARK: - Hero actions

    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            actionRow
            if !seasons.isEmpty {
                seasonRow
            }
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

    private var nextUpVersions: [FileVersion] {
        nextUpPlaybackDetail?.versions ?? []
    }

    private var actionRow: some View {
        TVDetailActionRow(
            playTitle: nextUpEpisode == nil ? nil : "Play",
            playSubtitle: nextUpEpisode.map(playButtonSubtitle(for:)),
            onPlay: {
                guard let nextUp = nextUpEpisode else { return }
                onPlayEpisode(nextUp.contentId, selectedFileId(for: nextUp), false)
            },
            onStartOver: nextUpEpisode?.userData?.isInProgress == true
                ? {
                    guard let nextUp = nextUpEpisode else { return }
                    onPlayEpisode(nextUp.contentId, selectedFileId(for: nextUp), true)
                }
                : nil,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            isWatched: isWatched,
            watchedLabelMark: "Mark Season Watched",
            watchedLabelUnmark: "Mark Season Unwatched",
            onToggleWatched: onToggleWatched,
            focusResetKey: detail.contentId,
            initialFocusScope: .season(key: selectedSeason?.contentId),
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $actionRowFocused,
            moreMenu: {
                if supportsTrailerFetch {
                    moreMenu
                }
            }
        )
    }

    // MARK: - More menu

    /// The series action row had no overflow button before "Find Trailers";
    /// it is the only entry today. Lives inside the row's existing
    /// `.focusSection()`, so it needs no focus work of its own.
    @ViewBuilder
    private var moreMenu: some View {
        TVCircleMenuButton(accessibilityLabel: "More options") {
            Button(action: onFindTrailers) {
                Label("Find Trailers", systemImage: "film.stack")
            }
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

    private func playButtonSubtitle(for episode: EpisodeListItem) -> String {
        "S\(episode.seasonNumber), \(String(format: "%02d", episode.episodeNumber))"
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

    /// Read-only disclosure for the main series overview. This deliberately
    /// mirrors the exact effective version and track state handed to Play;
    /// it is not focusable and does not replace the episode-detail selector.
    private var playbackSummaryText: String? {
        guard let version = effectiveNextUpVersion else {
            return provisionalPlaybackSummaryText
        }

        let quality = playbackQualityLabel(for: version)
        let audio = DetailPlaybackFormatting.audioTechnicalSummary(
            version: version,
            selectedAudioTrackIndex: selectedNextUpAudioTrackIndex
        )
        let subtitles = playbackSubtitleLabel(for: version)

        return [quality, audio, subtitles]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " · ")
    }

    /// Keeps the disclosure line present on the hero's first frame while the
    /// richer watch metadata is warming. Episode rows already carry enough
    /// file information for an honest resolution/channel preview; the exact
    /// codec and subtitle policy fade in without moving the controls.
    private var provisionalPlaybackSummaryText: String {
        let file = provisionalNextUpFile
        let quality = playbackQualityLabel(resolution: file?.resolution)
            ?? preferredQualityFallbackLabel
        let audio = playbackChannelLabel(file?.audioChannels) ?? "Audio Auto"
        let subtitles: String
        if selectedNextUpSubtitleTrackIndex == -1 {
            subtitles = "Subtitles Off"
        } else if selectedNextUpSubtitleTrackIndex != nil {
            subtitles = "Subtitles On"
        } else {
            subtitles = "Subtitles Auto"
        }
        return [quality, audio, subtitles].joined(separator: " · ")
    }

    private var provisionalNextUpFile: EpisodeFile? {
        guard let episode = nextUpEpisode,
              let files = episode.files,
              !files.isEmpty else { return nil }
        if let selectedNextUpFileId,
           let selected = files.first(where: { $0.fileId == selectedNextUpFileId }) {
            return selected
        }
        if let lastFileId = episode.userData?.lastFileId,
           let last = files.first(where: { $0.fileId == lastFileId }) {
            return last
        }

        let preference = PlayerSettings.shared.preferredQualityResolution.lowercased()
        let cap = playbackResolutionRank(preference)
        if cap > 0,
           let capped = files
            .filter({ playbackResolutionRank($0.resolution) <= cap })
            .max(by: { playbackResolutionRank($0.resolution) < playbackResolutionRank($1.resolution) }) {
            return capped
        }
        return files.max {
            playbackResolutionRank($0.resolution) < playbackResolutionRank($1.resolution)
        }
    }

    private var preferredQualityFallbackLabel: String {
        switch PlayerSettings.shared.preferredQualityResolution.lowercased() {
        case "2160p", "4k", "uhd": return "4K"
        case "1080p": return "1080p"
        case "720p": return "720p"
        case "576p": return "576p"
        case "480p": return "480p"
        case "original": return "Original"
        default: return "Auto"
        }
    }

    private func playbackChannelLabel(_ channels: Int?) -> String? {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let channels?: return "\(channels)ch"
        case nil: return nil
        }
    }

    private func playbackResolutionRank(_ resolution: String?) -> Int {
        let value = resolution?.lowercased() ?? ""
        if value.contains("2160") || value.contains("4k") || value.contains("uhd") { return 5 }
        if value.contains("1080") { return 4 }
        if value.contains("720") { return 3 }
        if value.contains("576") { return 2 }
        if value.contains("480") { return 1 }
        return 0
    }

    private func playbackQualityLabel(for version: FileVersion) -> String? {
        playbackQualityLabel(resolution: version.resolution)
    }

    private func playbackQualityLabel(resolution: String?) -> String? {
        let raw = resolution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = raw.lowercased()
        if normalized.contains("2160") || normalized.contains("4k") || normalized.contains("uhd") {
            return "4K"
        }
        if normalized.contains("1080") { return "1080p" }
        if normalized.contains("720") { return "720p" }
        if normalized.contains("576") { return "576p" }
        if normalized.contains("480") { return "480p" }
        return raw.isEmpty ? nil : raw
    }

    private func playbackSubtitleLabel(for version: FileVersion) -> String {
        if selectedNextUpSubtitleTrackIndex == -1 {
            return "Subtitles Off"
        }
        if let selectedNextUpSubtitleTrackIndex {
            let value = DetailPlaybackFormatting.subtitleValueLabel(
                version: version,
                selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex
            )
            let conciseValue = value.components(separatedBy: " · ").first ?? value
            return "Subtitles \(conciseValue)"
        }
        if !nextUpSubtitleOverrideCleared,
           nextUpPlaybackDetail?.effectiveSubtitleMode?.lowercased() == "off" {
            return "Subtitles Off"
        }
        return "Subtitles Auto"
    }

    // MARK: - Episodes + season selector

    @ViewBuilder
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            episodeSectionHeader
            episodeBody
        }
    }

    private var episodeSectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            TVSectionHeader(
                title: selectedSeason.map { season in
                    let label = season.seasonNumber > 0
                        ? "Season \(season.seasonNumber)"
                        : (season.title ?? "Specials")
                    return "\(label) Episodes"
                } ?? "Episodes"
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
        // Bound to the whole row: the binding flips true when any chip inside
        // gains focus, driving the episode-section re-center in `body`.
        .focused($seasonRowFocused)
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

    // MARK: - More Like This

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        TVSimilarRail(
            contentId: detail.contentId,
            title: "Recommended Series",
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
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }

}

#endif
