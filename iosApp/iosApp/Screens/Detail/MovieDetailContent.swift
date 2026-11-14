#if !os(tvOS)
import SwiftUI

/// Phone movie detail: artwork hero, then cast, trailers and extras, the
/// box set, More Like This and Details. Mirrors TVMovieDetailView's metadata and actions, sized for touch.
struct MovieDetailContent<BelowOverview: View>: View {
    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    /// The box set the movie belongs to; nil draws no row.
    let boxSet: CatalogBoxSetDetail?
    let selectedVersionFileId: Int?
    /// The edition picked on this visit; nil opens on the last-played one.
    let selectedEditionId: String?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// The viewer picked Auto on this visit, so `detail`'s effective
    /// subtitle settings no longer describe what Auto plays.
    let subtitleOverrideCleared: Bool
    /// `resumePosition` is the point the user was offered (nil for a
    /// restart or a title without progress).
    /// `watchState` is the watch state the position came from; Play
    /// resolves its file from it.
    let onPlay: (_ startFromBeginning: Bool, _ resumePosition: Double?, _ watchState: LeafItemUserData?) -> Void
    /// Reads the title's current watch state from the server, so the resume
    /// prompt never offers a position another device has moved past.
    let refreshResumeState: () async -> DetailResumeState
    let onSelectVersion: (Int?) -> Void
    let onSelectEdition: (String) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    /// Play a local extra from the trailers rail. Routed separately from
    /// `onPlay` because extras have no resume point.
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
    /// Reference-backed scroll state observed only by the small parallax and
    /// pinned-chrome views, keeping the native ScrollView's body stable.
    let scrollState: PhoneDetailScrollState
    /// `detail` is the tapped card's seed: it has no files, watch state or
    /// credits yet, so Play and the actions wait in their loading form.
    var isProvisional = false
    /// The artwork the seed drew, kept on screen while `detail`'s loads.
    var seedArtwork: DetailSeedArtwork? = nil
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.locale) private var locale
    /// The position the resume prompt offers; non-nil while it is shown.
    @State private var pendingResumePosition: Double?
    /// The watch state `pendingResumePosition` came from.
    @State private var pendingResumeWatchState: LeafItemUserData?
    /// The Play tap's in-flight watch-state read. A second tap replaces it.
    @State private var resumeLookupTask: Task<Void, Never>?
    /// The download options sheet, opened from the More menu.
    @State private var showDownloadOptions = false
    /// The viewer opened the Media Info section.
    @State private var showsMediaInfo = false

    var body: some View {
        PhoneDetailPageSurface(
            backdropURL: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            enablesArtworkGlass: SiloMediaType.isMovieLibrary(detail.type),
            keepsSideSafeArea: true,
            fallbackBackdropURL: seedArtwork?.backdrop
        ) {
            PhoneDetailPageLayout(scrollState: scrollState) {
                VStack(alignment: .leading, spacing: heroToContentSpacing) {
                    hero()
                    PhoneDetailBelowFold { belowFold }
                }
                .padding(.bottom, 40)
            } paneArtwork: {
                hero(pane: .artwork)
            } paneSidebar: {
                VStack(spacing: 16) {
                    hero(pane: .sidebar)
                    if let effectiveVersion {
                        playbackSelectors(for: effectiveVersion)
                    }
                }
            } paneContent: {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(spacing: 14) {
                        hero(pane: .overview)
                        belowOverview()
                    }
                    .padding(.horizontal, SiloTheme.safePadding)
                    belowFold
                }
                .padding(.bottom, 40)
            }
        }
        .siloResumePlaybackAlert(
            isPresented: Binding(
                get: { pendingResumePosition != nil },
                set: { if !$0 { pendingResumePosition = nil } }
            ),
            stoppedAt: resumeTimestamp
        ) {
            guard let pendingResumePosition else { return }
            onPlay(false, pendingResumePosition, pendingResumeWatchState)
        } onRestart: {
            onPlay(true, nil, pendingResumeWatchState ?? detail.userData)
        }
        .onDisappear {
            resumeLookupTask?.cancel()
            resumeLookupTask = nil
        }
    }

    private var heroToContentSpacing: CGFloat {
        horizontalSizeClass == .regular ? 16 : 32
    }

    // MARK: - Hero

    private func hero(pane: PhoneDetailHeroPane? = nil) -> some View {
        PhoneDetailHero(
            title: detail.title,
            logoUrl: detail.logoUrl,
            posterUrl: detail.posterUrl,
            posterThumbhash: detail.posterThumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: PhoneHeroMetadata.eyebrow(from: detail),
            sourceTokens: PhoneHeroMetadata.movieSourceTokens(from: detail),
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: PhoneHeroMetadata.movieFactsLine(from: detail, version: effectiveVersion),
            // A card carries only some of the ratings row; it waits for the
            // detail rather than growing under the viewer.
            ratings: isProvisional ? [] : detail.displayRatings,
            creditText: PhoneHeroMetadata.creditText(from: detail),
            overlayData: OverlayData.from(detail),
            enablesArtworkParallax: SiloMediaType.isMovieLibrary(detail.type),
            pane: pane,
            fallbackArtworkUrl: seedArtwork?.hero,
            fallbackPosterUrl: seedArtwork?.poster,
            actions: { actionStack },
            belowOverview: { heroExtras }
        )
    }

    /// Under the overview in one column. A split page places the two parts
    /// separately: selectors in the sidebar, the translation under the overview.
    private var heroExtras: some View {
        VStack(spacing: 14) {
            belowOverview()
            if let effectiveVersion {
                playbackSelectors(for: effectiveVersion)
            }
        }
    }

    /// Play, the named secondary actions, then the trailer status pill.
    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 14) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                // A seed has no watch state, so neither Play nor Resume is known.
                title: isProvisional
                    ? AppLanguage.string(.commonLoading, locale: locale)
                    : DetailPlayLabel.item(detail.userData, shown: effectiveVersion, in: availableVersions),
                action: handlePlayTap,
                fullWidth: true
            )
            .disabled(isProvisional)

            PhoneLabeledActionRow {
                PhoneLabeledAction(
                    icon: "heart",
                    iconActive: "heart.fill",
                    isActive: isFavorite,
                    label: AppLanguage.string(.detailFavorite, locale: locale),
                    accessibilityLabelOverride: AppLanguage.string(
                        isFavorite ? .detailMoreRemoveFavorite : .detailMoreAddFavorite,
                        locale: locale
                    ),
                    action: onToggleFavorite
                )
                PhoneLabeledAction(
                    icon: "bookmark",
                    iconActive: "bookmark.fill",
                    isActive: inWatchlist,
                    label: AppLanguage.string(.detailWatchlist, locale: locale),
                    accessibilityLabelOverride: AppLanguage.string(
                        inWatchlist ? .personalWatchlistRemove : .cardMenuAddWatchlist,
                        locale: locale
                    ),
                    action: onToggleWatchlist
                )
                PhoneLabeledAction(
                    icon: "checkmark.circle",
                    iconActive: "checkmark.circle.fill",
                    isActive: isWatched,
                    label: AppLanguage.string(.detailWatched, locale: locale),
                    accessibilityLabelOverride: AppLanguage.string(
                        isWatched ? .detailMoreMarkUnwatched : .detailMoreMarkWatched,
                        locale: locale
                    ),
                    action: onToggleWatched
                )
                if showsDownloadButton {
                    DownloadActionButton(
                        detail: detail,
                        versions: availableVersions,
                        selectedVersionFileId: selectedVersionFileId,
                        selectedEditionId: selectedEditionId,
                        showOptions: $showDownloadOptions
                    )
                } else if showsUnavailableDownload {
                    DownloadUnavailableButton()
                }
                if hasOverflowMenu {
                    PhoneLabeledMenu(label: AppLanguage.string(.detailMore, locale: locale)) {
                        overflowMenuItems
                    }
                }
            }
            // Watched, Download and More act on state a seed lacks, and the
            // seed's favorite and watchlist flags are the card's.
            .disabled(isProvisional)

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
            // The effective settings arrive with the watch-detail enrichment.
            previewsAutoSubtitle: !subtitleOverrideCleared && detail.hasWatchDetailSubtitlePolicy == true,
            subtitleLanguage: detail.effectiveSubtitleLanguage,
            subtitleMode: detail.effectiveSubtitleMode,
            subtitleSignature: detail.effectiveSubtitleTrackSignature,
            showForcedSubtitles: detail.showsForcedSubtitles,
            onSelectVersion: onSelectVersion,
            onSelectEdition: onSelectEdition,
            onSelectAudioTrack: onSelectAudioTrack,
            onSelectSubtitleTrack: onSelectSubtitleTrack
        )
    }

    private func handlePlayTap() {
        resumeLookupTask?.cancel()
        resumeLookupTask = Task {
            let state = await refreshResumeState()
            guard !Task.isCancelled else { return }
            resumeLookupTask = nil
            let watchState = state.userData(cached: detail.userData)
            // A position saved on another edition than the one shown isn't
            // offered: Play starts the shown one at 0.
            if let position = state.resumePosition(cached: detail.userData),
               DetailVersionSelection.savedPositionIsInEdition(
                   of: effectiveVersion, in: availableVersions, userData: watchState
               ) {
                pendingResumeWatchState = watchState
                pendingResumePosition = position
            } else {
                onPlay(false, nil, watchState)
            }
        }
    }
    /// Download is offered for movies once the
    /// server advertises the capability for this profile.
    private var showsDownloadButton: Bool {
        DownloadManager.shared.downloadsEnabled
            && detail.type == "movie"
    }

    /// The server offers downloads but this account may not use them:
    /// Download stays in its place, unavailable, and says why when tapped.
    private var showsUnavailableDownload: Bool {
        DownloadManager.shared.downloadsRestricted
            && detail.type == "movie"
    }

    /// Movies always get the More menu: it holds "Find Trailers" and, with
    /// downloads on, the download options sheet.
    private var hasOverflowMenu: Bool {
        detail.type == "movie"
    }
    /// Menu contents for the action row's named "More" entry.
    @ViewBuilder
    private var overflowMenuItems: some View {
        #if os(iOS)
        WatchPartyMenuButton(contentId: detail.contentId, title: detail.title, type: detail.type,
            fileId: watchPartyFileId, preview: WatchPartySelectedItem(previewing: detail))
        #endif
        if showsDownloadButton {
            Button {
                showDownloadOptions = true
            } label: {
                Label(.detailMoreDownloadOptions, systemImage: "slider.horizontal.3")
            }
        }
        if detail.type == "movie" {
            Button(action: onFindTrailers) {
                Label(.detailMoreFindTrailers, systemImage: "film")
            }
            .disabled(isFindingTrailers)
        }
    }

    // MARK: - Below the fold

    private var belowFold: some View {
        VStack(alignment: .leading, spacing: 36) {
            if let cast = detail.cast, !cast.isEmpty {
                castSection(cast: cast)
            }

            trailersSection

            if let boxSet {
                PhoneBoxSetRow(boxSet: boxSet, currentContentId: detail.contentId)
            }

            similarSection

            // A seed's facts are a partial list; show the detail's whole one.
            if !isProvisional {
                detailsSection
                    .padding(.horizontal, SiloTheme.safePadding)
            }

            PhoneMediaInfoSection(version: effectiveVersion, isExpanded: $showsMediaInfo)
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

    // MARK: - Cast

    @ViewBuilder
    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: AppLanguage.string(.detailCast, locale: locale))
                .padding(.horizontal, SiloTheme.safePadding)
            PhoneCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - More Like This

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
            PhoneSectionHeader(title: AppLanguage.string(.detailDetails, locale: locale))
            PhoneDetailFactsSection(detail: detail)
        }
    }

    // MARK: - Resume / play helpers

    private var resumeTimestamp: String {
        guard let pos = pendingResumePosition else { return "0:00" }
        return PlayerTimeFormatter.formatHMS(pos)
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
            lastFileInProgress: detail.userData?.hasResumePoint ?? false,
            preferredQualityId: PlayerSettings.shared.connectionPreferredQuality,
            editionId: selectedEditionId,
            lastEditionKey: detail.userData?.lastEditionKey,
            variants: detail.playbackVariants
        )
    }

    /// The file a party starts from: the one the page shows once the viewer
    /// picked an edition or a version here, else the server's default.
    private var watchPartyFileId: Int? {
        selectedVersionFileId == nil && selectedEditionId == nil ? nil : effectiveVersion?.fileId
    }
}
#endif
