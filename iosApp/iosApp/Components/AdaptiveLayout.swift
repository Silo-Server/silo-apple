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
        #if os(macOS)
        // A Mac window can be any width, so fit as many fixed-size cards as
        // the row holds instead of spreading a fixed count of columns apart.
        return [
            GridItem(
                .adaptive(minimum: SiloTheme.posterCardWidth * posterSize.scale),
                spacing: spacing,
                alignment: .top
            ),
        ]
        #else
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
        #endif
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

        /// Flexible, top-aligned columns at the fitted count.
        var columns: [GridItem] {
            Array(
                repeating: GridItem(.flexible(), spacing: AdaptiveColumns.tabletPosterSpacing, alignment: .top),
                count: columnCount
            )
        }
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

    /// Phone grids keep their fixed three-up layout below this container
    /// width. Every iPhone is narrower in portrait, the only orientation phone
    /// browsing allows; the iPhone Duo's inner display is wider, whether the
    /// app fills it or runs in its compatibility window.
    static let widePhoneGridMinimumWidth: CGFloat = 560

    /// Narrowest poster in a wide phone grid. A phone's points are physically
    /// smaller than an iPad's, so the iPhone Duo's inner display keeps the
    /// three-up grid's ~115pt posters and gains columns instead: six across
    /// open in landscape, five in portrait.
    static let widePhoneMinimumPosterWidth: CGFloat = 112

    /// A width-fitted grid for a phone container too wide for three-up
    /// posters, such as the iPhone Duo's inner display. Nil for narrower
    /// containers and compact-height windows: an iPhone turned to landscape
    /// for the player also rotates the grids beneath it, which keep their
    /// three-up layout and scroll position.
    static func widePhonePosterFit(
        containerWidth: CGFloat,
        posterSize: CardPosterSize,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> PosterGridFit? {
        guard containerWidth >= widePhoneGridMinimumWidth,
              verticalSizeClass == .regular else { return nil }
        return widthFittedPosters(
            containerWidth: containerWidth,
            minimumCardWidth: widePhoneMinimumPosterWidth * posterSize.scale,
            spacing: tabletPosterSpacing
        )
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
