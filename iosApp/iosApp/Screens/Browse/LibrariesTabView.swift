import SwiftUI

/// Root of the Libraries tab.
///
/// Mirrors the Plex/Android flow: the tab lands directly on the active
/// library's 3-tab view (Recommended / Library / Collections) with a custom
/// top bar — library selector on the left, search/saved/profile actions
/// on the right.
struct LibrariesTabView: View {
    @State private var libraries: [Library] = []
    @State private var selectedLibraryId: Int?
    @State private var selectedTab: LibraryPageTab = .recommended
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var showPicker = false
    @State private var currentProfile: UserProfile?
    @State private var navPrefs = AppNavPreferences.shared

    /// Persist the last-selected library across launches so the user lands
    /// back where they left off. Stored as Int because `@AppStorage` does
    /// not support `Int?` directly; `0` represents "no stored value".
    @AppStorage("librariesTabSelectedLibraryId") private var storedLibraryId: Int = 0

    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if let activeLibrary {
                loadedContent(activeLibrary: activeLibrary)
            } else if let error, visibleLibraries.isEmpty {
                ErrorView(state: error, onRetry: { Task { await loadLibraries() } })
            } else if isLoading && visibleLibraries.isEmpty {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No libraries available",
                    subtitle: "Libraries visible to this profile will appear here."
                )
            }
        }
        .continuumBackground()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            navPrefs.refresh()
            await loadLibraries()
            await loadCurrentProfile()
        }
        .onChange(of: navPrefs.showAudiobooks) {
            applyLibrarySelection()
        }
        .sheet(isPresented: $showPicker) {
            LibraryPickerSheet(
                libraries: visibleLibraries,
                selectedLibraryId: selectedLibraryId,
                onSelect: { id in
                    selectedLibraryId = id
                    storedLibraryId = id
                    showPicker = false
                    StartupContentPrefetcher.prefetchLibraryLanding(libraryId: id)
                }
            )
        }
    }

    @ViewBuilder
    private func loadedContent(activeLibrary: Library) -> some View {
        // Switch tab content directly here (rather than going through
        // `LibraryDetailView`) so we can hoist the top bar + tab selector
        // into a single `safeAreaInset` overlay shared by all three tabs.
        tabContent(activeLibrary: activeLibrary)
            // Forces the whole tab subtree to reset when switching
            // libraries, so stale content never flashes on screen.
            .id(activeLibrary.id)
            .safeAreaInset(edge: .top, spacing: 0) {
                topChrome(activeLibrary: activeLibrary)
            }
    }

    @ViewBuilder
    private func tabContent(activeLibrary: Library) -> some View {
        switch selectedTab {
        case .recommended:
            LibraryRecommendedView(libraryId: activeLibrary.id)
        case .library:
            BrowseView(libraryId: activeLibrary.id, title: nil, showsSearchShortcut: false)
        case .collections:
            LibraryCollectionsView(libraryId: activeLibrary.id)
        }
    }

    @ViewBuilder
    private func topChrome(activeLibrary: Library) -> some View {
        VStack(spacing: 0) {
            LibrariesTopBar(
                activeLibrary: activeLibrary,
                canSwitch: visibleLibraries.count > 1,
                profile: currentProfile,
                onLibraryTap: { showPicker = true },
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onSwitchProfile: {
                    AuthService.shared.profileId = nil
                    router.showProfileSelection()
                },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() }
            )
            .padding(.horizontal, ContinuumTheme.padding)
            .padding(.top, ContinuumTheme.smallPadding)
            .padding(.bottom, ContinuumTheme.smallPadding)

            LibraryPageTabSelector(selectedTab: $selectedTab)
                .padding(.bottom, ContinuumTheme.padding)
        }
    }

    private var activeLibrary: Library? {
        visibleLibraries.first(where: { $0.id == selectedLibraryId })
    }

    private var visibleLibraries: [Library] {
        libraries.filter { navPrefs.showAudiobooks || !$0.isAudiobookLibrary }
    }

    private func loadLibraries() async {
        // Hydrate from cache so a returning visit paints last-known
        // libraries instantly while the refresh runs.
        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            applyLibrarySelection()
        }
        if libraries.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            libraries = response.libraries
            applyLibrarySelection()
            if let selectedLibraryId {
                StartupContentPrefetcher.prefetchLibraryLanding(libraryId: selectedLibraryId)
            }
        } catch {
            if libraries.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Preserve the stored selection if it still exists; otherwise fall
    /// back to the first available library.
    private func applyLibrarySelection() {
        let selectableLibraries = visibleLibraries
        let restored = storedLibraryId != 0
            ? selectableLibraries.first(where: { $0.id == storedLibraryId })?.id
            : nil
        let resolved = restored ?? selectableLibraries.first?.id
        selectedLibraryId = resolved
        if let resolved { storedLibraryId = resolved }
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
}

// MARK: - Top Bar

/// Plex-style top bar: library selector on the left, shared action icons
/// (search / profile) on the right.
private struct LibrariesTopBar: View {
    let activeLibrary: Library
    let canSwitch: Bool
    let profile: UserProfile?
    let onLibraryTap: () -> Void
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SidebarToggleButton()

            LibrarySelectorButton(
                library: activeLibrary,
                canSwitch: canSwitch,
                onTap: onLibraryTap
            )

            Spacer(minLength: 8)

            TabTopBarActions(
                profile: profile,
                onSearch: onSearch,
                onOpenSettings: onOpenSettings,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut
            )
        }
    }
}

/// Compact library selector: library name with a small chevron, stacked above
/// a secondary label. Tap opens the picker sheet.
private struct LibrarySelectorButton: View {
    let library: Library
    let canSwitch: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(library.name)
                        .font(.continuumTitle)
                        .foregroundColor(.continuumOnSurface)
                        .lineLimit(1)
                    if canSwitch {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.continuumOnSurface)
                    }
                }
                Text(typeLabel)
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
    }

    private var typeLabel: String {
        if library.isAudiobookLibrary { return "Audiobooks" }
        if library.isSeriesLibrary { return "Series" }
        if library.type == "movies" { return "Movies" }
        if library.type == "music" { return "Music" }
        return "Library"
    }
}

// MARK: - Library Picker Sheet

/// Sheet listing all libraries available to the active profile. Used for
/// switching the active library from the Libraries tab.
private struct LibraryPickerSheet: View {
    let libraries: [Library]
    let selectedLibraryId: Int?
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        // tvOS does not support medium detents or presentation drags; render
        // as a full-screen focus-friendly list instead.
        content
        #else
        NavigationStack {
            content
                .toolbar {
                    #if os(macOS)
                    ToolbarItem {
                        Button("Done") { dismiss() }
                    }
                    #else
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                    #endif
                }
        }
        #if !os(macOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(libraries) { library in
                    LibraryPickerRow(
                        library: library,
                        isSelected: library.id == selectedLibraryId,
                        onTap: { onSelect(library.id) }
                    )
                }
            }
            .padding(.horizontal, ContinuumTheme.padding)
            .padding(.vertical, ContinuumTheme.padding)
        }
        .continuumBackground()
        .navigationTitle("Libraries")
    }
}

private struct LibraryPickerRow: View {
    let library: Library
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.continuumOnSurface.opacity(0.12))
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                        .font(.continuumHeadline)
                        .foregroundColor(.continuumOnSurface)
                    Text(typeLabel)
                        .font(.continuumCaption)
                        .foregroundColor(.continuumSecondaryText)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                    .fill(isSelected ? Color.continuumOnSurface.opacity(0.10) : Color.continuumSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                            .stroke(Color.continuumOutline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if library.isAudiobookLibrary { return "book.closed.fill" }
        if library.isSeriesLibrary { return "tv.fill" }
        if library.type == "movies" { return "film.fill" }
        if library.type == "music" { return "music.note" }
        return "square.stack.3d.up.fill"
    }

    private var typeLabel: String {
        if library.isAudiobookLibrary { return "Audiobooks library" }
        if library.isSeriesLibrary { return "TV library" }
        if library.type == "movies" { return "Movies library" }
        if library.type == "music" { return "Music library" }
        return "Library"
    }
}
