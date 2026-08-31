#if !os(tvOS)
import SwiftUI

struct PrimaryMenuEditorRow: Identifiable, Equatable {
    let item: PrimaryMenuItem
    let parentMediaType: PrimaryMenuBuiltin?

    var id: String { item.id }
    var isNestedLibrary: Bool { parentMediaType != nil }
}

func primaryMenuShortcutTypeTitle(
    _ item: PrimaryMenuItem,
    libraries: [Library] = [],
    isNestedLibrary: Bool = false
) -> String {
    switch item {
    case .builtin(.movies), .builtin(.series), .builtin(.music), .builtin(.audiobooks):
        return "Media Type"
    case .library(let libraryId, _):
        guard !isNestedLibrary,
              let library = libraries.first(where: { $0.id == libraryId })
        else { return "Library" }
        if library.isMixedLibrary { return "Mixed Library" }
        if library.isMovieLibrary { return "Movies Library" }
        if library.isSeriesLibrary { return "Series Library" }
        if library.isAudiobookLibrary { return "Audiobooks Library" }
        return "Library"
    case .section, .collection:
        return "Library"
    case .builtin(.forYou), .builtin(.calendar):
        return "Discover"
    case .builtin(.home):
        return "Your Stuff"
    }
}

func groupedPrimaryMenuEditorRows(
    _ items: [PrimaryMenuItem],
    libraries: [Library]
) -> [PrimaryMenuEditorRow] {
    groupPinnedLibrariesUnderMediaTypes(
        items,
        libraries: libraries,
        libraryID: { item in
            guard case .library(let libraryId, _) = item else { return nil }
            return libraryId
        },
        mediaTypeCategory: { item in
            guard case .builtin(let builtin) = item,
                  builtin == .movies
                    || builtin == .series
                    || builtin == .music
                    || builtin == .audiobooks
            else { return nil }
            return builtin
        }
    ).map { .init(item: $0.element, parentMediaType: $0.parentCategory) }
}

func availablePrimaryMenuShortcuts(
    candidates: [PrimaryMenuItem],
    libraries: [Library],
    visibleIds: Set<String>
) -> [PrimaryMenuItem] {
    let libraryItems = libraries.map {
        PrimaryMenuItem.library(libraryId: $0.id, label: $0.name)
    }
    return (candidates + libraryItems).filter { !visibleIds.contains($0.id) }
}

func offsetPrimaryMenuEditorItem(
    _ rows: [PrimaryMenuEditorRow],
    itemId: String,
    by offset: Int
) -> [PrimaryMenuItem]? {
    guard offset != 0,
          let sourceIndex = rows.firstIndex(where: { $0.id == itemId })
    else { return nil }
    let sourceRow = rows[sourceIndex]
    guard !sourceRow.item.isHome else { return nil }

    if let parent = sourceRow.parentMediaType {
        let siblingIndices = rows.indices.filter {
            rows[$0].parentMediaType == parent
        }
        guard let siblingSourceIndex = siblingIndices.firstIndex(of: sourceIndex) else {
            return nil
        }
        let siblingTargetIndex = siblingSourceIndex + offset
        guard siblingIndices.indices.contains(siblingTargetIndex) else { return nil }

        var reorderedRows = rows
        reorderedRows.swapAt(
            siblingIndices[siblingSourceIndex],
            siblingIndices[siblingTargetIndex]
        )
        return reorderedRows.map(\.item)
    }

    let movableRoots = rows.filter {
        $0.parentMediaType == nil && !$0.item.isHome
    }
    guard let rootSourceIndex = movableRoots.firstIndex(where: { $0.id == itemId }) else {
        return nil
    }
    let rootTargetIndex = rootSourceIndex + offset
    guard movableRoots.indices.contains(rootTargetIndex) else { return nil }

    var rootIds = rows.compactMap { row in
        row.parentMediaType == nil ? row.id : nil
    }
    guard let sourceRootIndex = rootIds.firstIndex(of: itemId),
          let targetRootIndex = rootIds.firstIndex(of: movableRoots[rootTargetIndex].id)
    else { return nil }
    rootIds.swapAt(sourceRootIndex, targetRootIndex)

    var blockByRootId: [String: [PrimaryMenuItem]] = [:]
    var currentRootId: String?
    for row in rows {
        if row.parentMediaType == nil {
            currentRootId = row.id
            blockByRootId[row.id] = [row.item]
        } else if let currentRootId {
            blockByRootId[currentRootId, default: []].append(row.item)
        }
    }
    return rootIds.flatMap { blockByRootId[$0] ?? [] }
}

/// Family-synced navigation and card presets for iPhone, iPad, and Mac.
/// Downloads, Search, and Profile are automatic shell utilities and stay
/// outside the reorderable list, matching the cross-client contract.
struct InterfaceCustomizationView: View {
    @State private var preferences = UICustomizationPreferences.shared
    @State private var registry = ServerRegistry.shared
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if let message = preferences.capabilityMessage {
                Section {
                    Label(message, systemImage: "server.rack")
                        .foregroundStyle(Color.continuumSecondaryText)
                }
            }

            if preferences.hasDeviceOverrides {
                Section {
                    Label(
                        "This device has older device-specific interface settings that override family sync.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    Button("Use Synced \(familySettingsName) Settings") {
                        preferences.useFamilySettings()
                    }
                    .disabled(preferences.isSaving || !preferences.allowsEditing)
                } footer: {
                    Text("Clearing the device override makes the controls below apply to all like-family devices on this profile.")
                }
            }

            Section {
                Picker("Preset", selection: presetSelection) {
                    ForEach(CardPresentationPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                    if preferences.cardPresentation.preset == nil {
                        Text("Custom").tag(Self.customPresetId)
                    }
                }

                Picker("Poster Size", selection: posterSize) {
                    ForEach(CardPosterSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }

                Picker("Captions", selection: captionStyle) {
                    ForEach(CardCaptionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                if preferences.cardPresentationUsesFamilyOverride {
                    Button("Use Profile Default") {
                        preferences.resetCardPresentationToInherited()
                    }
                    .disabled(preferences.isSaving)
                }
            } header: {
                Text("Cards & Posters")
            } footer: {
                Text("Start with Balanced, Compact, Cinema, or Artwork Only, then fine-tune size and captions. These choices sync with other \(familyLabel) devices on this profile.")
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.cardPresentationUsesDeviceOverride
            )

            Section {
                NavigationLink {
                    HomeSectionsCustomizationView()
                } label: {
                    Label("Home Sections", systemImage: "rectangle.3.group")
                }
            } header: {
                Text("Home")
            } footer: {
                Text("Choose which Home rows are visible and the order they appear in.")
            }

            Section {
                ForEach(visibleRows) { row in
                    let item = row.item
                    HStack(spacing: 12) {
                        if row.isNestedLibrary {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.continuumSecondaryText)
                                    .frame(width: 18)
                                shortcutLabel(for: item, isNestedLibrary: true)
                            }
                            .padding(.leading, 20)
                        } else {
                            shortcutLabel(for: item)
                        }
                        Spacer(minLength: 8)
                        if !item.isHome {
                            HStack(spacing: 4) {
                                Button {
                                    move(item, by: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canMove(item, by: -1))
                                .accessibilityLabel("Move \(displayTitle(for: item)) up")

                                Button {
                                    move(item, by: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canMove(item, by: 1))
                                .accessibilityLabel("Move \(displayTitle(for: item)) down")

                                Button {
                                    remove(item)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "\(removalVerb(for: item)) \(displayTitle(for: item))"
                                )
                            }
                            // The controls never compress; the flexible title
                            // column absorbs narrow widths by truncating.
                            .fixedSize()
                        }
                    }
                }
            } header: {
                Text("Primary Menu")
            } footer: {
                if isDefaultMenuApplied {
                    Text("Default menu applied. Add shortcuts to customize.")
                } else {
                    Text("Home is required. Use the arrows to reorder items. Libraries stay grouped under their media type and can only move within that group. Removing a library unpins it from your profile. Downloads (when available), Search, and Profile stay automatic.")
                }
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.primaryMenuUsesDeviceOverride
            )

            if !availableShortcuts.isEmpty {
                Section("Available Shortcuts") {
                    ForEach(availableShortcuts) { item in
                        Button {
                            addAvailableShortcut(item)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                shortcutLabel(for: item)
                            }
                        }
                        .accessibilityLabel(
                            "Pin \(displayTitle(for: item)), "
                                + primaryMenuShortcutTypeTitle(item, libraries: libraries)
                        )
                        .disabled(!canEditAvailableShortcut(item))
                    }
                }
            }

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage {
                Section {
                    Label(message, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.continuumSecondaryText)
                }
            }
        }
        .continuumGroupedListStyle()
        .navigationTitle("Interface")
        .task {
            await preferences.refresh()
        }
        .task(id: currentLibraryAuthority) {
            await refreshLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let authority = currentLibraryAuthority
            Task {
                async let preferencesRefresh: Void = preferences.refresh()
                async let librariesRefresh: Void = refreshLibraries(for: authority)
                _ = await (preferencesRefresh, librariesRefresh)
            }
        }
    }

    private var posterSize: Binding<CardPosterSize> {
        Binding(
            get: { preferences.cardPresentation.posterSize },
            set: { preferences.setPosterSize($0) }
        )
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { preferences.cardPresentation.preset?.rawValue ?? Self.customPresetId },
            set: { rawValue in
                guard let preset = CardPresentationPreset(rawValue: rawValue) else { return }
                preferences.setCardPresentation(preset.presentation)
            }
        )
    }

    private var captionStyle: Binding<CardCaptionStyle> {
        Binding(
            get: { preferences.cardPresentation.caption },
            set: { preferences.setCaptionStyle($0) }
        )
    }

    private static let candidates: [PrimaryMenuItem] = [
        .builtin(.home),
        .builtin(.movies),
        .builtin(.series),
        .builtin(.music),
        .builtin(.audiobooks),
        .builtin(.forYou),
        .builtin(.calendar),
    ]
    private static let customPresetId = "custom"

    private var currentLibraryAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
    }

    private var libraries: [Library] {
        librarySnapshot.availableLibraries(for: currentLibraryAuthority)
    }

    private func refreshLibraries(for authority: MainTabLibraryAuthority?) async {
        let retained = librarySnapshot.authority == authority ? librarySnapshot.libraries : []
        librarySnapshot = .init(authority: authority, libraries: retained)
        guard let authority else { return }
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentLibraryAuthority == authority else { return }
            librarySnapshot = .init(authority: authority, libraries: response.libraries)
        } catch {
            // Keep the same-authority cache; a different authority already
            // failed closed above.
        }
    }

    private var visibleDestinations: [PrimaryMenuItem] {
        preferences.resolvedPrimaryMenuItems().filter {
            mainTabSupportsDestination($0, availableLibraries: libraries)
        }
    }

    private var visibleRows: [PrimaryMenuEditorRow] {
        groupedPrimaryMenuEditorRows(visibleDestinations, libraries: libraries)
    }

    private var isDefaultMenuApplied: Bool {
        visibleDestinations.count == 1 && visibleDestinations[0].isHome
    }

    private var availableShortcuts: [PrimaryMenuItem] {
        let visible = Set(visibleDestinations.map(\.id))
        let candidates = Self.candidates.filter {
            mainTabSupportsDestination($0, availableLibraries: libraries)
        }
        return availablePrimaryMenuShortcuts(
            candidates: candidates,
            libraries: libraries.sorted(by: librarySort),
            visibleIds: visible
        )
    }

    private func displayTitle(for item: PrimaryMenuItem) -> String {
        if case .library(let libraryId, _) = item,
           let currentName = libraries.first(where: { $0.id == libraryId })?.name {
            return currentName
        }
        return item.title
    }

    private func shortcutLabel(
        for item: PrimaryMenuItem,
        isNestedLibrary: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: navigationIcon(for: item))
                .frame(width: 22)
            // The type caption sits under the title rather than beside it so
            // narrow screens never squeeze either into per-character wraps;
            // the title truncates instead of wrapping.
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(for: item))
                    .lineLimit(1)
                Text(
                    primaryMenuShortcutTypeTitle(
                        item,
                        libraries: libraries,
                        isNestedLibrary: isNestedLibrary
                    ).uppercased()
                )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.continuumSecondaryText.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }

    private func navigationIcon(for item: PrimaryMenuItem) -> String {
        guard case .library(let libraryId, _) = item else {
            return item.navigationIcon
        }
        return libraries.first(where: { $0.id == libraryId })?.navigationIcon
            ?? item.navigationIcon
    }

    private func move(_ item: PrimaryMenuItem, by offset: Int) {
        guard let items = offsetPrimaryMenuEditorItem(
            visibleRows,
            itemId: item.id,
            by: offset
        ) else { return }
        persistVisibleDestinations(items)
    }

    private func canMove(_ item: PrimaryMenuItem, by offset: Int) -> Bool {
        offsetPrimaryMenuEditorItem(
            visibleRows,
            itemId: item.id,
            by: offset
        ) != nil
    }

    private func remove(_ item: PrimaryMenuItem) {
        guard !item.isHome else { return }
        if case .library(let libraryId, _) = item,
           let library = libraries.first(where: { $0.id == libraryId }) {
            if preferences.isLibraryPinned(libraryId) {
                preferences.setLibraryPinned(library, isPinned: false)
            } else {
                // Older or independently-authored menus can contain a library
                // placement without a matching profile shortcut. There is
                // nothing to unpin in that case, so remove the placement
                // directly instead of letting setLibraryPinned no-op.
                persistVisibleDestinations(
                    visibleDestinations.filter { $0.id != item.id }
                )
            }
            return
        }
        persistVisibleDestinations(visibleDestinations.filter { $0.id != item.id })
    }

    private func removalVerb(for item: PrimaryMenuItem) -> String {
        if case .library = item { return "Unpin" }
        return "Hide"
    }

    private func addAvailableShortcut(_ item: PrimaryMenuItem) {
        if case .library(let libraryId, _) = item,
           let library = libraries.first(where: { $0.id == libraryId }) {
            if preferences.isLibraryPinned(libraryId) {
                persistVisibleDestinations(visibleDestinations + [item])
            } else {
                preferences.setLibraryPinned(library, isPinned: true)
            }
            return
        }
        persistVisibleDestinations(visibleDestinations + [item])
    }

    private func canEditAvailableShortcut(_: PrimaryMenuItem) -> Bool {
        guard preferences.allowsEditing else { return false }
        return !preferences.primaryMenuUsesDeviceOverride
    }

    private func persistVisibleDestinations(_ destinations: [PrimaryMenuItem]) {
        let currentlyVisibleIds = Set(visibleDestinations.map(\.id))
        var replacements = destinations.makeIterator()
        var result: [PrimaryMenuItem] = []

        for item in preferences.resolvedPrimaryMenuItems() {
            if currentlyVisibleIds.contains(item.id) {
                if let replacement = replacements.next() {
                    result.append(replacement)
                }
            } else {
                result.append(item)
            }
        }
        while let remaining = replacements.next() {
            result.append(remaining)
        }
        preferences.setPrimaryMenuItems(result)
    }

    private func librarySort(_ lhs: Library, _ rhs: Library) -> Bool {
        (lhs.sortOrder ?? Int.max, lhs.id) < (rhs.sortOrder ?? Int.max, rhs.id)
    }

    private var familyLabel: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return "iPhone-like"
        case "tablet": return "tablet-like"
        case "desktop": return "desktop-like"
        default: return "similar"
        }
    }

    private var familySettingsName: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "mobile": return "Mobile"
        case "tablet": return "Tablet"
        case "desktop": return "Desktop"
        default: return "Family"
        }
    }
}

/// Local profile-aware editor for the rows returned by `/home/sections`.
/// Visibility is an explicit eye control; native List editing supplies familiar
/// drag handles for ordering. Every change persists immediately, so returning
/// to Home reflects it without a separate network save or page reload.
private struct HomeSectionsCustomizationView: View {
    @State private var preferences = HomeSectionPreferences.shared
    @State private var sections: [ResolvedSection] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        List {
            Section {
                if arrangedSections.isEmpty, isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if arrangedSections.isEmpty {
                    ContentUnavailableView(
                        "No Home Sections",
                        systemImage: loadFailed ? "wifi.exclamationmark" : "rectangle.3.group",
                        description: Text(
                            loadFailed
                                ? "Silo couldn’t refresh the Home rows. Try again when the server is reachable."
                                : "Home has no populated rows to arrange yet."
                        )
                    )
                } else {
                    ForEach(arrangedSections) { section in
                        sectionRow(section)
                    }
                    .onMove(perform: moveSections)
                }
            } footer: {
                if !arrangedSections.isEmpty {
                    Text("Open eye: shown on Home. Closed eye: hidden and dimmed here. Tap Edit to drag rows into a new order. Changes save automatically for this profile on this device.")
                }
            }
        }
        .continuumGroupedListStyle()
        .navigationTitle("Home Sections")
        #if os(iOS)
        .toolbar {
            EditButton()
        }
        #endif
        .task {
            await loadSections()
        }
        .refreshable {
            await loadSections(forceRefresh: true)
        }
    }

    private var arrangedSections: [ResolvedSection] {
        preferences.arrangedSections(sections, includingHidden: true)
    }

    private func sectionRow(_ section: ResolvedSection) -> some View {
        let isVisible = preferences.isVisible(section.id)
        return HStack(spacing: 12) {
            Button {
                preferences.setVisible(!isVisible, sectionId: section.id)
            } label: {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isVisible ? Color.continuumOnSurface : Color.continuumSecondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isVisible ? "Hide \(section.title)" : "Show \(section.title)"
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.continuumOnSurface)
                    .lineLimit(1)

                Text("\(section.items.count) item\(section.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.continuumSecondaryText)
            }

            Spacer(minLength: 8)
        }
        .opacity(isVisible ? 1 : 0.42)
        .animation(.easeInOut(duration: ContinuumTheme.fastDuration), value: isVisible)
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        var ids = arrangedSections.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        preferences.setOrder(ids)
    }

    private func loadSections(forceRefresh: Bool = false) async {
        preferences.refresh()

        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            sections = cached.sections.filter { !$0.items.isEmpty }
        }

        _ = forceRefresh
        // Cached rows paint immediately; this awaited refresh remains owned by
        // the view task so it is cancelled cleanly when the editor disappears.
        await refreshFromServer()
    }

    private func refreshFromServer() async {
        isLoading = sections.isEmpty
        loadFailed = false
        defer { isLoading = false }

        do {
            let response = try await StartupContentPrefetcher.fetchHomeSections()
            guard !Task.isCancelled else { return }
            sections = response.sections.filter { !$0.items.isEmpty }
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = sections.isEmpty
        }
    }
}
#endif
