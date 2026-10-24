import SwiftUI

/// A poster grid — 3 columns on iPhone, as many as fit the measured width on
/// iPad and on wide phone windows such as the iPhone Duo's inner display (see
/// `AdaptiveColumns.widthFittedPosters`), 6 columns on tvOS. Cards
/// handle their own focus lift on tvOS.
struct CatalogGrid: View {
    let items: [BrowseItem]
    let isLoading: Bool
    let hasMore: Bool
    /// Library grids stay three-up on iPhone even when the shared card
    /// preference is Large. Other CatalogGrid call sites remain adaptive.
    var forcesThreeColumnsOnPhone = false
    let onItemTap: (BrowseItem) -> Void
    let onLoadMore: () -> Void
    @Environment(\.browseLibraryId) private var browseLibraryId
    @Environment(AppRouter.self) private var router
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(tvOS)
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 40, alignment: .top),
            count: AdaptiveColumns.tvPosterCount(
                standardCount: 6,
                posterSize: uiCustomization.cardPresentation.posterSize
            )
        )
    }
    private let rowSpacing: CGFloat = 60
    #else
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: hSize == .regular ? 3 : 2
            )
        }
        if let fit = widthFittedPosterFit {
            return fit.columns
        }
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize,
            spacing: 8
        )
    }
    private let rowSpacing: CGFloat = 12
    #endif

    var body: some View {
        let widthOverride = cardWidthOverride
        let columns = columns
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            if items.isEmpty && isLoading {
                // First page still loading: the grid's own shape, unfilled.
                ForEach(0..<(columns.count * 4), id: \.self) { _ in
                    PosterSkeletonCard()
                }
            }
            ForEach(IndexedItems(items: items)) { entry in
                let item = entry.item
                // Search can return episodes: caption them with the series
                // name and "S01E02 · Pilot", as on Home.
                card(for: item, widthOverride: widthOverride, rowTitles: rowTitles(at: entry.index, columnCount: columns.count))
                .frame(maxWidth: .infinity)
                .onAppear {
                    if item.id == items.suffix(6).first?.id, hasMore {
                        onLoadMore()
                    }
                }
            }
        }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }
        #endif

        if isLoading && !items.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .tint(.siloOnSurface)
                    .padding()
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func card(for item: BrowseItem, widthOverride: CGFloat?, rowTitles: [String]?) -> some View {
        if let boxSet = item.boxSet, item.isBoxSet {
            // A box set opens its own page and has no title menu or Play.
            MediaCard(
                title: item.title,
                posterUrl: item.posterUrl ?? boxSet.posterUrl ?? "",
                thumbhash: item.posterThumbhash ?? boxSet.posterThumbhash,
                mediaType: "movie",
                subtitle: boxSet.cardCaption,
                progress: boxSet.watchedProgress,
                action: {
                    if let route = Route.boxSet(boxSet) { router.navigate(to: route) }
                },
                aspect: .poster,
                cardWidthOverride: widthOverride,
                rowTitles: rowTitles,
                boxSet: boxSet
            )
        } else {
            MediaCard(
                title: EpisodeCardCaption.cardTitle(for: item),
                posterUrl: item.posterUrl ?? "",
                thumbhash: item.posterThumbhash,
                episodeWatchState: item.isEpisodeItem ? EpisodeWatchState(browseItem: item) : nil,
                imageIsEpisodeStill: item.posterIsEpisodeStill,
                mediaType: item.type,
                year: item.year,
                subtitle: EpisodeCardCaption.line(for: item),
                userState: item.userState,
                overlayData: OverlayData.from(item),
                action: { onItemTap(item) },
                playAction: playAction(for: item),
                contentId: item.contentId,
                seriesContext: SeriesDetailContext(item: SectionItem(browseItem: item)),
                aspect: item.isAudiobook ? .square : .poster,
                cardWidthOverride: widthOverride,
                episodeAccessibilityLabel: EpisodeCardCaption.accessibilityLabel(for: item),
                rowTitles: rowTitles
            )
        }
    }

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        #if os(tvOS)
        guard SiloMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                libraryId: browseLibraryId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
        #else
        return nil
        #endif
    }

    /// Card titles in the grid row holding `index`, so each card sizes its
    /// title to the row's tallest. Nil on macOS and tvOS, whose cards draw
    /// one-line titles.
    private func rowTitles(at index: Int, columnCount: Int) -> [String]? {
        #if os(iOS)
        guard columnCount > 0 else { return nil }
        let rowStart = index - index % columnCount
        let rowEnd = min(rowStart + columnCount, items.count)
        return items[rowStart..<rowEnd].map { EpisodeCardCaption.cardTitle(for: $0) }
        #else
        return nil
        #endif
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        forcesThreeColumnsOnPhone && UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// Cards fill their column instead of sitting at the fixed phone width
    /// inside it: always on iPad, and on a phone once the grid is too wide for
    /// three-up posters. Nil otherwise and until the grid has been measured.
    private var widthFittedPosterFit: AdaptiveColumns.PosterGridFit? {
        #if os(iOS)
        let posterSize = uiCustomization.cardPresentation.posterSize
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return AdaptiveColumns.widePhonePosterFit(
                containerWidth: gridWidth,
                posterSize: posterSize,
                verticalSizeClass: vSize
            )
        }
        return AdaptiveColumns.widthFittedPosters(
            containerWidth: gridWidth,
            minimumCardWidth: AdaptiveColumns.tabletMinimumPosterWidth * posterSize.scale,
            spacing: AdaptiveColumns.tabletPosterSpacing
        )
        #else
        return nil
        #endif
    }

    /// MediaCard applies the global poster-size scale after its override. Undo
    /// that scale here, then cap the standard width to the measured grid cell.
    private var cardWidthOverride: CGFloat? {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            let fittedWidth = AdaptiveColumns.fittedPosterWidth(
                containerWidth: gridWidth,
                columnCount: columns.count,
                spacing: 8,
                maximumWidth: 240
            )
            return fittedWidth / uiCustomization.cardPresentation.posterSize.scale
        }
        if let fit = widthFittedPosterFit {
            return fit.cardWidth / uiCustomization.cardPresentation.posterSize.scale
        }
        // Phone cards shrink to their column rather than spilling into the
        // gaps, as they would in a window narrower than three standard
        // posters, such as the iPhone Duo's cover screen beside its status
        // column.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        let scale = uiCustomization.cardPresentation.posterSize.scale
        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columns.count,
            spacing: 8,
            maximumWidth: usesThreeColumnPhoneLayout
                ? SiloTheme.posterCardWidth
                : SiloTheme.posterCardWidth * scale
        )
        return fittedWidth / scale
        #else
        return nil
        #endif
    }
}

/// The grid's items with their positions, without copying the array: a card
/// finds its row from its position, and stays keyed by its item's ID.
private struct IndexedItems: RandomAccessCollection {
    struct Entry: Identifiable {
        let index: Int
        let item: BrowseItem
        var id: String { item.id }
    }

    let items: [BrowseItem]
    var startIndex: Int { items.startIndex }
    var endIndex: Int { items.endIndex }

    subscript(position: Int) -> Entry {
        Entry(index: position, item: items[position])
    }
}
