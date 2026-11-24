import Foundation
import Observation
import SwiftUI

/// Drives in-place Home and Library section arrangement (iOS Zoom-Out Shelf
/// Mode, tvOS Skyline Grab & Slide, and Settings → Home Sections). Edits the
/// acting profile's layout on the server so order, visibility, and added rows
/// follow the profile across devices. Each change saves immediately through a
/// serialized chain, reverting only if the server refuses and no newer edit
/// is queued.
@Observable
@MainActor
final class HomeSectionsEditorModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    struct ServerCollectionOption: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let libraryId: Int
        let libraryName: String
        let itemCount: Int
        let posterUrl: String?
        let posterThumbhash: String?
    }

    let scope: ProfileSectionsScope

    private(set) var phase: Phase = .loading
    /// Every row of the profile in display order, hidden rows included.
    private(set) var rows: [APIv2ProfileSectionSetting] = []
    private(set) var saveError: String?
    private(set) var isSaving = false
    private(set) var isResetting = false
    private(set) var isRefreshing = false

    // Add Row picker catalog data
    private(set) var recipeCatalog: APIv2RecipeCatalog = .curatedFallback
    private(set) var personalCollections: [UserCollection] = []
    private(set) var serverCollections: [ServerCollectionOption] = []
    private(set) var availableLibraries: [Library] = []
    private(set) var isLoadingPickerCatalog = false
    @ObservationIgnored private var hasLoadedPickerCatalog = false

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let newID: () -> String
    @ObservationIgnored private var auth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var saved: [APIv2SectionOverride] = []
    @ObservationIgnored private var confirmedRows: [APIv2ProfileSectionSetting] = []
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var editGeneration = 0

    init(
        scope: ProfileSectionsScope = .home,
        api: SiloAPI = .shared,
        newID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.scope = scope
        self.api = api
        self.newID = newID
    }

    var visibleRows: [APIv2ProfileSectionSetting] {
        rows.filter { !$0.hidden }
    }

    var hiddenRows: [APIv2ProfileSectionSetting] {
        rows.filter(\.hidden)
    }

    /// Seeds instant preview rows from already-loaded feed sections so entering
    /// Customize Mode never flashes a blank loading spinner before the server
    /// settings response arrives. Edits remain gated until `load()` completes.
    func seedPreviewRowsIfEmpty(from sections: [ResolvedSection], locale: Locale) {
        guard rows.isEmpty, phase == .loading, !sections.isEmpty else { return }
        rows = sections.enumerated().map { index, section in
            APIv2ProfileSectionSetting(
                id: section.id,
                sectionType: section.sectionType,
                title: section.displayTitle(in: locale),
                defaultTitle: section.title,
                featured: section.isFeatured,
                itemLimit: section.items.count,
                hidden: false,
                isCustom: false,
                customized: false,
                position: index,
                config: nil
            )
        }
    }

    /// Reads the layout once every queued save has landed.
    func load() async {
        var generation: Int
        repeat {
            generation = editGeneration
            await saveChain?.value
        } while generation != editGeneration
        if rows.isEmpty { phase = .loading }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let layout = try await api.profileLayout(scope: scope)
            guard generation == editGeneration else { return }
            auth = layout.auth
            saved = layout.saved
            rows = layout.rows
            confirmedRows = layout.rows
            saveError = nil
            phase = .loaded
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, generation == editGeneration else { return }
            let message = ErrorState(error).message
            if rows.isEmpty {
                phase = .failed(message)
            } else {
                saveError = message
            }
        }
    }

    /// Loads recipes, personal collections, and server collections for the `+ Add Row` picker.
    func loadPickerCatalogIfNeeded(force: Bool = false) async {
        guard force || !hasLoadedPickerCatalog else { return }
        isLoadingPickerCatalog = true
        defer { isLoadingPickerCatalog = false }

        async let recipesTask: APIv2RecipeCatalog? = try? await api.sectionRecipeCatalog()
        async let personalTask: CollectionsResponse? = try? await api.collections()
        async let librariesTask: LibrariesResponse? = try? await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: true)

        let (fetchedRecipes, fetchedPersonal, fetchedLibraries) = await (recipesTask, personalTask, librariesTask)
        if let fetchedRecipes, !fetchedRecipes.categories.isEmpty {
            recipeCatalog = fetchedRecipes
        } else {
            recipeCatalog = .curatedFallback
        }
        if let fetchedPersonal {
            personalCollections = fetchedPersonal.collections ?? []
        }

        if let libraries = fetchedLibraries?.libraries {
            availableLibraries = libraries
            var collected: [ServerCollectionOption] = []
            await withTaskGroup(of: [ServerCollectionOption].self) { group in
                for library in libraries {
                    group.addTask { [api] in
                        guard let response = try? await api.libraryCollections(libraryId: library.id) else {
                            return []
                        }
                        return response.collections.map { col in
                            ServerCollectionOption(
                                id: col.id,
                                title: col.name,
                                libraryId: library.id,
                                libraryName: library.name,
                                itemCount: col.itemCount ?? 0,
                                posterUrl: col.posterUrl,
                                posterThumbhash: col.posterThumbhash
                            )
                        }
                    }
                }
                for await batch in group {
                    collected.append(contentsOf: batch)
                }
            }
            // Deduplicate by collection id while keeping alphabetical order.
            var seen = Set<String>()
            serverCollections = collected
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        hasLoadedPickerCatalog = true
    }

    // MARK: - Queries

    func isRecipeTypePresent(sectionType: String) -> Bool {
        rows.contains { !$0.hidden && $0.sectionType.lowercased() == sectionType.lowercased() }
    }

    func isRecipePresent(sectionType: String, params: [String: SettingJSONValue]) -> Bool {
        rows.contains { row in
            guard !row.hidden, row.sectionType.lowercased() == sectionType.lowercased() else { return false }
            if params.isEmpty { return true }
            return params.allSatisfy { key, val in row.config?[key] == val }
        }
    }

    func hasHiddenMatchingRecipe(sectionType: String, params: [String: SettingJSONValue]) -> Bool {
        rows.contains { row in
            guard row.hidden, row.sectionType.lowercased() == sectionType.lowercased() else { return false }
            if params.isEmpty { return row.config == nil || row.config?.isEmpty == true }
            return params.allSatisfy { key, val in row.config?[key] == val }
        }
    }

    func isCollectionPresent(collectionId: String, isUserCollection: Bool) -> Bool {
        ProfileHomeLayout.pinnedCollectionRow(
            collectionId: collectionId,
            isUserCollection: isUserCollection,
            in: rows
        ) != nil
    }

    func canMoveVisible(id: String, by offset: Int) -> Bool {
        let visible = visibleRows
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return false }
        return visible.indices.contains(index + offset)
    }

    // MARK: - Mutations

    /// Reorders visible rows using List `.onMove` offsets while keeping hidden
    /// rows intact at the end.
    @discardableResult
    func moveVisible(fromOffsets source: IndexSet, toOffset destination: Int) -> Task<Void, Never> {
        var visible = visibleRows
        visible.move(fromOffsets: source, toOffset: destination)
        return apply(visible + hiddenRows)
    }

    /// Slides a visible row by `offset` (e.g. -1 up, +1 down) within visible rows.
    @discardableResult
    func moveVisible(id: String, by offset: Int) -> Task<Void, Never> {
        var visible = visibleRows
        guard let index = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(index + offset) else {
            return Task {}
        }
        visible.swapAt(index, index + offset)
        return apply(visible + hiddenRows)
    }

    /// Reorders visible rows in memory during an active touch drag so sibling
    /// cards spring-swap at 120Hz without firing a save per crossed slot.
    /// Call `commitDraggedOrder()` when the drag finishes.
    @discardableResult
    func swapVisibleDuringDrag(id: String, by offset: Int) -> Bool {
        guard phase == .loaded else { return false }
        var visible = visibleRows
        guard let index = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(index + offset) else {
            return false
        }
        visible.swapAt(index, index + offset)
        rows = visible + hiddenRows
        return true
    }

    /// Persists the final order after a live drag ends (no-op if unchanged).
    @discardableResult
    func commitDraggedOrder() -> Task<Void, Never> {
        guard phase == .loaded, rows != confirmedRows else { return Task {} }
        saveError = nil
        editGeneration += 1
        let previous = saveChain
        let task = Task {
            await previous?.value
            await self.saveCurrentRows()
        }
        saveChain = task
        return task
    }

    /// Moves any row to the top of the visible stack (and unhides if hidden).
    @discardableResult
    func moveToTop(id: String) -> Task<Void, Never> {
        var next = rows
        guard let index = next.firstIndex(where: { $0.id == id }) else { return Task {} }
        var row = next.remove(at: index)
        row.hidden = false
        next.insert(row, at: 0)
        return apply(next)
    }

    /// Moves a visible row to the bottom of the visible stack.
    @discardableResult
    func moveToBottom(id: String) -> Task<Void, Never> {
        var visible = visibleRows
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return Task {} }
        let row = visible.remove(at: index)
        visible.append(row)
        return apply(visible + hiddenRows)
    }

    @discardableResult
    func setHidden(_ hidden: Bool, id: String) -> Task<Void, Never> {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return Task {} }
        var next = rows
        next[index].hidden = hidden
        return apply(next)
    }

    @discardableResult
    func addRecipeRow(
        sectionType: String,
        title: String,
        config: [String: SettingJSONValue]? = nil,
        itemLimit: Int = 20,
        featured: Bool = false
    ) -> Task<Void, Never> {
        let nonEmptyConfig = (config?.isEmpty == false) ? config : nil
        // If an identical hidden row exists and the user kept default options,
        // unhide it instead of creating a duplicate.
        if !featured && itemLimit == 20,
           let existingIdx = rows.firstIndex(where: { row in
               row.hidden
                   && row.sectionType.lowercased() == sectionType.lowercased()
                   && row.displayTitle.caseInsensitiveCompare(title) == .orderedSame
                   && (nonEmptyConfig == nil
                       ? (row.config == nil || row.config?.isEmpty == true)
                       : nonEmptyConfig!.allSatisfy { row.config?[$0.key] == $0.value })
           }) {
            return setHidden(false, id: rows[existingIdx].id)
        }
        let id = newID()
        let newRow = APIv2ProfileSectionSetting(
            id: id,
            sectionType: sectionType,
            title: title,
            defaultTitle: title,
            featured: featured,
            itemLimit: itemLimit,
            hidden: false,
            isCustom: true,
            customized: true,
            position: rows.count,
            config: nonEmptyConfig
        )
        var visible = visibleRows
        visible.append(newRow)
        return apply(visible + hiddenRows)
    }

    @discardableResult
    func addCollectionRow(
        collectionId: String,
        title: String,
        isUserCollection: Bool,
        itemLimit: Int = 20,
        featured: Bool = false
    ) -> Task<Void, Never> {
        if !featured && itemLimit == 20,
           let existing = ProfileHomeLayout.matchingCollectionRow(
               collectionId: collectionId,
               isUserCollection: isUserCollection,
               in: rows
           ),
           existing.hidden,
           existing.displayTitle.caseInsensitiveCompare(title) == .orderedSame {
            return setHidden(false, id: existing.id)
        }
        let newRow = ProfileHomeLayout.makeCollectionRow(
            id: newID(),
            title: title,
            collectionId: collectionId,
            isUserCollection: isUserCollection,
            position: rows.count,
            itemLimit: itemLimit,
            featured: featured
        )
        var visible = visibleRows
        visible.append(newRow)
        return apply(visible + hiddenRows)
    }

    @discardableResult
    func addCollectionPostersRow(
        title: String,
        refs: [(isUserCollection: Bool, id: String)]
    ) -> Task<Void, Never> {
        guard !refs.isEmpty else { return Task {} }
        let entries: [SettingJSONValue] = refs.map { ref in
            let key = ref.isUserCollection ? "user_collection_id" : "library_collection_id"
            return .object([key: .string(ref.id)])
        }
        let effectiveTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Collections"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRow = APIv2ProfileSectionSetting(
            id: newID(),
            sectionType: "collection_posters",
            title: effectiveTitle,
            defaultTitle: effectiveTitle,
            featured: false,
            itemLimit: 20,
            hidden: false,
            isCustom: true,
            customized: true,
            position: rows.count,
            config: ["collections": .array(entries)]
        )
        var visible = visibleRows
        visible.append(newRow)
        return apply(visible + hiddenRows)
    }

    @discardableResult
    func removeCustomRow(id: String) -> Task<Void, Never> {
        guard let index = rows.firstIndex(where: { $0.id == id && $0.isCustom }) else { return Task {} }
        var next = rows
        next.remove(at: index)
        return apply(next)
    }

    func resetToServerDefault() async {
        guard let auth else { return }
        isResetting = true
        defer { isResetting = false }
        await saveChain?.value
        do {
            try await api.resetProfileLayout(scope: scope, auth: auth)
            saveError = nil
            Self.refreshScope(scope)
            await load()
        } catch {
            saveError = "Couldn't reset layout. \(ErrorState(error).message)"
        }
    }

    /// Re-fetches Home or Library feeds immediately.
    func triggerFeedRefresh() {
        Self.refreshScope(scope)
    }

    // MARK: - Persistence

    private func apply(_ next: [APIv2ProfileSectionSetting]) -> Task<Void, Never> {
        guard phase == .loaded, next != rows else { return Task {} }
        rows = next
        saveError = nil
        editGeneration += 1
        let previous = saveChain
        let task = Task {
            await previous?.value
            await self.saveCurrentRows()
        }
        saveChain = task
        return task
    }

    private func saveCurrentRows() async {
        guard let auth, rows != confirmedRows else { return }
        let sent = rows
        let sentGeneration = editGeneration
        let overrides = ProfileHomeLayout.overrides(
            rows: sent,
            baseline: confirmedRows,
            saved: saved,
            newID: newID
        )
        isSaving = true
        defer { isSaving = false }
        do {
            try await api.saveProfileLayout(overrides, scope: scope, auth: auth)
            saved = overrides
            confirmedRows = sent
            saveError = nil
            Self.refreshScope(scope)
        } catch {
            if editGeneration == sentGeneration {
                rows = confirmedRows
            }
            saveError = "Couldn't save layout. \(ErrorState(error).message)"
        }
    }

    static func refreshScope(_ scope: ProfileSectionsScope) {
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        if case .library(let libraryId) = scope {
            ResponseCache.shared.remove(CacheKey.librarySections(libraryId))
        }
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }
}

// MARK: - Home Preferences Model

/// Reads and updates the profile's Home display preferences:
/// `ui.next_up_mode`, `ui.next_up_new_releases_first`, and `home.hide_watched_items`.
@Observable
@MainActor
final class HomePreferencesModel {
    enum NextUpMode: String, CaseIterable, Identifiable, Sendable {
        case combined
        case separate

        var id: String { rawValue }

        var title: String {
            switch self {
            case .combined: return "With Continue Watching"
            case .separate: return "Separate Row"
            }
        }

        var subtitle: String {
            switch self {
            case .combined: return "Upcoming episodes appear inside Continue Watching."
            case .separate: return "Upcoming episodes get their own Next Up row."
            }
        }
    }

    var nextUpMode: NextUpMode = .combined
    var newReleasesFirst = false
    var hideWatchedItems = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let writer: ProfileSettingsWriter

    init(api: SiloAPI = .shared, writer: ProfileSettingsWriter = ProfileSettingsWriter()) {
        self.api = api
        self.writer = writer
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let response = try await api.getEffectiveValues(keys: [
                .uiNextUpMode,
                .uiNextUpNewReleasesFirst,
                .homeHideWatchedItems,
            ])
            let byKey = response.byKey
            if let raw = byKey[.uiNextUpMode]?.value.stringValue,
               let parsed = NextUpMode(rawValue: raw) {
                nextUpMode = parsed
            }
            if let value = byKey[.uiNextUpNewReleasesFirst]?.value.boolValue {
                newReleasesFirst = value
            }
            if let value = byKey[.homeHideWatchedItems]?.value.boolValue {
                hideWatchedItems = value
            }
        } catch {
            // Leave defaults visible if an older server lacks one of the keys.
            errorMessage = nil
        }
    }

    func setNextUpMode(_ mode: NextUpMode) {
        guard mode != nextUpMode else { return }
        let previous = nextUpMode
        nextUpMode = mode
        Task {
            await persist(.uiNextUpMode, value: .string(mode.rawValue)) {
                self.nextUpMode = previous
            }
        }
    }

    func setNewReleasesFirst(_ enabled: Bool) {
        guard enabled != newReleasesFirst else { return }
        let previous = newReleasesFirst
        newReleasesFirst = enabled
        Task {
            await persist(.uiNextUpNewReleasesFirst, value: .bool(enabled)) {
                self.newReleasesFirst = previous
            }
        }
    }

    func setHideWatchedItems(_ enabled: Bool) {
        guard enabled != hideWatchedItems else { return }
        let previous = hideWatchedItems
        hideWatchedItems = enabled
        Task {
            await persist(.homeHideWatchedItems, value: .bool(enabled)) {
                self.hideWatchedItems = previous
            }
        }
    }

    private func persist(
        _ key: SettingKey,
        value: SettingJSONValue,
        revert: @escaping () -> Void
    ) async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await writer.write(key, value: value)
            HomeSectionsEditorModel.refreshScope(.home)
        } catch {
            revert()
            errorMessage = "Couldn't save preference. \(ErrorState(error).message)"
        }
    }
}
