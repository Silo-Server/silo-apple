#if os(tvOS)
import SwiftUI

/// Movie detail layout for tvOS. The hero fills the top of the
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
    /// Merged remote-video + local-extra rail, already shaped by the call
    /// site (which owns the YouTube-app availability probe that decides
    /// whether remote cards exist at all). Empty hides the rail.
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    /// Whether the manual "Find Trailers" action can be offered.
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
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool
    /// Whole recommendation rail focus, used only to keep its heading and
    /// focused poster comfortably framed during native vertical reveal.
    @FocusState private var similarRailFocused: Bool
    // Plain constants (not `static`) — the generic BelowSynopsis parameter
    // forbids static stored properties on this type.
    private let heroScrollId = "detail-hero"
    private let similarSectionScrollId = "detail-similar-section"
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared

    var body: some View {
        TVDetailPageSurface(backdropURL: detail.backdropUrl) {
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        TVDetailHero(
                            title: detail.title,
                            logoUrl: detail.logoUrl,
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
                    episodeSectionId: heroScrollId,
                    heroId: heroScrollId,
                    similarRailFocused: similarRailFocused,
                    similarSectionId: similarSectionScrollId
                )
                .tvActionPopoverHost()
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

    private enum MoreAction: String {
        case watchParty, favorite, watched, trailers
    }

    @Environment(AppRouter.self) private var partyRouter
    @Environment(\.browseLibraryId) private var partyLibraryId

    private var moreMenu: some View {
        TVCircleMenuButton(
            title: "More",
            accessibilityLabel: "More options",
            stabilizesFocusMotion: true,
            items: {
                var items: [TVActionPopoverItem] = [
                    TVActionPopoverItem(
                        id: MoreAction.favorite.rawValue,
                        title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorite ? "heart.fill" : "heart"
                    ),
                    TVActionPopoverItem(
                        id: MoreAction.watched.rawValue,
                        title: isWatched ? "Mark as Unwatched" : "Mark as Watched",
                        systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                    ),
                ]
                if supportsTrailerFetch {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.trailers.rawValue,
                        title: "Find Trailers",
                        systemImage: "film.stack"
                    ))
                }
                if WatchPartyEntry.isAvailable {
                    items.append(TVActionPopoverItem(id: MoreAction.watchParty.rawValue,
                        title: "Watch Party", systemImage: "person.3"))
                }
                return items
            },
            onSelect: { item in
                switch MoreAction(rawValue: item.id) {
                case .watchParty:
                    WatchPartyEntry.open(contentId: detail.contentId, title: detail.title, type: detail.type,
                        fileId: selectedVersionFileId, libraryId: partyLibraryId, router: partyRouter)
                case .favorite:
                    onToggleFavorite()
                case .watched:
                    onToggleWatched()
                case .trailers:
                    onFindTrailers()
                case .none:
                    break
                }
            }
        )
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

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        TVSimilarRail(
            contentId: detail.contentId,
            title: "Related Movies",
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
