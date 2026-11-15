#if !os(tvOS)
import SwiftUI

/// Phone, iPad, and Mac audiobook detail, drawn on the same `PhoneDetailPage`
/// as movies and series, with `PhoneDetailHero`, the named action row, and
/// the shared section headers, rails, and Details list. Opened from a card,
/// it draws the card's seed until the fetched detail replaces it, as they
/// do. Book-specific pieces are the cover-forward hero, the listening
/// controls (progress-aware Resume, start over), chapters and parts,
/// the author/narrator rail, and the series rails. Format wording and cover
/// shape come from `BookDetailKind`.
///
/// tvOS keeps its own audiobook page, `TVAudiobookDetailView`.
struct AudiobookDetailContent<BelowOverview: View>: View {
    let detail: ItemDetail
    var libraryId: Int? = nil
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    /// Reference-backed scroll state observed only by the small parallax and
    /// pinned-chrome views, keeping the native ScrollView's body stable.
    let scrollState: PhoneDetailScrollState
    /// `detail` is the tapped card's seed: it has no parts, listening
    /// progress or credits yet, so Play and the actions wait in their
    /// loading form.
    var isProvisional = false
    /// The artwork the seed drew, kept on screen while `detail`'s loads.
    var seedArtwork: DetailSeedArtwork? = nil
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.locale) private var locale
    @State private var showAllChapters = false

    private let kind = BookDetailKind.audiobook

    private var presentation: BookDetailPresentation {
        BookDetailPresentation(detail: detail, isMarkedFinished: isWatched)
    }

    var body: some View {
        // Without a backdrop the cover washes the page.
        PhoneDetailPage(
            backdropURL: hasBackdrop ? detail.backdropUrl : detail.posterUrl,
            backdropThumbhash: hasBackdrop ? detail.backdropThumbhash : detail.posterThumbhash,
            enablesArtworkGlass: true,
            fallbackBackdropURL: hasBackdrop ? seedArtwork?.backdrop : seedArtwork?.poster,
            scrollState: scrollState
        ) { pane in
            hero(pane: pane)
        } sidebarExtras: {
            EmptyView()
        } belowOverview: {
            belowOverview()
        } belowFold: {
            belowFold
        }
        // A downloaded book imported from the registry has no author on its
        // row until a detail names one.
        .task(id: "\(detail.contentId)|\(isProvisional)") {
            guard !isProvisional else { return }
            DownloadManager.shared.noteAudiobookAuthor(contentId: detail.contentId, author: presentation.playerSubtitle)
        }
    }

    private var hasBackdrop: Bool {
        !(detail.backdropUrl?.isEmpty ?? true)
    }

    // MARK: - Hero

    private func hero(pane: PhoneDetailHeroPane?) -> some View {
        let presentation = presentation
        return PhoneDetailHero(
            title: presentation.title,
            logoUrl: detail.logoUrl,
            posterUrl: detail.posterUrl,
            posterThumbhash: detail.posterThumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: AppLanguage.string(kind.eyebrow, locale: locale),
            sourceTokens: presentation.sourceTokens,
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: presentation.factsTokens.map(PhoneHeroFactToken.text),
            creditText: presentation.creditText,
            overlayData: nil,
            enablesArtworkParallax: true,
            artworkStyle: hasBackdrop
                ? .backdrop
                : .cover(aspectRatio: kind.coverAspectRatio, placeholderSymbol: kind.placeholderSymbol),
            pane: pane,
            fallbackArtworkUrl: seedArtwork?.hero,
            fallbackPosterUrl: seedArtwork?.poster,
            actions: { actionStack(presentation) },
            belowOverview: { belowOverview() }
        )
    }

    /// Resume, then the same named action row movies use, with the watch
    /// wording swapped for book wording and Download for a book stored as
    /// one file. Playback speed lives in the player.
    private func actionStack(_ presentation: BookDetailPresentation) -> some View {
        VStack(spacing: 14) {
            AudiobookPrimaryButton(
                contentId: detail.contentId,
                presentation: presentation,
                isProvisional: isProvisional,
                startPlayback: { restart, position in
                    startPlayback(restart: restart, startPosition: position)
                }
            )

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
                    label: AppLanguage.string(kind.queueLabel, locale: locale),
                    accessibilityLabelOverride: AppLanguage.string(
                        inWatchlist ? kind.queueRemoveLabel : kind.queueAddLabel,
                        locale: locale
                    ),
                    action: onToggleWatchlist
                )
                PhoneLabeledAction(
                    icon: "checkmark.circle",
                    iconActive: "checkmark.circle.fill",
                    isActive: isWatched,
                    label: AppLanguage.string(kind.finishedLabel, locale: locale),
                    accessibilityLabelOverride: AppLanguage.string(
                        isWatched ? .detailAudiobookMarkNotFinished : .detailAudiobookMarkFinished,
                        locale: locale
                    ),
                    action: onToggleWatched
                )
                if let part = downloadablePart {
                    if DownloadManager.shared.downloadsEnabled {
                        DownloadActionButton(
                            audiobook: detail,
                            part: part,
                            title: presentation.title,
                            author: presentation.playerSubtitle
                        )
                    } else if DownloadManager.shared.downloadsRestricted {
                        DownloadUnavailableButton()
                    }
                }
                PhoneLabeledMenu(label: AppLanguage.string(.detailMore, locale: locale)) {
                    moreMenuItems
                }
            }
            // Finished and Start Over act on state a seed lacks, and the
            // seed's favorite and queue flags are the card's.
            .disabled(isProvisional)
        }
        .frame(maxWidth: .infinity)
    }

    /// The book's one file, when it is stored as one. The server keeps a
    /// single download per book on a device, so a book split into several
    /// files can't be saved whole and isn't offered.
    private var downloadablePart: FileVersion? {
        let parts = AudiobookPlaybackContext.audioParts(of: detail)
        return parts.count == 1 ? parts.first : nil
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        Button {
            startPlayback(restart: true)
        } label: {
            Label(.detailStartOver, systemImage: "arrow.counterclockwise")
        }
        if !otherNarrations.isEmpty {
            Menu {
                ForEach(otherNarrations) { narration in
                    Button(narrationLabel(narration)) {
                        onNavigateToItem(narration.contentId)
                    }
                }
            } label: {
                Label(.detailAudiobookOtherNarrations, systemImage: "person.wave.2")
            }
        }
    }

    /// Every play affordance on the page starts through here so the player
    /// opens already showing this book's title, author, and cover.
    private func startPlayback(restart: Bool = false, startPosition: Double? = nil) {
        audioStore.play(
            contentId: detail.contentId,
            restart: restart,
            startPosition: startPosition,
            libraryId: libraryId,
            preview: AudioPlaybackPreview(
                contentId: detail.contentId,
                title: presentation.title,
                subtitle: presentation.playerSubtitle,
                posterUrl: detail.posterUrl
            )
        )
    }

    // MARK: - Below the fold

    private var belowFold: some View {
        // Derived once per render and handed to the sections.
        let audioParts = AudiobookPlaybackContext.audioParts(of: detail)
        let chapters = displayChapters(in: audioParts)
        let credits = creditMembers
        return VStack(alignment: .leading, spacing: 36) {
            if !chapters.isEmpty {
                chaptersSection(chapters)
                    .padding(.horizontal, SiloTheme.safePadding)
            }

            if audioParts.count > 1 {
                partsSection(audioParts)
                    .padding(.horizontal, SiloTheme.safePadding)
            }

            if !credits.isEmpty {
                creditsSection(credits)
            }

            if let series = detail.audiobook?.series, !series.entries.isEmpty {
                coverRail(
                    title: series.name ?? AppLanguage.string(.detailAudiobookSeries, locale: locale),
                    items: series.entries
                )
            }

            if !otherNarrations.isEmpty {
                narrationsSection
                    .padding(.horizontal, SiloTheme.safePadding)
            }

            if let alsoByAuthor = detail.audiobook?.related?.alsoByAuthor, !alsoByAuthor.isEmpty {
                coverRail(title: moreByAuthorTitle, items: alsoByAuthor)
            }

            // A seed's facts are a partial list; show the detail's whole one.
            if !isProvisional {
                detailsSection
                    .padding(.horizontal, SiloTheme.safePadding)
            }

            if let similar = detail.audiobook?.related?.similar, !similar.isEmpty {
                coverRail(title: AppLanguage.string(.detailMoreLikeThis, locale: locale), items: similar)
            }
        }
    }

    private func coverRail(title: String, items: [AudiobookRelatedItem]) -> some View {
        PhonePosterRail(
            title: title,
            items: items.map(SimilarPosterItem.init(audiobook:)),
            aspectRatio: kind.coverAspectRatio,
            placeholderSymbol: kind.placeholderSymbol,
            onSelect: onNavigateToItem
        )
    }

    private var moreByAuthorTitle: String {
        let authors = detail.audiobook?.authors ?? []
        if authors.count == 1, let name = authors.first?.name, !name.contains(",") {
            return AppLanguage.string(.detailAudiobookMoreByNamedAuthor(name), locale: locale)
        }
        return AppLanguage.string(.detailAudiobookMoreByTheseAuthors, locale: locale)
    }

    // MARK: - Chapters

    private func chaptersSection(_ chapters: [DisplayChapter]) -> some View {
        let visibleChapters = showAllChapters ? chapters : Array(chapters.prefix(chapterCollapseLimit))
        return VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(
                title: AppLanguage.string(.detailAudiobookChapters, locale: locale),
                trailingText: "\(chapters.count)"
            )
            VStack(spacing: 0) {
                ForEach(Array(visibleChapters.enumerated()), id: \.element.id) { index, chapter in
                    timelineRow(
                        icon: "play.fill",
                        title: chapter.title,
                        trailing: PlayerTimeFormatter.formatHMS(chapter.startSeconds),
                        showsDivider: index > 0
                    ) {
                        startPlayback(startPosition: chapter.startSeconds)
                    }
                }

                if chapters.count > chapterCollapseLimit {
                    Button {
                        withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                            showAllChapters.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(showAllChapters
                                 ? LocalizedStringResource.detailAudiobookChaptersShowLess
                                 : .detailAudiobookChaptersShowAll(count: chapters.count, LocaleFormat.integer(chapters.count)))
                            Image(systemName: showAllChapters ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func partsSection(_ parts: [FileVersion]) -> some View {
        let startOffsets = Self.partStartOffsets(parts)
        return VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(
                title: AppLanguage.string(.detailAudiobookParts, locale: locale),
                trailingText: "\(parts.count)"
            )
            VStack(spacing: 0) {
                ForEach(parts.indices, id: \.self) { index in
                    timelineRow(
                        icon: "waveform",
                        title: partTitle(parts[index], fallbackIndex: index),
                        trailing: PlayerTimeFormatter.formatRuntime(partDuration(parts[index])),
                        showsDivider: index > 0
                    ) {
                        startPlayback(startPosition: startOffsets[index])
                    }
                }
            }
        }
    }

    /// One tappable row in the chapter and part lists: a small play glyph,
    /// the title, and a quiet timestamp or length.
    private func timelineRow(
        icon: String,
        title: String,
        trailing: String,
        showsDivider: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                Spacer()
                Text(trailing)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Color.siloOnSurface.opacity(0.6))
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if showsDivider {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Authors & narrators

    private func creditsSection(_ credits: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: creditsTitle)
                .padding(.horizontal, SiloTheme.safePadding)
            PhoneCastRail(cast: credits, onTap: onPersonTap)
        }
    }

    private var creditsTitle: String {
        let hasAuthors = !(detail.audiobook?.authors.isEmpty ?? true)
        let hasNarrators = !(detail.audiobook?.narrators.isEmpty ?? true)
        let title: LocalizedStringResource
        switch (hasAuthors, hasNarrators) {
        case (true, false): title = .detailAudiobookAuthors
        case (false, true): title = .detailAudiobookNarrators
        default: title = .detailAudiobookAuthorsAndNarrators
        }
        return AppLanguage.string(title, locale: locale)
    }

    /// Authors then narrators as cast-rail entries, with each person's role
    /// in the caption. Someone who both wrote and reads the book appears
    /// once, as "Author & Narrator".
    private var creditMembers: [CastMember] {
        var people: [(person: AudiobookPerson, isAuthor: Bool, isNarrator: Bool)] = []
        var indexById: [String: Int] = [:]
        let credited = (detail.audiobook?.authors ?? []).map { ($0, true) }
            + (detail.audiobook?.narrators ?? []).map { ($0, false) }
        for (person, isAuthor) in credited {
            let index: Int
            if let existing = indexById[person.id] {
                index = existing
            } else {
                index = people.count
                indexById[person.id] = index
                people.append((person, false, false))
            }
            if isAuthor {
                people[index].isAuthor = true
            } else {
                people[index].isNarrator = true
            }
        }
        return people.enumerated().map { order, entry in
            let role: LocalizedStringResource = switch (entry.isAuthor, entry.isNarrator) {
            case (true, true): .detailAudiobookRoleAuthorAndNarrator
            case (true, false): .detailAudiobookRoleAuthor
            default: .detailAudiobookRoleNarrator
            }
            return CastMember(
                name: entry.person.name,
                character: AppLanguage.string(role, locale: locale),
                order: order,
                personId: entry.person.personId,
                tmdbId: nil,
                tvdbId: nil,
                imdbId: nil,
                photoUrl: entry.person.photoUrl,
                photoThumbhash: entry.person.photoThumbhash
            )
        }
    }

    // MARK: - Narrations

    private var narrationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: AppLanguage.string(.detailAudiobookOtherNarrations, locale: locale))
            VStack(spacing: 0) {
                ForEach(Array(otherNarrations.enumerated()), id: \.element.id) { index, narration in
                    Button {
                        onNavigateToItem(narration.contentId)
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "person.wave.2")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.siloOnSurface)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(narrationLabel(narration))
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.siloOnSurface)
                                    .lineLimit(1)
                                if let year = narration.year {
                                    Text(LocaleFormat.integer(year, locale: locale))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.siloOnSurface.opacity(0.6))
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func narrationLabel(_ narration: AudiobookNarration) -> String {
        narration.narrators.isEmpty ? narration.title : narration.narrators.joined(separator: ", ")
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: AppLanguage.string(.detailDetails, locale: locale))
            PhoneDetailFactsSection(detail: detail)
        }
    }

    // MARK: - Timeline data

    private var otherNarrations: [AudiobookNarration] {
        detail.audiobook?.otherNarrations ?? []
    }

    private func displayChapters(in parts: [FileVersion]) -> [DisplayChapter] {
        var offset = 0.0
        var chapters: [DisplayChapter] = []
        for part in parts {
            for chapter in part.chapters ?? [] {
                let title: String
                if let chapterTitle = chapter.title, !chapterTitle.isEmpty {
                    title = chapterTitle
                } else {
                    title = AppLanguage.string(.detailAudiobookChapter(LocaleFormat.integer(chapter.index + 1, locale: locale)), locale: locale)
                }
                chapters.append(DisplayChapter(
                    id: "\(part.fileId)-\(chapter.index)-\(chapter.startSeconds)",
                    title: title,
                    startSeconds: offset + chapter.startSeconds
                ))
            }
            offset += partDuration(part)
        }
        return chapters.sorted { $0.startSeconds < $1.startSeconds }
    }

    private let chapterCollapseLimit = 8

    private func partTitle(_ part: FileVersion, fallbackIndex: Int) -> String {
        if let fileName = part.fileName, !fileName.isEmpty {
            return fileName
        }
        let rawIndex = part.presentationPartIndex ?? fallbackIndex
        let displayIndex = rawIndex <= 0 ? rawIndex + 1 : rawIndex
        return AppLanguage.string(.detailAudiobookPart(LocaleFormat.integer(displayIndex, locale: locale)), locale: locale)
    }

    private func partDuration(_ part: FileVersion) -> Double {
        AudiobookPlaybackContext.partDuration(part)
    }

    /// Where each part starts on the whole-book timeline.
    private static func partStartOffsets(_ parts: [FileVersion]) -> [Double] {
        var offset = 0.0
        return parts.map { part in
            defer { offset += AudiobookPlaybackContext.partDuration(part) }
            return offset
        }
    }
}

// MARK: - Live player controls

/// The primary play control. While this book is the active session it
/// reflects the live player instead of the (stale) detail payload: it reopens
/// the player when playing, resumes and reopens it when paused, and restarts
/// the book once the session has reached the end. It reads the player itself,
/// so playback-time ticks re-render this button rather than the whole hero.
private struct AudiobookPrimaryButton: View {
    let contentId: String
    let presentation: BookDetailPresentation
    /// The page shows the card's seed, which has no listening progress.
    let isProvisional: Bool
    let startPlayback: (_ restart: Bool, _ startPosition: Double?) -> Void

    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.locale) private var locale

    var body: some View {
        let player = audioStore.player
        if player.context?.contentId == contentId {
            let fraction = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : nil
            if player.isPlaying {
                PhonePrimaryPillButton(
                    icon: "waveform",
                    title: AppLanguage.string(.detailNowPlaying, locale: locale),
                    action: { audioStore.showFullPlayer() },
                    fullWidth: true,
                    progress: fraction
                )
            } else if AudiobookProgress.isFinished(
                played: false,
                position: player.currentTime,
                totalDuration: player.duration
            ) {
                // The session reached the end. Playing from there would stop
                // at once, so restart the book like the finished state does.
                PhonePrimaryPillButton(
                    icon: "arrow.counterclockwise",
                    title: AppLanguage.string(.detailPlayAgain, locale: locale),
                    action: { startPlayback(true, nil) },
                    fullWidth: true
                )
            } else {
                let left = PlayerTimeFormatter.formatRuntime(max(0, player.duration - player.currentTime))
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: AppLanguage.string(left.isEmpty ? .detailResume : .detailResumeTimeLeft(left), locale: locale),
                    action: {
                        player.play()
                        audioStore.showFullPlayer()
                    },
                    fullWidth: true,
                    progress: fraction
                )
            }
        } else if isProvisional {
            // Neither Play nor Resume is known until the detail answers.
            PhonePrimaryPillButton(
                icon: "play.fill",
                title: AppLanguage.string(.commonLoading, locale: locale),
                action: {},
                fullWidth: true
            )
            .disabled(true)
        } else {
            PhonePrimaryPillButton(
                icon: presentation.primaryIcon,
                title: presentation.primaryLabel,
                action: { performPrimaryAction(presentation.primaryAction) },
                fullWidth: true,
                progress: presentation.resumeFraction
            )
        }
    }

    /// Audiobooks resume where the listener left off without the movie
    /// page's resume prompt; Start Over lives in the More menu.
    private func performPrimaryAction(_ action: BookDetailPresentation.PrimaryAction) {
        switch action {
        case .resume:
            // The player picks the resume point: the server's, or this
            // device's newer one for a downloaded book whose listening
            // hasn't reached the server yet. The page's copy can be stale.
            startPlayback(false, nil)
        case .playAgain:
            startPlayback(true, nil)
        case .play:
            startPlayback(false, nil)
        }
    }
}

private struct DisplayChapter: Identifiable, Hashable {
    let id: String
    let title: String
    let startSeconds: Double
}
#endif
