#if !os(tvOS)
import SwiftUI

func availablePrimaryMenuLibraryShortcuts(
    _ shortcuts: [PrimaryMenuItem],
    visibleIds: Set<String>,
    availableLibraryIds: Set<Int>
) -> [PrimaryMenuItem] {
    shortcuts.filter { item in
        guard case .library(let libraryId, _) = item else { return false }
        return availableLibraryIds.contains(libraryId) && !visibleIds.contains(item.id)
    }
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
                ForEach(visibleDestinations) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isHome ? "lock.fill" : "line.3.horizontal")
                            .foregroundStyle(Color.continuumSecondaryText)
                            .frame(width: 22)
                        Text(displayTitle(for: item))
                        Spacer()
#if os(macOS)
                        Button {
                            move(item, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(visibleDestinations.first?.id == item.id)
                        .accessibilityLabel("Move \(displayTitle(for: item)) up")

                        Button {
                            move(item, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(visibleDestinations.last?.id == item.id)
                        .accessibilityLabel("Move \(displayTitle(for: item)) down")
#endif
                        if !item.isHome {
                            Button {
                                hide(item)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide \(displayTitle(for: item))")
                        }
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("Primary Menu")
            } footer: {
                Text("Home is required. Downloads (when available), Search, and Profile stay automatic. Media categories share Libraries; pinned libraries open directly. Unsupported section and collection rows stay synced for clients that can show them.")
            }
            .disabled(
                !preferences.allowsEditing
                    || preferences.primaryMenuUsesDeviceOverride
            )

            if !hiddenDestinations.isEmpty {
                Section("Hidden") {
                    ForEach(hiddenDestinations) { item in
                        Button {
                            show(item)
                        } label: {
                            Label("Show \(displayTitle(for: item))", systemImage: "plus.circle.fill")
                        }
                    }
                }
                .disabled(
                    !preferences.allowsEditing
                        || preferences.primaryMenuUsesDeviceOverride
                )
            }

            if !availableShortcuts.isEmpty {
                Section("Available Shortcuts") {
                    ForEach(availableShortcuts) { item in
                        Button {
                            show(item)
                        } label: {
                            Label("Show \(item.title)", systemImage: "pin.circle.fill")
                        }
                    }
                }
                .disabled(
                    !preferences.allowsEditing
                        || preferences.primaryMenuUsesDeviceOverride
                )
            }

            if !libraries.isEmpty {
                Section("Pinned Libraries") {
                    ForEach(libraries.sorted(by: librarySort)) { library in
                        Toggle(
                            library.name,
                            isOn: Binding(
                                get: { preferences.isLibraryPinned(library.id) },
                                set: { preferences.setLibraryPinned(library, isPinned: $0) }
                            )
                        )
                    }
                }
                .disabled(!preferences.allowsEditing)
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
#if os(iOS)
        .toolbar { EditButton() }
#endif
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

    private var hiddenDestinations: [PrimaryMenuItem] {
        let visible = Set(visibleDestinations.map(\.id))
        return Self.candidates.filter {
            mainTabSupportsDestination($0, availableLibraries: libraries)
                && !visible.contains($0.id)
        }
    }

    private var availableShortcuts: [PrimaryMenuItem] {
        let visible = Set(visibleDestinations.map(\.id))
        return availablePrimaryMenuLibraryShortcuts(
            preferences.shortcuts.items,
            visibleIds: visible,
            availableLibraryIds: Set(libraries.map(\.id))
        )
    }

    private func displayTitle(for item: PrimaryMenuItem) -> String {
        item.title
    }

    private func move(from source: IndexSet, to destination: Int) {
        var items = visibleDestinations
        items.move(fromOffsets: source, toOffset: destination)
        persistVisibleDestinations(items)
    }

    private func move(_ item: PrimaryMenuItem, by offset: Int) {
        var items = visibleDestinations
        guard let source = items.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = source + offset
        guard items.indices.contains(destination) else { return }
        items.swapAt(source, destination)
        persistVisibleDestinations(items)
    }

    private func hide(_ item: PrimaryMenuItem) {
        guard !item.isHome else { return }
        persistVisibleDestinations(visibleDestinations.filter { $0.id != item.id })
    }

    private func show(_ item: PrimaryMenuItem) {
        persistVisibleDestinations(visibleDestinations + [item])
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
#endif
