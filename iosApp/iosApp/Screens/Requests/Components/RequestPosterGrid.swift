import SwiftUI

#if !os(tvOS)
/// Request cards in library search's grid (`CatalogGrid`): the shared
/// phone/pad column counts, 8pt gutters, and posters that fill their column.
/// The hub's search results and a Discover row's See all page use it.
struct RequestPosterGrid: View {
    let results: [RequestMediaResult]
    /// Quiet placeholders in the same cells instead of results, while loading.
    var placeholderCount: Int = 0
    /// Called when the last card appears, to load the next page.
    var onReachEnd: (() -> Void)? = nil

    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppRouter.self) private var router

    private static let gridSpacing: CGFloat = 8
    private static let gridRowSpacing: CGFloat = 12

    private var columns: [GridItem] {
        if let fit = widePhonePosterFit {
            return fit.columns
        }
        return AdaptiveColumns.posters(
            for: horizontalSizeClass,
            posterSize: uiCustomization.cardPresentation.posterSize,
            spacing: Self.gridSpacing
        )
    }

    /// A phone window too wide for the standard counts (the iPhone Duo's
    /// inner display) adds columns rather than stretching posters.
    private var widePhonePosterFit: AdaptiveColumns.PosterGridFit? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        return AdaptiveColumns.widePhonePosterFit(
            containerWidth: gridWidth,
            posterSize: uiCustomization.cardPresentation.posterSize,
            verticalSizeClass: verticalSizeClass
        )
        #else
        return nil
        #endif
    }

    private var cardWidth: CGFloat {
        #if os(macOS)
        // The Mac grid is one adaptive column that repeats to fit, so the
        // column count says nothing about the cell. Work the cell out the
        // way the grid does. Before the first measurement the fit is nil
        // and the card takes the cell's minimum width.
        let minimumWidth = SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
        return AdaptiveColumns.widthFittedPosters(
            containerWidth: gridWidth,
            minimumCardWidth: minimumWidth,
            spacing: Self.gridSpacing,
            minimumColumns: 1
        )?.cardWidth ?? minimumWidth
        #else
        // Before the first measurement, a standard poster: the uncapped fit
        // below would return its infinite maximum.
        guard gridWidth > 0 else { return SiloTheme.posterCardWidth }
        if let fit = widePhonePosterFit { return fit.cardWidth }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columns.count,
            spacing: Self.gridSpacing,
            maximumWidth: .greatestFiniteMagnitude
        )
        #endif
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gridRowSpacing) {
            if placeholderCount > 0 {
                ForEach(0..<placeholderCount, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        RequestsSkeleton.block(
                            width: nil,
                            height: cardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth),
                            cornerRadius: SiloTheme.cornerRadius
                        )
                        RequestsSkeleton.bar(width: cardWidth * 0.7, height: 10, opacity: 0.14)
                    }
                }
            } else {
                ForEach(results) { result in
                    RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                        .cardWidth(cardWidth)
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            if result.id == results.last?.id { onReachEnd?() }
                        }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }
        .accessibilityHidden(placeholderCount > 0)
    }
}
#endif
