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
    @State private var titleArt = TitleArtPreferences.shared
    @State private var themeMusic = ThemeMusicPreferences.shared
    @State private var registry = ServerRegistry.shared
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Resolved once per render: every row asks whether it can move, and
        // each answer would otherwise re-resolve the whole menu.
        let rows = visibleRows
        let shortcuts = availableShortcuts
        List {
            if titleArt.isOffered {
                TitleArtSettingsSection(preferences: titleArt)
            }

            if themeMusic.isOffered {
                ThemeMusicSettingsSection(preferences: themeMusic)
            }

            if let message = preferences.capabilityMessage {
                Section {
                    Label(message, systemImage: "server.rack")
                        .foregroundStyle(Color.siloSecondaryText)
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
                Picker("Poster Size", selection: posterSize) {
                    ForEach(CardPosterSize.allCases) { size in
                        Text(size.title).tag(size)
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
                Text("Poster size syncs with other \(familyLabel) devices on this profile.")
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.cardPresentationUsesDeviceOverride
            )

            Section {
                ForEach(rows) { row in
                    let item = row.item
                    HStack(spacing: 12) {
                        if row.isNestedLibrary {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.siloSecondaryText)
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
                                .disabled(!canMove(item, by: -1, in: rows))
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
                                .disabled(!canMove(item, by: 1, in: rows))
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
                    #if os(macOS)
                    Text("Home is required. Use the arrows to reorder items. This menu is shared with your other devices. On this Mac the sidebar always lists every library, so pinning or removing a library here changes only those devices; the order of For You and Calendar applies here too.")
                    #else
                    Text("Home is required. Use the arrows to reorder items. Libraries stay grouped under their media type and can only move within that group. Removing a library unpins it from your profile. Downloads (when available), Search, and Profile stay automatic.")
                    #endif
                }
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.primaryMenuUsesDeviceOverride
            )

            if !shortcuts.isEmpty {
                Section("Available Shortcuts") {
                    ForEach(shortcuts) { item in
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
                        .disabled(!canEditShortcuts)
                    }
                }
            }

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage,
               message != HeldSettingChange.message {
                Section {
                    Label(message, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
            if preferences.hasHeldChanges {
                HeldSettingChangesSection(
                    retry: { preferences.retryHeldChanges() },
                    discard: { await preferences.discardHeldChanges() }
                )
            }
        }
        #if os(macOS)
        .settingsListChrome()
        #else
        .siloGroupedListStyle()
        #endif
        .navigationTitle("Interface")
        .task {
            async let preferencesRefresh: Void = preferences.refresh()
            async let titleArtRefresh: Void = titleArt.refresh()
            async let themeMusicRefresh: Void = themeMusic.refresh()
            _ = await (preferencesRefresh, titleArtRefresh, themeMusicRefresh)
        }
        .task(id: currentLibraryAuthority) {
            await refreshLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let authority = currentLibraryAuthority
            Task {
                async let preferencesRefresh: Void = preferences.refresh()
                async let titleArtRefresh: Void = titleArt.refresh()
                async let themeMusicRefresh: Void = themeMusic.refresh()
                async let librariesRefresh: Void = refreshLibraries(for: authority)
                _ = await (preferencesRefresh, titleArtRefresh, themeMusicRefresh, librariesRefresh)
            }
        }
    }

    private var posterSize: Binding<CardPosterSize> {
        Binding(
            get: { preferences.cardPresentation.posterSize },
            set: { preferences.setPosterSize($0) }
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
        let destinations = visibleDestinations
        return destinations.count == 1 && destinations[0].isHome
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
                    .foregroundStyle(Color.siloSecondaryText.opacity(0.75))
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

    private func canMove(
        _ item: PrimaryMenuItem,
        by offset: Int,
        in rows: [PrimaryMenuEditorRow]
    ) -> Bool {
        offsetPrimaryMenuEditorItem(rows, itemId: item.id, by: offset) != nil
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

    private var canEditShortcuts: Bool {
        preferences.allowsEditing && !preferences.primaryMenuUsesDeviceOverride
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

/// "Title Pages": whether detail pages name a title with its logo art, and
/// whether that choice is this device's own or the profile's for every device.
/// See `TitleArtPreferences` for the scopes each switch writes.
private struct TitleArtSettingsSection: View {
    let preferences: TitleArtPreferences

    var body: some View {
        Section {
            TitlePagesToggleRow(
                title: "Show Title Art",
                subtitle: "Use logo artwork as the title when available.",
                systemImage: "photo.artframe",
                isOn: Binding(
                    get: { preferences.showsTitleArt },
                    set: { preferences.setShowTitleArt($0) }
                )
            )
            TitlePagesToggleRow(
                title: "Apply to All Devices",
                subtitle: "Use this choice everywhere on this profile.",
                systemImage: "laptopcomputer.and.iphone",
                isOn: Binding(
                    get: { preferences.appliesToAllDevices },
                    set: { preferences.setAppliesToAllDevices($0) }
                )
            )
            if preferences.appliesToAllDevices {
                Label(
                    "Title art is \(preferences.showsTitleArt ? "on" : "off") on every device signed into this profile. Changing it here changes it everywhere.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(Color.siloSecondaryText)
            }
            if let message = preferences.errorMessage ?? preferences.readErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        } header: {
            Text("Title Pages")
        } footer: {
            if preferences.appliesToAllDevices {
                Text("Turn off Apply to All Devices to choose for this \(TitlePagesDevice.noun) only.")
            } else {
                Text("Only affects this \(TitlePagesDevice.noun). Your other devices keep their own setting.")
            }
        }
        .disabled(!preferences.allowsEditing)
    }
}

/// What the "this device" footers call the device.
private enum TitlePagesDevice {
    static var noun: String {
        switch AppleDeviceIdentity.current.clientFamily {
        case "tablet": return "iPad"
        case "desktop": return "Mac"
        case "tv": return "Apple TV"
        default: return "iPhone"
        }
    }
}

/// "Theme Music": local theme songs on title pages, written as this device's
/// choice. See `ThemeMusicPreferences`.
private struct ThemeMusicSettingsSection: View {
    let preferences: ThemeMusicPreferences

    var body: some View {
        Section {
            TitlePagesToggleRow(
                title: "Play Theme Music",
                subtitle: "Play a title's theme song from your library while its page is open.",
                systemImage: "music.note",
                isOn: Binding(
                    get: { preferences.playsThemeMusic },
                    set: { preferences.setEnabled($0) }
                )
            )
            TitlePagesToggleRow(
                title: "Loop Theme Music",
                subtitle: "Repeat the theme while the page stays open.",
                systemImage: "repeat",
                isOn: Binding(
                    get: { preferences.loops },
                    set: { preferences.setLoop($0) }
                )
            )
            .disabled(!preferences.playsThemeMusic)
            if let message = preferences.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        } header: {
            Text("Theme Music")
        } footer: {
            Text("Only affects this \(TitlePagesDevice.noun).")
        }
        .disabled(!preferences.allowsEditing)
    }
}

/// The Settings overview toggle on iPhone and iPad; a plain labeled toggle on
/// the Mac, which has no overview row style.
private struct TitlePagesToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        #if os(iOS)
        SettingsOverviewToggleRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            isOn: $isOn
        )
        #else
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        #endif
    }
}
#endif
