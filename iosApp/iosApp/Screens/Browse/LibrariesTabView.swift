import SwiftUI

/// The media type a library groups under. A mixed library matches both
/// Movies and Series.
enum LibraryMediaCategory: CaseIterable {
    case movies
    case series
    case audiobooks

    func matches(_ library: Library) -> Bool {
        switch self {
        case .movies: return library.isMovieLibrary || library.isMixedLibrary
        case .series: return library.isSeriesLibrary || library.isMixedLibrary
        case .audiobooks: return library.isAudiobookLibrary
        }
    }

    var navigationIcon: String {
        switch self {
        case .movies: return "film.stack"
        case .series: return "tv"
        case .audiobooks: return "book.closed"
        }
    }
}

private func sharesMediaCategory(_ lhs: Library, _ rhs: Library) -> Bool {
    // A mixed library is its own scope. Treating its Movies and Series
    // memberships as sibling relationships would expose every movie and
    // series library from it.
    if lhs.isMixedLibrary {
        return rhs.isMixedLibrary
    }
    return LibraryMediaCategory.allCases.contains { $0.matches(lhs) && $0.matches(rhs) }
}

func visibleLibrariesForRoot(
    _ libraries: [Library],
    fixedLibraryId: Int?,
    showAudiobooks: Bool
) -> [Library] {
    if let fixedLibraryId {
        // A direct library root still requires the exact library to be
        // accessible, but exposes sibling libraries of the same media type
        // so the top selector can switch between them.
        guard let fixed = libraries.first(where: { $0.id == fixedLibraryId }) else {
            return []
        }
        return libraries.filter {
            $0.id == fixed.id || sharesMediaCategory(fixed, $0)
        }
    }
    return libraries.filter { showAudiobooks || !$0.isAudiobookLibrary }
}

func resolvedLibraryIdForRoot(
    _ libraries: [Library],
    fixedLibraryId: Int?,
    showAudiobooks: Bool,
    storedLibraryId: Int,
    currentSelectionId: Int? = nil
) -> Int? {
    let visible = visibleLibrariesForRoot(
        libraries,
        fixedLibraryId: fixedLibraryId,
        showAudiobooks: showAudiobooks
    )
    if let fixedLibraryId {
        // Keep an in-session switch to a sibling library, but always land on
        // the exact library when entering the root fresh.
        if let current = currentSelectionId,
           visible.contains(where: { $0.id == current }) {
            return current
        }
        return visible.first(where: { $0.id == fixedLibraryId })?.id
    }
    if storedLibraryId != 0,
       let restored = visible.first(where: { $0.id == storedLibraryId }) {
        return restored.id
    }
    return visible.first?.id
}

private func libraryRootScopeID(
    fixedLibraryId: Int?,
    authority: MainTabLibraryAuthority?
) -> String {
    let destination = fixedLibraryId.map { "library:\($0)" } ?? "all"
    return "\(authority?.serverId ?? "none"):\(authority?.profileId ?? "none"):\(destination)"
}

/// Where the Libraries tab remembers its library. A direct library root
/// (a Mac sidebar row) has no key: its destination already fixes the ID.
func librarySelectionStorageKey(fixedLibraryId: Int?) -> String? {
    fixedLibraryId == nil ? "librariesTabSelectedLibraryId" : nil
}

func storedLibrarySelectionId(
    for storageKey: String?,
    defaults: UserDefaults = .standard
) -> Int {
    guard let storageKey else { return 0 }
    return defaults.integer(forKey: storageKey)
}

/// A mixed library shows the Movies/Series selector's choice.
func mixedLibraryVideoScope(libraryType: String, selection: LibraryVideoScope) -> LibraryVideoScope? {
    SiloMediaType.isMixedLibrary(libraryType) ? selection : nil
}

struct LibraryVideoScopePicker: View {
    @Binding var selection: LibraryVideoScope

    var body: some View {
        Picker("Media type", selection: $selection) {
            Text("Movies").tag(LibraryVideoScope.movie)
            Text("Series").tag(LibraryVideoScope.series)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, SiloTheme.padding)
        .padding(.bottom, SiloTheme.smallPadding)
    }
}

/// Root of the Libraries tab.
///
/// Mirrors the Plex/Android flow: the tab lands directly on the active
/// library's 3-tab view (Recommended / Library / Collections) with a custom
/// top bar — library selector on the left, search/saved/profile actions
/// on the right.
struct LibrariesTabView: View {
    let fixedLibraryId: Int?
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @State private var libraries: [Library] = []
    @State private var selectedLibraryId: Int?
    @State private var selectedTab: LibraryPageTab = .recommended
    @State private var selectedVideoScope: LibraryVideoScope = .movie
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var showPicker = false
    @State private var navPrefs = AppNavPreferences.shared
    /// Feeds the glass strip behind the hoisted top chrome. Tab content reads
    /// it from the environment so each tab's ScrollView can report its offset.
    @State private var chromeScrollState = PageChromeScrollState()

    /// Persist the last-selected library. Fixed-library roots have no
    /// persistence key because their destination already fixes the ID.
    private let selectionStorageKey: String?
    @State private var storedLibraryId: Int
    /// Scope the current `selectedLibraryId` belongs to. A direct-library
    /// root allows switching to sibling libraries in-session, but a fresh
    /// visit (or a reused view whose destination changed) must land on the
    /// exact library again.
    @State private var appliedScopeID: String?

    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.statusColumn) private var statusColumn
    #endif

    init(
        fixedLibraryId: Int? = nil,
        libraryAuthority: MainTabLibraryAuthority? = nil,
        onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)? = nil
    ) {
        self.fixedLibraryId = fixedLibraryId
        self.libraryAuthority = libraryAuthority
        self.onLibrariesLoaded = onLibrariesLoaded
        let storageKey = librarySelectionStorageKey(fixedLibraryId: fixedLibraryId)
        selectionStorageKey = storageKey
        _storedLibraryId = State(initialValue: storedLibrarySelectionId(for: storageKey))
    }

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
        .siloPageBackground()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: libraryRootScopeID(
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )) {
            navPrefs.refresh()
            storedLibraryId = storedLibrarySelectionId(for: selectionStorageKey)
            // SwiftUI can preserve this view while a split-view selection
            // changes from one direct library root to another. Reconcile the
            // selection before awaiting I/O so the old library never renders
            // under the new destination.
            applyLibrarySelection()
            await loadLibraries()
        }
        .onChange(of: navPrefs.showAudiobooks) {
            applyLibrarySelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) {
            notification in
            guard let response = notification.object as? LibrariesResponse else { return }
            acceptRefreshedLibraries(response)
        }
        .sheet(isPresented: $showPicker) {
            LibraryPickerSheet(
                libraries: visibleLibraries,
                scopedCategory: pickerScopeCategory,
                selectedLibraryId: selectedLibraryId,
                onSelect: { id in
                    selectedLibraryId = id
                    persistLibrarySelection(id)
                    showPicker = false
                    StartupContentPrefetcher.prefetchLibraryLanding(
                        libraryId: id,
                        groupsBoxSets: visibleLibraries.first { $0.id == id }?.browsesBoxSets ?? false
                    )
                }
            )
        }
    }

    @ViewBuilder
    private func loadedContent(activeLibrary: Library) -> some View {
        // Switch tab content directly here so we can hoist the top bar + tab
        // selector into a single `safeAreaInset` overlay shared by all three
        // tabs.
        tabContent(activeLibrary: activeLibrary)
            // Forces the whole tab subtree to reset when switching
            // libraries, so stale content never flashes on screen.
            .id("\(activeLibrary.id):\(videoScope(for: activeLibrary)?.rawValue ?? "all")")
            .environment(chromeScrollState)
            .safeAreaInset(edge: .top, spacing: 0) {
                topChrome(activeLibrary: activeLibrary)
                    // The title and tab selector share one rounded panel.
                    .pageChromeBacking(
                        scrollState: chromeScrollState,
                        outset: EdgeInsets(top: 0, leading: -8, bottom: -8, trailing: -8)
                    )
                    // Same scroll-driven glass as the Detail page chrome so
                    // the selector and actions stay legible over posters.
                    .background {
                        PageChromeGlass(scrollState: chromeScrollState)
                    }
            }
    }

    @ViewBuilder
    private func tabContent(activeLibrary: Library) -> some View {
        switch selectedTab {
        case .recommended:
            LibraryRecommendedView(libraryId: activeLibrary.id, mediaScope: videoScope(for: activeLibrary))
        case .library:
            BrowseView(
                libraryId: activeLibrary.id,
                title: nil,
                showsSearchShortcut: false,
                libraryType: activeLibrary.type,
                mediaScope: videoScope(for: activeLibrary),
                groupsBoxSets: activeLibrary.browsesBoxSets
            )
        case .collections:
            LibraryCollectionsView(libraryId: activeLibrary.id, mediaScope: videoScope(for: activeLibrary))
        }
    }

    @ViewBuilder
    private func topChrome(activeLibrary: Library) -> some View {
        if centersHeader {
            // The title and tabs center as one block, the title lined up
            // with the first tab, while they fit side by side.
            ViewThatFits(in: .horizontal) {
                headerStack(activeLibrary: activeLibrary, scrollsTabs: false)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
                headerStack(activeLibrary: activeLibrary, scrollsTabs: true)
            }
        } else {
            headerStack(activeLibrary: activeLibrary, scrollsTabs: true)
        }
    }

    private func headerStack(activeLibrary: Library, scrollsTabs: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LibrariesTopBar(
                activeLibrary: activeLibrary,
                canSwitch: canSwitchLibraries,
                onLibraryTap: { showPicker = true },
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onSwitchProfile: {
                    router.switchProfile()
                },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() }
            )
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, centersHeader ? SiloTheme.padding : SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.smallPadding)

            if activeLibrary.isMixedLibrary {
                LibraryVideoScopePicker(selection: $selectedVideoScope)
            }
            LibraryPageTabSelector(selectedTab: $selectedTab, scrolls: scrollsTabs)
                .padding(.bottom, SiloTheme.padding)
        }
    }

    /// The iPhone Duo's cover screen moves the header actions into the
    /// status column, leaving the title and tabs alone in a rounded panel.
    private var centersHeader: Bool {
        #if os(iOS)
        statusColumn != nil
        #else
        false
        #endif
    }

    private func videoScope(for library: Library) -> LibraryVideoScope? {
        mixedLibraryVideoScope(libraryType: library.type, selection: selectedVideoScope)
    }

    private var activeLibrary: Library? {
        visibleLibraries.first(where: { $0.id == selectedLibraryId })
    }

    /// The media-type scope the picker opened under, if any. A direct-library
    /// root inherits its library's type since its siblings share it.
    /// Mixed-library roots have their own scope rather than inheriting either
    /// Movies or Series.
    private var pickerScopeCategory: LibraryMediaCategory? {
        guard let fixedLibraryId,
              let fixed = libraries.first(where: { $0.id == fixedLibraryId }),
              !fixed.isMixedLibrary
        else { return nil }
        return LibraryMediaCategory.allCases.first { $0.matches(fixed) }
    }

    /// The Mac lists every library in its sidebar, so the page title offers
    /// no picker there.
    private var canSwitchLibraries: Bool {
        #if os(macOS)
        false
        #else
        visibleLibraries.count > 1
        #endif
    }

    private var visibleLibraries: [Library] {
        visibleLibrariesForRoot(
            libraries,
            fixedLibraryId: fixedLibraryId,
            showAudiobooks: navPrefs.showAudiobooks
        )
    }

    private func loadLibraries() async {
        // Hydrate from cache so a returning visit paints last-known
        // libraries instantly while the refresh runs.
        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            applyLibrarySelection()
            onLibrariesLoaded?(libraryAuthority, cached.libraries)
        }
        if libraries.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled else { return }
            acceptRefreshedLibraries(response)
        } catch {
            if libraries.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Apply library metadata refreshed elsewhere (for example Home pull to
    /// refresh) so retained tab instances cannot keep renamed or revoked
    /// libraries in their local state.
    private func acceptRefreshedLibraries(_ response: LibrariesResponse) {
        libraries = response.libraries
        error = nil
        isLoading = false
        applyLibrarySelection()
        onLibrariesLoaded?(libraryAuthority, response.libraries)
        if let selectedLibraryId {
            StartupContentPrefetcher.prefetchLibraryLanding(
                libraryId: selectedLibraryId,
                groupsBoxSets: response.libraries.first { $0.id == selectedLibraryId }?.browsesBoxSets ?? false
            )
        }
    }

    /// Preserve the stored selection if it still exists; otherwise fall
    /// back to the first available library.
    private func applyLibrarySelection() {
        let scopeID = libraryRootScopeID(
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )
        let resolved = resolvedLibraryIdForRoot(
            libraries,
            fixedLibraryId: fixedLibraryId,
            showAudiobooks: navPrefs.showAudiobooks,
            storedLibraryId: storedLibraryId,
            currentSelectionId: appliedScopeID == scopeID ? selectedLibraryId : nil
        )
        appliedScopeID = scopeID
        selectedLibraryId = resolved
        if let resolved { persistLibrarySelection(resolved) }
    }

    private func persistLibrarySelection(_ libraryId: Int) {
        if let selectionStorageKey {
            storedLibraryId = libraryId
            UserDefaults.standard.set(libraryId, forKey: selectionStorageKey)
        }
    }
}

// MARK: - Top Bar

/// Plex-style top bar: library selector on the left, shared action icons
/// (search / profile) on the right.
private struct LibrariesTopBar: View {
    let activeLibrary: Library
    let canSwitch: Bool
    let onLibraryTap: () -> Void
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    let onOpenRequests: () -> Void
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
                onSearch: onSearch,
                onOpenSettings: onOpenSettings,
                onOpenRequests: onOpenRequests,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut
            )
        }
        .clearsWindowControls()
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
                        .font(.siloTitle)
                    .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    if canSwitch {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.siloOnSurface)
                    }
                }
                Text(typeLabel)
                    .font(.siloCaption)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
    }

    private var typeLabel: String {
        if library.isAudiobookLibrary { return "Audiobooks" }
        if library.isMixedLibrary { return "Movies & Series" }
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
    let scopedCategory: LibraryMediaCategory?
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
                        scopedCategory: scopedCategory,
                        isSelected: library.id == selectedLibraryId,
                        onTap: { onSelect(library.id) }
                    )
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.padding)
        }
        .siloSheetBackground()
        .navigationTitle("Libraries")
    }
}

private struct LibraryPickerRow: View {
    let library: Library
    let scopedCategory: LibraryMediaCategory?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.siloOnSurface.opacity(0.12))
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                        .font(.siloHeadline)
                        .foregroundColor(.siloOnSurface)
                    if let typeLabel {
                        Text(typeLabel)
                            .font(.siloCaption)
                            .foregroundColor(.siloSecondaryText)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                    .fill(isSelected ? Color.siloOnSurface.opacity(0.10) : Color.siloSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                            .stroke(Color.siloOutline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if library.isAudiobookLibrary { return "book.closed.fill" }
        if library.isMixedLibrary { return "square.stack.3d.up.fill" }
        if library.isSeriesLibrary { return "tv.fill" }
        if library.type == "movies" { return "film.fill" }
        if library.type == "music" { return "music.note" }
        return "square.stack.3d.up.fill"
    }

    /// Nil when the caption would just repeat the media-type scope the picker
    /// opened under — every non-mixed library there shares that type. Mixed
    /// libraries keep their caption since they stand out from the scope.
    private var typeLabel: String? {
        if scopedCategory != nil && !library.isMixedLibrary { return nil }
        if library.isAudiobookLibrary { return "Audiobooks library" }
        if library.isMixedLibrary { return "Movies & Series library" }
        if library.isSeriesLibrary { return "TV library" }
        if library.type == "movies" { return "Movies library" }
        if library.type == "music" { return "Music library" }
        return "Library"
    }
}
