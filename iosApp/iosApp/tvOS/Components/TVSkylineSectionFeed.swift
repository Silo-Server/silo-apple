#if os(tvOS)
import SwiftUI

/// Shared Skyline landing layout (§6.1): an ambient backdrop, a focus
/// marquee that passively previews the focused card, and native vertically
/// scrolling section rows. Shared by Home, library Browse, For You, and the
/// Watch Party picker so they render identically; only the sections differ.
///
/// Row-to-row movement belongs to the tvOS focus engine and the vertical
/// scroll view. Programmatic focus is reserved for entering the page and
/// returning from detail; ordinary Up/Down movement stays geometric.
struct TVSkylineSectionFeed: View {
    /// Section rows to page through, in order (already filtered to rows
    /// with cards, `hasCards`, and non-featured by the caller). A row may
    /// hold collections instead of titles.
    let sections: [ResolvedSection]
    /// The app language, so a switch gives the marquee the row's current title.
    @Environment(\.locale) private var locale
    /// Marquee scale. Every Skyline landing currently uses `.home` so the
    /// pages render identically; kept as a parameter for explicit variants.
    var marqueeScale: TVFocusMarquee.Scale = .home
    /// Focus hand-down token from the shell — claims the first card on entry.
    var focusRequest: Int = 0
    /// Return token from a card-pushed detail page. Every row receives it, but
    /// only the row that owned focus before the push may reclaim its last card.
    var detailReturnFocusRequest: Int = 0
    /// Whether the top menu currently holds focus. A late content load must
    /// not steal focus while the user is up in the menu.
    var isTopMenuFocused: Bool = false
    /// Up at the first page hands focus to the top bar.
    let onTopMenuFocusRequest: (() -> Void)?
    /// Open a content item (detail).
    let onItemTap: (_ destinationContentId: String, _ item: SectionItem) -> Void
    /// Opens a row's full page from its trailing Explore all card. Home and
    /// library feeds supply it; feeds of rows without a page leave it nil.
    var onExploreAll: ((ResolvedSection) -> Void)? = nil
    /// Optional Home-only action. Library feeds leave this nil.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    /// Optional Home-only watched-state mutation. Library feeds leave this nil.
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil

    /// Immediate foreground content with a separately delayed backdrop.
    @State private var marqueeModel: TVFocusMarqueeModel
    /// Token handed only to row 1 when the shell explicitly enters content.
    /// It is never changed during ordinary row-to-row navigation.
    @State private var contentFocusToken = 0
    /// Entry tokens that arrived before any row mounted — sections load
    /// async, so the initial hand-down would land on nothing.
    @State private var pendingFocusRequest: Int?
    @State private var lastAppliedRequest = 0
    /// The row that owns card focus or its context-menu dismissal flow. Unlike
    /// the marquee preview, this is cleared when focus moves into chrome.
    @State private var focusRestorationOwnerSectionId: String?
    /// The row the built rows center on: the last row to take card focus or
    /// an entry claim. Found by id, so rows added or removed above it don't
    /// move the built range off the focused row. It holds while the menu has
    /// focus.
    @State private var builtRowCenter: BuiltRowCenter?
    /// Each built row's last measured height, so a row that leaves the built
    /// range keeps its exact place as an empty spacer.
    @State private var rowHeights: [String: CGFloat] = [:]
    /// Bumped when the row that owned focus leaves while the feed is on
    /// screen. It rides on the detail-return request, so the row that took its
    /// place claims focus the way it does after Back.
    @State private var removedOwnerFocusRequest = 0
    @State private var isOnScreen = false
    /// The card the marquee content was last built from, kept so a spoiler
    /// settings change can rebuild it. The settings load after sign-in and
    /// can land after Home has already seeded the marquee.
    @State private var marqueeSource: TVSkylineMarqueeSource?

    init(
        sections: [ResolvedSection],
        libraryId: Int? = nil,
        marqueeScale: TVFocusMarquee.Scale = .home,
        focusRequest: Int = 0,
        detailReturnFocusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)?,
        onItemTap: @escaping (String, SectionItem) -> Void,
        onExploreAll: ((ResolvedSection) -> Void)? = nil,
        onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil,
        onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    ) {
        self.sections = sections
        self.marqueeScale = marqueeScale
        self.focusRequest = focusRequest
        self.detailReturnFocusRequest = detailReturnFocusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
        self.onItemTap = onItemTap
        self.onExploreAll = onExploreAll
        self.onRemoveFromContinueWatching = onRemoveFromContinueWatching
        self.onSetWatched = onSetWatched
        _marqueeModel = State(initialValue: TVFocusMarqueeModel(libraryId: libraryId))
    }

    var body: some View {
        ZStack(alignment: .top) {
            TVSkylineBackdrop(model: marqueeModel)

            // Native scrolling lives only in the bottom row band. The viewport
            // clips at its top edge so rows do not paint through the marquee
            // title, description, and metadata while they scroll upward.
            scrollingRows
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)

            // Floats over the band above the row; never focusable or hit-testable.
            TVSkylineMarquee(model: marqueeModel, scale: marqueeScale)
            .offset(y: SiloTheme.Skyline.landingContentVerticalOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.browseLibraryId, marqueeModel.libraryId)
        .onAppear {
            isOnScreen = true
            marqueeModel.resume()
            seedMarqueeFromFirstItem()
            requestEntryFocus(focusRequest)
        }
        .onDisappear {
            isOnScreen = false
            marqueeModel.suspend()
        }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: isTopMenuFocused) { _, isFocused in
            if isFocused {
                focusRestorationOwnerSectionId = nil
            }
        }
        // Rows mount only after the async section load; a deferred entry
        // token re-fires once they exist.
        .onChange(of: sections.map(\.id)) { oldIds, newIds in
            handOffRemovedRows(from: oldIds, to: newIds)
            seedMarqueeFromFirstItem()
            if let pending = pendingFocusRequest { requestEntryFocus(pending) }
        }
        .onChange(of: sections.map(\.items)) { _, _ in refreshMarqueeSource() }
        .onChange(of: sections.map(\.collections)) { _, _ in refreshMarqueeSource() }
        // A collection preview names another profile's collection from the
        // profile list, which can arrive after the first preview is built.
        .task(id: sections.flatMap(\.collections).compactMap(\.creatorProfileId)) {
            let cards = sections.flatMap(\.collections)
            guard CollectionOwnerName.needsProfiles(cards),
                  await CollectionOwnerName.profiles() != nil,
                  case .collection = marqueeSource else { return }
            refreshMarqueeSource()
        }
        .onChange(of: EpisodeSpoilerPreferences.shared.settings) { _, _ in
            guard let source = marqueeSource else { return }
            marqueeModel.replaceContent(marqueeContent(for: source))
        }
    }

    // MARK: - Rows

    /// Native vertical row scrolling, clipped to the lower band so rows always
    /// appear from the same bottom area and disappear before the marquee text.
    @ViewBuilder
    private var scrollingRows: some View {
        GeometryReader { proxy in
            let bandHeight = proxy.size.height * SiloTheme.Skyline.rowBandHeightFraction
            // Position the focusable viewport with layout, not a render
            // offset. Its bottom must match the screen's bottom: otherwise
            // tvOS can resolve directional clicks against offscreen space
            // while a swipe still pans far enough to reveal the next target.
            let bandTop = min(
                proxy.size.height,
                max(0, proxy.size.height - bandHeight + SiloTheme.Skyline.landingContentVerticalOffset)
            )
            let visibleBandHeight = max(0, proxy.size.height - bandTop)
            let trailingPreviewPadding = max(
                0,
                visibleBandHeight - SiloTheme.Skyline.rowBandBottomInset
            )

            ScrollView(.vertical, showsIndicators: false) {
                // The rows near focus are built and the rest stand in as
                // spacers, which bounds the live view graph the way a lazy
                // stack would. A lazy stack unloads the row above the resting
                // one, though, and a quick run of Up presses then reached a
                // row with nothing loaded above it: the last press landed on
                // the top bar, and the first row stayed unloaded (#1152).
                let builtCenter = builtRowCenterIndex
                VStack(alignment: .leading, spacing: SiloTheme.Skyline.rowBandPreviewSpacing) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        Group {
                            if isRowBuilt(index, center: builtCenter) {
                                featuredRow(section, index: index)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                        if rowHeights[section.id] != height {
                                            rowHeights[section.id] = height
                                        }
                                    }
                            } else {
                                Color.clear
                                    .frame(height: rowHeights[section.id] ?? estimatedRowHeight)
                            }
                        }
                        .id(section.id)
                    }
                }
                .scrollTargetLayout()
                // Allows the final row to top-align like every prior row,
                // with a blank preview area underneath instead of clamping.
                .padding(.bottom, trailingPreviewPadding)
            }
            .scrollTargetBehavior(.viewAligned)
            // Row changes animate the band; the marquee holds its backdrop
            // swap until the scroll settles so the two never composite in
            // the same frames.
            .onScrollPhaseChange { _, phase in
                marqueeModel.setBackdropDeferred(phase != .idle)
            }
            .modifier(TVMenuEntryScroll(request: lastAppliedRequest, isTopMenuFocused: isTopMenuFocused, onReady: claimEntryFocus))
            .frame(width: proxy.size.width, height: visibleBandHeight, alignment: .topLeading)
            .clipped()
            .padding(.top, bandTop)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func featuredRow(_ section: ResolvedSection, index: Int) -> some View {
        let isFirstRow = index == 0
        SectionRow(
            section: section,
            onItemTap: onItemTap,
            onExploreAll: onExploreAll.map { open in { open(section) } },
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: onSetWatched,
            // Cold entry: let the engine's *initial* focus resolution land on
            // the first card so it renders already focused instead of growing
            // a few frames after the page paints. `.automatic` keeps d-pad
            // movement between rows geometric — only system-initiated
            // resolutions use the preference. While the top menu owns focus
            // the priority is raised to `.userInitiated`: a Down press from
            // the bar is resolved natively by the engine (the bar's
            // `onMoveCommand` only fires when no native move exists), and
            // without the preference it lands on whichever card sits under
            // the centered tab instead of the left-most one. The imperative
            // entry token below is unchanged and covers every other entry path.
            prefersDefaultFocusOnFirstItem: isFirstRow,
            defaultFocusPriority: isTopMenuFocused ? .userInitiated : .automatic,
            focusRequest: isFirstRow ? contentFocusToken : 0,
            detailReturnFocusRequest: detailReturnFocusRequest + removedOwnerFocusRequest,
            // This is the sole directional interception: Up from the first
            // content row crosses the intentional page-to-tab-bar boundary.
            // Every other vertical move remains native.
            onMoveUp: isFirstRow ? onTopMenuFocusRequest : nil,
            onItemFocus: { item in
                noteRowFocus(section.id)
                previewFocusedItem(item, in: section)
            },
            // The marquee keeps the last card it previewed.
            onExploreAllFocus: { noteRowFocus(section.id) },
            onCollectionFocus: { card in
                noteRowFocus(section.id)
                previewFocusedCollection(card, in: section)
            },
            cardWidth: SiloTheme.Skyline.denseCardWidth(for: SectionRow.layout(for: section)),
            cardVerticalPadding: SiloTheme.Skyline.rowBandCardVerticalPadding,
            focusRestorationOwner: Binding(
                get: { focusRestorationOwnerSectionId == section.id },
                set: { ownsRestoration in
                    // A row may reassert ownership while its context menu is
                    // dismissing. Ignore false writes—the next real card focus,
                    // top-menu focus, or row change remains authoritative.
                    if ownsRestoration {
                        focusRestorationOwnerSectionId = section.id
                    }
                }
            )
        )
        .modifier(TVSkylineArtworkVisibility(onVisible: { warmRows(after: index) }))
    }

    /// Decode the leading cards of the rows below one that came into view,
    /// so a Down press reveals painted artwork rather than thumbhashes.
    private func warmRows(after index: Int) -> [CardArtwork] {
        let next = sections.dropFirst(index + 1).prefix(ArtworkLookahead.rowsAhead)
        let titles = ArtworkLookahead.warmRows(next, items: \.items) { section, item in
            let layout = SectionRow.layout(for: section)
            return MediaRow.cardArtwork(
                for: item,
                layout: layout,
                cardWidth: SiloTheme.Skyline.denseCardWidth(for: layout)
            )
        }
        let collections = ArtworkLookahead.warmRows(next, items: \.collections) { _, card in
            TVCollectionsRow.cardArtwork(for: card, cardWidth: SiloTheme.Skyline.denseCardWidth(for: .poster))
        }
        return titles + collections
    }

    // MARK: - Focus

    /// Entry focus → the first row's first card. Tokens that arrive before
    /// the rows mount wait as a pending claim. A claim is dropped while the
    /// menu holds focus, so neither a late fetch (library loads async, so its
    /// feed mounts after entry) nor a stale token ever yanks focus away from
    /// the user once they've moved up into the bar. On a normal tab entry the
    /// shell has already relinquished the menu, so the claim proceeds. The
    /// request token is monotonic, so re-entry always lands fresh while
    /// onAppear/onChange can't double-claim the same value.
    private func requestEntryFocus(_ request: Int) {
        guard request > 0 else { return }
        guard !sections.isEmpty else {
            pendingFocusRequest = request
            return
        }
        pendingFocusRequest = nil
        if isTopMenuFocused { return }
        guard request != lastAppliedRequest else { return }
        lastAppliedRequest = request
    }

    private func claimEntryFocus(_ request: Int) {
        guard !isTopMenuFocused,
              lastAppliedRequest == request,
              let firstSectionId = sections.first?.id else { return }
        noteRowFocus(firstSectionId)
        contentFocusToken += 1
    }

    // MARK: - Built rows

    /// Rows built above the focused one. Up needs the row above built, and
    /// each move re-centers the range, but a quick run of Up can arrive before
    /// the re-center, so the range keeps one more row above as margin.
    private static let builtRowsAbove = 2
    /// Rows built below the focused one, so Down has a target.
    private static let builtRowsBelow = 1
    /// Leading rows that stay built, so a page entry that scrolls to the top
    /// finds the first row there.
    private static let alwaysBuiltLeadingRows = 1

    private struct BuiltRowCenter: Equatable {
        var id: String
        /// The row's index when it became the center. Used only for the one
        /// update after the row is removed and before the center is handed
        /// off, so the rows around it stay built.
        var index: Int
    }

    /// A card in this row took focus: it owns restoration, and the built
    /// rows center on it.
    private func noteRowFocus(_ sectionId: String) {
        focusRestorationOwnerSectionId = sectionId
        centerBuiltRows(on: sectionId)
    }

    private func centerBuiltRows(on sectionId: String) {
        guard let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        builtRowCenter = BuiltRowCenter(id: sectionId, index: index)
    }

    private var builtRowCenterIndex: Int {
        guard let center = builtRowCenter, !sections.isEmpty else { return 0 }
        return sections.firstIndex { $0.id == center.id } ?? min(center.index, sections.count - 1)
    }

    private func isRowBuilt(_ index: Int, center: Int) -> Bool {
        index < Self.alwaysBuiltLeadingRows
            || (center - Self.builtRowsAbove...center + Self.builtRowsBelow).contains(index)
    }

    /// The row that takes a removed row's place: the one now at its index, or
    /// the last row when it was last. Nil while the row is still present.
    private static func replacementId(
        for id: String?, from oldIds: [String], to newIds: [String]
    ) -> String? {
        guard let id, !newIds.contains(id),
              let index = oldIds.firstIndex(of: id),
              !newIds.isEmpty else { return nil }
        return newIds[min(index, newIds.count - 1)]
    }

    /// Spacer height for a row not built yet, usually one below the built
    /// range. A row added above, or one whose layout changed while it was a
    /// spacer, can shift the rows below it once it is built, as rows the lazy
    /// stack placed from estimates did.
    private var estimatedRowHeight: CGFloat {
        guard !rowHeights.isEmpty else { return 0 }
        return rowHeights.values.reduce(0, +) / CGFloat(rowHeights.count)
    }

    /// Not interested on a title page can empty the row it was opened from,
    /// and Home drops that row when it reloads after Back. Restoration and the
    /// built rows move to the row that took its place, and while the feed is
    /// on screen that row claims focus: the engine finds no card to move to
    /// when the replacement was a spacer until now. The center is re-indexed
    /// even when its row stays. Heights of removed rows are dropped.
    private func handOffRemovedRows(from oldIds: [String], to newIds: [String]) {
        if let owner = Self.replacementId(for: focusRestorationOwnerSectionId, from: oldIds, to: newIds) {
            focusRestorationOwnerSectionId = owner
            if isOnScreen { removedOwnerFocusRequest += 1 }
        }
        if let centerId = builtRowCenter?.id {
            centerBuiltRows(on: Self.replacementId(for: centerId, from: oldIds, to: newIds) ?? centerId)
        }
        rowHeights = rowHeights.filter { newIds.contains($0.key) }
    }

    private func previewFocusedItem(_ item: SectionItem, in section: ResolvedSection) {
        marqueeSource = .title(item, section: section)
        marqueeModel.preview(
            marqueeContent(for: item, in: section),
            neighborBackdropURLs: neighborBackdropURLs(around: item, in: section)
        )
    }

    private func previewFocusedCollection(_ card: SectionCollectionCard, in section: ResolvedSection) {
        marqueeSource = .collection(card, section: section)
        marqueeModel.preview(
            marqueeContent(for: card, in: section),
            neighborBackdropURLs: neighborBackdropURLs(around: card, in: section)
        )
    }

    private func marqueeContent(for source: TVSkylineMarqueeSource) -> TVMarqueeContent {
        switch source {
        case .title(let item, let section): marqueeContent(for: item, in: section)
        case .collection(let card, let section): marqueeContent(for: card, in: section)
        }
    }

    private func marqueeContent(for item: SectionItem, in section: ResolvedSection) -> TVMarqueeContent {
        TVMarqueeContent(
            item: item,
            rowId: section.id,
            rowTitle: section.displayTitle(in: locale),
            isContinueWatching: section.isContinueWatchingSection,
            isFeatured: section.isFeatured,
            spoilers: EpisodeSpoilerPreferences.shared.settings
        )
    }

    /// A collection preview, built like the Requests page's previews: no
    /// content id, so the marquee requests no title detail. A server
    /// collection's backdrop fills the hero as a title's does; without one
    /// the poster is framed as a cover there, and a collection with neither
    /// shows only the text.
    private func marqueeContent(for card: SectionCollectionCard, in section: ResolvedSection) -> TVMarqueeContent {
        var meta: [String] = []
        if card.itemCount > 0 {
            meta.append(AppLanguage.string(
                .collectionsItemCount(count: card.itemCount, LocaleFormat.groupedCount(card.itemCount, locale: locale)),
                locale: locale
            ))
        }
        if let byline = CollectionOwnerName.byline(for: card, locale: locale) {
            meta.append(byline)
        }
        return TVMarqueeContent(
            id: "\(section.id)#\(card.rowKey)",
            contentId: nil,
            rowId: section.id,
            eyebrow: section.displayTitle(in: locale),
            title: card.title,
            logoUrl: nil,
            badges: [],
            metaParts: meta,
            rating: nil,
            trailingMetaParts: [],
            runtimeMetaIndex: meta.count,
            runtimeText: nil,
            synopsis: nil,
            backdropUrl: card.backdropUrl,
            backdropThumbhash: card.backdropThumbhash,
            fallbackArtworkUrl: card.posterUrl,
            fallbackArtworkThumbhash: card.posterThumbhash,
            fallbackArtworkAspect: .poster,
            baseOverlayData: nil,
            contentRatingBadge: nil,
            progressUpdatedAt: nil,
            prefersLastUsedPlaybackMetadata: false,
            isEpisode: false,
            protectsEpisodeImages: false,
            seriesContextId: nil,
            seriesContextSeasonNumber: nil
        )
    }

    /// Backdrops of the collections on either side of `card` in its row.
    private func neighborBackdropURLs(
        around card: SectionCollectionCard,
        in section: ResolvedSection
    ) -> [String] {
        guard let index = section.collections.firstIndex(where: { $0.rowKey == card.rowKey }) else { return [] }
        let radius = SiloTheme.Skyline.marqueeNeighborBackdropPrefetchRadius
        let window = section.collections.indices.clamped(to: (index - radius)..<(index + radius + 1))
        return window.compactMap { $0 == index ? nil : section.collections[$0].backdropUrl }
    }

    /// Section-level backdrops of the cards on either side of `item` in its
    /// row: a card's own backdrop, or an episode's series backdrop when the
    /// card carries one. Other episodes and items without a backdrop
    /// resolve their hero art from detail enrichment, which is a metadata
    /// request the marquee already rate-limits and must not be duplicated
    /// here for cards the user may never rest on.
    private func neighborBackdropURLs(
        around item: SectionItem,
        in section: ResolvedSection
    ) -> [String] {
        guard let index = section.items.firstIndex(where: { $0.id == item.id }) else { return [] }
        let radius = SiloTheme.Skyline.marqueeNeighborBackdropPrefetchRadius
        let window = section.items.indices.clamped(to: (index - radius)..<(index + radius + 1))
        return window.compactMap { neighborIndex -> String? in
            guard neighborIndex != index else { return nil }
            let neighbor = section.items[neighborIndex]
            if let seriesBackdrop = neighbor.episodeSeriesBackdrop { return seriesBackdrop.url }
            guard neighbor.type.lowercased() != "episode",
                  let url = neighbor.backdropUrl, !url.isEmpty else { return nil }
            return url
        }
    }

    /// Seed the first card as soon as sections exist, so cold entry does not
    /// wait for a focus report or the backdrop rest delay. A later focus
    /// report remains authoritative if the engine lands on another card.
    private func seedMarqueeFromFirstItem() {
        guard marqueeModel.content == nil,
              let source = sections.first.flatMap(TVSkylineMarqueeSource.firstCard(in:)) else { return }
        marqueeSource = source
        marqueeModel.seed(marqueeContent(for: source))
    }

    /// The rows changed: keep the previewed card, rebuilt from the new rows,
    /// while it is still there; otherwise start over from the first card.
    private func refreshMarqueeSource() {
        guard let source = marqueeSource?.refreshed(in: sections) else {
            marqueeSource = nil
            marqueeModel.clearSelection()
            seedMarqueeFromFirstItem()
            return
        }
        marqueeSource = source
        marqueeModel.replaceContent(marqueeContent(for: source))
    }

}

/// The card the marquee preview was built from: a title or a collection,
/// with its row.
private enum TVSkylineMarqueeSource {
    case title(SectionItem, section: ResolvedSection)
    case collection(SectionCollectionCard, section: ResolvedSection)

    /// The first card of `section`, in the kind the row holds.
    static func firstCard(in section: ResolvedSection) -> TVSkylineMarqueeSource? {
        if section.holdsCollections {
            return section.collections.first.map { .collection($0, section: section) }
        }
        return section.items.first.map { .title($0, section: section) }
    }

    /// The same card in `sections`, or nil when its row no longer shows it.
    func refreshed(in sections: [ResolvedSection]) -> TVSkylineMarqueeSource? {
        switch self {
        case .title(let item, let section):
            guard let row = sections.first(where: { $0.id == section.id }),
                  let current = row.items.first(where: { $0.contentId == item.contentId }) else { return nil }
            return .title(current, section: row)
        case .collection(let card, let section):
            guard let row = sections.first(where: { $0.id == section.id }),
                  let current = row.collections.first(where: { $0.rowKey == card.rowKey }) else { return nil }
            return .collection(current, section: row)
        }
    }
}

/// Cancel artwork work when a row leaves the viewport without removing its
/// buttons from the native focus graph. Visibility changes only at the edge.
private struct TVSkylineArtworkVisibility: ViewModifier {
    /// Runs each time the row comes into view and returns the artwork it
    /// warmed, which is cancelled when the row leaves the viewport.
    let onVisible: () -> [CardArtwork]
    @State private var isVisible = false
    @State private var warmed: [CardArtwork] = []

    func body(content: Content) -> some View {
        content
            .environment(\.tvArtworkLoadingEnabled, isVisible)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isVisible = visible
                if visible {
                    warmed = onVisible()
                } else {
                    // Cards already on screen keep their own requests.
                    PosterImageCache.stopPrefetchingArtwork(warmed)
                    warmed = []
                }
            }
    }
}

/// Observe preview changes at the leaves. Reading the model's properties in
/// the feed's body makes every artwork, tint, and enrichment update rebuild
/// the scrolling rows and their focusable cards as well. Also used by the
/// Requests page.
struct TVSkylineBackdrop: View {
    let model: TVFocusMarqueeModel

    var body: some View {
        TVRootHeroBackdrop(
            tints: model.tints,
            artworkURL: model.backdropURL,
            artworkThumbhash: model.backdropThumbhash,
            artworkCoverAspect: model.backdropCoverAspect,
            isVisible: model.backdropURL != nil,
            crossfadeDuration: SiloTheme.Skyline.marqueeCrossfadeDuration,
            washCrossfadeDuration: SiloTheme.Skyline.marqueeWashCrossfadeDuration
        )
    }
}

struct TVSkylineMarquee: View {
    let model: TVFocusMarqueeModel
    let scale: TVFocusMarquee.Scale

    /// How long a card must hold focus before its description is translated
    /// on view, so rolling across a row starts no jobs.
    private static let translationDwell: Duration = .milliseconds(1500)

    var body: some View {
        TVFocusMarquee(
            content: displayedContent,
            enrichment: model.enrichment,
            scale: scale
        )
        .task(id: translationRequest) {
            // Featured cards in `auto` mode only. The marquee has no
            // focusable controls, so `button` mode leaves the action to the
            // detail page's More menu.
            guard let trigger = translationRequest else { return }
            try? await Task.sleep(for: Self.translationDwell)
            guard !Task.isCancelled else { return }
            CardDescriptionTranslation.shared.cardDidAppear(
                contentId: trigger.contentId,
                pendingLanguage: trigger.language,
                libraryId: model.libraryId
            )
        }
    }

    /// The focused card with any landed translation and its status.
    private var displayedContent: TVMarqueeContent? {
        guard var content = model.content else { return nil }
        guard !content.hidesSynopsis else { return content }
        let presentation = translationPresentation(for: content)
        content.synopsis = presentation.overview
        content.translationStatus = presentation.status
        return content
    }

    private var translationRequest: TVMarqueeTranslationRequest? {
        guard let content = model.content else { return nil }
        return content.onViewTranslationRequest(
            pendingLanguage: translationPresentation(for: content).pendingLanguage,
            mode: AICapabilities.shared.metadataOnView
        )
    }

    private func translationPresentation(for content: TVMarqueeContent) -> CardDescriptionTranslation.Presentation {
        CardDescriptionTranslation.shared.presentation(
            contentId: content.contentId,
            overview: content.synopsis,
            pendingLanguage: content.pendingTranslationLanguage,
            machineTranslatedFields: content.machineTranslatedFields
        )
    }
}

#endif
