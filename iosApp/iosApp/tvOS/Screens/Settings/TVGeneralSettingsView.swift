#if os(tvOS)
import SwiftUI

/// Family-synced tvOS interface preferences. Every control is a native focus
/// target; the menu editor changes data only on Select and never intercepts
/// directional movement, preserving the stable focus graph described in
/// `docs/tvos-focus.md`.
struct TVGeneralSettingsPane: View {
    @State private var preferences = UICustomizationPreferences.shared
    @State private var navPrefs = TVNavPreferences.shared
    @State private var activePicker: PickerKind?
    @State private var showsMenuEditor = false
    @State private var registry = ServerRegistry.shared
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = preferences.capabilityMessage {
                TVSettingsSectionHeader("SERVER SUPPORT")
                TVSettingsFooter(message)
            }

            if preferences.hasDeviceOverrides {
                TVSettingsSectionHeader("SYNC SOURCE")
                if preferences.cardPresentationUsesDeviceOverride {
                    familySettingsButton
                        .focused(detailFocus, equals: .top)
                } else {
                    familySettingsButton
                }
                TVSettingsFooter("This Apple TV has older device-specific settings. Clear them to use the TV-family choices shared by this profile.")
            }

            TVSettingsSectionHeader("CARDS & POSTERS")

            presetRow

            TVSettingsPickerRow(
                title: "Poster Size",
                value: preferences.cardPresentation.posterSize.title
            ) { activePicker = .posterSize }
            .disabled(
                !preferences.allowsEditing
                    || preferences.cardPresentationUsesDeviceOverride
            )

            TVSettingsPickerRow(
                title: "Captions",
                value: preferences.cardPresentation.caption.title
            ) { activePicker = .caption }
            .disabled(
                !preferences.allowsEditing
                    || preferences.cardPresentationUsesDeviceOverride
            )

            if preferences.cardPresentationUsesFamilyOverride {
                Button("Use Profile Default") {
                    preferences.resetCardPresentationToInherited()
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .disabled(preferences.isSaving || !preferences.allowsEditing)
            }

            TVSettingsFooter("Start with Balanced, Compact, Cinema, or Artwork Only, then fine-tune size and captions. These choices sync with other TV-family devices on this profile.")

            TVSettingsSectionHeader("TOP MENU")

            if preferences.supportProjection == .knownUnsupported {
                TVSettingsToggleRow(
                    title: "Show Audiobooks",
                    isOn: navPrefs.showAudiobooks
                ) {
                    navPrefs.setShowAudiobooks(!navPrefs.showAudiobooks)
                }
                .focused(detailFocus, equals: .top)

                TVSettingsFooter("This server uses the legacy device-local menu preference. Adds an Audiobooks tab when an audiobook library is available.")
            } else {
                Button { showsMenuEditor = true } label: {
                    HStack(spacing: 16) {
                        Text("Customize Top Menu")
                            .font(.system(size: 26))
                        Spacer(minLength: 16)
                        Text("\(visibleMenuCount) items")
                            .font(.system(size: 24))
                            .opacity(0.68)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .disabled(!preferences.allowsEditing)

                TVSettingsFooter("Reorder or hide destinations and pin individual libraries. Search and Profile stay fixed so remote navigation always has stable anchors.")
            }

            if let message = preferences.syncErrorMessage,
               message != preferences.capabilityMessage {
                TVSettingsFooter(message)
            }
        }
        .fullScreenCover(item: $activePicker) { picker in
            pickerSheet(for: picker)
        }
        .fullScreenCover(isPresented: $showsMenuEditor) {
            TVMenuCustomizationSheet(libraries: libraries)
        }
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

    private var visibleMenuCount: Int {
        preferences.resolvedPrimaryMenuItems(availableLibraries: libraries).count
    }

    @ViewBuilder
    private var presetRow: some View {
        let row = TVSettingsPickerRow(
            title: "Preset",
            value: preferences.cardPresentation.preset?.title ?? "Custom"
        ) { activePicker = .preset }

        if preferences.cardPresentationUsesDeviceOverride || !preferences.allowsEditing {
            row.disabled(true)
        } else {
            row.focused(detailFocus, equals: .top)
        }
    }

    private var familySettingsButton: some View {
        Button("Use Synced TV Settings") {
            preferences.useFamilySettings()
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .disabled(preferences.isSaving || !preferences.allowsEditing)
    }

    @ViewBuilder
    private func pickerSheet(for picker: PickerKind) -> some View {
        switch picker {
        case .preset:
            TVSettingsPickerSheet(
                title: "Card Preset",
                options: CardPresentationPreset.allCases.map {
                    TVSettingsOption(id: $0.rawValue, label: $0.title)
                } + (preferences.cardPresentation.preset == nil
                    ? [TVSettingsOption(id: Self.customPresetId, label: "Custom")]
                    : []),
                selection: Binding(
                    get: {
                        preferences.cardPresentation.preset?.rawValue ?? Self.customPresetId
                    },
                    set: { value in
                        guard let preset = CardPresentationPreset(rawValue: value) else { return }
                        preferences.setCardPresentation(preset.presentation)
                    }
                ),
                allowsSelection: preferences.allowsEditing,
                disabledMessage: preferences.capabilityMessage
            )
        case .posterSize:
            TVSettingsPickerSheet(
                title: "Poster Size",
                options: CardPosterSize.allCases.map {
                    TVSettingsOption(id: $0.rawValue, label: $0.title)
                },
                selection: Binding(
                    get: { preferences.cardPresentation.posterSize.rawValue },
                    set: { value in
                        guard let size = CardPosterSize(rawValue: value) else { return }
                        preferences.setPosterSize(size)
                    }
                ),
                allowsSelection: preferences.allowsEditing,
                disabledMessage: preferences.capabilityMessage
            )
        case .caption:
            TVSettingsPickerSheet(
                title: "Card Captions",
                options: CardCaptionStyle.allCases.map {
                    TVSettingsOption(id: $0.rawValue, label: $0.title)
                },
                selection: Binding(
                    get: { preferences.cardPresentation.caption.rawValue },
                    set: { value in
                        guard let style = CardCaptionStyle(rawValue: value) else { return }
                        preferences.setCaptionStyle(style)
                    }
                ),
                allowsSelection: preferences.allowsEditing,
                disabledMessage: preferences.capabilityMessage
            )
        }
    }

    private enum PickerKind: String, Identifiable {
        case preset
        case posterSize
        case caption
        var id: String { rawValue }
    }

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

    private static let customPresetId = "custom"
}

private struct TVMenuCustomizationSheet: View {
    let libraries: [Library]
    @State private var preferences = UICustomizationPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let message = preferences.capabilityMessage {
                        TVSettingsFooter(message)
                    }

                    if preferences.primaryMenuUsesDeviceOverride {
                        TVSettingsFooter("This Apple TV's older device-specific menu is read-only. You can still update profile library pins below, or clear the override from General settings.")
                    }

                    sectionHeader("VISIBLE DESTINATIONS")

                    VStack(spacing: 10) {
                        ForEach(visibleItems) { item in
                            visibleRow(item)
                        }
                    }
                    .focusSection()
                    .disabled(!familyMenuMutationsEnabled)

                    if !hiddenBuiltins.isEmpty {
                        sectionHeader("HIDDEN DESTINATIONS")
                        VStack(spacing: 10) {
                            ForEach(hiddenBuiltins) { item in
                                Button {
                                    persistVisibleItems(visibleItems + [item])
                                } label: {
                                    HStack(spacing: 18) {
                                        Image(systemName: "plus.circle.fill")
                                        Text("Show \(item.title)")
                                        Spacer()
                                    }
                                    .font(.system(size: 26, weight: .medium))
                                }
                                .buttonStyle(TVSettingsPaneRowStyle())
                            }
                        }
                        .focusSection()
                        .disabled(!familyMenuMutationsEnabled)
                    }

                    if !availableLibraryShortcuts.isEmpty {
                        sectionHeader("AVAILABLE LIBRARY SHORTCUTS")
                        VStack(spacing: 10) {
                            ForEach(availableLibraryShortcuts) { item in
                                Button {
                                    persistVisibleItems(visibleItems + [item])
                                } label: {
                                    HStack(spacing: 18) {
                                        Image(systemName: "plus.circle.fill")
                                        Text("Show \(item.title)")
                                        Spacer()
                                    }
                                    .font(.system(size: 26, weight: .medium))
                                }
                                .buttonStyle(TVSettingsPaneRowStyle())
                            }
                        }
                        .focusSection()
                        .disabled(!familyMenuMutationsEnabled)
                    }

                    if !libraries.isEmpty {
                        sectionHeader("PIN LIBRARIES")
                        VStack(spacing: 10) {
                            ForEach(libraries.sorted(by: librarySort)) { library in
                                TVSettingsToggleRow(
                                    title: library.name,
                                    isOn: preferences.isLibraryPinned(library.id)
                                ) {
                                    preferences.setLibraryPinned(
                                        library,
                                        isPinned: !preferences.isLibraryPinned(library.id)
                                    )
                                }
                            }
                        }
                        .focusSection()
                        .disabled(!profilePinMutationsEnabled)
                    }

                    TVSettingsFooter("Home cannot be hidden. Pinned libraries also enter your profile shortcut catalog; their top-menu placement stays specific to TV-family devices.")
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(.horizontal, 72)
                .padding(.vertical, 36)
            }
            .navigationTitle("Customize Top Menu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .background(Color.continuumBackground.ignoresSafeArea())
        }
    }

    private var visibleItems: [PrimaryMenuItem] {
        let availableIds = Set(libraries.map(\.id))
        return preferences.resolvedPrimaryMenuItems(availableLibraries: libraries).filter { item in
            switch item {
            case .builtin(.movies): return hasLibrary(.movies)
            case .builtin(.series): return hasLibrary(.series)
            case .builtin(.music): return hasLibrary(.music)
            case .builtin(.audiobooks): return hasLibrary(.audiobooks)
            case .library(let id, _): return availableIds.contains(id)
            case .section, .collection: return false
            case .builtin(.home), .builtin(.forYou), .builtin(.calendar): return true
            }
        }
    }

    private var familyMenuMutationsEnabled: Bool {
        tvCustomizationMutationIsEnabled(
            allowsEditing: preferences.allowsEditing,
            usesDeviceMenuOverride: preferences.primaryMenuUsesDeviceOverride,
            changesFamilyMenu: true
        )
    }

    private var profilePinMutationsEnabled: Bool {
        tvCustomizationMutationIsEnabled(
            allowsEditing: preferences.allowsEditing,
            usesDeviceMenuOverride: preferences.primaryMenuUsesDeviceOverride,
            changesFamilyMenu: false
        )
    }

    private var hiddenBuiltins: [PrimaryMenuItem] {
        let visibleIds = Set(visibleItems.map(\.id))
        return builtinCandidates.filter { !visibleIds.contains($0.id) }
    }

    /// A profile shortcut and a TV-family menu row are separate pieces of
    /// state. Keep a hidden pinned library pinned, while still offering an
    /// explicit way to restore it to this TV's top menu.
    private var availableLibraryShortcuts: [PrimaryMenuItem] {
        let visibleIds = Set(visibleItems.map(\.id))
        let availableLibraryIds = Set(libraries.map(\.id))
        return preferences.shortcuts.items.filter { item in
            guard case .library(let libraryId, _) = item else { return false }
            return availableLibraryIds.contains(libraryId) && !visibleIds.contains(item.id)
        }
    }

    private var builtinCandidates: [PrimaryMenuItem] {
        var items: [PrimaryMenuItem] = [.builtin(.home)]
        for type in TVLibraryTabType.allCases where hasLibrary(type) {
            let builtin: PrimaryMenuBuiltin
            switch type {
            case .movies: builtin = .movies
            case .series: builtin = .series
            case .music: builtin = .music
            case .audiobooks: builtin = .audiobooks
            }
            items.append(.builtin(builtin))
        }
        items.append(contentsOf: [.builtin(.forYou), .builtin(.calendar)])
        return items
    }

    private func visibleRow(_ item: PrimaryMenuItem) -> some View {
        let index = visibleItems.firstIndex(where: { $0.id == item.id }) ?? 0
        return HStack(spacing: 12) {
            Text(item.title)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)

            Button {
                move(item, by: -1)
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .disabled(index == 0)
            .accessibilityLabel("Move \(item.title) earlier")

            Button {
                move(item, by: 1)
            } label: {
                Image(systemName: "arrow.down")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .disabled(index == visibleItems.count - 1)
            .accessibilityLabel("Move \(item.title) later")

            if !item.isHome {
                Button {
                    hide(item)
                } label: {
                    Image(systemName: "eye.slash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Hide \(item.title)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.continuumChromeRestingFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
        }
    }

    private func move(_ item: PrimaryMenuItem, by offset: Int) {
        var items = visibleItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        persistVisibleItems(items)
    }

    private func hide(_ item: PrimaryMenuItem) {
        guard !item.isHome else { return }
        persistVisibleItems(visibleItems.filter { $0.id != item.id })
    }

    /// Weave the edited, focus-visible rows back through the complete synced
    /// menu. Section/collection targets and temporarily unavailable libraries
    /// are not renderable roots on Apple TV yet, but must survive an unrelated
    /// reorder so another TV-family client does not lose them.
    private func persistVisibleItems(_ updatedVisibleItems: [PrimaryMenuItem]) {
        let currentlyVisibleIds = Set(visibleItems.map(\.id))
        var replacements = updatedVisibleItems.makeIterator()
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

    private func hasLibrary(_ type: TVLibraryTabType) -> Bool {
        libraries.contains(where: { type.matches($0) })
    }

    private func librarySort(_ lhs: Library, _ rhs: Library) -> Bool {
        (lhs.sortOrder ?? Int.max, lhs.id) < (rhs.sortOrder ?? Int.max, rhs.id)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color.continuumSecondaryText)
    }
}
#endif
