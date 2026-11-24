import SwiftUI

extension EnvironmentValues {
    /// Bumped when the iPhone Libraries dock's selected section is tapped
    /// again, which scrolls that library page back to its top. Nil where no
    /// dock asks, so other hosts of the pages are untouched.
    @Entry var libraryPageScrollToTopRequest: Int? = nil

    /// Bumped when the iPhone Libraries tab shows its Browse page again
    /// after a title's watched state, favourite or progress changed while
    /// the page was hidden, so the page reads its list again, as a page
    /// built afresh on every switch would. Nil elsewhere.
    @Entry var libraryPageReloadRequest: Int? = nil

    /// Told when a library page is pulled to refresh, so the iPhone
    /// Libraries header reads its count again. Nil elsewhere.
    @Entry var libraryPageDidRefresh: (@MainActor () -> Void)? = nil

    /// Told how many titles the Browse page's filters leave (nil when it
    /// shows the whole library), so the iPhone Libraries header counts
    /// what the grid shows. Nil elsewhere.
    @Entry var libraryPageFilteredCount: (@MainActor (BrowseViewModel.FilteredTotal?) -> Void)? = nil
}

extension View {
    /// Scroll this vertical `ScrollView` to its top when the Libraries dock
    /// asks (`libraryPageScrollToTopRequest`). On iPhone it also reports
    /// the scroll view's arrival, so the tab bar follows the page.
    func scrollsToTopOnLibraryDockRequest() -> some View {
        modifier(LibraryPageScrollToTop())
    }
}

private struct LibraryPageScrollToTop: ViewModifier {
    @Environment(\.libraryPageScrollToTopRequest) private var request
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        if request != nil {
            content
                .scrollPosition($position)
                #if os(iOS)
                .reportsLibraryPageScrollView()
                #endif
                .onChange(of: request) {
                    withAnimation(reduceMotion ? nil : .smooth) {
                        position.scrollTo(edge: .top)
                    }
                }
        } else {
            content
        }
    }
}
