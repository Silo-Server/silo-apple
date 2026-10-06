import SwiftUI

/// A poster grid — 3 columns on iPhone, as many as fit the measured width on
/// iPad (see `AdaptiveColumns.widthFittedPosters`), 6 columns on tvOS. Cards
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
    #if !os(tvOS)
    @State private var detailBrowseOriginID = UUID().uuidString
    @State private var detailBrowseSource: ItemDetailBrowseSource?
    #endif

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
    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: hSize == .regular ? 3 : 2
            )
        }
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: 3
            )
        }
        if let fit = tabletPosterFit {
            return Array(
                repeating: GridItem(.flexible(), spacing: AdaptiveColumns.tabletPosterSpacing, alignment: .top),
                count: fit.columnCount
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
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            if items.isEmpty && isLoading {
                // First page still loading: the grid's own shape, unfilled.
                ForEach(0..<(columns.count * 4), id: \.self) { _ in
                    PosterSkeletonCard()
                }
            }
            ForEach(items) { item in
                // Search can return episodes: caption them with the series
                // name and "S01E02 · Pilot", as on Home.
                MediaCard(
                    title: EpisodeCardCaption.cardTitle(for: item),
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
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
                    episodeAccessibilityLabel: EpisodeCardCaption.accessibilityLabel(for: item)
                )
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
        #if !os(tvOS)
        .environment(\.itemDetailBrowseSource, detailBrowseSource)
        // Keyed on a hash of the ordered IDs rather than the ID array: a paged
        // grid holds thousands of items and this runs on each body pass.
        .onChange(of: ItemsFingerprint(items), initial: true) {
            detailBrowseSource = ItemDetailBrowseSource(
                originID: detailBrowseOriginID,
                contentIDs: items.map(\.contentId)
            )
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

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        forcesThreeColumnsOnPhone && UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// iPad cards fill their column instead of sitting at the fixed phone
    /// width inside it. Nil on iPhone and until the grid has been measured.
    private var tabletPosterFit: AdaptiveColumns.PosterGridFit? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        return AdaptiveColumns.widthFittedPosters(
            containerWidth: gridWidth,
            minimumCardWidth: AdaptiveColumns.tabletMinimumPosterWidth
                * uiCustomization.cardPresentation.posterSize.scale,
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
        if let fit = tabletPosterFit {
            return fit.cardWidth / uiCustomization.cardPresentation.posterSize.scale
        }
        #endif
        guard usesThreeColumnPhoneLayout else { return nil }
        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: 3,
            spacing: 8
        )
        return fittedWidth / uiCustomization.cardPresentation.posterSize.scale
    }
}

#if !os(tvOS)
/// Changes when a paged list is replaced, extended, or reordered at its ends.
private struct ItemsFingerprint: Equatable {
    let count: Int
    let orderedIDsHash: Int

    init(_ items: [BrowseItem]) {
        count = items.count
        var hasher = Hasher()
        for item in items { hasher.combine(item.contentId) }
        orderedIDsHash = hasher.finalize()
    }
}
#endif
