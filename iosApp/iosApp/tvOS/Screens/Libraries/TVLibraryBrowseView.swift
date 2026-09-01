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
                TVLibraryBrowseLoadingView(libraryName: library.name)
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
                    onItemTap: { destinationContentId, item in
                        router.navigate(
                            to: .itemDetail(
                                destinationContentId: destinationContentId,
                                sectionItem: item
                            )
                        )
                    }
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

/// Passive first frame for a cold library tab.
///
/// The top bar stays interactive while section metadata is in flight, so this
/// surface deliberately owns no focus. Its geometry mirrors the Skyline
/// marquee and first landscape row closely enough that the real feed replaces
/// it without the page appearing to build itself from an empty black canvas.
private struct TVLibraryBrowseLoadingView: View {
    let libraryName: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.continuumBackground

            LinearGradient(
                colors: [
                    Color.continuumSurfaceElevated.opacity(0.72),
                    Color.continuumBackground.opacity(0.88),
                    Color.continuumBackground,
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            VStack(alignment: .leading, spacing: 0) {
                marqueePlaceholder
                Spacer(minLength: 24)
                rowPlaceholder
            }
            .padding(.horizontal, ContinuumTheme.Skyline.safeAreaX)
            .padding(.top, 188)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading \(libraryName)")
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
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.72))
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
