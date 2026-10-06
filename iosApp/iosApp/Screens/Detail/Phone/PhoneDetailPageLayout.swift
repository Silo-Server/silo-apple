#if !os(tvOS)
import SwiftUI

/// The scrolling body of a movie or series detail page. Usually one column:
/// the hero, then the sections below it. A wide, short page (see
/// `PhoneDetailHeroLayout.usesSplitLayout`) instead holds the hero still in
/// the leading half and scrolls the sections in the trailing half, the way
/// Apple Music lays out an album on the iPhone Duo's open display.
///
/// Place it in a `PhoneDetailPageSurface` that keeps the side safe area: the
/// split reads those insets, and the single column extends back under them.
struct PhoneDetailPageLayout<Column: View, PaneHero: View, PaneContent: View>: View {
    let scrollState: PhoneDetailScrollState
    /// The single-column page.
    @ViewBuilder let column: () -> Column
    /// The hero for the leading pane, given the pane's height.
    @ViewBuilder let paneHero: (_ height: CGFloat) -> PaneHero
    /// Everything below the hero, for the trailing pane.
    @ViewBuilder let paneContent: () -> PaneContent

    @State private var page = PageGeometry()

    /// Clears the floating Close and Remote buttons, which sit 9pt below the
    /// top edge and are 44pt tall. The content pane scrolls beneath this inset
    /// rather than under the buttons, so it needs no backing strip.
    static var contentPaneTopInset: CGFloat { 9 + SiloTheme.topBarIconHitSize + 12 }

    var body: some View {
        Group {
            if PhoneDetailHeroLayout.usesSplitLayout(pageSize: page.size) {
                split
            } else {
                singleColumn
            }
        }
        .onGeometryChange(for: PageGeometry.self) { proxy in
            PageGeometry(
                size: proxy.size,
                leadingInset: proxy.safeAreaInsets.leading,
                trailingInset: proxy.safeAreaInsets.trailing
            )
        } action: { geometry in
            page = geometry
        }
    }

    private var singleColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            column()
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
        .detailScrollDismissal()
        .phoneDetailScrollTracking(scrollState)
    }

    private var split: some View {
        HStack(spacing: 0) {
            paneHero(page.size.height)
                .frame(width: page.heroPaneWidth)
                .frame(maxHeight: .infinity)

            ScrollView(.vertical, showsIndicators: false) {
                paneContent()
            }
            .detailScrollDismissal()
            .padding(.top, Self.contentPaneTopInset)
            // iPhone Duo reserves about 20pt either side of the fold. With
            // the sections' own 16pt inset this keeps every control clear of
            // it, matching the hero pane's 28pt margin on the other side.
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Rails scroll within the pane rather than across the hero.
            .clipped()
        }
    }
}

private struct PageGeometry: Equatable {
    var size: CGSize = .zero
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    /// The hero pane ends at the middle of the window, insets included, so
    /// on iPhone Duo the panes meet at the fold even though the content pane
    /// loses the status-bar column on its trailing side.
    var heroPaneWidth: CGFloat {
        let windowMidpoint = (leadingInset + size.width + trailingInset) / 2
        return min(max(windowMidpoint - leadingInset, 0), size.width)
    }
}
#endif
