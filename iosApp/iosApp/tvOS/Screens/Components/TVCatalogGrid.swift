#if os(tvOS)
import SwiftUI

/// Flexible poster grid for tvOS. Delegates pagination + prefetch to the
/// caller via callbacks so the same view works against any paged catalog
/// source (library browse, collection detail, filter result).
///
/// - Pagination: `onNearEnd(currentIndex)` fires when a cell in the last 8
///   rows of items appears. That's a generous lead time on a 100-item page,
///   which gives
///   the network room to complete before the user reaches the bottom.
/// - Prefetch: row visibility reports let the caller cancel stale work and
///   warm a bounded nearby window. The grid does not touch the image cache.
/// - Columns: caller picks `columnCount` (default 6). Drop to 5 when a
///   side-rail (alphabet jumper etc.) eats horizontal space, or the
///   fixed `posterCardWidth` cards start overlapping each other.
struct TVCatalogGrid: View {
    let items: [BrowseItem]
    let isLoading: Bool
    let hasMore: Bool
    let onItemTap: (BrowseItem) -> Void
    let onNearEnd: (Int) -> Void
    var columnCount: Int = 6
    /// Per-card width. Defaults to the theme poster size; shrink when a
    /// side-rail squeezes the usable width and the default cards would
    /// overflow their grid cells.
    var cardWidth: CGFloat = ContinuumTheme.posterCardWidth
    var prefersDefaultFocusOnFirstItem: Bool = false
    var focusRequest: Int = 0
    var onRowVisibilityChange: ((Range<Int>, Bool) -> Void)? = nil

    @Namespace private var gridFocusNamespace
    @FocusState private var focusedItemId: String?
    @State private var lastAppliedFocusRequest = 0
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router

    private let columnSpacing: CGFloat = 40
    private let rowSpacing: CGFloat = 60

    /// Trigger prefetch/pagination when a cell within this many rows of
    /// the end appears. 8 rows of lead time — larger buffer means fast
    /// scrolls that skip `.onAppear` events still hit the trigger
    /// before the user reaches the bottom.
    private let prefetchRowsRemaining: Int = 8

    private var resolvedColumnCount: Int {
        AdaptiveColumns.tvPosterCount(
            standardCount: columnCount,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    private var rowStartIndices: [Int] {
        stride(from: 0, to: items.count, by: resolvedColumnCount).map { $0 }
    }

    var body: some View {
        // Rows are explicit full-width focus sections so a D-pad move into a
        // ragged row (fewer cards than columns) still lands: the focus engine
        // resolves moves geometrically, and a partially filled LazyVGrid row
        // has no focusable under most columns. The row's full-width section
        // frame is the catchment; the engine snaps to its nearest card.
        LazyVStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rowStartIndices, id: \.self) { rowStart in
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(IndexedItems(rowItems(from: rowStart))) { indexed in
                        let item = indexed.element
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            posterThumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            overlayData: OverlayData.from(item),
                            action: { onItemTap(item) },
                            playAction: playAction(for: item),
                            cardWidth: cardWidth,
                            aspect: item.isAudiobook ? .square : .poster,
                            prefersDefaultFocus: prefersDefaultFocusOnFirstItem
                                && rowStart == 0 && indexed.index == 0,
                            defaultFocusNamespace: gridFocusNamespace,
                            focusBinding: $focusedItemId,
                            focusContentId: item.contentId,
                            contentId: item.contentId
                        )
                        .frame(maxWidth: .infinity)
                        .onAppear { onCellAppear(index: rowStart + indexed.index) }
                    }
                    // Keep ragged-row cards in their column positions by
                    // filling the empty slots with equally flexible spacers.
                    ForEach(0..<emptySlotCount(from: rowStart), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
                .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                    onRowVisibilityChange?(
                        rowStart..<min(rowStart + resolvedColumnCount, items.count),
                        isVisible
                    )
                }
            }
        }
        .focusScope(gridFocusNamespace)
        .focusSection()
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: items.map(\.contentId)) { _, _ in applyFocusRequest(focusRequest) }

        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(.continuumOnSurface)
                    .padding()
                Spacer()
            }
        }
    }

    private func rowItems(from rowStart: Int) -> [BrowseItem] {
        Array(items[rowStart..<min(rowStart + resolvedColumnCount, items.count)])
    }

    private func emptySlotCount(from rowStart: Int) -> Int {
        resolvedColumnCount - rowItems(from: rowStart).count
    }

    private func onCellAppear(index: Int) {
        guard hasMore else { return }
        let threshold = items.count - (prefetchRowsRemaining * resolvedColumnCount)
        if index >= threshold {
            onNearEnd(index)
        }
    }

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        guard SiloMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        guard let firstItemId = items.first?.contentId else { return }
        lastAppliedFocusRequest = request
        focusedItemId = firstItemId
    }
}

private struct IndexedItems<Base: RandomAccessCollection>: RandomAccessCollection
where Base.Index == Int, Base.Element: Identifiable {
    let base: Base

    init(_ base: Base) {
        self.base = base
    }

    var startIndex: Int { base.startIndex }
    var endIndex: Int { base.endIndex }

    func index(after i: Int) -> Int {
        base.index(after: i)
    }

    func index(before i: Int) -> Int {
        base.index(before: i)
    }

    subscript(position: Int) -> IndexedItem<Base.Element> {
        IndexedItem(index: position, element: base[position])
    }
}

private struct IndexedItem<Element: Identifiable>: Identifiable {
    let index: Int
    let element: Element

    var id: Element.ID { element.id }
}
#endif
