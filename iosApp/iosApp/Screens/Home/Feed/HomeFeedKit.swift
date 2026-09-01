#if !os(tvOS)
import SwiftUI

// MARK: - Metrics

/// Layout constants shared by the Design Lab variants.
///
/// These deliberately diverge from `ContinuumTheme` in a few places — the
/// divergences *are* the proposal, and each one is called out below so the
/// reasoning survives the experiment.
enum HomeFeedMetrics {
    /// True 2:3, the ratio every poster source (TMDB, TVDB, Fanart) ships.
    /// The shipping card is 120×198 — a 1.65 ratio — so `.fill` + `.clipped()`
    /// currently shaves roughly 10% off both sides of every poster in the app.
    static let posterAspect: CGFloat = 3.0 / 2.0

    /// Wider than today's 120pt. At 120 the cards read as thumbnails against
    /// 24pt row gaps; the screen ends up feeling sparse rather than spacious.
    static let posterWidth: CGFloat = 132
    /// Poster Wall trades size for count.
    static let densePosterWidth: CGFloat = 104
    /// 16:9 still used by resume rows. Tuned so a still row shows the same
    /// "two cards plus a peek" as a poster row — at 210 the stills were
    /// noticeably less dense than the 132pt posters directly below them, which
    /// made the page rhythm feel inconsistent as you scrolled.
    static let stillWidth: CGFloat = 184
    /// Runway under the last row so captions clear the floating tab bar.
    static let bottomRunway: CGFloat = 96

    static let posterRadius: CGFloat = 10
    static let stillRadius: CGFloat = 12

    /// Screen gutter. Matches `ContinuumTheme.safePadding` so variants stay
    /// aligned with the rest of the app's chrome.
    static let gutter: CGFloat = 16
    static let cardSpacing: CGFloat = 10
    /// Row-to-row gap. Slightly wider than today's 24 because the rows
    /// themselves are now tighter internally.
    static let sectionSpacing: CGFloat = 30
    /// Header baseline to the top of the artwork.
    static let headerGap: CGFloat = 12
}

// MARK: - Feed helpers

/// Row-shaping helpers shared by the Home feed.
enum HomeFeed {
    /// Resume rows get 16:9 stills rather than posters — showing where you
    /// are inside a runtime is the row's entire job.
    static func isResume(_ section: ResolvedSection) -> Bool {
        let type = section.sectionType.lowercased()
        return type == "continue_watching" || type == "in_progress"
    }
}

// MARK: - Metadata formatting

enum HomeFeedMeta {
    static func runtime(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0, remainder > 0 { return "\(hours)h \(remainder)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(remainder)m"
    }

    static func remaining(position: Double?, duration: Double?) -> String? {
        guard let position, let duration, duration > 0, position > 0 else { return nil }
        let minutesLeft = Int((duration - position) / 60)
        guard minutesLeft > 0 else { return nil }
        return runtime(minutes: minutesLeft).map { "\($0) left" }
    }

    static func progress(for item: SectionItem) -> Double? {
        guard let position = item.positionSeconds,
              let duration = item.durationSeconds,
              duration > 0, position > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    /// "1968  ·  Horror  ·  1h 36m" — the meta line under a hero title.
    static func heroLine(for item: SectionItem, maxGenres: Int = 2) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let genres = item.genres, !genres.isEmpty {
            parts.append(contentsOf: genres.prefix(maxGenres))
        }
        if let runtime = runtime(minutes: item.runtime) { parts.append(runtime) }
        return parts.joined(separator: "  ·  ")
    }

    static func episodeCode(for item: SectionItem) -> String? {
        guard let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
        return "S\(season) E\(episode)"
    }

    /// Caption under a resume still — "S2 E4  ·  23m left".
    ///
    /// Some items carry a resume position but no duration, which left their
    /// card showing a progress bar and no caption while the card beside it had
    /// one — ragged, and it read like missing data. Percentage is a weaker
    /// answer than time remaining but it is still true, and it keeps every
    /// resume card the same height.
    static func resumeCaption(for item: SectionItem) -> String? {
        let progressText: String?
        if let remainingText = remaining(position: item.positionSeconds, duration: item.durationSeconds) {
            progressText = remainingText
        } else if let fraction = progress(for: item) {
            progressText = "\(Int((fraction * 100).rounded()))% watched"
        } else {
            progressText = nil
        }

        let pieces = [episodeCode(for: item), progressText].compactMap { $0 }
        return pieces.isEmpty ? nil : pieces.joined(separator: "  ·  ")
    }

    /// The title a card should be captioned with. Episodes caption with the
    /// series name — the bare episode title is frequently "TBA".
    static func cardTitle(for item: SectionItem) -> String {
        item.type.lowercased() == "episode" ? (item.seriesTitle ?? item.title) : item.title
    }

}

// MARK: - Navigation

/// Shared tap handling so every variant card pushes detail the same way,
/// including the iOS 26 zoom transition the shipping `MediaCard` uses.
private struct HomeCardTap<Label: View>: View {
    let contentId: String
    let accessibilityLabel: String
    @ViewBuilder var label: () -> Label

    @Environment(AppRouter.self) private var router
    @Environment(\.itemDetailBrowseSource) private var detailBrowseSource
    @Environment(\.zoomNamespace) private var zoomNamespace
    @State private var zoomInstanceID = UUID()

    var body: some View {
        Button {
            router.pendingZoomSourceID = zoomInstanceID.uuidString
            router.presentItemDetail(
                contentId: contentId,
                browseSource: detailBrowseSource
            )
        } label: {
            label()
                .zoomTransitionSource(id: zoomInstanceID.uuidString, in: zoomNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Card context menu

/// Long-press menu for a Home card.
///
/// `MediaCard` carries these actions on Browse and For You, so a card that
/// loses them on Home behaves differently depending on which tab you found it
/// in — and `HomeViewModel`'s dismiss/watched mutations become unreachable.
/// Same action set and ordering as `MediaCard`: watched toggle, personal
/// lists, then the destructive removal.
private struct HomeCardMenu: ViewModifier {
    let item: SectionItem
    let onRemoveFromContinueWatching: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?

    /// Owned by the card, not the menu, so the artwork's watched check flips
    /// with the menu label instead of waiting on the Home refresh —
    /// `MediaCard` drives its badge from the same effective state.
    @Binding var playedOverride: Bool?
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?

    private var isPlayed: Bool { playedOverride ?? (item.userState?.played == true) }
    private var isFavorite: Bool { favoriteOverride ?? (item.userState?.isFavorite == true) }
    private var inWatchlist: Bool { watchlistOverride ?? (item.userState?.inWatchlist == true) }

    /// Only cards backed by server user state get the personal-list entries,
    /// matching `MediaCard`.
    private var hasPersonalActions: Bool { item.userState != nil }

    private var hasAnyAction: Bool {
        hasPersonalActions || onSetWatched != nil || onRemoveFromContinueWatching != nil
    }

    func body(content: Content) -> some View {
        if hasAnyAction {
            content
                .contextMenu { menuItems }
                .onChange(of: item.userState) { _, _ in
                    playedOverride = nil
                    favoriteOverride = nil
                    watchlistOverride = nil
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let onSetWatched {
            Button {
                let played = !isPlayed
                Task { @MainActor in
                    playedOverride = played
                    if await onSetWatched(played) == false {
                        playedOverride = nil
                    }
                }
            } label: {
                Label(
                    isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isPlayed ? "circle" : "checkmark.circle"
                )
            }
        }

        if hasPersonalActions {
            PersonalListMenuItems(
                isFavorite: isFavorite,
                inWatchlist: inWatchlist,
                onToggleFavorite: toggleFavorite,
                onToggleWatchlist: toggleWatchlist
            )
        }

        if let onRemoveFromContinueWatching {
            Button(role: .destructive, action: onRemoveFromContinueWatching) {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    private func toggleFavorite() {
        let newValue = !isFavorite
        let watchlist = inWatchlist
        favoriteOverride = newValue
        Task {
            if await PersonalListSync.setFavorite(
                contentId: item.contentId, isFavorite: newValue, inWatchlist: watchlist
            ) == false {
                favoriteOverride = !newValue
            }
        }
    }

    private func toggleWatchlist() {
        let newValue = !inWatchlist
        let favorite = isFavorite
        watchlistOverride = newValue
        Task {
            if await PersonalListSync.setWatchlist(
                contentId: item.contentId, isFavorite: favorite, inWatchlist: newValue
            ) == false {
                watchlistOverride = !newValue
            }
        }
    }
}

// MARK: - Watched check

/// Top-trailing watched indicator shared by both Home cards.
private struct HomeWatchedCheck: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.continuumBackground)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.continuumOnSurface))
    }
}

// MARK: - Poster card

/// Poster card with the shipping card's flaws corrected: true 2:3 artwork,
/// a single-line title and the year folded onto the caption line instead of
/// occupying its own. Card overlays remain shared with the rest of the app.
struct HomePosterCard: View {
    let item: SectionItem
    var width: CGFloat = HomeFeedMetrics.posterWidth
    var showsCaption: Bool = true
    var showsMetadata: Bool = true
    /// Draws the resume rail across the bottom of the artwork.
    var showsProgress: Bool = false
    /// Audiobook covers are square; stretching one into a 2:3 poster crops
    /// its edges off.
    var aspect: MediaCardAspect = .poster
    /// "S2 · E10" for an episode rendered as a poster. Without it, several
    /// episodes of one series are captioned identically (they caption with
    /// the series name) and become indistinguishable cards.
    var episodeBadge: String? = nil
    /// Long-press actions, matching what `MediaCard` offers elsewhere.
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onSetWatched: ((Bool) async -> Bool)? = nil

    @EnvironmentObject private var overlayStore: OverlayPrefsStore
    /// Optimistic watched state, shared with the menu so the badge flips the
    /// moment "Mark as Watched" is tapped rather than after the Home refresh.
    @State private var playedOverride: Bool?

    private var isPlayed: Bool { playedOverride ?? (item.userState?.played == true) }

    private var height: CGFloat {
        switch aspect {
        case .poster: (width * HomeFeedMetrics.posterAspect).rounded()
        case .square: width
        }
    }

    var body: some View {
        HomeCardTap(
            contentId: item.contentId,
            accessibilityLabel: accessibilityDescription
        ) {
            VStack(alignment: .leading, spacing: 7) {
                artwork
                if showsCaption { caption }
            }
            .frame(width: width, alignment: .leading)
        }
        .modifier(HomeCardMenu(
            item: item,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: onSetWatched,
            playedOverride: $playedOverride
        ))
    }

    private var artwork: some View {
        AsyncImageView(
            url: item.posterUrl ?? "",
            thumbhash: item.posterThumbhash,
            targetSize: CGSize(width: width, height: height),
            contentMode: .fill
        )
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: HomeFeedMetrics.posterRadius, style: .continuous))
        // A hairline lifts the poster off a pure-black background. Without
        // it, dark artwork bleeds into the page and the card loses its edge.
        .overlay(
            RoundedRectangle(cornerRadius: HomeFeedMetrics.posterRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .overlay {
            // Home uses the same renderer and resolved profile preferences as
            // Browse, For You, Watchlist, and Favorites. Keep this below the
            // episode/progress/watched affordances so those controls retain
            // their established corner priority.
            if overlayStore.enabled {
                CardOverlays(
                    data: OverlayData.from(item),
                    prefs: overlayStore.prefs,
                    variant: .poster
                )
                .frame(width: width, height: height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: HomeFeedMetrics.posterRadius,
                        style: .continuous
                    )
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let episodeBadge {
                Text(episodeBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.65)))
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPlayed {
                HomeWatchedCheck()
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if showsProgress, let progress = HomeFeedMeta.progress(for: item) {
                ProgressBar(value: progress)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        }
        .overlay {
            DownloadedBadgeOverlay(contentId: item.contentId, padding: 6)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(HomeFeedMeta.cardTitle(for: item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.continuumOnSurface)
                // One line, always. Reserving two lines (as the shipping card
                // does) makes every row 17pt taller than it needs to be; letting
                // it wrap makes row baselines ragged. Truncation is the honest
                // answer — the poster already carries the identity.
                .lineLimit(1)
                .truncationMode(.tail)

            if showsMetadata, let year = item.year {
                Text(String(year))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.5))
                    .monospacedDigit()
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var accessibilityDescription: String {
        var components = [HomeFeedMeta.cardTitle(for: item)]
        components.append(contentsOf: [episodeBadge, item.year.map(String.init)].compactMap { $0 })
        if isPlayed {
            components.append("Watched")
        }
        return components.joined(separator: ", ")
    }
}

// MARK: - Still card (16:9)

/// Wide 16:9 card for resume rows. A half-watched episode is a *moment* in
/// a video, not a poster — the still plus an inline progress rail says
/// "you're 40 minutes into this" at a glance, which a 2:3 poster cannot.
struct HomeStillCard: View {
    let item: SectionItem
    var width: CGFloat = HomeFeedMetrics.stillWidth
    var showsCaption: Bool = true
    var showsMetadata: Bool = true
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var onSetWatched: ((Bool) async -> Bool)? = nil

    /// Optimistic watched state, shared with the menu — see `HomePosterCard`.
    @State private var playedOverride: Bool?
    @EnvironmentObject private var overlayStore: OverlayPrefsStore

    private var isPlayed: Bool { playedOverride ?? (item.userState?.played == true) }

    private var height: CGFloat { (width * 9.0 / 16.0).rounded() }

    /// Backdrop when the payload actually has one — some send `""` rather
    /// than omitting the field — otherwise the poster, with the thumbhash
    /// kept in lockstep so the blur placeholder previews the image that
    /// will actually load.
    private var art: (url: String, thumbhash: String?) {
        if let backdrop = item.backdropUrl, !backdrop.isEmpty {
            return (backdrop, item.backdropThumbhash)
        }
        return (item.posterUrl ?? "", item.posterThumbhash)
    }

    var body: some View {
        HomeCardTap(
            contentId: item.contentId,
            accessibilityLabel: accessibilityDescription
        ) {
            VStack(alignment: .leading, spacing: 8) {
                artwork
                if showsCaption { caption }
            }
            .frame(width: width, alignment: .leading)
        }
        .modifier(HomeCardMenu(
            item: item,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: onSetWatched,
            playedOverride: $playedOverride
        ))
    }

    private var artwork: some View {
        ZStack(alignment: .bottom) {
            AsyncImageView(
                url: art.url,
                thumbhash: art.thumbhash,
                targetSize: CGSize(width: width, height: height),
                contentMode: .fill
            )
            .frame(width: width, height: height)
            .clipped()

            // Scrim so the play affordance and rail stay legible over bright
            // stills without dimming the whole image.
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: height * 0.6)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            if overlayStore.enabled {
                CardOverlays(
                    data: OverlayData.from(item),
                    prefs: overlayStore.prefs,
                    variant: .wide
                )
                .frame(width: width, height: height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: HomeFeedMetrics.stillRadius,
                        style: .continuous
                    )
                )
            }

            if let progress = HomeFeedMeta.progress(for: item) {
                ProgressBar(value: progress)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: HomeFeedMetrics.stillRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HomeFeedMetrics.stillRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .overlay(alignment: .center) {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(0.32)))
                .overlay(Circle().stroke(.white.opacity(0.38), lineWidth: 0.75))
                .allowsHitTesting(false)
        }
        // A watched item can sit in Continue Watching again on a rewatch —
        // the check says "you've finished this before" alongside the rail's
        // "here's where you are now", same as the replaced EpisodeThumbCard.
        .overlay(alignment: .topTrailing) {
            if isPlayed {
                HomeWatchedCheck()
                    .padding(6)
            }
        }
        // Above the progress rail rather than on it — the rail owns the
        // bottom edge of a resume still.
        .overlay {
            DownloadedBadgeOverlay(contentId: item.contentId, padding: 6)
                .padding(.bottom, 10)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HomeFeedMeta.cardTitle(for: item))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.continuumOnSurface)
                .lineLimit(1)

            if showsMetadata, let subtitle = HomeFeedMeta.resumeCaption(for: item) {
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var accessibilityDescription: String {
        var components = [HomeFeedMeta.cardTitle(for: item)]
        if let resumeCaption = HomeFeedMeta.resumeCaption(for: item) {
            components.append(resumeCaption)
        }
        if isPlayed {
            components.append("Watched")
        }
        return components.joined(separator: ", ")
    }
}

// MARK: - Section header

/// Section header. Tighter and quieter than the shipping one: negative
/// tracking at this size stops the label sprawling, and the count/chevron
/// pair replaces the text "See All" button.
struct HomeSectionHeader: View {
    let title: String
    var icon: String? = nil
    var style: Style = .standard
    var onSeeAll: (() -> Void)? = nil

    enum Style {
        case standard
        /// Small uppercase label over a hairline rule — Poster Wall.
        case rule
    }

    var body: some View {
        switch style {
        case .standard: standardHeader
        case .rule: ruleHeader
        }
    }

    private var standardHeader: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.85))
            }

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.continuumOnSurface)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let onSeeAll {
                Button(action: onSeeAll) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.continuumOnSurface.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HomeFeedMetrics.gutter)
    }

    private var ruleHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let onSeeAll {
                    Button(action: onSeeAll) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.continuumOnSurface.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 0.5)
        }
        .padding(.horizontal, HomeFeedMetrics.gutter)
    }
}

// MARK: - Hero buttons
#endif
