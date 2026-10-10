#if !os(tvOS)
import SwiftUI

/// The iOS Watch, Listen and single-type tabs: one root for every library of
/// a hub.
///
/// Chips under the title (`MediaScopeChips`) scope the page to one library
/// and open Browse and Collections; the title switches kinds, and once the
/// header folds it offers everything the chips did. A single
/// library shows its server-built rows, led by Home's resume row when the
/// library has none. A whole kind composes resume rows from Home, a
/// cross-library Recently Added row, and one row per library.
struct MediaHubView: View {
    let hub: MediaHub
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @State private var libraries: [Library] = []
    @State private var kind: MediaKind = .movies
    @State private var selectedLibraryId: Int?
    @State private var hasResolvedSelection = false
    @State private var isLoadingLibraries = true
    @State private var libraryError: ErrorState?
    @State private var landing = MediaLandingViewModel()
    @State private var chromeScrollState = PageChromeScrollState()

    @Environment(AppRouter.self) private var router

    private var memory: MediaHubMemory {
        MediaHubMemory(authority: libraryAuthority)
    }
    private var availableKinds: [MediaKind] { MediaHubScope.availableKinds(for: hub, in: libraries) }
    private var kindLibraries: [Library] { MediaHubScope.libraries(for: kind, in: libraries) }
    private var selectedLibrary: Library? {
        selectedLibraryId.flatMap { id in kindLibraries.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if hasResolvedSelection, !availableKinds.isEmpty {
                loadedContent
            } else if let libraryError, libraries.isEmpty {
                ErrorView(state: libraryError, onRetry: { Task { await loadLibraries() } })
            } else if isLoadingLibraries {
                Color.clear
            } else {
                EmptyStateView(
                    icon: hub.capability == .listen ? "headphones" : "play.tv",
                    title: hub.capability == .listen ? "Nothing to listen to yet" : "Nothing to watch yet",
                    subtitle: hub.capability == .listen
                        ? "Audiobook libraries visible to this profile will appear here."
                        : "Movie and TV libraries visible to this profile will appear here."
                )
            }
        }
        .siloPageBackground()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: libraryAuthority) {
            // Another profile's libraries must not stand in for this one's.
            hasResolvedSelection = false
            libraries = []
            await loadLibraries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) { notification in
            guard let response = notification.object as? LibrariesResponse else { return }
            accept(response.libraries)
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
            // Watched state, progress or hidden libraries changed, and the
            // resume and library rows still show the old answer.
            guard hasResolvedSelection else { return }
            Task { await reloadLanding() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaHubSelectionDidChange)) { _ in
            // The Libraries page chose a library for this hub's capability.
            guard hasResolvedSelection else { return }
            hasResolvedSelection = false
            accept(libraries)
        }
    }

    // MARK: - Layout

    private var loadedContent: some View {
        landingContent
            .environment(chromeScrollState)
            .mediaHubTopBar(scrollState: chromeScrollState) { topChrome }
            .task(id: MediaLandingKey(kind: kind, libraryId: selectedLibraryId, libraries: kindLibraries.map(\.id))) {
                await landing.load(kind: kind, library: selectedLibrary, kindLibraries: kindLibraries)
            }
    }

    private var header: MediaScopeHeader {
        MediaHubScope.header(
            kind: kind,
            library: selectedLibrary,
            kindLibraries: kindLibraries
        )
    }

    private var menu: MediaScopeMenu {
        MediaHubScope.menu(for: hub, kind: kind, in: libraries)
    }

    private var selection: MediaScopeSelection {
        MediaHubScope.currentSelection(kind: kind, libraryId: selectedLibraryId, kindLibraries: kindLibraries)
    }

    private func browse() {
        router.navigate(to: .mediaBrowse(kind: kind, libraryId: selectedLibraryId))
    }

    private var openCollections: (() -> Void)? {
        selectedLibrary.map { library in
            {
                router.navigate(to: .libraryCollections(
                    libraryId: library.id,
                    title: "\(library.name) Collections",
                    mediaScope: library.isMixedLibrary ? kind.videoScope : nil
                ))
            }
        }
    }

    private var topChrome: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .mediaTitleRow, spacing: 12) {
                SidebarToggleButton()
                MediaScopeTitleMenu(
                    header: header,
                    menu: menu,
                    kind: kind,
                    selection: selection,
                    onSelectKind: { select(.init(kind: $0, libraryId: memory.libraryId(for: $0))) },
                    onSelect: select,
                    onBrowse: browse,
                    onCollections: openCollections,
                    isCompact: chromeScrollState.isCompact
                )
                Spacer(minLength: 8)
                TabTopBarActions(
                    onSearch: { router.navigate(to: .search) },
                    onOpenSettings: { router.navigate(to: .settings) },
                    onOpenRequests: { router.navigate(to: .requestsHub) },
                    onSwitchProfile: { router.switchProfile() },
                    onSwitchServer: { router.navigate(to: .serverList) },
                    onSignOut: { router.signOutAndReset() }
                )
            }
            .padding(.horizontal, SiloTheme.padding)
            if !chromeScrollState.isCompact {
                MediaScopeChips(
                    options: menu.showsChips ? menu.options : [],
                    selection: selection,
                    onSelect: select,
                    onBrowse: browse,
                    onCollections: openCollections
                )
                .transition(.opacity)
            }
        }
        .padding(.top, SiloTheme.smallPadding)
        .padding(.bottom, SiloTheme.smallPadding)
        .animatesPageChromeFold(chromeScrollState)
    }

    private var landingContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: SiloTheme.largePadding) {
                if landing.sections.isEmpty, let error = landing.error {
                    ErrorView(state: error, onRetry: { Task { await reloadLanding() } })
                        .frame(minHeight: 280)
                } else if landing.sections.isEmpty, !landing.isLoading {
                    EmptyStateView(
                        icon: "film.stack",
                        title: "Nothing here yet",
                        subtitle: "New additions to this library will show up here."
                    )
                    .frame(minHeight: 280)
                }

                ForEach(landing.sections) { section in
                    if HomeFeed.isResume(section)
                        || section.sectionType.lowercased().contains("next") {
                        // Home's own row: resume rows keep Home's 16:9 stills.
                        // A selected library scopes the detail and playback
                        // its cards open, as the rows below do.
                        HomeFeedRow(section: section)
                            .environment(\.browseLibraryId, selectedLibraryId)
                    } else {
                        sectionRow(section)
                    }
                }
            }
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
        .reportsPageChromeScroll()
        .refreshable { await reloadLanding() }
    }

    private func sectionRow(_ section: ResolvedSection) -> some View {
        SectionRow(
            section: section,
            onItemTap: { destinationContentId, item in
                router.navigate(
                    to: .itemDetail(
                        destinationContentId: destinationContentId,
                        sectionItem: item,
                        libraryId: MediaLandingViewModel.libraryRowLibraryId(section) ?? selectedLibraryId
                    )
                )
            },
            onSeeAll: seeAllAction(for: section)
        )
    }

    private func seeAllAction(for section: ResolvedSection) -> (() -> Void)? {
        if let libraryId = MediaLandingViewModel.libraryRowLibraryId(section) {
            return { select(.init(kind: kind, libraryId: libraryId)) }
        }
        if section.id == MediaLandingViewModel.recentlyAddedID {
            // Every library of the kind, or the selected library whose
            // sections fell back to this row.
            return { router.navigate(to: .mediaBrowse(kind: kind, libraryId: selectedLibraryId)) }
        }
        return nil
    }

    // MARK: - Selection

    private func select(_ selection: MediaScopeSelection) {
        let kindLibraries = MediaHubScope.libraries(for: selection.kind, in: libraries)
        memory.setKind(selection.kind, for: hub)
        if kindLibraries.count > 1 {
            memory.setLibraryId(selection.libraryId, for: selection.kind)
        }
        withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
            kind = selection.kind
            selectedLibraryId = MediaHubScope.resolvedLibraryId(
                kind: selection.kind,
                storedLibraryId: selection.libraryId,
                kindLibraries: kindLibraries
            )
        }
        if let selectedLibraryId {
            memory.setLastUsedLibraryId(selectedLibraryId, for: hub.capability)
            StartupContentPrefetcher.prefetchLibraryLanding(libraryId: selectedLibraryId)
        }
    }

    private func reloadLanding() async {
        await landing.load(kind: kind, library: selectedLibrary, kindLibraries: kindLibraries, force: true)
    }

    // MARK: - Libraries

    private func loadLibraries() async {
        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            accept(cached.libraries)
        }
        isLoadingLibraries = libraries.isEmpty
        libraryError = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled else { return }
            accept(response.libraries)
        } catch {
            if libraries.isEmpty { libraryError = ErrorState(error) }
        }
        isLoadingLibraries = false
    }

    private func accept(_ newLibraries: [Library]) {
        libraries = newLibraries
        onLibrariesLoaded?(libraryAuthority, newLibraries)
        let kinds = MediaHubScope.availableKinds(for: hub, in: newLibraries)
        guard let fallbackKind = kinds.first else { return }
        let previousKind = kind
        if !hasResolvedSelection || !kinds.contains(kind) {
            kind = memory.kind(for: hub).flatMap { kinds.contains($0) ? $0 : nil } ?? fallbackKind
        }
        let kindLibraries = MediaHubScope.libraries(for: kind, in: newLibraries)
        var remembered = memory.libraryId(for: kind)
        // A remembered library that was removed or lost falls back to every
        // library of the kind, and that becomes the saved selection.
        if let id = remembered, !kindLibraries.contains(where: { $0.id == id }) {
            memory.setLibraryId(nil, for: kind)
            remembered = nil
        }
        let keepsCurrent = hasResolvedSelection && kind == previousKind
        selectedLibraryId = MediaHubScope.resolvedLibraryId(
            kind: kind,
            storedLibraryId: keepsCurrent ? selectedLibraryId : remembered,
            kindLibraries: kindLibraries
        )
        hasResolvedSelection = true
    }
}

private struct MediaLandingKey: Hashable {
    let kind: MediaKind
    let libraryId: Int?
    let libraries: [Int]
}

// MARK: - Title menu

extension VerticalAlignment {
    /// Centers the header's trailing actions on the title line rather than
    /// on the title-plus-subtitle block.
    private enum MediaTitleRow: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let mediaTitleRow = VerticalAlignment(MediaTitleRow.self)
}

/// The hub's large title. Unfolded, the chips pick a library, so the title
/// is a menu only when there are kinds to switch between. Folded, the chips
/// are gone and the title's menu offers everything they did.
struct MediaScopeTitleMenu: View {
    let header: MediaScopeHeader
    let menu: MediaScopeMenu
    let kind: MediaKind
    let selection: MediaScopeSelection
    let onSelectKind: (MediaKind) -> Void
    let onSelect: (MediaScopeSelection) -> Void
    var onBrowse: (() -> Void)? = nil
    var onCollections: (() -> Void)? = nil
    /// Scrolled: one smaller line, no subtitle, no chips.
    var isCompact = false

    private var showsMenu: Bool {
        guard isCompact else { return !menu.kinds.isEmpty }
        return !menu.isEmpty || onBrowse != nil || onCollections != nil
    }

    private var title: String { isCompact ? header.foldedTitle : header.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if showsMenu {
                    Menu { menuContent } label: { titleLine(showsChevron: true) }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .accessibilityLabel([title, header.subtitle].compactMap { $0 }.joined(separator: ", "))
                        .accessibilityHint("Choose what this page shows")
                } else {
                    titleLine(showsChevron: false)
                }
            }
            .accessibilityAddTraits(.isHeader)
            .alignmentGuide(.mediaTitleRow) { $0[VerticalAlignment.center] }
            if !isCompact, let subtitle = header.subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: SiloTheme.normalDuration), value: header)
    }

    @ViewBuilder
    private var menuContent: some View {
        if !menu.kinds.isEmpty {
            Picker("Show", selection: Binding(get: { kind }, set: onSelectKind)) {
                ForEach(menu.kinds, id: \.self) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.inline)
        }
        if isCompact {
            if menu.showsChips {
                Section {
                    ForEach(menu.options) { option in
                        Toggle(option.title, isOn: Binding(
                            get: { option.selection == selection },
                            set: { if $0 { onSelect(option.selection) } }
                        ))
                    }
                }
            }
            Section {
                if let onBrowse {
                    Button("Browse A–Z", systemImage: "square.grid.2x2", action: onBrowse)
                }
                if let onCollections {
                    Button("Collections", systemImage: "rectangle.stack", action: onCollections)
                }
            }
        }
    }

    private func titleLine(showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Exact library names run long; shrink before truncating.
            Text(title)
                .font(isCompact ? .title3.bold() : .title.bold())
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: isCompact ? 12 : 15, weight: .bold))
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One row of chips under the title: Browse A–Z, then the kind's libraries
/// ("All" first), then the selected library's collections. The libraries
/// sit between the two actions so picking one never moves the others.
private struct MediaScopeChips: View {
    let options: [MediaScopeMenu.Option]
    let selection: MediaScopeSelection
    let onSelect: (MediaScopeSelection) -> Void
    let onBrowse: () -> Void
    let onCollections: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    MediaScopeChip(title: "A–Z", systemImage: "square.grid.2x2", action: onBrowse)
                        .accessibilityLabel("Browse A to Z")
                    if !options.isEmpty {
                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 2)
                        ForEach(options) { option in
                            MediaScopeChip(title: option.chipTitle, isSelected: option.selection == selection) {
                                onSelect(option.selection)
                            }
                            .accessibilityLabel(option.title)
                            .id(option.selection)
                        }
                    }
                    if let onCollections {
                        MediaScopeChip(title: "Collections", systemImage: "rectangle.stack", action: onCollections)
                    }
                }
                .padding(.horizontal, SiloTheme.padding)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, newValue in
                withAnimation(reduceMotion ? nil : .easeOut(duration: SiloTheme.normalDuration)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

/// The season chips' look: a filled white capsule when selected, an
/// outlined one otherwise, inside a 44-point touch target.
private struct MediaScopeChip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background {
                Group {
                    if isSelected {
                        Capsule().fill(Color.white)
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                }
                .padding(.vertical, 6)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Top bar

extension View {
    /// Pins `bar` above a scrolling page with the shared strip behind it,
    /// as Home and For You do. The system's hard scroll edge ended in a
    /// visible line and its soft edge alone let posters show through the
    /// title; a native `safeAreaBar` doesn't draw a background placed behind
    /// its content, so this is a plain inset.
    func mediaHubTopBar<Bar: View>(
        scrollState: PageChromeScrollState,
        @ViewBuilder _ bar: () -> Bar
    ) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            bar().background { PageChromeGlass(scrollState: scrollState) }
        }
        .siloScrollEdgeEffect()
    }
}

// MARK: - Browse grid

/// Full grid for one library or every library of a kind. The navigation
/// title is a menu of the kind's libraries, so the scope can change without
/// going back.
struct MediaBrowseView: View {
    let kind: MediaKind
    let initialLibraryId: Int?

    @State private var selectedLibraryId: Int?
    @State private var libraries: [Library] = []

    init(kind: MediaKind, initialLibraryId: Int?) {
        self.kind = kind
        self.initialLibraryId = initialLibraryId
        _selectedLibraryId = State(initialValue: initialLibraryId)
        let cached: LibrariesResponse? = ResponseCache.shared.get(CacheKey.userLibraries)
        _libraries = State(initialValue: cached?.libraries ?? [])
    }

    private var kindLibraries: [Library] { MediaHubScope.libraries(for: kind, in: libraries) }
    private var selectedLibrary: Library? {
        selectedLibraryId.flatMap { id in kindLibraries.first { $0.id == id } }
    }

    private var title: String {
        selectedLibrary?.name ?? kind.browseAllTitle
    }

    var body: some View {
        BrowseView(
            libraryId: selectedLibraryId,
            title: nil,
            showsSearchShortcut: false,
            libraryType: selectedLibrary?.type,
            // A mixed library shows the kind's half, with its own cache and
            // saved filters; "All" scopes the cross-library query. A
            // single-type library already scopes the grid.
            mediaScope: selectedLibrary?.isMixedLibrary == true ? kind.videoScope : nil,
            crossLibraryType: selectedLibraryId == nil ? kind.browseMediaType : nil
        )
        .id(selectedLibraryId)
        .navigationTitle(title)
        .siloNavigationTitleDisplayMode(.inline)
        .modifier(MediaBrowseTitleMenu(
            kind: kind,
            libraries: kindLibraries,
            selectedLibraryId: $selectedLibraryId
        ))
        .siloPageBackground()
        .task {
            if let response = try? await StartupContentPrefetcher.fetchUserLibraries() {
                libraries = response.libraries
                // The library was hidden, removed or retyped since the
                // cached list: browse every library of the kind instead.
                if let id = selectedLibraryId, !kindLibraries.contains(where: { $0.id == id }) {
                    selectedLibraryId = nil
                }
            }
        }
    }
}

/// The system navigation-title menu, shown only when there is a library to
/// switch to.
private struct MediaBrowseTitleMenu: ViewModifier {
    let kind: MediaKind
    let libraries: [Library]
    @Binding var selectedLibraryId: Int?

    func body(content: Content) -> some View {
        if libraries.count > 1 {
            content.toolbarTitleMenu {
                toggle(kind.browseAllTitle, libraryId: nil)
                Section {
                    ForEach(libraries) { library in
                        toggle(library.name, libraryId: library.id)
                    }
                }
            }
        } else {
            content
        }
    }

    private func toggle(_ title: String, libraryId: Int?) -> some View {
        Toggle(title, isOn: Binding(
            get: { selectedLibraryId == libraryId },
            set: { if $0 { selectedLibraryId = libraryId } }
        ))
    }
}

// MARK: - Landing model

@Observable
@MainActor
final class MediaLandingViewModel {
    private(set) var sections: [ResolvedSection] = []
    private(set) var isLoading = false
    private(set) var error: ErrorState?

    static let recentlyAddedID = "watch.recently_added"
    private static let libraryRowPrefix = "watch.library."
    private static let rowLimit = 20

    /// Last composed landing per scope lives in `ResponseCache` (cleared on
    /// profile and server changes), so switching scopes back and forth
    /// repaints instantly while the refresh runs.
    private static func cacheKey(_ key: String) -> String { "mediaHub:\(key)" }
    private var loadedKey: String?
    /// Advances with every load, so an older load of the same scope (one a
    /// refresh replaced) can't publish after the newer one.
    private var generation = 0

    static func libraryRowLibraryId(_ section: ResolvedSection) -> Int? {
        guard section.id.hasPrefix(libraryRowPrefix) else { return nil }
        return Int(section.id.dropFirst(libraryRowPrefix.count))
    }

    func load(kind: MediaKind, library: Library?, kindLibraries: [Library], force: Bool = false) async {
        let key = "\(kind.rawValue).\(library.map { String($0.id) } ?? "all").\(kindLibraries.map(\.id))"
        if loadedKey != key {
            sections = ResponseCache.shared.get(Self.cacheKey(key)) ?? []
            loadedKey = key
        } else if !force, !sections.isEmpty {
            return
        }
        generation += 1
        let run = generation
        // A cache invalidation while this runs keeps its rows out of the cache.
        let writeToken = ResponseCache.shared.writeToken
        isLoading = true
        error = nil

        do {
            let result: [ResolvedSection]
            if let library {
                result = try await Self.librarySections(
                    kind: kind,
                    library: library,
                    borrowsResume: kindLibraries.count == 1,
                    fresh: force
                )
            } else {
                result = try await Self.mergedSections(kind: kind, libraries: kindLibraries, fresh: force)
            }
            guard !Task.isCancelled, run == generation else { return }
            sections = result
            ResponseCache.shared.set(result, for: Self.cacheKey(key), fetchedAt: writeToken)
        } catch {
            guard !Task.isCancelled, run == generation else { return }
            if sections.isEmpty { self.error = ErrorState(error) }
        }
        isLoading = false
    }

    /// One library: its server-built rows. A mixed library keeps only the
    /// half that matches the selected kind. Home's resume rows can't tell
    /// libraries apart, so a library borrows them only when it is the kind's
    /// only library.
    private static func librarySections(
        kind: MediaKind,
        library: Library,
        borrowsResume: Bool,
        fresh: Bool
    ) async throws -> [ResolvedSection] {
        async let resume = borrowsResume ? resumeSections(kind: kind, fresh: fresh) : []
        let read: APIv2LibrarySectionsRead
        do {
            read = try await StartupContentPrefetcher.fetchLibrarySectionsRead(libraryId: library.id)
        } catch {
            // The server builds every library row in one response, so one
            // slow row fails the page. Fall back to rows from endpoints that
            // still answer rather than blanking the hub.
            let recent = try? await catalogRow(
                id: recentlyAddedID,
                title: "Recently Added",
                kind: kind,
                library: library
            )
            let fallback = await resume + [recent].compactMap { $0 }.filter { !$0.items.isEmpty }
            guard !fallback.isEmpty else { throw error }
            return fallback
        }
        var sections = read.sections.filter { !$0.isFeatured }
        if library.isMixedLibrary, let scope = kind.videoScope {
            // A shelf's inline items can all be the other half; page each
            // shelf's source for this one, as the library page does.
            let refilled = try? await scope.refillLibrarySections(sections, libraryId: library.id, auth: read.auth)
            sections = refilled?.map(\.section) ?? sections.compactMap { filtered($0, to: kind) }
        }
        sections.removeAll { $0.items.isEmpty }
        // Audiobook libraries have no server resume row; borrow Home's,
        // without repeating a Next Up row the library already has.
        if !sections.contains(where: \.isContinueWatchingSection) {
            let borrowed = await resume.filter { row in
                row.isContinueWatchingSection || !sections.contains { $0.sectionType == row.sectionType }
            }
            sections.insert(contentsOf: borrowed, at: 0)
        }
        return sections
    }

    /// Every library of a kind: resume rows from Home filtered to the kind,
    /// Recently Added across libraries, then one row per library.
    private static func mergedSections(
        kind: MediaKind,
        libraries: [Library],
        fresh: Bool
    ) async throws -> [ResolvedSection] {
        async let resume = resumeSections(kind: kind, fresh: fresh)
        async let recent = catalogRow(
            id: recentlyAddedID,
            title: "Recently Added",
            kind: kind,
            library: nil
        )
        let libraryRows = await withTaskGroup(of: (Int, Result<ResolvedSection, Error>).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    do {
                        let row = try await catalogRow(
                            id: "\(libraryRowPrefix)\(library.id)",
                            title: library.name,
                            kind: kind,
                            library: library
                        )
                        return (index, .success(row))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var rows: [(Int, Result<ResolvedSection, Error>)] = []
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let recentRow: Result<ResolvedSection, Error>
        do {
            recentRow = .success(try await recent)
        } catch {
            recentRow = .failure(error)
        }

        // One failed row drops out rather than failing the page. When every
        // row fails and there is nothing to resume, the page shows the error
        // and Retry rather than claiming the libraries are empty.
        var sections = await resume
        let loaded = ([recentRow] + libraryRows).compactMap { try? $0.get() }
        if loaded.isEmpty, sections.isEmpty, case .failure(let error) = recentRow {
            throw error
        }
        sections.append(contentsOf: loaded.filter { !$0.items.isEmpty })
        return sections
    }

    /// Home's cached rows, or a fresh fetch (falling back to the cache) on
    /// pull-to-refresh, since the cache has no expiry.
    private static func homeSections(fresh: Bool) async -> [ResolvedSection] {
        let cached: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        if !fresh, let cached { return cached.sections }
        let fetched = try? await StartupContentPrefetcher.fetchHomeSections()
        return (fetched ?? cached)?.sections ?? []
    }

    private static func resumeSections(kind: MediaKind, fresh: Bool) async -> [ResolvedSection] {
        await homeSections(fresh: fresh)
            .filter { section in
                section.isContinueWatchingSection
                    || (kind == .series && section.sectionType.lowercased().contains("next"))
            }
            .compactMap { section in
                filtered(section, to: kind, title: section.isContinueWatchingSection ? kind.resumeTitle : nil)
            }
    }

    private static func catalogRow(
        id: String,
        title: String,
        kind: MediaKind,
        library: Library?
    ) async throws -> ResolvedSection {
        var query = APIv2CatalogQuery()
        query.libraryId = library.map { String($0.id) }
        query.type = kind.catalogType(for: library)
        query.sort = CatalogSortKey.addedAt.field
        query.order = "desc"
        query.limit = rowLimit
        // Rows never show a count, and an exact total is the slow part of
        // the query.
        query.skipTotal = true
        let page = try await SiloAPI.shared.catalogPage(query)
        return ResolvedSection(
            id: id,
            sectionType: "recently_added",
            title: title,
            featured: false,
            itemLimit: rowLimit,
            totalCount: nil,
            isCustom: nil,
            customized: nil,
            items: page.response.items.map { SectionItem(browseItem: $0) }
        )
    }

    private static func filtered(
        _ section: ResolvedSection,
        to kind: MediaKind,
        title: String? = nil
    ) -> ResolvedSection? {
        let items = section.items.filter { kind.includes(itemType: $0.type) }
        guard !items.isEmpty else { return nil }
        return ResolvedSection(
            id: section.id,
            sectionType: section.sectionType,
            title: title ?? section.title,
            featured: section.featured,
            itemLimit: section.itemLimit,
            totalCount: section.totalCount,
            isCustom: section.isCustom,
            customized: section.customized,
            items: items
        )
    }
}
#endif
