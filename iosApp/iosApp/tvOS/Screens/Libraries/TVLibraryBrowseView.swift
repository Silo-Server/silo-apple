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
    var mediaScope: LibraryVideoScope? = nil
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
    @State private var scopeIncomplete = false
    @State private var loadGeneration = 0

    @Environment(AppRouter.self) private var router

    // MARK: - Derived

    private var contentSections: [ResolvedSection] {
        sections.filter { !$0.isFeatured && !$0.items.isEmpty }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isLoadingSections && sections.isEmpty {
                TVLibraryBrowseLoadingView(libraryName: library.name)
                    .tvPageFocusOwner(
                        focusRequest: focusRequest,
                        isTopMenuFocused: isTopMenuFocused,
                        accessibilityLabel: "Loading \(library.name)",
                        onMoveUp: onMoveUp
                    )
            } else if let error = sectionsError, sections.isEmpty {
                ErrorView(state: error, onRetry: { Task { await loadContent() } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if contentSections.isEmpty {
                emptyHint
            } else {
                TVSkylineSectionFeed(
                    sections: contentSections,
                    libraryId: library.id,
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    onTopMenuFocusRequest: onMoveUp,
                    onItemTap: { destinationContentId, item in
                        router.navigate(
                            to: .itemDetail(
                                destinationContentId: destinationContentId,
                                sectionItem: item,
                                libraryId: library.id
                            )
                        )
                    }
                )
                .id(library.id)
            }
        }
        .overlay(alignment: .bottom) {
            if scopeIncomplete {
                Text("Some shelves could not be fully loaded. Open Browse to see this media type.")
                    .font(.caption).padding().background(.ultraThinMaterial)
            }
        }
        .environment(\.browseLibraryId, library.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadContent() }
    }

    private var emptyHint: some View {
        EmptyStateView(
            icon: emptyLibraryIcon,
            title: scopeIncomplete ? "Some shelves could not be loaded" : mediaScope != nil ? "No titles for this tab" : "\(library.name) is empty",
            subtitle: mediaScope != nil ? "Open Browse to see titles matching this tab." : "Add media to this library on the server to see it here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tvPageFocusOwner(
            focusRequest: focusRequest,
            isTopMenuFocused: isTopMenuFocused,
            accessibilityLabel: "\(library.name) is empty",
            onMoveUp: onMoveUp
        )
    }

    private var emptyLibraryIcon: String {
        if library.isSeriesLibrary { return "tv" }
        if library.isAudiobookLibrary { return "book.closed" }
        return "film.stack"
    }

    // MARK: - Data

    private func loadContent() async {
        loadGeneration += 1
        let requestGeneration = loadGeneration
        defer {
            if requestGeneration == loadGeneration { isLoadingSections = false }
        }
        let scopedCacheKey = mediaScope.map { CacheKey.librarySections(library.id) + ".type-\($0.rawValue)" }
        if sections.isEmpty, let scopedCacheKey,
           let cached: (sections: [ResolvedSection], incomplete: Bool) = ResponseCache.shared.get(scopedCacheKey) {
            sections = cached.sections
            scopeIncomplete = cached.incomplete
        }
        if sections.isEmpty,
           let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.librarySections(library.id)) {
            sections = cached.sections.map { row in
                guard let mediaScope else { return row }
                return mediaScope.section(row, items: row.items.filter { mediaScope.contains($0.type) })
            }
        }
        isLoadingSections = true
        sectionsError = nil
        do {
            if let mediaScope {
                let read = try await StartupContentPrefetcher.fetchLibrarySectionsRead(libraryId: library.id)
                let visibleRows = read.response.sections.filter { !$0.isFeatured }
                let scoped = try await mediaScope.refillSections(visibleRows) { [libraryID = library.id] (row: ResolvedSection, cursor: APIv2CatalogContinuation?) in
                    guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
                    let page: CatalogListPage
                    if let cursor { page = try await SiloAPI.shared.nextCatalogPage(cursor) }
                    else {
                        var query = APIv2CatalogQuery()
                        query.source = "section"; query.scope = "library"
                        query.libraryId = String(libraryID); query.sectionId = row.id; query.limit = 100
                        page = try await SiloAPI.shared.catalogPage(query)
                    }
                    guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
                    return LibraryScopedPage(items: page.response.items.map { SectionItem(browseItem: $0) },
                                             next: page.continuation, startsOver: page.startsOver)
                }
                guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
                guard requestGeneration == loadGeneration, !Task.isCancelled else { return }
                sections = scoped.map(\.section)
                scopeIncomplete = scoped.contains { $0.incomplete }
                if let scopedCacheKey {
                    ResponseCache.shared.set((sections: sections, incomplete: scopeIncomplete), for: scopedCacheKey)
                }
            } else {
                let read = try await StartupContentPrefetcher.fetchLibrarySectionsRead(libraryId: library.id)
                guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
                guard requestGeneration == loadGeneration, !Task.isCancelled else { return }
                sections = read.response.sections
            }
        } catch {
            guard requestGeneration == loadGeneration, !Task.isCancelled else { return }
            if error is CancellationError { return }
            if case HTTPError.requestIdentityChanged = error { sections = [] }
            if case HTTPError.authorityChanged = error { sections = [] }
            sectionsError = ErrorState(error)
            scopeIncomplete = mediaScope != nil && !sections.isEmpty
        }
    }
}

/// Passive first frame for a cold library tab. The caller makes it the page's
/// focus owner; its geometry mirrors the Skyline marquee and first row so the
/// real feed replaces it in place.
private struct TVLibraryBrowseLoadingView: View {
    let libraryName: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.siloBackground

            LinearGradient(
                colors: [
                    Color.siloSurfaceElevated.opacity(0.72),
                    Color.siloBackground.opacity(0.88),
                    Color.siloBackground,
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            VStack(alignment: .leading, spacing: 0) {
                marqueePlaceholder
                Spacer(minLength: 24)
                rowPlaceholder
            }
            .padding(.horizontal, SiloTheme.Skyline.safeAreaX)
            .padding(.top, 188)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // No `allowsHitTesting(false)`: the caller makes this skeleton the
        // page's focus owner while sections load, and an empty hit-test
        // region would leave the focus engine with nothing to focus.
        .accessibilityElement(children: .ignore)
    }

    private var marqueePlaceholder: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 520, height: 72)

            HStack(spacing: 14) {
                loadingBar(width: 118, height: 22)
                loadingBar(width: 82, height: 22)
                loadingBar(width: 150, height: 22)
            }

            VStack(alignment: .leading, spacing: 13) {
                loadingBar(width: 720, height: 18)
                loadingBar(width: 610, height: 18)
            }

            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)

                Text("Loading \(libraryName)")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.72))
            }
            .padding(.top, 4)
        }
    }

    private var rowPlaceholder: some View {
        VStack(alignment: .leading, spacing: 20) {
            loadingBar(width: 300, height: 28)

            HStack(spacing: 40) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.11))
                            .frame(width: 330, height: 186)

                        loadingBar(width: 210, height: 16)
                    }
                }
            }
        }
    }

    private func loadingBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .frame(width: width, height: height)
    }
}
#endif
