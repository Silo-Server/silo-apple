import SwiftUI

/// Personalized recommendations tab — mirrors the Android Recommendations
/// screen. Reuses the existing SectionRow UI so each row renders with the
/// same layout as Home.
struct RecommendationsView: View {
    /// tvOS: focus hand-down token from `TVMainTabView`, forwarded to the
    /// Skyline feed so the screen never opens with a dead remote.
    var focusRequest: Int = 0
    /// tvOS: the custom top menu owns focus, so deferred content focus
    /// claims must not yank focus away from it.
    var isTopMenuFocused: Bool = false
    var onTopMenuFocusRequest: (() -> Void)? = nil

    @State private var viewModel: RecommendationsViewModel
    #if !os(tvOS)
    @State private var savedListSelection: SavedShortcut = .watchlist
    /// Feeds the shared glass strip behind the pinned header as rows scroll
    /// under it, matching Home and the Library tab.
    @State private var chromeScrollState = PageChromeScrollState()
    #endif
    @Environment(AppRouter.self) private var router

    init(
        focusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil,
        viewModel: RecommendationsViewModel? = nil
    ) {
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
        _viewModel = State(initialValue: viewModel ?? RecommendationsViewModel())
    }

    var body: some View {
        rootLayout
            .task {
                await viewModel.loadRecommendations()
            }
        #if !os(tvOS)
            .refreshable {
                async let overlayRefresh: Void = OverlayPrefsStore.shared.refresh()
                await viewModel.refresh()
                await overlayRefresh
            }
        #endif
    }

    @ViewBuilder
    private var rootLayout: some View {
        #if os(tvOS)
        tvOSPageContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        // Content scrolls under the pinned header, which sits in a top
        // safe-area inset with the shared glass strip behind it (same
        // structure as `LibrariesTabView`).
        pageContent
            .environment(chromeScrollState)
            .safeAreaInset(edge: .top, spacing: 0) {
                topChrome
                    .background {
                        PageChromeGlass(scrollState: chromeScrollState)
                    }
            }
        .siloPageBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #endif
    }

    #if !os(tvOS)
    private var topChrome: some View {
        HStack(spacing: 12) {
            SidebarToggleButton()

            Text("Recommendations")
                .font(.siloTitle)
                .foregroundColor(.siloOnSurface)

            Spacer(minLength: 8)

            TabTopBarActions(
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onSwitchProfile: {
                    router.switchProfile()
                },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() }
            )
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.top, SiloTheme.smallPadding)
        .padding(.bottom, SiloTheme.smallPadding)
    }
    #endif

    #if os(tvOS)
    /// For You uses the exact Skyline page shell as Home. Recommendation
    /// sections supply only the content; the shared feed owns the backdrop,
    /// marquee, rail geometry, focus hand-off, and vertical scrolling.
    @ViewBuilder
    private var tvOSPageContent: some View {
        if !viewModel.sections.isEmpty {
            TVSkylineSectionFeed(
                sections: viewModel.sections,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: onTopMenuFocusRequest,
                onItemTap: { destinationContentId, item in
                    router.navigate(
                        to: .itemDetail(
                            destinationContentId: destinationContentId,
                            sectionItem: item
                        )
                    )
                }
            )
            .task(id: initialMarqueePrewarmKey) {
                await prewarmInitialMarqueeDetails()
            }
        } else if let error = viewModel.error {
            ErrorView(
                state: error,
                onRetry: { Task { await viewModel.loadRecommendations() } }
            )
        } else if viewModel.isLoading {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tvPageFocusOwner(
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: "Loading recommendations",
                    onMoveUp: onTopMenuFocusRequest
                )
        } else {
            EmptyStateView(
                icon: "sparkles.tv",
                title: "No recommendations yet",
                subtitle: "Watch or rate a few titles to build your personalised recommendations."
            )
            .tvPageFocusOwner(
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                accessibilityLabel: "No recommendations yet",
                onMoveUp: onTopMenuFocusRequest
            )
        }
    }

    /// Two rows × eight visible cards, matching the For You viewport. Only
    /// items missing their lightweight content-rating field need detail
    /// prewarming, and requests run three at a time to avoid a server burst.
    private var initialMarqueePrewarmKey: String {
        initialMarqueeItems.map(\.contentId).joined(separator: "|")
    }

    private var initialMarqueeItems: [SectionItem] {
        viewModel.sections.prefix(2).flatMap { section in
            Array(section.items.prefix(8))
        }
    }

    private func prewarmInitialMarqueeDetails() async {
        let contentIds = initialMarqueeItems.compactMap { item -> String? in
            let rating = item.contentRating?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rating?.isEmpty != false else { return nil }
            let key = CacheKey.itemDetail(item.contentId)
            let cached: ItemDetail? = ResponseCache.shared.get(key)
            return cached == nil ? item.contentId : nil
        }

        let maxConcurrent = 3
        for batchStart in stride(from: 0, to: contentIds.count, by: maxConcurrent) {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + maxConcurrent, contentIds.count)
            let batch = Array(contentIds[batchStart..<batchEnd])
            let details = await withTaskGroup(of: (String, ItemDetail?).self) { group in
                for contentId in batch {
                    group.addTask {
                        let detail = try? await SiloAPI.shared.itemDetail(
                            contentId: contentId
                        )
                        return (contentId, detail)
                    }
                }

                var results: [(String, ItemDetail)] = []
                for await (contentId, detail) in group {
                    if let detail { results.append((contentId, detail)) }
                }
                return results
            }

            guard !Task.isCancelled else { return }
            for (contentId, detail) in details {
                ResponseCache.shared.set(detail, for: CacheKey.itemDetail(contentId))
            }
        }
    }
    #endif

    #if !os(tvOS)
    /// iOS/macOS: the Watchlist/Favorites shortcut row renders in every
    /// state — the user's saved lists are reachable from here even when
    /// there are no recommendations (or they failed to load).
    @ViewBuilder
    private var pageContent: some View {
        if !viewModel.sections.isEmpty {
            content
        } else {
            VStack(spacing: 0) {
                shortcutsRow
                    .padding(.horizontal, SiloTheme.padding)

                Group {
                    if let error = viewModel.error {
                        ErrorView(state: error, onRetry: { Task { await viewModel.loadRecommendations() } })
                    } else if viewModel.isLoading {
                        Color.clear
                    } else {
                        savedListsFallback
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// True when recommendations loaded fine but the server had nothing to
    /// suggest (e.g. embeddings disabled). The shortcut row then acts as a
    /// selector for the inline Watchlist/Favorites fallback instead of
    /// navigating away.
    private var showsSavedListsFallback: Bool {
        viewModel.sections.isEmpty && viewModel.error == nil && !viewModel.isLoading
    }

    private var shortcutsRow: some View {
        SavedShortcutsRow(
            selection: showsSavedListsFallback ? savedListSelection : nil,
            onSelect: { shortcut in
                if showsSavedListsFallback {
                    savedListSelection = shortcut
                } else {
                    router.navigate(to: shortcut.route)
                }
            }
        )
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: SiloTheme.largePadding) {
                shortcutsRow
                    .padding(.horizontal, SiloTheme.padding)

                ForEach(viewModel.sections) { section in
                    SectionRow(
                        section: section,
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
            .padding(.bottom, SiloTheme.largePadding)
        }
        .reportsPageChromeScroll()
    }

    /// Shown when the server has no recommendation sections: rather than an
    /// empty promise, surface the user's saved lists inline. The shortcut row
    /// above acts as the selector between the two.
    @ViewBuilder
    private var savedListsFallback: some View {
        VStack(spacing: SiloTheme.smallPadding) {
            Text("No recommendations yet — showing your saved titles.")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)

            switch savedListSelection {
            case .watchlist:
                WatchlistView(showsNavigationTitle: false)
            case .favorites:
                FavoritesView(showsNavigationTitle: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif
}

#if !os(tvOS)
private struct SavedShortcutsRow: View {
    /// Non-nil puts the row in selector mode (inline saved-lists fallback):
    /// the matching capsule renders selected instead of the row navigating.
    var selection: SavedShortcut? = nil
    let onSelect: (SavedShortcut) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(SavedShortcut.allCases) { shortcut in
                Button {
                    onSelect(shortcut)
                } label: {
                    Label {
                        Text(shortcut.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: shortcut.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SavedShortcutButtonStyle(isSelected: selection == shortcut))
                .accessibilityLabel(shortcut.rawValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SavedShortcut: String, CaseIterable, Identifiable {
    case watchlist = "Watchlist"
    case favorites = "Favorites"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .watchlist:
            return "bookmark.fill"
        case .favorites:
            return "heart.fill"
        }
    }

    var route: Route {
        switch self {
        case .watchlist:
            return .watchlist
        case .favorites:
            return .favorites
        }
    }
}

private struct SavedShortcutButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        SavedShortcutButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct SavedShortcutButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    /// Selection (or keyboard focus) gets the filled capsule.
    private var isProminent: Bool {
        isFocused || isSelected
    }

    var body: some View {
        configuration.label
            .foregroundColor(isProminent ? .siloBackground : .siloOnSurface)
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(
                Capsule()
                    .fill(
                        isProminent
                            ? Color.siloOnSurface.opacity(0.96)
                            : (isSelected ? Color.white.opacity(0.14) : Color.clear)
                    )
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(isSelected ? 0.7 : 0.3),
                    lineWidth: isFocused ? 3 : 1.5
                )
            )
            .scaleEffect(isFocused ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.siloOnSurface.opacity(0.36) : .clear,
                radius: isFocused ? 18 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
            .animation(SiloTheme.springAnimation, value: isFocused)
            .animation(SiloTheme.springAnimation, value: isSelected)
    }
}
#endif
