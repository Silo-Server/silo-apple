#if os(tvOS)
import SwiftUI

/// Persistent video-detail layout for tvOS. Movies use the supplied detail as
/// their playback target. Series-family pages keep this same view mounted as
/// the active series, season, or episode changes; container pages supply the
/// next playable episode separately through `playbackDetail`.
struct TVMovieDetailView<BelowSynopsis: View>: View {
    let detail: ItemDetail
    var playbackDetail: ItemDetail? = nil
    var playTitleOverride: String? = nil
    var isLoadingPlaybackDetail = false
    var didLoadPlaybackDetail = true
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
    var onFocusedSeasonChange: ((Season?) -> Void)? = nil
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    let onEpisodeTap: (String) -> Void
    var onFocusedEpisodeChange: ((String?) -> Void)? = nil
    var onPlayFocusedEpisode: ((String) -> Void)? = nil
    var currentEpisodeContentId: String? = nil
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the synopsis.
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis

    @Namespace private var detailFocusNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var actionFocus: TVDetailActionFocus?
    /// One focus owner for the season pills and episode cards. The whole
    /// browser settles into its expanded framing once focus enters either
    /// row, avoiding a second scroll when focus moves from pills to cards.
    @FocusState private var episodeBrowserFocused: Bool
    /// One page-owned focus value for Version / Audio / Subtitles. Keeping it
    /// outside the child row preserves the native horizontal focus context.
    @FocusState private var playbackSelectorFocus: TVPlaybackSelectorFocus?
    @State private var selectorRowFocused = false
    /// Keeps the lower browser out of the action row's Down search until the
    /// visible playback selector has actually accepted focus. This survives
    /// the focus engine's transient source -> nil -> destination frame.
    @State private var episodeBrowserSuppressedForSelectorEntry = false
    @State private var selectorEntryReleaseTask: Task<Void, Never>?
    /// Symmetric latch for Version -> Season. While the selector row owns
    /// focus, large episode cards are excluded until a Season pill lands.
    @State private var episodeRailSuppressedForSeasonEntry = false
    @State private var seasonEntryReleaseTask: Task<Void, Never>?
    /// Keeps the hidden hero editorial controls out of the focus graph while
    /// a lower rail is active. Without this, Up from Cast & Crew can first
    /// land on an invisible synopsis control before a second Up reaches Play.
    @State private var castRailFocused = false
    /// High-priority only for page entry; later focus reevaluations should
    /// respect the active season or episode row.
    @State private var prefersPageEntryPlay = true
    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let episodeSectionScrollId = "detail-episode-section"
    private let heroScrollId = "detail-hero"
    private let selectorEntryReleaseDelayNanoseconds: UInt64 = 2_000_000_000
    @State private var focusedEpisodeContentId: String?
    @State private var heroRevealOpacity = 1.0
    @State private var episodeRailRevealOpacity = 1.0
    /// Single source of truth for the backdrop parallax and compact-header
    /// reveal. Keeping this in a fine-grained Observation object prevents
    /// every scroll frame from invalidating this complete focus-owning view.
    @State private var scrollVisualState = TVDetailScrollVisualState()

    var body: some View {
        GeometryReader { geometry in
            let episodeSectionOffset = max(
                680,
                geometry.size.height - TVDetailLayoutMetrics.episodePreviewDepth
            )
            let heroCanvasHeight = max(
                episodeSectionOffset,
                geometry.size.height - TVDetailLayoutMetrics.heroCanvasBottomMargin
            )

            ZStack {
                TVDetailPageBackdrop(
                    artworkURL: detail.backdropUrl,
                    artworkThumbhash: detail.backdropThumbhash,
                    scrollVisualState: scrollVisualState
                )

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        // The transparent spacer gives the scroll coordinator
                        // a stable hero destination while the visible hero is
                        // rendered as a fixed sibling overlay. Negative layout
                        // spacing preserves the real episode rail's preview
                        // position without duplicating its artwork.
                        VStack(
                            alignment: .leading,
                            spacing: episodeSectionOffset - heroCanvasHeight
                        ) {
                            Color.clear
                                .frame(height: heroCanvasHeight)
                            .id(heroScrollId)

                            VStack(alignment: .leading, spacing: 72) {
                                if showsEpisodeRail {
                                    episodesSection
                                        .id(episodeSectionScrollId)
                                        .focused($episodeBrowserFocused)
                                        .disabled(
                                            episodeBrowserSuppressedForSelectorEntry
                                        )
                                } else {
                                    compactScrolledHeader
                                        .frame(
                                            height: TVDetailLayoutMetrics.compactHeaderHeight,
                                            alignment: .topLeading
                                        )
                                }
                                if let cast = detail.cast, !cast.isEmpty {
                                    castSection(cast: cast)
                                        .disabled(episodeRailSuppressedForSeasonEntry)
                                }
                                trailersSection
                                    .disabled(episodeRailSuppressedForSeasonEntry)
                                detailsSection
                                    .disabled(episodeRailSuppressedForSeasonEntry)
                                if showsSimilarRail {
                                    similarSection
                                        .disabled(episodeRailSuppressedForSeasonEntry)
                                }
                            }
                            .padding(.horizontal, ContinuumTheme.safePadding)
                            .padding(.bottom, 160)
                        }
                    }
                    .ignoresSafeArea()
                    .padding(
                        .bottom,
                        TVDetailLayoutMetrics.browserViewportBottomInset
                    )
                    // The shorter viewport shapes native focus placement, but
                    // its reserved bottom band is still part of the cinematic
                    // canvas. Let the real episode artwork and hero backdrop
                    // paint through it instead of exposing a clipped hard edge.
                    .scrollClipDisabled()
                    .detailFocusScroll(
                        proxy: scrollProxy,
                        episodeBrowserFocused: episodeBrowserFocused,
                        heroControlsFocused: actionRowFocused || selectorRowFocused,
                        episodeSectionId: episodeSectionScrollId,
                        heroId: heroScrollId
                    )
                    .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
                        let offset = scrollGeometry.contentOffset.y
                            + scrollGeometry.contentInsets.top
                        return min(max(offset / max(episodeSectionOffset, 1), 0), 1)
                    } action: { _, progress in
                        scrollVisualState.progress = progress
                    }
                    .onPlayPauseCommand(perform: playFocusedEpisodeOrCurrent)
                }

                heroCanvas(height: heroCanvasHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .focusScope(detailFocusNamespace)
            .defaultFocus(
                $actionFocus,
                .play,
                priority: prefersPageEntryPlay ? .userInitiated : .automatic
            )
        }
        .ignoresSafeArea()
        .onChange(of: actionFocus, initial: true) { _, action in
            if action != nil {
                armEpisodeBrowserSuppression()
            } else {
                scheduleEpisodeBrowserSuppressionRelease()
            }
        }
        .onDisappear {
            selectorEntryReleaseTask?.cancel()
            selectorEntryReleaseTask = nil
            seasonEntryReleaseTask?.cancel()
            seasonEntryReleaseTask = nil
        }
        .onChange(of: seasons.count) { _, count in
            if count <= 1 {
                releaseEpisodeRailSuppression()
            } else if selectorRowFocused {
                armEpisodeRailSuppression()
            }
        }
    }

    private func heroCanvas(height: CGFloat) -> some View {
        TVDetailHero(
            title: detail.title,
            seriesTitle: heroSeriesTitle,
            logoUrl: detail.logoUrl,
            eyebrow: heroEyebrow,
            sourceTokens: heroSourceTokens,
            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: heroFactsLine,
            starringText: TVHeroMetadata.starringText(from: detail),
            heroHeight: height,
            heroCanvasHeight: height,
            scrollRevealProgress: 0,
            scrollVisualState: scrollVisualState,
            suppressesEditorialFocus: episodeBrowserFocused
                || castRailFocused
                || selectorRowFocused,
            actions: { actionColumn },
            belowSynopsis: belowSynopsis
        )
        .opacity(heroRevealOpacity)
        .onChange(of: detail.contentId) { _, _ in
            releaseEpisodeBrowserSuppression()
            releaseEpisodeRailSuppression()
            if actionRowFocused {
                armEpisodeBrowserSuppression()
            } else if selectorRowFocused {
                armEpisodeRailSuppression()
            }
            revealHeroMetadata()
        }
    }

    // MARK: - Hero actions

    @ViewBuilder
    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            actionRow
            if shouldShowVersionPlaceholder {
                TVVersionPillPlaceholder()
            } else if let effectivePlaybackDetail {
                TVPlaybackSelectorRow(
                    versions: availableVersions,
                    currentVersion: currentVersion,
                    selectedVersionFileId: selectedVersionFileId,
                    selectedAudioTrackIndex: selectedAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedSubtitleTrackIndex,
                    subtitleMode: subtitleOverrideCleared
                        ? nil
                        : effectivePlaybackDetail.effectiveSubtitleMode,
                    subtitleSignature: subtitleOverrideCleared
                        ? nil
                        : effectivePlaybackDetail.effectiveSubtitleTrackSignature,
                    showForcedSubtitles: effectivePlaybackDetail.effectiveShowForcedSubtitles ?? false,
                    onSelectVersion: onSelectVersion,
                    onSelectAudioTrack: onSelectAudioTrack,
                    onSelectSubtitleTrack: onSelectSubtitleTrack,
                    focusedSelector: $playbackSelectorFocus,
                    onPrepareBrowserEntry: prepareBrowserEntry,
                    onSelectorRowFocusChanged: setSelectorRowFocused
                )
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
        .onChange(of: actionFocus) { _, action in
            if action == .play {
                prefersPageEntryPlay = false
            }
        }
        .onChange(of: hasPlaybackSelector) { _, hasTarget in
            if hasTarget, actionRowFocused {
                armEpisodeBrowserSuppression()
            } else if !hasTarget {
                releaseEpisodeBrowserSuppression()
            }
        }
    }

    private func setSelectorRowFocused(_ isFocused: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectorRowFocused = isFocused
            if isFocused {
                selectorEntryReleaseTask?.cancel()
                selectorEntryReleaseTask = nil
                // The real episode rail is already peeking into the hero, but
                // remains ineligible until Down explicitly prepares entry.
                // This keeps horizontal selector moves inside their row.
                episodeBrowserSuppressedForSelectorEntry = true
            }
        }
        if isFocused {
            armEpisodeRailSuppression()
        } else {
            scheduleEpisodeRailSuppressionRelease()
        }
    }

    private var actionRow: some View {
        TVDetailActionRow(
            playTitle: primaryPlayLabel,
            onPlay: { onPlay(false) },
            onStartOver: hasResumeProgress ? { onPlay(true) } : nil,
            isFavorite: isFavorite,
            onToggleFavorite: onToggleFavorite,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            isWatched: isWatched,
            watchedLabelMark: watchedLabelMark,
            watchedLabelUnmark: watchedLabelUnmark,
            onToggleWatched: onToggleWatched,
            initialFocusScope: isSeriesFamily
                ? .season(key: selectedSeason?.contentId)
                : .page,
            focusNamespace: detailFocusNamespace,
            focusedAction: $actionFocus,
            routesSelectorUpToPlay: playbackSelectorFocus != nil,
            moreMenu: {
                if hasMoreMenu {
                    moreMenu
                }
            }
        )
    }

    private var actionRowFocused: Bool {
        actionFocus != nil
    }

    // MARK: - More menu

    private var hasOverflowNavigation: Bool {
        (detail.type == "season" || detail.type == "episode")
            && detail.seriesId != nil
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
        switch detail.type {
        case "series": "Mark Series Watched"
        case "season": "Mark Season Watched"
        case "episode": "Mark Episode Watched"
        default: "Mark as Watched"
        }
    }

    private var watchedLabelUnmark: String {
        switch detail.type {
        case "series": "Mark Series Unwatched"
        case "season": "Mark Season Unwatched"
        case "episode": "Mark Episode Unwatched"
        default: "Mark as Unwatched"
        }
    }

    private var resumePositionSeconds: Double? {
        guard let playback = effectivePlaybackDetail,
              let pos = playback.userData?.positionSeconds,
              pos > 30 else { return nil }
        if let dur = playback.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
    }

    private var hasResumeProgress: Bool { resumePositionSeconds != nil }

    private var primaryPlayLabel: String? {
        if let playTitleOverride { return playTitleOverride }
        guard effectivePlaybackDetail != nil else { return nil }
        guard let pos = resumePositionSeconds else { return "Play" }
        return "Resume \(PlayerTimeFormatter.formatHMS(pos))"
    }

    private var shouldShowVersionPlaceholder: Bool {
        primaryPlayLabel != nil
            && (isLoadingPlaybackDetail
                || (!didLoadPlaybackDetail && effectivePlaybackDetail == nil))
    }

    // MARK: - Episodes (episode detail page)

    private var showsEpisodeRail: Bool {
        isSeriesFamily
    }

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactScrolledHeader
                .frame(
                    height: TVDetailLayoutMetrics.compactHeaderHeight,
                    alignment: .topLeading
                )

            if seasonEpisodes.isEmpty, isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView().tint(.continuumOnSurface).padding()
                    Spacer()
                }
                .frame(height: 330)
            } else if seasonEpisodes.isEmpty {
                Text("No episodes available")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.continuumSecondaryText)
            } else {
                ZStack(alignment: .topTrailing) {
                    TVEpisodeRail(
                        episodes: seasonEpisodes,
                        onSelect: onEpisodeTap,
                        onFocusedEpisodeChange: {
                            focusedEpisodeContentId = $0
                            onFocusedEpisodeChange?($0)
                        },
                        onSetWatched: onSetEpisodeWatched,
                        onSetFavorite: onSetEpisodeFavorite,
                        currentContentId: currentEpisodeContentId
                            ?? (detail.type == "episode" ? detail.contentId : nil),
                        currentContentIsFavorite: detail.type == "episode" ? isFavorite : false,
                        favoriteStates: episodeFavoriteStates
                    )
                    .disabled(isLoadingEpisodes || episodeRailSuppressedForSeasonEntry)
                    .opacity(isLoadingEpisodes ? 0.55 : episodeRailRevealOpacity)
                    .onChange(of: episodeRailIdentity) { _, _ in
                        revealEpisodeRail()
                    }

                    if isLoadingEpisodes {
                        HStack(spacing: 12) {
                            ProgressView().tint(.continuumOnSurface)
                            Text("Loading season")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.continuumOnSurface.opacity(0.82))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 28)
                    }
                }
                .padding(.horizontal, -ContinuumTheme.safePadding)
            }
        }
    }

    /// Apple TV-style compact identity block revealed by the same progress
    /// that moves the canvas. It is always present in layout and focus, so a
    /// Down move can target the Season row before the scroll reveals it.
    private var compactScrolledHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            compactTitle

            if showsEpisodeRail, seasons.count > 1 {
                TVSeasonChipRow(
                    seasons: seasons,
                    selectedSeasonId: selectedSeason?.id,
                    onSelect: onSelectSeason,
                    onFocusedSeasonChange: { season in
                        if season != nil || seasons.count <= 1 {
                            releaseEpisodeRailSuppression()
                        }
                        onFocusedSeasonChange?(season)
                    }
                )
                .onMoveCommand { direction in
                    guard direction == .up else { return }
                    playbackSelectorFocus = .version
                }
            }
        }
        .padding(.top, 34)
        .modifier(TVDetailCompactHeaderReveal(scrollVisualState: scrollVisualState))
    }

    @ViewBuilder
    private var compactTitle: some View {
        if let logoURL = detail.logoUrl, !logoURL.isEmpty {
            CachedAsyncImage(
                url: logoURL,
                contentMode: .fit,
                placeholderStyle: .clear
            )
            .frame(width: 460, height: 82, alignment: .leading)
            .accessibilityLabel(compactTitleText)
        } else {
            Text(compactTitleText)
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(Color.continuumOnSurface)
                .lineLimit(1)
        }
    }

    private var compactTitleText: String {
        if detail.type == "episode" || detail.type == "season" {
            return detail.seriesTitle ?? detail.title
        }
        return detail.title
    }

    private var hasPlaybackSelector: Bool {
        currentVersion != nil && !shouldShowVersionPlaceholder
    }

    private func armEpisodeBrowserSuppression() {
        guard hasPlaybackSelector else {
            releaseEpisodeBrowserSuppression()
            return
        }
        selectorEntryReleaseTask?.cancel()
        selectorEntryReleaseTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            episodeBrowserSuppressedForSelectorEntry = true
        }
    }

    /// Focus may leave the action row for chrome instead of the selector. A
    /// short fallback prevents that path from leaving Episodes unavailable;
    /// a real selector landing cancels it synchronously.
    private func scheduleEpisodeBrowserSuppressionRelease() {
        guard episodeBrowserSuppressedForSelectorEntry else { return }
        selectorEntryReleaseTask?.cancel()
        selectorEntryReleaseTask = Task { @MainActor in
            // Scroll-backed focus searches can outlive the old 500 ms
            // fallback on tvOS 26.5. A real selector landing cancels this
            // immediately, so the longer ceiling affects only aborted moves.
            try? await Task.sleep(
                nanoseconds: selectorEntryReleaseDelayNanoseconds
            )
            guard !Task.isCancelled, !selectorRowFocused else { return }
            releaseEpisodeBrowserSuppression()
        }
    }

    private func releaseEpisodeBrowserSuppression() {
        selectorEntryReleaseTask?.cancel()
        selectorEntryReleaseTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            episodeBrowserSuppressedForSelectorEntry = false
        }
    }

    private func armEpisodeRailSuppression() {
        guard showsEpisodeRail,
              seasons.count > 1,
              !seasonEpisodes.isEmpty else {
            releaseEpisodeRailSuppression()
            return
        }
        seasonEntryReleaseTask?.cancel()
        seasonEntryReleaseTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            episodeRailSuppressedForSeasonEntry = true
        }
    }

    private func scheduleEpisodeRailSuppressionRelease() {
        guard episodeRailSuppressedForSeasonEntry else { return }
        seasonEntryReleaseTask?.cancel()
        seasonEntryReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, !selectorRowFocused else { return }
            releaseEpisodeRailSuppression()
        }
    }

    private func releaseEpisodeRailSuppression() {
        seasonEntryReleaseTask?.cancel()
        seasonEntryReleaseTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            episodeRailSuppressedForSeasonEntry = false
        }
    }

    private func prepareBrowserEntry() {
        guard showsEpisodeRail, !seasonEpisodes.isEmpty else { return }
        releaseEpisodeBrowserSuppression()
    }

    private var episodeRailIdentity: String {
        let first = seasonEpisodes.first?.contentId ?? "none"
        let last = seasonEpisodes.last?.contentId ?? "none"
        return "\(first)|\(last)|\(seasonEpisodes.count)"
    }

    private func revealHeroMetadata() {
        guard !reduceMotion else {
            heroRevealOpacity = 1
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            heroRevealOpacity = 0.88
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                heroRevealOpacity = 1
            }
        }
    }

    private func revealEpisodeRail() {
        guard !reduceMotion else {
            episodeRailRevealOpacity = 1
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            episodeRailRevealOpacity = 0.82
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: ContinuumTheme.normalDuration)) {
                episodeRailRevealOpacity = 1
            }
        }
    }

    /// Siri Remote Play/Pause is a page-level shortcut. A different episode
    /// highlighted in the rail wins; every other focus zone plays the episode
    /// represented by this detail page and preserves its selector overrides.
    private func playFocusedEpisodeOrCurrent() {
        if let focusedEpisodeContentId {
            onPlayFocusedEpisode?(focusedEpisodeContentId)
        } else if primaryPlayLabel != nil {
            onPlay(false)
        }
    }

    // MARK: - More Like This

    /// Hide on episode pages — viewers want the next episode, not
    /// tangentially related titles. The episode rail above already
    /// serves browsing.
    private var showsSimilarRail: Bool {
        detail.type == "movie" || detail.type == "series"
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
            TVDetailCastRail(
                cast: cast,
                onTap: onPersonTap,
                onFocusChanged: { isFocused in
                    castRailFocused = isFocused
                    if isFocused {
                        releaseEpisodeBrowserSuppression()
                        releaseEpisodeRailSuppression()
                    }
                }
            )
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
        effectivePlaybackDetail?.versions ?? []
    }

    private var currentVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: availableVersions,
            selectedFileId: selectedVersionFileId,
            lastFileId: effectivePlaybackDetail?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private var effectivePlaybackDetail: ItemDetail? {
        playbackDetail ?? (detail.type == "movie" || detail.type == "episode" ? detail : nil)
    }

    private var isSeriesFamily: Bool {
        detail.type == "series" || detail.type == "season" || detail.type == "episode"
    }

    private var heroSeriesTitle: String? {
        detail.type == "episode" ? detail.seriesTitle : nil
    }

    private var heroEyebrow: String? {
        switch detail.type {
        case "episode": nil
        case "season": detail.seriesTitle
        default: TVHeroMetadata.eyebrow(from: detail)
        }
    }

    private var heroSourceTokens: [String] {
        if detail.type == "series" {
            return TVHeroMetadata.seriesSourceTokens(from: detail)
        }
        if detail.type == "season" {
            var tokens: [String] = []
            if let count = detail.episodeCount, count > 0 {
                tokens.append("\(count) Episode\(count == 1 ? "" : "s")")
            } else if !seasonEpisodes.isEmpty {
                tokens.append("\(seasonEpisodes.count) Episode\(seasonEpisodes.count == 1 ? "" : "s")")
            }
            if let genres = detail.genres, !genres.isEmpty {
                tokens.append(contentsOf: genres.prefix(2))
            }
            return tokens
        }
        return TVHeroMetadata.movieSourceTokens(from: detail)
    }

    private var heroFactsLine: [TVHeroFactToken] {
        if detail.type == "series" {
            return TVHeroMetadata.seriesFactsLine(from: detail)
        }
        if detail.type == "season" {
            return []
        }
        return TVHeroMetadata.movieFactsLine(from: detail, version: currentVersion)
    }
}

/// Keeps the compact title and Season pills mounted in the native focus graph
/// while limiting per-frame invalidation to this render-only wrapper. A tiny
/// opacity floor is visually transparent but avoids the focus removal caused
/// by a literal zero without requiring an offscreen mask every frame.
private struct TVDetailCompactHeaderReveal: ViewModifier {
    let scrollVisualState: TVDetailScrollVisualState

    func body(content: Content) -> some View {
        content.opacity(max(opacity, 0.001))
    }

    private var opacity: Double {
        let progress = min(max((scrollVisualState.progress - 0.24) / 0.36, 0), 1)
        let eased = progress * progress * (3 - (2 * progress))
        return Double(eased)
    }
}
#endif
