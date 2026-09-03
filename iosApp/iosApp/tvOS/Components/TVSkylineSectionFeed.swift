#if os(tvOS)
import SwiftUI

/// Shared Skyline landing layout (§6.1): an ambient backdrop, a focus
/// marquee that passively previews the focused card, and native vertically
/// scrolling section rows. Used by **both** Home and the library Browse tabs
/// so the two stay pixel-identical — the only difference is the sections each
/// feeds in.
///
/// Row-to-row movement belongs to the tvOS focus engine and the vertical
/// scroll view. Programmatic focus is reserved for entering the page and
/// returning from detail; ordinary Up/Down movement stays geometric.
struct TVSkylineSectionFeed: View {
    /// Section rows to page through, in order (already filtered to
    /// non-empty, non-featured by the caller).
    let sections: [ResolvedSection]
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
    /// Optional Home-only action. Library feeds leave this nil.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    /// Optional Home-only watched-state mutation. Library feeds leave this nil.
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil

    /// Immediate foreground content with a separately delayed backdrop.
    @State private var marqueeModel = TVFocusMarqueeModel()
    /// Token handed only to row 1 when the shell explicitly enters content.
    /// It is never changed during ordinary row-to-row navigation.
    @State private var contentFocusToken = 0
    /// Snaps the row band back to the first section before a focus claim.
    /// The band clips rows outside the viewport, and tvOS refuses to focus a
    /// clipped view — so when entry focus fires while the user is parked on a
    /// lower row (e.g. re-clicking the current tab in the top menu), the first
    /// card's claim silently no-ops unless the band is scrolled home first.
    @State private var entryScrollToken = 0
    /// Entry tokens that arrived before any row mounted — sections load
    /// async, so the initial hand-down would land on nothing.
    @State private var pendingFocusRequest: Int?
    @State private var lastAppliedRequest = 0
    /// The row that owns card focus or its context-menu dismissal flow. Unlike
    /// the marquee preview, this is cleared when focus moves into chrome.
    @State private var focusRestorationOwnerSectionId: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .offset(y: ContinuumTheme.Skyline.landingContentVerticalOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            marqueeModel.resume()
            seedMarqueeFromFirstItem()
            requestEntryFocus(focusRequest)
        }
        .onDisappear { marqueeModel.suspend() }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: isTopMenuFocused) { _, isFocused in
            if isFocused {
                focusRestorationOwnerSectionId = nil
            }
        }
        // Rows mount only after the async section load; a deferred entry
        // token re-fires once they exist.
        .onChange(of: sections.map(\.id)) { _, _ in
            seedMarqueeFromFirstItem()
            if let pending = pendingFocusRequest { requestEntryFocus(pending) }
        }
    }

    // MARK: - Rows

    /// Native vertical row scrolling, clipped to the lower band so rows always
    /// appear from the same bottom area and disappear before the marquee text.
    @ViewBuilder
    private var scrollingRows: some View {
        GeometryReader { proxy in
            let bandHeight = proxy.size.height * ContinuumTheme.Skyline.rowBandHeightFraction
            // Position the focusable viewport with layout, not a render
            // offset. Its bottom must match the screen's bottom: otherwise
            // tvOS can resolve directional clicks against offscreen space
            // while a swipe still pans far enough to reveal the next target.
            let bandTop = min(
                proxy.size.height,
                max(0, proxy.size.height - bandHeight + ContinuumTheme.Skyline.landingContentVerticalOffset)
            )
            let visibleBandHeight = max(0, proxy.size.height - bandTop)
            let trailingPreviewPadding = max(
                0,
                visibleBandHeight - ContinuumTheme.Skyline.rowBandBottomInset
            )

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Bound the live view graph to nearby rows. Keeping the
                    // entire feed mounted makes focus and scroll transactions
                    // traverse offscreen card, image, and button subgraphs.
                    // The native scroll container loads directional targets;
                    // its viewport uses the corrected layout frames above.
                    LazyVStack(alignment: .leading, spacing: ContinuumTheme.Skyline.rowBandPreviewSpacing) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            featuredRow(section, isFirstRow: index == 0)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(section.id)
                        }
                    }
                    .scrollTargetLayout()
                    // Allows the final row to top-align like every prior row,
                    // with a blank preview area underneath instead of clamping.
                    .padding(.bottom, trailingPreviewPadding)
                }
                .scrollTargetBehavior(.viewAligned)
                // Animated ride home; the first card's focus claim is
                // re-asserted by MediaRow until the scroll settles, so the
                // animation can't lose the claim to mid-flight focus repairs.
                .onChange(of: entryScrollToken) { _, _ in
                    if let firstId = sections.first?.id {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.slowDuration)) {
                            scrollProxy.scrollTo(firstId, anchor: .top)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: visibleBandHeight, alignment: .topLeading)
            .clipped()
            .padding(.top, bandTop)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func featuredRow(_ section: ResolvedSection, isFirstRow: Bool) -> some View {
        SectionRow(
            section: section,
            onItemTap: onItemTap,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching,
            onSetWatched: onSetWatched,
            // Cold entry: let the engine's *initial* focus resolution land on
            // the first card so it renders already focused instead of growing
            // a few frames after the page paints. `.automatic` keeps d-pad
            // movement between rows geometric — only system-initiated
            // resolutions use the preference. The imperative entry token
            // below is unchanged and covers every other entry path.
            prefersDefaultFocusOnFirstItem: isFirstRow,
            defaultFocusPriority: .automatic,
            focusRequest: isFirstRow ? contentFocusToken : 0,
            detailReturnFocusRequest: detailReturnFocusRequest,
            // This is the sole directional interception: Up from the first
            // content row crosses the intentional page-to-tab-bar boundary.
            // Every other vertical move remains native.
            onMoveUp: isFirstRow ? onTopMenuFocusRequest : nil,
            onItemFocus: { item in
                focusRestorationOwnerSectionId = section.id
                previewFocusedItem(item, in: section)
            },
            cardWidth: ContinuumTheme.Skyline.densePosterCardWidth,
            cardVerticalPadding: ContinuumTheme.Skyline.rowBandCardVerticalPadding,
            onMoveDown: nil,
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
        .modifier(TVSkylineArtworkVisibility())
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
        guard let firstSectionId = sections.first?.id else { return }
        focusRestorationOwnerSectionId = firstSectionId
        // Scroll the band home first, then claim on the next turn: the claim
        // is a @FocusState write on the first row's first card, which the
        // engine drops while that card is still clipped out of the viewport.
        entryScrollToken += 1
        DispatchQueue.main.async {
            guard !isTopMenuFocused,
                  sections.first?.id == firstSectionId else { return }
            contentFocusToken += 1
        }
    }

    private func previewFocusedItem(_ item: SectionItem, in section: ResolvedSection) {
        marqueeModel.preview(
            TVMarqueeContent(
                item: item,
                rowTitle: section.title,
                isContinueWatching: section.isContinueWatchingSection
            )
        )
    }

    /// Seed the first card as soon as sections exist, so cold entry does not
    /// wait for a focus report or the backdrop rest delay. A later focus
    /// report remains authoritative if the engine lands on another card.
    private func seedMarqueeFromFirstItem() {
        guard marqueeModel.content == nil,
              let section = sections.first,
              let item = section.items.first else { return }
        marqueeModel.seed(
            TVMarqueeContent(
                item: item,
                rowTitle: section.title,
                isContinueWatching: section.isContinueWatchingSection
            )
        )
    }

}

/// Cancel artwork work when a row leaves the viewport without removing its
/// buttons from the native focus graph. Visibility changes only at the edge.
private struct TVSkylineArtworkVisibility: ViewModifier {
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .environment(\.tvArtworkLoadingEnabled, isVisible)
            .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
    }
}

/// Observe preview changes at the leaves. Reading the model's properties in
/// the feed's body makes every artwork, tint, and enrichment update rebuild
/// the scrolling rows and their focusable cards as well.
private struct TVSkylineBackdrop: View {
    let model: TVFocusMarqueeModel

    var body: some View {
        TVRootHeroBackdrop(
            tintColor: model.tintColor,
            artworkURL: model.backdropURL,
            artworkThumbhash: model.backdropThumbhash,
            isVisible: model.backdropURL != nil,
            crossfadeDuration: ContinuumTheme.Skyline.marqueeCrossfadeDuration
        )
    }
}

private struct TVSkylineMarquee: View {
    let model: TVFocusMarqueeModel
    let scale: TVFocusMarquee.Scale

    var body: some View {
        TVFocusMarquee(
            content: model.content,
            enrichment: model.enrichment,
            scale: scale
        )
    }
}

#endif
