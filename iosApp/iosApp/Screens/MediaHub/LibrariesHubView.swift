#if !os(tvOS)
import SwiftUI

/// The iOS Libraries tab: a switcher for every library the profile can open,
/// not a content feed.
///
/// Libraries are grouped by capability (`LibrariesPage.sections`), each as
/// its own card. Pinned libraries lead their section in pin order; the rest
/// keep the server's order. Opening a library makes it the capability's
/// remembered selection (`MediaHubMemory`) and switches to the tab that hosts
/// it, which opens on that library. The page marks the last library used in
/// each capability. Hiding a library (`HiddenLibraryPreference`) takes it off
/// the page and the tab bar; a row at the end opens the switches that bring
/// it back (`LibraryVisibilitySettingsView`).
struct LibrariesHubView: View {
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @State private var libraries: [Library] = []
    @State private var hiddenLibraries: [Library] = []
    @State private var pinnedIds: [Int] = []
    @State private var lastUsed: [MediaCapability: Int] = [:]
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var hideError: String?
    @State private var navPrefs = AppNavPreferences.shared
    @State private var chromeScrollState = PageChromeScrollState()

    @Environment(AppRouter.self) private var router

    private var memory: MediaHubMemory {
        MediaHubMemory(authority: libraryAuthority)
    }

    private var sections: [LibrariesPageSection] {
        LibrariesPage.sections(libraries: listed(libraries), pinnedIds: pinnedIds)
    }

    private var hiddenCount: Int {
        listed(hiddenLibraries).count
    }

    /// Audiobook libraries appear only while Show Audiobooks is on.
    private func listed(_ libraries: [Library]) -> [Library] {
        navPrefs.showAudiobooks ? libraries : libraries.filter { !$0.isAudiobookLibrary }
    }

    var body: some View {
        Group {
            if !sections.isEmpty {
                grid
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadLibraries() } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No libraries available",
                    subtitle: "Libraries visible to this profile will appear here."
                )
            }
        }
        .environment(chromeScrollState)
        .mediaHubTopBar(scrollState: chromeScrollState) { topChrome }
        .siloPageBackground()
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: libraryAuthority) {
            // Another profile's libraries and pins must not stand in for
            // this one's.
            libraries = []
            readMemory()
            await loadLibraries()
        }
        .onAppear(perform: readMemory)
        .onChange(of: sections.isEmpty) { _, isEmpty in
            // The grid was the page's only scroll view; its replacement
            // can't scroll, so the header must not stay folded.
            if isEmpty { chromeScrollState.reset() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) { notification in
            guard let response = notification.object as? LibrariesResponse else { return }
            accept(response, isFresh: true)
        }
        .alert(
            "Couldn’t Hide Library",
            isPresented: Binding(get: { hideError != nil }, set: { if !$0 { hideError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hideError ?? "")
        }
    }

    // MARK: - Layout

    private var topChrome: some View {
        HStack(spacing: 12) {
            SidebarToggleButton()
            Text("Libraries")
                .font(chromeScrollState.isCompact ? .title3.bold() : .title.bold())
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
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
        .padding(.top, SiloTheme.smallPadding)
        .padding(.bottom, chromeScrollState.isCompact ? SiloTheme.smallPadding : SiloTheme.padding)
        .animatesPageChromeFold(chromeScrollState)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: SiloTheme.largePadding) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: SiloTheme.spacing) {
                        Text(section.capability.title)
                            .font(.title3.bold())
                            .foregroundStyle(Color.siloOnSurface)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: SiloTheme.spacing)],
                            alignment: .leading,
                            spacing: SiloTheme.padding
                        ) {
                            ForEach(section.libraries) { library in
                                LibrarySwitcherCard(
                                    library: library,
                                    isPinned: pinnedIds.contains(library.id),
                                    isLastUsed: lastUsed[section.capability] == library.id,
                                    onOpen: { open(library) },
                                    onTogglePin: { togglePin(library) },
                                    onHide: { Task { await hide(library) } }
                                )
                            }
                        }
                    }
                }
                if hiddenCount > 0 {
                    hiddenLibrariesRow
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
        .reportsPageChromeScroll()
        .refreshable { await loadLibraries() }
    }

    /// Opens the switches for every library, hidden ones included.
    private var hiddenLibrariesRow: some View {
        Button {
            router.navigate(to: .libraryVisibility)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                Text(hiddenLibrariesLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text("Show")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.siloSecondaryText)
                }
                .foregroundStyle(Color.siloOnSurface)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.siloSecondaryText)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hiddenLibrariesLabel)
        .accessibilityHint("Shows every library with a switch to show or hide it")
    }

    private var hiddenLibrariesLabel: String {
        hiddenCount == 1 ? "1 hidden library" : "\(hiddenCount) hidden libraries"
    }

    // MARK: - Actions

    private func open(_ library: Library) {
        memory.remember(library)
        readMemory()
        StartupContentPrefetcher.prefetchLibraryLanding(libraryId: library.id)
        router.requestedHubLibraryId = library.id
    }

    private func togglePin(_ library: Library) {
        var ids = pinnedIds
        if let index = ids.firstIndex(of: library.id) {
            ids.remove(at: index)
        } else {
            ids.append(library.id)
        }
        memory.setPinnedLibraryIds(ids)
        withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
            pinnedIds = ids
        }
    }

    /// Takes the library off the page at once, then saves. The library list
    /// refresh that follows updates the tab bar; a failed save puts the card
    /// back. Saves run in order (`HiddenLibraryPreference.setHidden`), so
    /// hiding a second library before the first lands keeps both hidden.
    private func hide(_ library: Library) async {
        let authority = libraryAuthority
        let index = libraries.firstIndex { $0.id == library.id }
        withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
            libraries.removeAll { $0.id == library.id }
            hiddenLibraries.append(library)
        }
        do {
            let hiddenIds = try await HiddenLibraryPreference.setHidden(true, libraryId: library.id)
            await HiddenLibraryPreference.publishChange(hiddenIds: hiddenIds)
        } catch {
            // A profile switch cancelled the save, or another profile's
            // libraries have replaced this one's.
            guard libraryAuthority == authority, !(error is CancellationError) else { return }
            withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                hiddenLibraries.removeAll { $0.id == library.id }
                if !libraries.contains(where: { $0.id == library.id }) {
                    libraries.insert(library, at: min(index ?? .max, libraries.count))
                }
            }
            hideError = LibraryVisibilitySettingsView.saveFailureMessage(
                for: error,
                library: library,
                isVisible: false
            )
        }
    }

    private func readMemory() {
        pinnedIds = memory.pinnedLibraryIds()
        var marks: [MediaCapability: Int] = [:]
        for capability in MediaCapability.allCases {
            marks[capability] = memory.lastUsedLibraryId(for: capability)
        }
        lastUsed = marks
    }

    // MARK: - Libraries

    private func loadLibraries() async {
        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            accept(cached, isFresh: false)
        }
        isLoading = libraries.isEmpty
        error = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled else { return }
            accept(response, isFresh: true)
        } catch {
            if libraries.isEmpty { self.error = ErrorState(error) }
        }
        isLoading = false
    }

    /// Only a fresh list prunes pins: a cached list may predate a library
    /// the profile gained since.
    private func accept(_ response: LibrariesResponse, isFresh: Bool) {
        let newLibraries = response.libraries
        libraries = newLibraries
        hiddenLibraries = response.hiddenLibraries ?? []
        onLibrariesLoaded?(libraryAuthority, newLibraries)
        guard isFresh else { return }
        let pruned = LibrariesPage.prunedPins(pinnedIds, libraries: newLibraries)
        if pruned != pinnedIds {
            memory.setPinnedLibraryIds(pruned)
            pinnedIds = pruned
        }
    }
}

/// A library's artwork with its exact name below. Pinned and last-used
/// states show as badges on the artwork.
private struct LibrarySwitcherCard: View {
    let library: Library
    let isPinned: Bool
    let isLastUsed: Bool
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    let onHide: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        if isLastUsed {
                            Text("Last used")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.65), in: Capsule())
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.65), in: Circle())
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(library.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(library.switcherTypeLabel)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app", action: onOpen)
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin", action: onTogglePin)
            Divider()
            // The second Text is the menu item's subtitle.
            Button(action: onHide) {
                Label("Hide", systemImage: "eye.slash")
                Text("On all devices for this profile")
            }
        }
        .accessibilityAction(named: isPinned ? "Unpin" : "Pin", onTogglePin)
        .accessibilityAction(named: "Hide", onHide)
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { proxy in
            if let posterUrl = library.posterUrl, !posterUrl.isEmpty {
                AsyncImageView(url: posterUrl, targetSize: proxy.size, contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.siloSurfaceVariant
                    Image(systemName: library.switcherIcon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [library.name, library.switcherTypeLabel]
        if isPinned { parts.append("Pinned") }
        if isLastUsed { parts.append("Last used") }
        return parts.joined(separator: ", ")
    }
}

extension Library {
    var switcherTypeLabel: String {
        if isAudiobookLibrary { return "Audiobooks" }
        if isMixedLibrary { return "Movies & Series" }
        if isSeriesLibrary { return "Series" }
        return "Movies"
    }

    var switcherIcon: String {
        if isAudiobookLibrary { return "book.closed.fill" }
        if isMixedLibrary { return "square.stack.3d.up.fill" }
        if isSeriesLibrary { return "tv.fill" }
        return "film.fill"
    }
}
#endif
