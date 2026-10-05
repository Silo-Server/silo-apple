#if !os(tvOS)
import SwiftUI

/// Phone, iPad, and Mac audiobook detail, built on the same scaffold as
/// `MovieDetailContent`: the artwork page surface, `PhoneDetailHero`, the
/// named action row, and the shared section headers, rails, and Details
/// list. Book-specific pieces are the cover-forward hero, the listening
/// controls (progress-aware Resume, speed, start over), chapters and parts,
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
    /// On-view description-translation affordance, built at the detail call
    /// site (which owns the view model) and rendered under the overview.
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showAllChapters = false

    private let kind = BookDetailKind.audiobook

    private var presentation: BookDetailPresentation {
        BookDetailPresentation(detail: detail, isMarkedFinished: isWatched)
    }

    var body: some View {
        PhoneDetailPageSurface(
            backdropURL: hasBackdrop ? detail.backdropUrl : detail.posterUrl,
            backdropThumbhash: hasBackdrop ? detail.backdropThumbhash : detail.posterThumbhash,
            enablesArtworkGlass: true
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
    }

    private var heroToContentSpacing: CGFloat {
        horizontalSizeClass == .regular ? 16 : 32
    }

    private var hasBackdrop: Bool {
        !(detail.backdropUrl?.isEmpty ?? true)
    }

    // MARK: - Hero

    private var hero: some View {
        let presentation = presentation
        return PhoneDetailHero(
            title: presentation.title,
            logoUrl: detail.logoUrl,
            posterUrl: detail.posterUrl,
            posterThumbhash: detail.posterThumbhash,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: kind.eyebrow,
            sourceTokens: presentation.sourceTokens,
            ratingChip: PhoneHeroMetadata.contentRatingChip(from: detail),
            overview: detail.overview,
            factsLine: presentation.factsTokens.map(PhoneHeroFactToken.text),
            creditText: presentation.creditText,
            enablesArtworkParallax: true,
            artworkStyle: hasBackdrop
                ? .backdrop
                : .cover(aspectRatio: kind.coverAspectRatio, placeholderSymbol: kind.placeholderSymbol),
            actions: { actionStack(presentation) },
            belowOverview: { belowOverview() }
        )
    }

    /// Resume, then the same named action row movies use, with the watch
    /// wording swapped for book wording and listening controls in place of
    /// download.
    private func actionStack(_ presentation: BookDetailPresentation) -> some View {
        VStack(spacing: 14) {
            AudiobookPrimaryButton(
                contentId: detail.contentId,
                presentation: presentation,
                startPlayback: { restart, position in
                    startPlayback(restart: restart, startPosition: position)
                }
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
                    label: kind.queueLabel,
                    accessibilityLabelOverride: inWatchlist
                        ? "Remove from \(kind.queueLabel)" : "Add to \(kind.queueLabel)",
                    action: onToggleWatchlist
                )
                PhoneLabeledAction(
                    icon: "checkmark.circle",
                    iconActive: "checkmark.circle.fill",
                    isActive: isWatched,
                    label: kind.finishedLabel,
                    accessibilityLabelOverride: isWatched
                        ? "Mark as Not Finished" : "Mark as Finished",
                    action: onToggleWatched
                )
                AudiobookSpeedMenu()
                PhoneLabeledMenu(label: "More") {
                    moreMenuItems
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        Button {
            startPlayback(restart: true)
        } label: {
            Label("Start Over", systemImage: "arrow.counterclockwise")
        }
        if !otherNarrations.isEmpty {
            Menu {
                ForEach(otherNarrations) { narration in
                    Button(narrationLabel(narration)) {
                        onNavigateToItem(narration.contentId)
                    }
                }
            } label: {
                Label("Other Narrations", systemImage: "person.wave.2")
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
                coverRail(title: series.name ?? "Series", items: series.entries)
            }

            if !otherNarrations.isEmpty {
                narrationsSection
                    .padding(.horizontal, SiloTheme.safePadding)
            }

            if let alsoByAuthor = detail.audiobook?.related?.alsoByAuthor, !alsoByAuthor.isEmpty {
                coverRail(title: moreByAuthorTitle, items: alsoByAuthor)
            }

            detailsSection
                .padding(.horizontal, SiloTheme.safePadding)

            if let similar = detail.audiobook?.related?.similar, !similar.isEmpty {
                coverRail(title: "More Like This", items: similar)
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
            return "More by \(name)"
        }
        return "More by These Authors"
    }

    // MARK: - Chapters

    private func chaptersSection(_ chapters: [DisplayChapter]) -> some View {
        let visibleChapters = showAllChapters ? chapters : Array(chapters.prefix(chapterCollapseLimit))
        return VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Chapters", trailingText: "\(chapters.count)")
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
                                 ? "Show less"
                                 : "Show all \(chapters.count) chapters")
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
            PhoneSectionHeader(title: "Parts", trailingText: "\(parts.count)")
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
        switch (hasAuthors, hasNarrators) {
        case (true, false): return "Authors"
        case (false, true): return "Narrators"
        default: return "Authors & Narrators"
        }
    }

    /// Authors then narrators as cast-rail entries, with each person's role
    /// in the caption. Someone who both wrote and reads the book appears
    /// once, as "Author & Narrator".
    private var creditMembers: [CastMember] {
        var people: [(person: AudiobookPerson, roles: [String])] = []
        var indexById: [String: Int] = [:]
        let credited = (detail.audiobook?.authors ?? []).map { ($0, "Author") }
            + (detail.audiobook?.narrators ?? []).map { ($0, "Narrator") }
        for (person, role) in credited {
            if let index = indexById[person.id] {
                if !people[index].roles.contains(role) {
                    people[index].roles.append(role)
                }
            } else {
                indexById[person.id] = people.count
                people.append((person, [role]))
            }
        }
        return people.enumerated().map { order, entry in
            CastMember(
                name: entry.person.name,
                character: entry.roles.joined(separator: " & "),
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
            PhoneSectionHeader(title: "Other Narrations")
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
                                    Text(String(year))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.siloOnSurface.opacity(0.6))
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
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
            PhoneSectionHeader(title: "Details")
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
                    title = "Chapter \(chapter.index + 1)"
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
        return "Part \(displayIndex)"
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
    let startPlayback: (_ restart: Bool, _ startPosition: Double?) -> Void

    @Environment(AudioPlaybackStore.self) private var audioStore

    var body: some View {
        let player = audioStore.player
        if player.context?.contentId == contentId {
            let fraction = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : nil
            if player.isPlaying {
                PhonePrimaryPillButton(
                    icon: "waveform",
                    title: "Now Playing",
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
                    title: "Play Again",
                    action: { startPlayback(true, nil) },
                    fullWidth: true
                )
            } else {
                let left = PlayerTimeFormatter.formatRuntime(max(0, player.duration - player.currentTime))
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: left.isEmpty ? "Resume" : "Resume · \(left) left",
                    action: {
                        player.play()
                        audioStore.showFullPlayer()
                    },
                    fullWidth: true,
                    progress: fraction
                )
            }
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
        case .resume(let position):
            startPlayback(false, position)
        case .playAgain:
            startPlayback(true, nil)
        case .play:
            startPlayback(false, nil)
        }
    }
}

/// Playback speed menu. Reads the live rate itself for the same reason as
/// `AudiobookPrimaryButton`.
private struct AudiobookSpeedMenu: View {
    @Environment(AudioPlaybackStore.self) private var audioStore

    private let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        PhoneLabeledMenu(
            icon: "speedometer",
            label: "Speed \(speedLabel(audioStore.player.playbackRate))"
        ) {
            ForEach(speedOptions, id: \.self) { rate in
                Button {
                    audioStore.player.setPlaybackRate(rate)
                } label: {
                    if abs(audioStore.player.playbackRate - rate) < 0.01 {
                        Label(speedLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(rate))
                    }
                }
            }
        }
    }

    private func speedLabel(_ rate: Double) -> String {
        let value = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate))
            : String(format: "%g", rate)
        return "\(value)×"
    }
}

private struct DisplayChapter: Identifiable, Hashable {
    let id: String
    let title: String
    let startSeconds: Double
}
#endif
