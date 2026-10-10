#if !os(tvOS)
import SwiftUI

/// Settings > Interface > Libraries, also opened from the end of the
/// Libraries page: a switch for every library the profile can open.
///
/// Turning one off adds it to the profile's `ui.disabled_library_ids`. The
/// server then leaves it out of Home, Search and Calendar on every client,
/// and this app drops it from the tab bar and Libraries
/// (`HiddenLibraryPreference`). On iOS the page shows the tab bar the
/// current choice gives.
struct LibraryVisibilitySettingsView: View {
    /// Every library the profile can open, hidden ones included, in server
    /// order.
    @State private var libraries: [Library] = []
    @State private var hiddenIds: Set<Int> = []
    @State private var isLoading = true
    @State private var loadError: ErrorState?
    /// One save at a time: each save rewrites the whole list, so two at once
    /// could undo each other.
    @State private var isSaving = false
    /// Advances with each load and each save, so only the newest load
    /// applies, and never over a save that started after it.
    @State private var loadGeneration = 0
    @State private var saveError: String?
    @State private var navPrefs = AppNavPreferences.shared

    private var sections: [LibrariesPageSection] {
        let listed = navPrefs.showAudiobooks ? libraries : libraries.filter { !$0.isAudiobookLibrary }
        return LibrariesPage.sections(libraries: listed, pinnedIds: [])
    }

    var body: some View {
        List {
            #if os(iOS)
            if !sections.isEmpty {
                Section("Tab Bar") {
                    TabBarPreview(
                        destinations: appleFixedTabDestinations(
                            libraries: HiddenLibraryPreference.visibleLibraries(libraries, hiding: hiddenIds),
                            showAudiobooks: navPrefs.showAudiobooks
                        )
                    )
                }
            }
            #endif

            ForEach(sections) { section in
                Section {
                    ForEach(section.libraries) { library in
                        row(for: library)
                    }
                } header: {
                    Text(section.capability.title)
                } footer: {
                    if section.id == sections.last?.id {
                        Text("Hidden libraries leave the tab bar, Home, Search and Calendar for this profile on all its devices, including the web app.")
                    }
                }
            }
        }
        .overlay {
            if sections.isEmpty {
                if let loadError {
                    ErrorView(state: loadError, onRetry: { Task { await load() } })
                } else if !isLoading {
                    EmptyStateView(
                        icon: "square.stack.3d.up",
                        title: "No libraries available",
                        subtitle: "Libraries visible to this profile will appear here."
                    )
                }
            }
        }
        .navigationTitle("Libraries")
        .task { await load() }
        // A foreground refresh can bring a change made on another device.
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) { _ in
            guard !isSaving else { return }
            Task { await load() }
        }
        .alert(
            "Couldn’t Update Libraries",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func row(for library: Library) -> some View {
        Toggle(isOn: Binding(
            get: { !hiddenIds.contains(library.id) },
            set: { isVisible in Task { await setVisible(isVisible, library) } }
        )) {
            HStack(spacing: 12) {
                LibraryThumbnail(library: library)
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.name)
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    Text(library.switcherTypeLabel)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .tint(.siloSwitchOn)
        .disabled(isSaving)
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        // A save can supersede the only load in flight.
        defer { isLoading = false }
        async let hidden = HiddenLibraryPreference.hiddenLibraryIds()
        do {
            let response = try await SiloAPI.shared.libraries()
            let hiddenIds = await hidden
            guard generation == loadGeneration else { return }
            libraries = response.libraries
            self.hiddenIds = hiddenIds
            loadError = nil
        } catch {
            guard generation == loadGeneration else { return }
            if libraries.isEmpty { loadError = ErrorState(error) }
        }
    }

    /// Shows the choice at once, then saves it. A failed save puts the
    /// switch back.
    private func setVisible(_ isVisible: Bool, _ library: Library) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // A load already running read the setting before this save.
        loadGeneration += 1
        setLocally(isVisible, library.id)
        do {
            // Also picks up libraries hidden on another device meanwhile.
            hiddenIds = try await HiddenLibraryPreference.setHidden(!isVisible, libraryId: library.id)
            await HiddenLibraryPreference.publishChange(hiddenIds: hiddenIds)
        } catch {
            // The profile changed before the write; this page is leaving.
            guard !(error is CancellationError) else { return }
            setLocally(!isVisible, library.id)
            saveError = Self.saveFailureMessage(for: error, library: library, isVisible: isVisible)
        }
    }

    private func setLocally(_ isVisible: Bool, _ libraryId: Int) {
        if isVisible {
            hiddenIds.remove(libraryId)
        } else {
            hiddenIds.insert(libraryId)
        }
    }

    static func saveFailureMessage(for error: Error, library: Library, isVisible: Bool) -> String {
        let action = isVisible ? "show" : "hide"
        switch SettingsAPIError.from(error) {
        case .transport:
            return "Couldn't \(action) \(library.name). Check the connection and try again."
        case .serverUpgradeRequired, .unknownSetting:
            return "This server can't hide libraries."
        default:
            return "The server didn't \(action) \(library.name). Try again."
        }
    }
}

/// A library's artwork as a small 16:9 tile, or its type icon when it has
/// none.
private struct LibraryThumbnail: View {
    let library: Library

    private static let size = CGSize(width: 48, height: 27)

    var body: some View {
        Group {
            if let posterUrl = library.posterUrl, !posterUrl.isEmpty {
                AsyncImageView(url: posterUrl, targetSize: Self.size, contentMode: .fill)
            } else {
                ZStack {
                    Color.siloSurfaceVariant
                    Image(systemName: library.switcherIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }
}

#if os(iOS)
/// The tab bar's destinations as icons and titles, Home selected.
private struct TabBarPreview: View {
    let destinations: [MainTabDestination]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(destinations) { destination in
                let isHome = destination.id == .app(.home)
                VStack(spacing: 3) {
                    Image(systemName: isHome ? destination.selectedIcon : destination.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 22)
                    Text(destination.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(Color.siloOnSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if isHome {
                        Capsule().fill(Color.white.opacity(0.15))
                    }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.siloSurfaceElevated))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab bar: \(destinations.map(\.title).joined(separator: ", "))")
    }
}
#endif
#endif
