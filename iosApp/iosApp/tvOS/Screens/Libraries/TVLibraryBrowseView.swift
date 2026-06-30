#if os(tvOS)
import SwiftUI

/// Browse landing of a library tab (Skyline §6.2). Renders this library's
/// server-provided sections through `TVSkylineSectionFeed` — the exact same
/// layout component Home uses — so Movies / Series / Audiobooks are
/// identical to the Home page. The page respects the server's section API:
/// it shows exactly the sections `librarySections` returns, with no
/// client-injected shelves. The server's featured hero section is ignored on
/// TV surfaces (§9); the marquee passively previews whichever card holds
/// focus.
struct TVLibraryBrowseView: View {
    let library: Library
    /// Focus hand-down token from the shell — claims the first card of row 1
    /// on tab entry.
    var focusRequest: Int = 0
    /// Whether the top menu currently holds focus. Deferred focus claims are
    /// dropped while the user is up in the menu so data loads never yank
    /// focus.
    var isTopMenuFocused: Bool = false
    /// Boundary hand-up — Up from row 1 reaches the top bar.
    let onMoveUp: (() -> Void)?

    // MARK: - State

    @State private var sections: [ResolvedSection] = []
    @State private var isLoadingSections = true
    @State private var sectionsError: ErrorState? = nil

    @Environment(AppRouter.self) private var router

    // MARK: - Derived

    private var contentSections: [ResolvedSection] {
        sections.filter { !$0.isFeatured && !$0.items.isEmpty }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoadingSections && sections.isEmpty {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = sectionsError, sections.isEmpty {
                ErrorView(state: error, onRetry: { Task { await loadContent() } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if contentSections.isEmpty {
                emptyHint
            } else {
                TVSkylineSectionFeed(
                    sections: contentSections,
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    onTopMenuFocusRequest: onMoveUp,
                    onItemTap: { router.navigate(to: .itemDetail(contentId: $0)) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadContent() }
    }

    private var emptyHint: some View {
        EmptyStateView(
            icon: emptyLibraryIcon,
            title: "\(library.name) is empty",
            subtitle: "Add media to this library on the server to see it here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibraryIcon: String {
        if library.isSeriesLibrary { return "tv" }
        if library.isAudiobookLibrary { return "book.closed" }
        return "film.stack"
    }

    // MARK: - Data

    private func loadContent() async {
        if sections.isEmpty,
           let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.librarySections(library.id)) {
            sections = cached.sections
        }
        isLoadingSections = true
        sectionsError = nil
        do {
            let response = try await StartupContentPrefetcher.fetchLibrarySections(libraryId: library.id)
            sections = response.sections
        } catch {
            sectionsError = ErrorState(error)
        }
        isLoadingSections = false
    }
}
#endif
