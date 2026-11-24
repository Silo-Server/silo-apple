#if os(tvOS)
import SwiftUI

/// Movie detail for tvOS: a full-width hero with Play, the version/audio/
/// subtitle selectors and More, then cast, trailers and extras, the box set,
/// recommendations and details rails.
struct TVMovieDetailView: View {
    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    /// The box set the movie belongs to; nil draws no row.
    var boxSet: CatalogBoxSetDetail? = nil
    let selectedVersionFileId: Int?
    /// The edition picked on this visit; nil opens on the last-played one.
    let selectedEditionId: String?
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
    let onPlay: (_ startFromBeginning: Bool) -> Void
    let onSelectVersion: (Int?) -> Void
    let onSelectEdition: (String) -> Void
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    /// Nil hides Not interested: the server predates it.
    var isNotInterested: Bool? = nil
    var onToggleNotInterested: (() -> Void)? = nil
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    /// On-view description translation status, drawn inside the synopsis.
    var synopsisStatus: DescriptionTranslationStatus? = nil
    /// Translate Description in the More menu; nil hides it. A More-menu
    /// item keeps the action reachable without adding a focus stop to the
    /// hero, whose synopsis is deliberately not focusable.
    var onTranslateDescription: (() -> Void)? = nil
    /// The viewer's rating, 1...10, nil when unrated.
    var userRating: Int? = nil
    /// False on the card's provisional copy of the page: the star button is
    /// shown but takes no input yet.
    var canRate = false
    /// Nil removes the rating. Nil hides the star button.
    var onSetRating: ((Int?) -> Void)? = nil

    @Namespace private var detailFocusNamespace
    @FocusState private var focusedAction: TVDetailAction?
    @State private var preferredAction: TVDetailAction = .play
    /// True while focus sits anywhere in the hero's primary action row —
    /// drives the scroll back to the page-entry (hero at top) framing.
    @FocusState private var actionRowFocused: Bool
    /// Whole poster rail focus (box set, recommendations), used only to keep
    /// the rail's heading and focused poster comfortably framed during native
    /// vertical reveal.
    @FocusState private var boxSetRailFocused: Bool
    @FocusState private var similarRailFocused: Bool
    /// True while the star button edits; the page below the action row is
    /// disabled meanwhile so remote presses have nowhere else to go.
    @State private var isRatingEditing = false
    @State private var collectionsModel: AddToCollectionModel?
    private let heroScrollId = "detail-hero"
    private let boxSetSectionScrollId = "detail-box-set-section"
    private let similarSectionScrollId = "detail-similar-section"
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared
    @Environment(\.locale) private var locale

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
                            sourceTokens: TVHeroMetadata.movieSourceTokens(from: detail, locale: locale),
                            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
                            overlayData: OverlayData.from(detail),
                            overview: detail.overview,
                            synopsisStatus: synopsisStatus,
                            factsLine: TVHeroMetadata.movieFactsLine(from: detail, version: currentVersion),
                            ratings: detail.displayRatings,
                            personalRating: TVHeroPersonalRating(score: userRating, isSeries: false),
                            starringText: TVHeroMetadata.starringText(from: detail, locale: locale),
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
                                showForcedSubtitles: detail.showsForcedSubtitles,
                                locale: locale
                            ),
                            actions: { actionColumn },
                            belowSynopsis: { EmptyView() }
                        )
                        .id(heroScrollId)

                        VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                            if let cast = detail.cast, !cast.isEmpty {
                                castSection(cast: cast)
                            }
                            trailersSection
                            if let boxSet {
                                TVBoxSetRow(boxSet: boxSet, currentContentId: detail.contentId)
                                    .focused($boxSetRailFocused)
                                    .id(boxSetSectionScrollId)
                            }
                            similarSection
                                .focused($similarRailFocused)
                                .id(similarSectionScrollId)
                            detailsSection
                        }
                        .padding(.horizontal, TVDetailLayout.horizontalInset)
                        .padding(.bottom, TVDetailLayout.pageBottomPadding)
                        .disabled(isRatingEditing)
                    }
                }
                .ignoresSafeArea()
                .focusScope(detailFocusNamespace)
                .defaultFocus($focusedAction, preferredAction, priority: .userInitiated)
                .detailFocusScroll(
                    proxy: scrollProxy,
                    actionRowFocused: actionRowFocused,
                    heroId: heroScrollId,
                    focusedPosterRailId: focusedPosterRailId
                )
                .tvActionPopoverHost()
                .onChange(of: detail.contentId) { _, _ in
                    collectionsModel = nil
                }
                .alert(
                    Text(.homeUpdateFailedTitle),
                    isPresented: Binding(
                        get: { collectionsModel?.errorMessage != nil && collectionsModel?.hasLoaded == true },
                        set: { if !$0 { collectionsModel?.clearError() } }
                    )
                ) {
                    Button(.homeUpdateFailedOk, role: .cancel) {}
                } message: {
                    if let error = collectionsModel?.errorMessage {
                        Text(verbatim: error)
                    }
                }
            }
        }
    }

    /// The poster rail section holding focus, which the page centers.
    private var focusedPosterRailId: String? {
        if boxSetRailFocused { return boxSetSectionScrollId }
        if similarRailFocused { return similarSectionScrollId }
        return nil
    }

    // MARK: - Hero actions

    private var actionColumn: some View {
        actionRow
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
            focusedAction: $focusedAction,
            preferredAction: $preferredAction,
            rowFocused: $actionRowFocused,
            stabilizesFocusMotion: true,
            primaryButtonWidth: 340,
            rating: ratingInput,
            isRatingEditing: $isRatingEditing,
            playbackSelectors: { focusedAction in
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
                    showForcedSubtitles: detail.showsForcedSubtitles,
                    preferredSubtitleLanguage: profilePrefsStore.preferredSubtitleLanguage,
                    onSelectVersion: onSelectVersion,
                    onSelectEdition: onSelectEdition,
                    onSelectAudioTrack: onSelectAudioTrack,
                    onSelectSubtitleTrack: onSelectSubtitleTrack,
                    focusedAction: focusedAction
                )
            },
            moreMenu: { moreMenu }
        )
    }

    private var ratingInput: TVDetailRating? {
        guard SiloMediaType.isMovieLibrary(detail.type), let onSetRating else { return nil }
        return TVDetailRating(
            score: userRating,
            isSeries: false,
            isWatched: isWatched,
            isAvailable: canRate,
            onChange: onSetRating
        )
    }

    // MARK: - More menu

    private enum MoreAction: String {
        case watchParty, favorite, watched, translate, notInterested
    }

    @Environment(AppRouter.self) private var partyRouter
    @Environment(\.browseLibraryId) private var partyLibraryId

    private var moreMenu: some View {
        TVCircleMenuButton(
            title: AppLanguage.string(.detailMore, locale: locale),
            accessibilityLabel: AppLanguage.string(.detailMoreOptions, locale: locale),
            stabilizesFocusMotion: true,
            items: {
                var items: [TVActionPopoverItem] = [
                    TVActionPopoverItem(
                        id: MoreAction.watched.rawValue,
                        title: AppLanguage.string(
                            isWatched ? .detailMoreMarkUnwatched : .detailMoreMarkWatched,
                            locale: locale
                        ),
                        systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle"
                    ),
                    TVActionPopoverItem(
                        id: MoreAction.favorite.rawValue,
                        title: AppLanguage.string(
                            isFavorite ? .detailMoreRemoveFavorite : .detailMoreAddFavorite,
                            locale: locale
                        ),
                        systemImage: isFavorite ? "heart.fill" : "heart"
                    ),
                ]
                let collectionChildren: [TVActionPopoverItem] = {
                    let loadingTitle = AppLanguage.string(.collectionsAddToLoading, locale: locale)
                    guard let model = collectionsModel else {
                        return [TVActionPopoverItem(id: "col:loading", title: loadingTitle, isEnabled: false)]
                    }
                    if model.isLoading && !model.hasLoaded {
                        return [TVActionPopoverItem(id: "col:loading", title: loadingTitle, isEnabled: false)]
                    }
                    if let error = model.errorMessage, !model.hasLoaded {
                        return [
                            TVActionPopoverItem(id: "col:error", title: error, isEnabled: false),
                            TVActionPopoverItem(id: "col:retry", title: AppLanguage.string(.commonRetry, locale: locale), systemImage: "arrow.clockwise"),
                        ]
                    }
                    if model.entries.isEmpty {
                        return [TVActionPopoverItem(
                            id: "col:empty",
                            title: AppLanguage.string(.collectionsAddToEmptyTv, locale: locale),
                            isEnabled: false
                        )]
                    }
                    return model.entries.map { entry in
                        TVActionPopoverItem(
                            id: "col:\(entry.id)",
                            title: entry.collection.name,
                            detail: AppLanguage.string(
                                .collectionsItemCount(count: entry.itemCount, LocaleFormat.groupedCount(entry.itemCount, locale: locale)),
                                locale: locale
                            ),
                            systemImage: "folder",
                            isSelected: entry.containsItem,
                            isEnabled: !model.busyCollectionIds.contains(entry.id)
                        )
                    }
                }()
                items.append(TVActionPopoverItem(
                    id: "add-to-collection-submenu",
                    title: AppLanguage.string(.collectionsAddToTitle, locale: locale),
                    systemImage: "folder.badge.plus",
                    children: collectionChildren
                ))
                if WatchPartyEntry.isAvailable {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.watchParty.rawValue,
                        title: WatchPartyEntry.actionTitle,
                        systemImage: "person.3",
                        startsSection: true
                    ))
                }
                var startedUtilitySection = false
                if onTranslateDescription != nil {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.translate.rawValue,
                        title: AppLanguage.string(.detailMoreTranslate, locale: locale),
                        systemImage: MachineTranslation.symbol,
                        startsSection: !startedUtilitySection
                    ))
                    startedUtilitySection = true
                }
                if let isNotInterested, onToggleNotInterested != nil {
                    items.append(TVActionPopoverItem(
                        id: MoreAction.notInterested.rawValue,
                        title: AppLanguage.string(
                            isNotInterested ? .cardMenuShowInRecommendations : .cardMenuNotInterested,
                            locale: locale
                        ),
                        systemImage: isNotInterested ? "hand.thumbsup" : "hand.thumbsdown",
                        startsSection: !startedUtilitySection
                    ))
                }
                return items
            },
            onOpen: {
                if collectionsModel == nil || collectionsModel?.contentId != detail.contentId {
                    let model = AddToCollectionModel(contentId: detail.contentId)
                    collectionsModel = model
                    Task { await model.load() }
                } else if let model = collectionsModel, !model.hasLoaded, !model.isLoading {
                    Task { await model.load() }
                }
            },
            onSelect: { item in
                if item.id == "col:retry" {
                    if let model = collectionsModel {
                        Task { await model.load() }
                    }
                    return
                }
                if item.id.hasPrefix("col:") {
                    let colId = String(item.id.dropFirst(4))
                    if let model = collectionsModel {
                        Task { await model.toggle(collectionId: colId) }
                    }
                    return
                }
                switch MoreAction(rawValue: item.id) {
                case .watchParty:
                    WatchPartyEntry.open(contentId: detail.contentId, title: detail.title, type: detail.type,
                        fileId: watchPartyFileId, libraryId: partyLibraryId,
                        preview: WatchPartySelectedItem(previewing: detail), router: partyRouter)
                case .favorite:
                    onToggleFavorite()
                case .watched:
                    onToggleWatched()
                case .translate:
                    onTranslateDescription?()
                case .notInterested:
                    onToggleNotInterested?()
                case .none:
                    break
                }
            }
        )
    }

    /// Nil also when the position was saved on another edition than the
    /// one shown: Play starts the shown one at 0.
    private var resumePositionSeconds: Double? {
        guard DetailVersionSelection.savedPositionIsInEdition(
            of: currentVersion, in: availableVersions, userData: detail.userData
        ) else { return nil }
        guard let pos = detail.userData?.positionSeconds, pos > 30 else { return nil }
        if let dur = detail.userData?.durationSeconds, dur > 0, pos >= dur - 5 {
            return nil
        }
        return pos
    }

    private var hasResumeProgress: Bool { resumePositionSeconds != nil }

    private var primaryPlayLabel: String {
        guard let pos = resumePositionSeconds else { return AppLanguage.string(.commonPlay, locale: locale) }
        return AppLanguage.string(.detailResumeAt(PlayerTimeFormatter.formatHMS(pos)), locale: locale)
    }

    private var similarSection: some View {
        // Header lives inside the rail so it disappears with the cards when
        // recommendations are disabled or empty.
        TVSimilarRail(
            contentId: detail.contentId,
            title: AppLanguage.string(.detailRelatedMovies, locale: locale),
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
            TVSectionHeader(title: AppLanguage.string(.detailCast, locale: locale))
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }

    // MARK: - Details section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: AppLanguage.string(.detailDetails, locale: locale))
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
        selectedVersionFileId == nil && selectedEditionId == nil ? nil : currentVersion?.fileId
    }
}
#endif
