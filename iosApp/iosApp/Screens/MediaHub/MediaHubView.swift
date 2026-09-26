#if !os(tvOS)
import SwiftUI

/// The iOS Watch, Listen and single-type tabs: one root for every library of
/// a hub.
///
/// The large title is a menu (`MediaScopeTitleMenu`) that scopes the page to
/// one kind or one library, and holds Browse and Collections. A single
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

    private var topChrome: some View {
        HStack(alignment: .mediaTitleRow, spacing: 12) {
            SidebarToggleButton()
            MediaScopeTitleMenu(
                header: header,
                menu: MediaHubScope.menu(for: hub, kind: kind, in: libraries),
                kind: kind,
                selection: MediaHubScope.currentSelection(
                    kind: kind,
                    libraryId: selectedLibraryId,
                    kindLibraries: kindLibraries
                ),
                onSelectKind: { select(.init(kind: $0, libraryId: memory.libraryId(for: $0))) },
                onSelect: select,
                onBrowse: {
                    router.navigate(to: .mediaBrowse(kind: kind, libraryId: selectedLibraryId))
                },
                onCollections: selectedLibrary.map { library in
                    {
                        router.navigate(to: .libraryCollections(
                            libraryId: library.id,
                            title: "\(library.name) Collections"
                        ))
                    }
                }
            )
            Spacer(minLength: 8)
            TabTopBarActions(
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onSwitchProfile: { router.switchProfile() },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() },
                groupsInGlass: true
            )
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.top, SiloTheme.smallPadding)
        .padding(.bottom, SiloTheme.padding)
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
                        HomeFeedRow(section: section)
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
                        libraryId: landing.libraryId(for: section) ?? selectedLibraryId
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
            return { router.navigate(to: .mediaBrowse(kind: kind, libraryId: nil)) }
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

/// The hub's large title doubles as its scope picker, the pattern Photos and
/// Files use. The panel is custom content in a native popover: the system
/// supplies the glass, animation and dismissal.
struct MediaScopeTitleMenu: View {
    let header: MediaScopeHeader
    let menu: MediaScopeMenu
    let kind: MediaKind
    let selection: MediaScopeSelection
    /// Switches the page to another kind and leaves the panel open, so a
    /// library can be picked next.
    let onSelectKind: (MediaKind) -> Void
    let onSelect: (MediaScopeSelection) -> Void
    var onBrowse: (() -> Void)? = nil
    var onCollections: (() -> Void)? = nil

    @State private var isPresented = false

    private var hasMenu: Bool {
        !menu.isEmpty || onBrowse != nil || onCollections != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if hasMenu {
                Button { isPresented = true } label: {
                    titleLine(showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel([header.title, header.subtitle].compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint("Choose what this page shows")
                .accessibilityAddTraits(.isHeader)
                .alignmentGuide(.mediaTitleRow) { $0[VerticalAlignment.center] }
            } else {
                titleLine(showsChevron: false)
                    .accessibilityAddTraits(.isHeader)
                    .alignmentGuide(.mediaTitleRow) { $0[VerticalAlignment.center] }
            }
            // Always laid out so the header height never changes.
            Text(header.subtitle ?? " ")
                .font(.footnote)
                .foregroundStyle(Color.siloSecondaryText)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        // Anchored to the title and subtitle together so the panel opens
        // below the subtitle instead of over it.
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            MediaScopePanel(
                menu: menu,
                kind: kind,
                selection: selection,
                onSelectKind: onSelectKind,
                onSelect: { choice in
                    isPresented = false
                    onSelect(choice)
                },
                onBrowse: onBrowse.map { action in { closeThen(action) } },
                onCollections: onCollections.map { action in { closeThen(action) } }
            )
            .presentationCompactAdaptation(.popover)
        }
        .animation(.easeInOut(duration: SiloTheme.normalDuration), value: header)
    }

    /// Pushing while the popover animates out can drop the push, so
    /// navigation waits for it to close.
    private func closeThen(_ action: @escaping () -> Void) {
        isPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            action()
        }
    }

    private func titleLine(showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Exact library names run long; shrink before truncating.
            Text(header.title)
                .font(.title.bold())
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.siloSecondaryText)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
                    .animation(.snappy(duration: 0.25), value: isPresented)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The popover's content, top to bottom: a segmented kind switch, the
/// current kind's libraries with a trailing checkmark, and Browse and
/// Collections as a footer. Each control makes one decision, so the list
/// never has to show a hierarchy.
private struct MediaScopePanel: View {
    let menu: MediaScopeMenu
    let kind: MediaKind
    let selection: MediaScopeSelection
    let onSelectKind: (MediaKind) -> Void
    let onSelect: (MediaScopeSelection) -> Void
    let onBrowse: (() -> Void)?
    let onCollections: (() -> Void)?

    @State private var contentHeight: CGFloat = 0

    private static let width: CGFloat = 296
    private static let maxHeight: CGFloat = 540
    static let inset: CGFloat = 10
    static let textInset: CGFloat = 16

    /// Natural size when it fits, so the popover wraps the content with its
    /// own insets; a scrolling list only past `maxHeight`.
    var body: some View {
        Group {
            if contentHeight > Self.maxHeight {
                ScrollView { measuredContent }
                    .scrollIndicators(.hidden)
                    .frame(height: Self.maxHeight)
            } else {
                measuredContent
            }
        }
        .frame(width: Self.width)
    }

    private var measuredContent: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }

    private var hasBody: Bool { !menu.isEmpty }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !menu.kinds.isEmpty {
                Picker("Show", selection: Binding(get: { kind }, set: onSelectKind)) {
                    ForEach(menu.kinds, id: \.self) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 6)
            }
            ForEach(menu.options) { option in
                MediaScopeRow(title: option.title, isSelected: option.selection == selection) {
                    onSelect(option.selection)
                }
            }
            if onBrowse != nil || onCollections != nil {
                if hasBody {
                    Divider()
                        .padding(.horizontal, Self.textInset)
                        .padding(.vertical, 6)
                }
                HStack(spacing: 8) {
                    if let onBrowse {
                        MediaScopeFooterButton(title: "Browse A–Z", systemImage: "square.grid.2x2", action: onBrowse)
                    }
                    if let onCollections {
                        MediaScopeFooterButton(title: "Collections", systemImage: "rectangle.stack", action: onCollections)
                    }
                }
                .padding(.horizontal, Self.inset)
            }
        }
        .padding(.vertical, Self.inset)
    }
}

private struct MediaScopeRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Exact library names, so wrap rather than truncate.
                Text(title)
                    .font(isSelected ? .body.weight(.semibold) : .body)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, MediaScopePanel.textInset)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(MediaScopeRowStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Selected rows keep a soft highlight; pressed rows brighten it.
private struct MediaScopeRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : (isSelected ? 0.1 : 0)))
                    .padding(.horizontal, 6)
            }
    }
}

private struct MediaScopeFooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                // Fixed glyph box: symbols differ in width, and the labels
                // must sit at the same offset in both buttons.
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.siloOnSurface)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(MediaScopeFooterButtonStyle())
    }
}

private struct MediaScopeFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
    }
}

// MARK: - Top bar

extension View {
    /// Pins `bar` above a scrolling page. iOS 26 uses a native safe-area bar,
    /// so content passes under the glass controls with the system's soft
    /// scroll-edge blur; iOS 18 keeps the fading glass strip.
    @ViewBuilder
    func mediaHubTopBar<Bar: View>(
        scrollState: PageChromeScrollState,
        @ViewBuilder _ bar: () -> Bar
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            // The hard edge keeps the large title and subtitle legible over
            // posters scrolling underneath; the soft edge let them show
            // through.
            self
                .safeAreaBar(edge: .top, spacing: 0) { bar() }
                .scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0) {
                bar().background { PageChromeGlass(scrollState: scrollState) }
            }
        }
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

    /// "All" and mixed libraries need the kind's media scope; a single-type
    /// library already scopes the grid.
    private var browseScope: BrowseMediaType? {
        guard let selectedLibrary, !selectedLibrary.isMixedLibrary else { return kind.browseMediaType }
        return nil
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
            scope: browseScope
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

    static func libraryRowLibraryId(_ section: ResolvedSection) -> Int? {
        guard section.id.hasPrefix(libraryRowPrefix) else { return nil }
        return Int(section.id.dropFirst(libraryRowPrefix.count))
    }

    func libraryId(for section: ResolvedSection) -> Int? {
        Self.libraryRowLibraryId(section)
    }

    func load(kind: MediaKind, library: Library?, kindLibraries: [Library], force: Bool = false) async {
        let key = "\(kind.rawValue).\(library.map { String($0.id) } ?? "all").\(kindLibraries.map(\.id))"
        if loadedKey != key {
            sections = ResponseCache.shared.get(Self.cacheKey(key)) ?? []
            loadedKey = key
        } else if !force, !sections.isEmpty {
            return
        }
        isLoading = true
        error = nil

        do {
            let result: [ResolvedSection]
            if let library {
                result = try await Self.librarySections(kind: kind, library: library, fresh: force)
            } else {
                result = try await Self.mergedSections(kind: kind, libraries: kindLibraries, fresh: force)
            }
            guard !Task.isCancelled, loadedKey == key else { return }
            sections = result
            ResponseCache.shared.set(result, for: Self.cacheKey(key))
        } catch {
            guard !Task.isCancelled, loadedKey == key else { return }
            if sections.isEmpty { self.error = ErrorState(error) }
        }
        isLoading = false
    }

    /// One library: its server-built rows. A mixed library keeps only the
    /// half that matches the selected kind.
    private static func librarySections(
        kind: MediaKind,
        library: Library,
        fresh: Bool
    ) async throws -> [ResolvedSection] {
        async let resume = resumeSections(kind: kind, fresh: fresh)
        let response: SectionsResponse
        do {
            response = try await StartupContentPrefetcher.fetchLibrarySections(libraryId: library.id)
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
        var sections = response.sections.filter { !$0.isFeatured && !$0.items.isEmpty }
        if library.isMixedLibrary {
            sections = sections.compactMap { filtered($0, to: kind) }
        }
        // Audiobook libraries have no server resume row; borrow Home's.
        if !sections.contains(where: \.isContinueWatchingSection) {
            sections.insert(contentsOf: await resume, at: 0)
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
        let libraryRows = await withTaskGroup(of: (Int, ResolvedSection?).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    let row = try? await catalogRow(
                        id: "\(libraryRowPrefix)\(library.id)",
                        title: library.name,
                        kind: kind,
                        library: library
                    )
                    return (index, row)
                }
            }
            var rows: [(Int, ResolvedSection?)] = []
            for await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }

        // One failed row drops out rather than failing the page.
        let recentRow = try? await recent
        var sections = await resume
        if let recentRow, !recentRow.items.isEmpty { sections.append(recentRow) }
        sections.append(contentsOf: libraryRows.filter { !$0.items.isEmpty })
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
                let type = section.sectionType.lowercased()
                if section.isContinueWatchingSection { return true }
                return kind == .series && type.contains("next")
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
