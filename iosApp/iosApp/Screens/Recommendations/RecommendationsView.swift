import SwiftUI

/// Personalized recommendations tab — mirrors the Android Recommendations
/// screen. Reuses the existing SectionRow UI so each row renders with the
/// same layout as Home.
struct RecommendationsView: View {
    /// Active focus hand-down token from `TVMainTabView`. When this changes
    /// (the For You root was selected), focus is pushed onto the saved-
    /// shortcuts row so the screen never opens with a dead remote.
    var focusRequest: Int = 0
    /// tvOS-only: the custom top menu owns focus, so deferred content focus
    /// claims must not yank focus back into the shortcut row.
    var isTopMenuFocused: Bool = false
    var onTopMenuFocusRequest: (() -> Void)? = nil

    @State private var viewModel: RecommendationsViewModel
    @State private var currentProfile: UserProfile?
    @State private var savedListSelection: SavedShortcut = .watchlist
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
                #if os(iOS)
                async let recommendations: Void = viewModel.loadRecommendations()
                async let profile: Void = loadCurrentProfile()
                _ = await (recommendations, profile)
                #else
                await viewModel.loadRecommendations()
                await loadCurrentProfile()
                #endif
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
        ZStack(alignment: .top) {
            TVRootHeroBackdrop(
                tintColor: .continuumBackground,
                artworkURL: nil,
                artworkThumbhash: nil,
                isVisible: false
            )

            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SidebarToggleButton()

                Text("Recommendations")
                    .font(.continuumTitle)
                    .foregroundColor(.continuumOnSurface)

                Spacer(minLength: 8)

                TabTopBarActions(
                    profile: currentProfile,
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
            .padding(.horizontal, ContinuumTheme.padding)
            .padding(.top, ContinuumTheme.smallPadding)
            .padding(.bottom, ContinuumTheme.smallPadding)

            pageContent
        }
        .continuumBackground()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #endif
    }

    /// The Watchlist/Favorites shortcut row renders in every state — the
    /// user's saved lists are reachable from here even when there are no
    /// recommendations (or they failed to load).
    @ViewBuilder
    private var pageContent: some View {
        if !viewModel.sections.isEmpty {
            content
        } else {
            VStack(spacing: 0) {
                shortcutsRow
                    .padding(.horizontal, contentHorizontalPadding)
                    #if os(tvOS)
                    .padding(.top, TVTopMenuLayout.contentTopInset)
                    #endif

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
            focusRequest: focusRequest,
            isTopMenuFocused: isTopMenuFocused,
            selection: showsSavedListsFallback ? savedListSelection : nil,
            onSelect: { shortcut in
                if showsSavedListsFallback {
                    savedListSelection = shortcut
                } else {
                    router.navigate(to: shortcut.route)
                }
            },
            onMoveUp: onTopMenuFocusRequest
        )
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: sectionSpacing) {
                shortcutsRow
                    .padding(.horizontal, contentHorizontalPadding)

                ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) { index, section in
                    SectionRow(
                        section: section,
                        onItemTap: { destinationContentId, item in
                            router.navigate(
                                to: .itemDetail(
                                    destinationContentId: destinationContentId,
                                    sectionItem: item
                                )
                            )
                        },
                        prefersDefaultFocusOnFirstItem: prefersDefaultFocus(forSectionAt: index),
                        onMoveUp: nil
                    )
                }
            }
            #if os(tvOS)
            .padding(.top, TVTopMenuLayout.contentTopInset)
            #endif
            .padding(.bottom, ContinuumTheme.largePadding)
        }
    }

    /// Shown when the server has no recommendation sections: rather than an
    /// empty promise, surface the user's saved lists inline. The shortcut row
    /// above acts as the selector between the two.
    @ViewBuilder
    private var savedListsFallback: some View {
        VStack(spacing: ContinuumTheme.smallPadding) {
            Text("No recommendations yet — showing your saved titles.")
                .font(.continuumCaption)
                .foregroundColor(.continuumSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.top, ContinuumTheme.smallPadding)

            switch savedListSelection {
            case .watchlist:
                WatchlistView(showsNavigationTitle: false)
            case .favorites:
                FavoritesView(showsNavigationTitle: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Load the currently-selected profile so we can render its avatar in
    /// the top bar. Non-fatal on failure — we fall back to a generic icon.
    private func loadCurrentProfile() async {
        guard let profileId = AuthService.shared.profileId else { return }
        do {
            let profiles = try await AuthService.shared.getProfiles()
            currentProfile = profiles.first(where: { $0.id == profileId })
        } catch {
            // Leave currentProfile nil; the top bar renders a fallback.
        }
    }

    private var sectionSpacing: CGFloat {
        #if os(tvOS)
        return 30
        #else
        return ContinuumTheme.largePadding
        #endif
    }

    private var contentHorizontalPadding: CGFloat {
        #if os(tvOS)
        return 96
        #else
        return ContinuumTheme.padding
        #endif
    }

    private func prefersDefaultFocus(forSectionAt index: Int) -> Bool {
        return false
    }
}

private struct SavedShortcutsRow: View {
    var focusRequest: Int = 0
    var isTopMenuFocused: Bool = false
    /// Non-nil puts the row in selector mode (inline saved-lists fallback):
    /// the matching capsule renders selected instead of the row navigating.
    var selection: SavedShortcut? = nil
    let onSelect: (SavedShortcut) -> Void
    let onMoveUp: (() -> Void)?

    @FocusState private var focusedShortcut: SavedShortcut?

    #if os(tvOS)
    @Namespace private var focusScope
    /// Last hand-down token applied, so each token claims focus exactly once.
    /// This row lives in a `LazyVStack`; without the guard, `onAppear` re-fires
    /// when the row is recycled back into view on scroll-up and would yank
    /// focus away from whatever the user was on.
    @State private var lastAppliedFocusRequest = 0
    @State private var pendingFocusRequest: Int?
    #endif

    var body: some View {
        HStack(spacing: 12) {
            ForEach(SavedShortcut.allCases) { shortcut in
                Button {
                    onSelect(shortcut)
                } label: {
                    Label {
                        Text(shortcut.rawValue)
                            .font(labelFont)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: shortcut.systemImage)
                            .font(iconFont)
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SavedShortcutButtonStyle(isSelected: selection == shortcut))
                .accessibilityLabel(shortcut.rawValue)
                .focused($focusedShortcut, equals: shortcut)
                #if os(tvOS)
                .prefersDefaultFocus(shortcut == .watchlist, in: focusScope)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .focusScope(focusScope)
        .focusSection()
        .onMoveCommand { direction in
            if direction == .up {
                onMoveUp?()
            }
        }
        // Imperative hand-down from the top menu: prefersDefaultFocus only
        // fires when the engine ENTERS this scope, which doesn't happen when
        // the For You root is swapped in beneath a remote sitting in the menu.
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: isTopMenuFocused) { _, focused in
            guard !focused, let pendingFocusRequest else { return }
            applyFocusRequest(pendingFocusRequest)
        }
        #endif
    }

    #if os(tvOS)
    private func applyFocusRequest(_ request: Int) {
        guard request > 0 else { return }
        guard request != lastAppliedFocusRequest else {
            pendingFocusRequest = nil
            return
        }
        guard !isTopMenuFocused else {
            pendingFocusRequest = request
            return
        }
        pendingFocusRequest = nil
        lastAppliedFocusRequest = request
        focusedShortcut = .watchlist
    }
    #endif

    private var labelFont: Font {
        #if os(tvOS)
        return .system(size: 24, weight: .semibold)
        #else
        return .system(size: 14, weight: .semibold)
        #endif
    }

    private var iconFont: Font {
        #if os(tvOS)
        return .system(size: 20, weight: .semibold)
        #else
        return .system(size: 13, weight: .semibold)
        #endif
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

    /// tvOS keeps the filled capsule as the focus indicator, so a selected-
    /// but-unfocused capsule only gets a stronger stroke and a faint fill.
    /// On touch/pointer platforms there is no focus, so selection owns the
    /// filled treatment outright.
    private var isProminent: Bool {
        #if os(tvOS)
        return isFocused
        #else
        return isFocused || isSelected
        #endif
    }

    var body: some View {
        configuration.label
            .foregroundColor(isProminent ? .continuumBackground : .continuumOnSurface)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                Capsule()
                    .fill(
                        isProminent
                            ? Color.continuumOnSurface.opacity(0.96)
                            : (isSelected ? Color.white.opacity(0.14) : Color.clear)
                    )
            )
            .overlay(
                Capsule().stroke(
                    isFocused ? Color.white : Color.white.opacity(isSelected ? 0.7 : 0.3),
                    lineWidth: isFocused ? 3 : 1.5
                )
            )
            .overlay {
                #if os(tvOS)
                if isFocused {
                    Capsule()
                        .stroke(Color.white.opacity(0.36), lineWidth: 7)
                        .padding(-6)
                        .blur(radius: 6)
                }
                #endif
            }
            .scaleEffect(isFocused ? 1.045 : 1.0)
            .shadow(
                color: isFocused ? Color.continuumOnSurface.opacity(0.36) : .clear,
                radius: isFocused ? 18 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
            .animation(ContinuumTheme.springAnimation, value: isFocused)
            .animation(ContinuumTheme.springAnimation, value: isSelected)
    }

    private var height: CGFloat {
        #if os(tvOS)
        return 64
        #else
        return 40
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        return 26
        #else
        return 15
        #endif
    }
}
