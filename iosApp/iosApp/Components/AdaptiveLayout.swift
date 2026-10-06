import SwiftUI

/// Size-class-aware poster grid columns.
///
/// iPhone portrait and iPad in narrow split view report `.compact` and get
/// 3 columns. iPad full-screen and landscape report `.regular` and get 5
/// columns, so posters render at their intended density instead of
/// stretching to nearly 2× width.
enum AdaptiveColumns {
    static func posters(
        for sizeClass: UserInterfaceSizeClass?,
        posterSize: CardPosterSize = .standard,
        spacing: CGFloat = 12
    ) -> [GridItem] {
        let standardCount = (sizeClass == .regular) ? 5 : 3
        let count: Int
        switch posterSize {
        case .compact:
            count = sizeClass == .regular ? standardCount + 1 : standardCount
        case .standard:
            count = standardCount
        case .large:
            count = max(2, standardCount - 1)
        }
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: count
        )
    }

    /// Keeps tvOS poster grids dense enough for compact artwork while making
    /// room for large artwork and its native focus lift. Six columns is the
    /// safe upper bound inside the standard 1,760-point content width.
    static func tvPosterCount(
        standardCount: Int,
        posterSize: CardPosterSize,
        minimumCount: Int = 3
    ) -> Int {
        switch posterSize {
        case .compact:
            return min(6, standardCount + 1)
        case .standard:
            return standardCount
        case .large:
            return max(minimumCount, standardCount - 1)
        }
    }

    /// Narrowest standard-size poster in an iPad grid, between the design
    /// language's 140pt compact and 185pt normal tablet densities. The
    /// card-size preference scales it like every other card.
    static let tabletMinimumPosterWidth: CGFloat = 140

    /// Gap between iPad grid columns; matches the grid's row spacing.
    static let tabletPosterSpacing: CGFloat = 12

    struct PosterGridFit: Equatable {
        let columnCount: Int
        let cardWidth: CGFloat
    }

    /// A poster grid that fills `containerWidth`: as many columns as fit at
    /// `minimumCardWidth`, then every card widened to its column so the only
    /// gaps are `spacing`. Cards therefore stay under twice the minimum at
    /// any width, from a Slide Over or Split View pane to a full-screen or
    /// Stage Manager window. Nil until the container has been measured.
    static func widthFittedPosters(
        containerWidth: CGFloat,
        minimumCardWidth: CGFloat,
        spacing: CGFloat,
        minimumColumns: Int = 2
    ) -> PosterGridFit? {
        guard containerWidth > 0, minimumCardWidth > 0 else { return nil }
        let fitting = Int(((containerWidth + spacing) / (minimumCardWidth + spacing)).rounded(.down))
        let count = max(minimumColumns, fitting)
        let cardWidth = (containerWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
        return PosterGridFit(columnCount: count, cardWidth: max(1, cardWidth))
    }

    /// Fits a fixed-density grid card inside its actual container while
    /// preserving the standard poster width whenever enough room is available.
    static func fittedPosterWidth(
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat,
        maximumWidth: CGFloat = SiloTheme.posterCardWidth
    ) -> CGFloat {
        guard containerWidth > 0, columnCount > 0 else { return maximumWidth }
        let totalSpacing = CGFloat(max(0, columnCount - 1)) * spacing
        let availableWidth = max(1, containerWidth - totalSpacing)
        return min(maximumWidth, availableWidth / CGFloat(columnCount))
    }
}

extension View {
    /// Caps form/content width so text fields and buttons don't stretch
    /// edge-to-edge on iPad. iPhones are already narrower than the cap, so
    /// this is a no-op on phone. The second `frame` centers the capped view.
    func siloFormWidth(_ maxWidth: CGFloat = 600) -> some View {
        self
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
