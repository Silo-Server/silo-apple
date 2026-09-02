enum TVSkylineVerticalMove {
    case up
    case down
}

enum TVSkylineRowMoveTarget: Equatable {
    case topMenu
    case row(Int)
    case none
}

/// Pure row-boundary routing used by every Skyline landing. Explicit routing
/// avoids asking the focus engine to discover a row that is still clipped by
/// the lower-half viewport while the vertical stack is scrolling.
func tvSkylineRowMoveTarget(
    currentIndex: Int,
    rowCount: Int,
    direction: TVSkylineVerticalMove
) -> TVSkylineRowMoveTarget {
    guard rowCount > 0, currentIndex >= 0, currentIndex < rowCount else {
        return .none
    }
    switch direction {
    case .up:
        return currentIndex == 0 ? .topMenu : .row(currentIndex - 1)
    case .down:
        return currentIndex + 1 < rowCount ? .row(currentIndex + 1) : .none
    }
}

#if os(tvOS)
import SwiftUI

/// Shared Skyline landing layout (§6.1): an ambient backdrop, a focus
/// marquee that passively previews the focused card, and native vertically
/// scrolling section rows. Used by **both** Home and the library Browse tabs
/// so the two stay pixel-identical — the only difference is the sections each
/// feeds in.
///
/// Rows remain native focus sections. Downward movement stays entirely native
/// so one remote gesture advances one row with the platform's normal pacing.
/// Upward movement only intervenes when the clipped band needs help revealing
/// the preceding row.
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

    /// Debounced focused-card state driving the marquee + backdrop.
    @State private var marqueeModel = TVFocusMarqueeModel()
    /// Per-row focus handoff tokens. A single monotonic generation prevents a
    /// request from colliding with a token that row applied earlier.
    @State private var rowFocusRequestGeneration = 0
    @State private var rowFocusRequests: [String: Int] = [:]
    @State private var rowFocusRequestItemIds: [String: String] = [:]
    @State private var lastFocusedItemIds: [String: String] = [:]
    /// Invalidates a queued scroll-then-focus claim when another touchpad
    /// gesture arrives first. Without this generation, the older async claim
    /// can run after the newer one and bounce focus back a row.
    @State private var rowNavigationGeneration = 0
    /// A touchpad swipe can emit several Up commands while the destination is
    /// still being revealed. Treat that burst as one gesture so it cannot page
    /// through several rows before focus has visually settled.
    @State private var isUpwardRowMoveInFlight = false
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
            TVRootHeroBackdrop(
                tintColor: marqueeModel.tintColor,
                artworkURL: marqueeModel.backdropURL,
                artworkThumbhash: marqueeModel.backdropThumbhash,
                isVisible: marqueeModel.content != nil,
                crossfadeDuration: ContinuumTheme.Skyline.marqueeCrossfadeDuration
            )

            // Native scrolling lives only in the bottom row band. The viewport
            // clips at its top edge so rows do not paint through the marquee
            // title, description, and metadata while they scroll upward.
            scrollingRows
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
                .offset(y: ContinuumTheme.Skyline.landingContentVerticalOffset)

            // Floats over the band above the row; never focusable or hit-testable.
            TVFocusMarquee(
                content: marqueeModel.content,
                enrichment: marqueeModel.enrichment,
                scale: marqueeScale
            )
            .offset(y: ContinuumTheme.Skyline.landingContentVerticalOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            seedMarqueeFromFirstItem()
            requestEntryFocus(focusRequest)
        }
        .onChange(of: focusRequest) { _, request in requestEntryFocus(request) }
        .onChange(of: isTopMenuFocused) { _, isFocused in
            if isFocused {
                rowNavigationGeneration &+= 1
                isUpwardRowMoveInFlight = false
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
            let visibleBandHeight = max(0, bandHeight)
            let trailingPreviewPadding = max(
                0,
                visibleBandHeight - ContinuumTheme.Skyline.rowBandBottomInset
            )

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: ContinuumTheme.Skyline.rowBandPreviewSpacing) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            featuredRow(
                                section,
                                at: index,
                                scrollProxy: scrollProxy
                            )
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
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }

    @ViewBuilder
    private func featuredRow(
        _ section: ResolvedSection,
        at index: Int,
        scrollProxy: ScrollViewProxy
    ) -> some View {
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
            prefersDefaultFocusOnFirstItem: index == 0,
            defaultFocusPriority: .automatic,
            focusRequest: rowFocusRequests[section.id] ?? 0,
            focusRequestItemId: rowFocusRequestItemIds[section.id],
            detailReturnFocusRequest: detailReturnFocusRequest,
            onMoveUp: {
                moveFocusUp(
                    from: index,
                    scrollProxy: scrollProxy
                )
            },
            onItemFocus: { item in
                focusRestorationOwnerSectionId = section.id
                lastFocusedItemIds[section.id] = item.contentId
                previewFocusedItem(item, in: section)
            },
            cardWidth: ContinuumTheme.Skyline.densePosterCardWidth,
            cardVerticalPadding: ContinuumTheme.Skyline.rowBandCardVerticalPadding,
            // Preserve the original smooth tvOS focus/scroll behavior when
            // moving down. Programmatic Down paging made one touchpad swipe
            // produce several rapid row jumps.
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
    }

    // MARK: - Focus

    private func moveFocusUp(
        from index: Int,
        scrollProxy: ScrollViewProxy
    ) {
        guard !isUpwardRowMoveInFlight else { return }
        switch tvSkylineRowMoveTarget(
            currentIndex: index,
            rowCount: sections.count,
            direction: .up
        ) {
        case .topMenu:
            rowNavigationGeneration &+= 1
            isUpwardRowMoveInFlight = false
            focusRestorationOwnerSectionId = nil
            onTopMenuFocusRequest?()
        case .row(let targetIndex):
            let targetSection = sections[targetIndex]
            let targetItemId = lastFocusedItemIds[targetSection.id]
                ?? targetSection.items.first?.contentId
            rowNavigationGeneration &+= 1
            let navigationGeneration = rowNavigationGeneration
            isUpwardRowMoveInFlight = true
            // Ownership changes before the animation so any retry still queued
            // by the previous row immediately yields instead of stealing focus
            // back during a rapid touchpad gesture.
            focusRestorationOwnerSectionId = targetSection.id
            withAnimation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: ContinuumTheme.slowDuration)
            ) {
                scrollProxy.scrollTo(targetSection.id, anchor: .top)
            }
            // Let the preceding row become focusable before claiming it. A
            // later release ends the gesture burst without accelerating into
            // another row; a new deliberate press/swipe then moves once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard navigationGeneration == rowNavigationGeneration else { return }
                requestRowFocus(targetSection.id, itemId: targetItemId)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + ContinuumTheme.slowDuration + 0.12
            ) {
                guard navigationGeneration == rowNavigationGeneration else { return }
                isUpwardRowMoveInFlight = false
            }
        case .none:
            break
        }
    }

    private func requestRowFocus(_ sectionId: String, itemId: String? = nil) {
        focusRestorationOwnerSectionId = sectionId
        rowFocusRequestItemIds[sectionId] = itemId
        rowFocusRequestGeneration += 1
        rowFocusRequests[sectionId] = rowFocusRequestGeneration
    }

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
        rowNavigationGeneration &+= 1
        let navigationGeneration = rowNavigationGeneration
        isUpwardRowMoveInFlight = false
        focusRestorationOwnerSectionId = firstSectionId
        // Scroll the band home first, then claim on the next turn: the claim
        // is a @FocusState write on the first row's first card, which the
        // engine drops while that card is still clipped out of the viewport.
        entryScrollToken += 1
        DispatchQueue.main.async {
            guard navigationGeneration == rowNavigationGeneration,
                  !isTopMenuFocused,
                  sections.contains(where: { $0.id == firstSectionId }) else { return }
            requestRowFocus(firstSectionId, itemId: sections.first?.items.first?.contentId)
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

    /// Cold-entry backdrop: the marquee normally waits for the first card's
    /// focus report plus the 150 ms rest debounce, which paints the hero as
    /// a fade-in after the page is already visible. Entry focus always lands
    /// on the first row's first card, so pre-display that item as soon as
    /// sections exist; if focus somehow lands elsewhere, the focus-driven
    /// preview corrects within the debounce window.
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

#endif
