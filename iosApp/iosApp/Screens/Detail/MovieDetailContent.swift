#if !os(tvOS)
import SwiftUI

/// Phone movie detail: artwork hero, then cast, trailers, Details and More
/// Like This. Mirrors TVMovieDetailView's metadata and actions, sized for touch.
struct MovieDetailContent<BelowOverview: View>: View {
    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let selectedVersionFileId: Int?
    let selectedAudioTrackIndex: Int?
    let selectedSubtitleTrackIndex: Int?
    /// `resumePosition` is the point the user was offered (nil for a
    /// restart or a title without progress).
    let onPlay: (_ startFromBeginning: Bool, _ resumePosition: Double?) -> Void
    /// Reads the title's current watch state from the server, so the resume
    /// prompt never offers a position another device has moved past.
    let refreshResumeState: () async -> DetailResumeState
    let onSelectVersion: (Int?) -> Void
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
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The position the resume prompt offers; non-nil while it is shown.
    @State private var pendingResumePosition: Double?
    /// The Play tap's in-flight watch-state read. A second tap replaces it.
    @State private var resumeLookupTask: Task<Void, Never>?
    /// The download options sheet, opened from the More menu.
    @State private var showDownloadOptions = false

    var body: some View {
        PhoneDetailPageSurface(
            backdropURL: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            enablesArtworkGlass: SiloMediaType.isMovieLibrary(detail.type)
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: heroToContentSpacing) {
                    hero
                    belowFold
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
            .detailScrollDismissal()
            .phoneDetailScrollTracking(scrollState)
        }
        .siloResumePlaybackAlert(
            isPresented: Binding(
                get: { pendingResumePosition != nil },
                set: { if !$0 { pendingResumePosition = nil } }
            ),
            stoppedAt: resumeTimestamp
        ) {
            guard let pendingResumePosition else { return }
            onPlay(false, pendingResumePosition)
        } onRestart: {
            onPlay(true, nil)
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

    private var hero: some View {
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
            ratings: detail.displayRatings,
            creditText: PhoneHeroMetadata.creditText(from: detail),
            enablesArtworkParallax: SiloMediaType.isMovieLibrary(detail.type),
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

    /// Play, the named secondary actions, then the trailer status pill.
    @ViewBuilder
    private var actionStack: some View {
        VStack(spacing: 14) {
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: DetailPlayLabel.item(detail.userData),
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
                        ? "Mark as Unwatched" : "Mark as Watched",
                    action: onToggleWatched
                )
                if showsDownloadButton {
                    DownloadActionButton(
                        detail: detail,
                        versions: availableVersions,
                        selectedVersionFileId: selectedVersionFileId,
                        showOptions: $showDownloadOptions
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
        resumeLookupTask?.cancel()
        resumeLookupTask = Task {
            let state = await refreshResumeState()
            guard !Task.isCancelled else { return }
            resumeLookupTask = nil
            if let position = state.resumePosition(cached: detail.userData) {
                pendingResumePosition = position
            } else {
                onPlay(false, nil)
            }
        }
    }
    /// Download is offered for movies once the
    /// server advertises the capability for this profile.
    private var showsDownloadButton: Bool {
        DownloadManager.shared.downloadsEnabled
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
            fileId: selectedVersionFileId, preview: WatchPartySelectedItem(previewing: detail))
        #endif
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
            if let cast = detail.cast, !cast.isEmpty {
                castSection(cast: cast)
            }

            trailersSection

            detailsSection
                .padding(.horizontal, SiloTheme.safePadding)

            similarSection
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
            PhoneSectionHeader(title: "Cast & Crew")
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
            PhoneSectionHeader(title: "Details")
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
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }
}
#endif
