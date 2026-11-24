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
    /// Committed rows in display order, hidden rows included.
    private var committedRows: [APIv2ProfileSectionSetting] = []
    /// Live drag-reorder visible row IDs, projected onto `committedRows` so
    /// visibility or membership changes that settle during a drag are never overwritten.
    private var dragDraftVisibleOrder: [String]?
    /// Every row of the profile in display order, hidden rows included.
    var rows: [APIv2ProfileSectionSetting] {
        guard let order = dragDraftVisibleOrder else { return committedRows }
        return Self.applyingVisibleOrder(order, to: committedRows)
    }
    private(set) var hasLoadedFromServer = false
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
    private(set) var personalCollectionsError: String?
    private(set) var serverCollectionsError: String?
    @ObservationIgnored private var hasLoadedPickerCatalog = false
    @ObservationIgnored private var pickerCatalogIdentity: HTTPRequestIdentity?

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let newID: () -> String
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var auth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var saved: [APIv2SectionOverride] = []
    @ObservationIgnored private var confirmedRows: [APIv2ProfileSectionSetting] = []
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var quickActionChain: Task<Void, Never>?
    @ObservationIgnored private var editGeneration = 0
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pickerLoadGeneration = 0

    init(
        scope: ProfileSectionsScope = .home,
        api: SiloAPI = .shared,
        newID: @escaping () -> String = { UUID().uuidString.lowercased() },
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.scope = scope
        self.api = api
        self.newID = newID
        self.requestIdentity = requestIdentity
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
        guard committedRows.isEmpty, !hasLoadedFromServer, phase == .loading, !sections.isEmpty else { return }
        committedRows = sections.enumerated().map { index, section in
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

    private var scopeCacheKey: String {
        switch scope {
        case .home: CacheKey.homeSections
        case .library(let libraryId): CacheKey.librarySections(libraryId)
        }
    }

    /// Reads the layout once every queued save has landed.
    /// Returns `true` only when this call fetched and applied fresh server state.
    @discardableResult
    func load() async -> Bool {
        var generation: Int
        repeat {
            generation = editGeneration
            await saveChain?.value
        } while generation != editGeneration
        loadGeneration += 1
        let myLoadGen = loadGeneration
        let startIdentity = requestIdentity()
        phase = .loading
        saveError = nil
        isRefreshing = true
        defer {
            if loadGeneration == myLoadGen {
                isRefreshing = false
            }
        }
        // Retry if another surface invalidates this scope's cache while the
        // read is in flight, so even an initial load never publishes a stale
        // pre-invalidation layout.
        for attempt in 0..<3 {
            let startCacheToken = ResponseCache.shared.writeToken
            do {
                let layout = try await api.profileLayout(scope: scope)
                guard !Task.isCancelled,
                      loadGeneration == myLoadGen,
                      generation == editGeneration,
                      requestIdentity() == startIdentity else {
                    return false
                }
                if ResponseCache.shared.wasInvalidated(scopeCacheKey, after: startCacheToken) {
                    if attempt < 2 {
                        continue
                    }
                    let message = ErrorState(URLError(.cannotLoadFromNetwork)).message
                    phase = .failed(message)
                    saveError = message
                    return false
                }
                auth = layout.auth
                saved = layout.saved
                committedRows = layout.rows
                dragDraftVisibleOrder = nil
                confirmedRows = layout.rows
                hasLoadedFromServer = true
                saveError = nil
                phase = .loaded
                return true
            } catch {
                guard !(error is CancellationError),
                      !Task.isCancelled,
                      loadGeneration == myLoadGen,
                      generation == editGeneration,
                      requestIdentity() == startIdentity else { return false }
                let message = ErrorState(error).message
                phase = .failed(message)
                saveError = message
                return false
            }
        }
        return false
    }

    /// Loads recipes, personal collections, and server collections for the `+ Add Row` picker.
    func loadPickerCatalogIfNeeded(force: Bool = false) async {
        let currentIdentity = requestIdentity()
        guard force || !hasLoadedPickerCatalog || pickerCatalogIdentity != currentIdentity else { return }
        pickerLoadGeneration += 1
        let myGen = pickerLoadGeneration
        let startIdentity = currentIdentity
        isLoadingPickerCatalog = true
        defer {
            if pickerLoadGeneration == myGen {
                isLoadingPickerCatalog = false
            }
        }

        async let recipesResult: Result<APIv2RecipeCatalog, Error> = {
            do { return .success(try await api.sectionRecipeCatalog()) }
            catch { return .failure(error) }
        }()
        async let personalResult: Result<CollectionsResponse, Error> = {
            do { return .success(try await api.collections()) }
            catch { return .failure(error) }
        }()
        async let librariesResult: Result<LibrariesResponse, Error> = {
            do { return .success(try await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: !force)) }
            catch { return .failure(error) }
        }()

        let (fetchedRecipes, fetchedPersonal, fetchedLibraries) = await (recipesResult, personalResult, librariesResult)
        guard !Task.isCancelled, pickerLoadGeneration == myGen, requestIdentity() == startIdentity else { return }

        var allSucceeded = true

        switch fetchedRecipes {
        case .success(let catalog) where !catalog.categories.isEmpty:
            recipeCatalog = catalog
        case .success:
            recipeCatalog = .curatedFallback
        case .failure:
            recipeCatalog = .curatedFallback
            allSucceeded = false
        }

        switch fetchedPersonal {
        case .success(let response):
            personalCollections = response.collections ?? []
            personalCollectionsError = nil
        case .failure(let error):
            personalCollections = []
            personalCollectionsError = ErrorState(error).message
            allSucceeded = false
        }

        switch fetchedLibraries {
        case .success(let response):
            let libraries = response.libraries
            availableLibraries = libraries
            var collected: [ServerCollectionOption] = []
            var libraryErrors = 0
            var firstLibraryError: Error?
            await withTaskGroup(of: Result<[ServerCollectionOption], Error>.self) { group in
                for library in libraries {
                    group.addTask { [api] in
                        do {
                            let response = try await api.libraryCollections(libraryId: library.id)
                            let mapped = response.collections.map { col in
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
                            return .success(mapped)
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await batch in group {
                    switch batch {
                    case .success(let options):
                        collected.append(contentsOf: options)
                    case .failure(let error):
                        libraryErrors += 1
                        if firstLibraryError == nil {
                            firstLibraryError = error
                        }
                    }
                }
            }
            guard !Task.isCancelled, pickerLoadGeneration == myGen, requestIdentity() == startIdentity else { return }
            var seen = Set<String>()
            serverCollections = collected
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if libraryErrors > 0 {
                serverCollectionsError = ErrorState(firstLibraryError ?? URLError(.cannotLoadFromNetwork)).message
                allSucceeded = false
            } else {
                serverCollectionsError = nil
            }
        case .failure(let error):
            serverCollections = []
            serverCollectionsError = ErrorState(error).message
            allSucceeded = false
        }

        hasLoadedPickerCatalog = allSucceeded
        pickerCatalogIdentity = allSucceeded ? startIdentity : nil
    }

    // MARK: - Queries

    static func matchesRecipe(
        _ row: APIv2ProfileSectionSetting,
        sectionType: String,
        params: [String: SettingJSONValue]
    ) -> Bool {
        guard row.sectionType.lowercased() == sectionType.lowercased() else { return false }
        if params.isEmpty { return row.config == nil || row.config?.isEmpty == true }
        return params.allSatisfy { key, val in row.config?[key] == val }
    }

    func isRecipeTypePresent(sectionType: String) -> Bool {
        rows.contains { !$0.hidden && $0.sectionType.lowercased() == sectionType.lowercased() }
    }

    func isRecipePresent(sectionType: String, params: [String: SettingJSONValue]) -> Bool {
        rows.contains { !$0.hidden && Self.matchesRecipe($0, sectionType: sectionType, params: params) }
    }

    func hasHiddenMatchingRecipe(sectionType: String, params: [String: SettingJSONValue]) -> Bool {
        rows.contains { $0.hidden && Self.matchesRecipe($0, sectionType: sectionType, params: params) }
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

    /// Reorders only the visible slots inside `list`, keeping every hidden row
    /// anchored at its original index so admin order is never perturbed.
    static func reorderVisibleSlots(
        in list: [APIv2ProfileSectionSetting],
        transform: (inout [APIv2ProfileSectionSetting]) -> Bool
    ) -> [APIv2ProfileSectionSetting]? {
        let visibleIndices = list.indices.filter { !list[$0].hidden }
        var visible = visibleIndices.map { list[$0] }
        let before = visible
        guard transform(&visible), visible != before else { return nil }
        var result = list
        for (slot, row) in zip(visibleIndices, visible) {
            result[slot] = row
        }
        return result
    }

    /// Reorders visible rows using List `.onMove` offsets while keeping hidden
    /// rows anchored in their original slots.
    @discardableResult
    func moveVisible(fromOffsets source: IndexSet, toOffset destination: Int) -> Task<Void, Never> {
        guard let next = Self.reorderVisibleSlots(in: committedRows, transform: { visible in
            visible.move(fromOffsets: source, toOffset: destination)
            return true
        }) else { return Task {} }
        return apply(next)
    }

    /// Slides a visible row by `offset` (e.g. -1 up, +1 down) within visible slots.
    @discardableResult
    func moveVisible(id: String, by offset: Int) -> Task<Void, Never> {
        guard let next = Self.reorderVisibleSlots(in: committedRows, transform: { visible in
            guard let index = visible.firstIndex(where: { $0.id == id }),
                  visible.indices.contains(index + offset) else { return false }
            visible.swapAt(index, index + offset)
            return true
        }) else { return Task {} }
        return apply(next)
    }

    /// Projects a dragged visible-row ID order onto `base` without altering
    /// visibility, membership, hidden-row slots, or rows restored after drag began.
    static func applyingVisibleOrder(
        _ orderedVisibleIds: [String],
        to base: [APIv2ProfileSectionSetting]
    ) -> [APIv2ProfileSectionSetting] {
        let draftSet = Set(orderedVisibleIds)
        // Reorder only the visible slots currently occupied by IDs in the draft
        // so rows restored since the drag started (e.g. a reverted hide) stay
        // anchored at their current indices.
        let targetSlots = base.indices.filter { !base[$0].hidden && draftSet.contains(base[$0].id) }
        let byId = Dictionary(uniqueKeysWithValues: targetSlots.map { (base[$0].id, base[$0]) })
        var placed = Set<String>()
        var reordered: [APIv2ProfileSectionSetting] = []
        reordered.reserveCapacity(targetSlots.count)
        for id in orderedVisibleIds {
            if let row = byId[id], placed.insert(id).inserted {
                reordered.append(row)
            }
        }
        var result = base
        for (slot, row) in zip(targetSlots, reordered) {
            result[slot] = row
        }
        return result
    }

    /// Reorders visible rows inside a separate drag draft so sibling cards
    /// spring-swap at 120Hz without firing a save per crossed slot or leaking
    /// uncommitted order into queued saves. Call `commitDraggedOrder()` on drop
    /// or `cancelDraggedOrder()` on cancellation.
    @discardableResult
    func swapVisibleDuringDrag(id: String, by offset: Int) -> Bool {
        guard phase == .loaded, !isResetting else { return false }
        var visible = visibleRows
        guard let index = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(index + offset) else { return false }
        visible.swapAt(index, index + offset)
        dragDraftVisibleOrder = visible.map(\.id)
        return true
    }

    /// Discards an active drag/grab draft without persisting it.
    func cancelDraggedOrder() {
        dragDraftVisibleOrder = nil
    }

    /// Persists the final order after a live drag or tvOS grab ends (no-op if unchanged).
    /// Applies only the dragged visible order onto the latest `committedRows`,
    /// never re-applying visibility or membership changes that settled concurrently.
    @discardableResult
    func commitDraggedOrder() -> Task<Void, Never> {
        guard let order = dragDraftVisibleOrder else { return Task {} }
        dragDraftVisibleOrder = nil
        let next = Self.applyingVisibleOrder(order, to: committedRows)
        return apply(next)
    }

    /// Moves any row to the top of the visible stack (keeping hidden rows anchored
    /// when the target is already visible, or unhiding and inserting at the top if hidden).
    @discardableResult
    func moveToTop(id: String) -> Task<Void, Never> {
        guard let index = committedRows.firstIndex(where: { $0.id == id }) else { return Task {} }
        if !committedRows[index].hidden {
            guard let next = Self.reorderVisibleSlots(in: committedRows, transform: { visible in
                guard let visibleIndex = visible.firstIndex(where: { $0.id == id }),
                      visibleIndex > 0 else { return false }
                let row = visible.remove(at: visibleIndex)
                visible.insert(row, at: 0)
                return true
            }) else { return Task {} }
            return apply(next)
        }
        var next = committedRows
        var row = next.remove(at: index)
        row.hidden = false
        next.insert(row, at: 0)
        return apply(next)
    }

    /// Moves a visible row to the bottom of the visible slots without moving hidden rows.
    @discardableResult
    func moveToBottom(id: String) -> Task<Void, Never> {
        guard let next = Self.reorderVisibleSlots(in: committedRows, transform: { visible in
            guard let index = visible.firstIndex(where: { $0.id == id }),
                  index < visible.count - 1 else { return false }
            let row = visible.remove(at: index)
            visible.append(row)
            return true
        }) else { return Task {} }
        return apply(next)
    }

    @discardableResult
    func setHidden(_ hidden: Bool, id: String) -> Task<Void, Never> {
        guard let index = committedRows.firstIndex(where: { $0.id == id }),
              committedRows[index].hidden != hidden else { return Task {} }
        var next = committedRows
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
           let existingIdx = committedRows.firstIndex(where: { row in
               row.hidden
                   && row.sectionType.lowercased() == sectionType.lowercased()
                   && row.displayTitle.caseInsensitiveCompare(title) == .orderedSame
                   && (nonEmptyConfig == nil
                       ? (row.config == nil || row.config?.isEmpty == true)
                       : nonEmptyConfig!.allSatisfy { row.config?[$0.key] == $0.value })
           }) {
            return setHidden(false, id: committedRows[existingIdx].id)
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
            position: committedRows.count,
            config: nonEmptyConfig
        )
        var next = committedRows
        next.append(newRow)
        return apply(next)
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
               in: committedRows
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
            position: committedRows.count,
            itemLimit: itemLimit,
            featured: featured
        )
        var next = committedRows
        next.append(newRow)
        return apply(next)
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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = trimmed.isEmpty
            ? AppLanguage.string(.collectionsTitle)
            : trimmed
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
            position: committedRows.count,
            config: ["collections": .array(entries)]
        )
        var next = committedRows
        next.append(newRow)
        return apply(next)
    }

    @discardableResult
    func removeCustomRow(id: String) -> Task<Void, Never> {
        guard let index = committedRows.firstIndex(where: { $0.id == id && $0.isCustom }) else { return Task {} }
        var next = committedRows
        next.remove(at: index)
        return apply(next)
    }

    /// Serializes a Home feed quick action's fresh layout read, mutation, and save
    /// so two rapid context-menu actions never supersede each other's read.
    func performQuickAction(
        _ mutation: @escaping @MainActor (HomeSectionsEditorModel) -> Task<Void, Never>
    ) async -> Bool {
        let previous = quickActionChain
        let task = Task<Bool, Never> { @MainActor in
            await previous?.value
            let loaded = await self.load()
            guard loaded, self.phase == .loaded else { return false }
            await mutation(self).value
            return self.saveError == nil
        }
        quickActionChain = Task { _ = await task.value }
        return await task.value
    }

    func resetToServerDefault() async {
        guard let auth, !isResetting, !isRefreshing, phase == .loaded else { return }
        let startIdentity = requestIdentity()
        isResetting = true
        dragDraftVisibleOrder = nil
        // Invalidate concurrent reads without bumping `editGeneration`, so a
        // prior queued PUT that fails can still restore `confirmedRows` if DELETE
        // also fails.
        loadGeneration += 1
        let previous = saveChain
        let task = Task { @MainActor in
            await previous?.value
            defer { self.isResetting = false }
            guard !Task.isCancelled, self.requestIdentity() == startIdentity else { return }
            do {
                try await self.api.resetProfileLayout(scope: self.scope, auth: auth)
                guard !Task.isCancelled, self.requestIdentity() == startIdentity else { return }
                // Invalidate pre-reset state immediately once the server accepts DELETE
                // so a failed reload can never resend pre-reset overrides.
                self.editGeneration += 1
                self.saved = []
                self.confirmedRows = []
                self.committedRows = []
                self.dragDraftVisibleOrder = nil
                self.hasLoadedFromServer = false
                self.phase = .loading
                self.saveError = nil
                Self.refreshScope(self.scope)
                await self.reloadAfterReset(expectedIdentity: startIdentity, preservingError: nil)
            } catch {
                guard self.requestIdentity() == startIdentity else { return }
                let message = ErrorState(error).message
                // DELETE may have reached the server even when the client receives
                // an error. Clear the pre-reset baseline and reconcile from the
                // server (keeping edits blocked if the reload also fails) so a
                // subsequent edit can never re-upload stale pre-reset overrides.
                self.editGeneration += 1
                self.saved = []
                self.confirmedRows = []
                self.committedRows = []
                self.dragDraftVisibleOrder = nil
                self.hasLoadedFromServer = false
                self.phase = .loading
                self.saveError = message
                Self.refreshScope(self.scope)
                await self.reloadAfterReset(expectedIdentity: startIdentity, preservingError: message)
            }
        }
        saveChain = task
        await task.value
    }

    private func reloadAfterReset(expectedIdentity: HTTPRequestIdentity?, preservingError: String?) async {
        loadGeneration += 1
        let myLoadGen = loadGeneration
        isRefreshing = true
        defer {
            if loadGeneration == myLoadGen {
                isRefreshing = false
            }
        }
        for attempt in 0..<3 {
            let startCacheToken = ResponseCache.shared.writeToken
            do {
                let layout = try await api.profileLayout(scope: scope)
                guard !Task.isCancelled, loadGeneration == myLoadGen, requestIdentity() == expectedIdentity else { return }
                if ResponseCache.shared.wasInvalidated(scopeCacheKey, after: startCacheToken) {
                    if attempt < 2 {
                        continue
                    }
                    let message = preservingError ?? ErrorState(URLError(.cannotLoadFromNetwork)).message
                    phase = .failed(message)
                    saveError = message
                    return
                }
                auth = layout.auth
                saved = layout.saved
                committedRows = layout.rows
                dragDraftVisibleOrder = nil
                confirmedRows = layout.rows
                hasLoadedFromServer = true
                saveError = preservingError
                phase = .loaded
                return
            } catch {
                guard !(error is CancellationError),
                      !Task.isCancelled,
                      loadGeneration == myLoadGen,
                      requestIdentity() == expectedIdentity else { return }
                let message = preservingError ?? ErrorState(error).message
                phase = .failed(message)
                saveError = message
                return
            }
        }
    }

    /// Re-fetches Home or Library feeds immediately.
    func triggerFeedRefresh() {
        Self.refreshScope(scope)
    }

    // MARK: - Persistence

    private func apply(_ next: [APIv2ProfileSectionSetting]) -> Task<Void, Never> {
        guard phase == .loaded, !isResetting, next != committedRows else { return Task {} }
        dragDraftVisibleOrder = nil
        committedRows = next
        saveError = nil
        editGeneration += 1
        let previous = saveChain
        let task = Task { @MainActor in
            await previous?.value
            await self.saveCurrentRows()
        }
        saveChain = task
        return task
    }

    private func saveCurrentRows() async {
        guard let auth, committedRows != confirmedRows else { return }
        let startIdentity = requestIdentity()
        let sent = committedRows
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
            guard requestIdentity() == startIdentity else { return }
            saved = overrides
            confirmedRows = sent
            saveError = nil
            Self.refreshScope(scope)
        } catch {
            guard requestIdentity() == startIdentity else { return }
            // Only revert committedRows if no newer edit superseded this save,
            // and never clobber an active drag draft.
            if editGeneration == sentGeneration {
                committedRows = confirmedRows
            }
            saveError = ErrorState(error).message
        }
    }

    static func refreshScope(_ scope: ProfileSectionsScope) {
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        if case .library(let libraryId) = scope {
            StartupContentPrefetcher.invalidateLibrarySectionsInFlight(libraryId: libraryId)
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

        var titleResource: LocalizedStringResource {
            switch self {
            case .combined: .settingsManifestUiNextUpModeOptionCombined
            case .separate: .homeCustomizeNextUpSeparate
            }
        }

        var title: String {
            AppLanguage.string(titleResource)
        }

        var subtitle: String {
            switch self {
            case .combined: AppLanguage.string(.homeCustomizeNextUpCombinedSubtitle)
            case .separate: AppLanguage.string(.homeCustomizeNextUpSeparateSubtitle)
            }
        }
    }

    var nextUpMode: NextUpMode = .combined
    var newReleasesFirst = false
    var hideWatchedItems = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    /// True only after both the contract capability probe and the effective-values
    /// read succeeded for the current server and profile.
    private struct KeyScope: Hashable {
        let identity: HTTPRequestIdentity
        let key: SettingKey

        func hash(into hasher: inout Hasher) {
            hasher.combine(identity.serverId)
            hasher.combine(identity.serverURL)
            hasher.combine(identity.profileId)
            hasher.combine(identity.clientFamily)
            hasher.combine(identity.localAccountId)
            hasher.combine(key)
        }
    }

    private(set) var isAuthorized = false
    private(set) var supportedKeys = Set<SettingKey>()
    private var reconcilingKeys = Set<KeyScope>()

    @ObservationIgnored private let transport: ProfileScopedSettingTransport
    @ObservationIgnored private let writer: ProfileSettingsWriter
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var loadedIdentity: HTTPRequestIdentity?
    @ObservationIgnored private var loadSequence = 0
    @ObservationIgnored private var confirmedNextUpMode: NextUpMode = .combined
    @ObservationIgnored private var confirmedNewReleasesFirst = false
    @ObservationIgnored private var confirmedHideWatchedItems = false
    @ObservationIgnored private var keyGeneration: [KeyScope: Int] = [:]
    @ObservationIgnored private var pendingWrites: [KeyScope: Int] = [:]
    @ObservationIgnored private var settledWrites: [KeyScope: Int] = [:]
    @ObservationIgnored private var uncertainConfirmedKeys = Set<KeyScope>()
    @ObservationIgnored private var keyWriteTail: [KeyScope: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeWriteCount = 0

    private static let preferenceKeys: [SettingKey] = [
        .uiNextUpMode,
        .uiNextUpNewReleasesFirst,
        .homeHideWatchedItems,
    ]

    init(
        transport: ProfileScopedSettingTransport = SiloProfileScopedSettingTransport(),
        writer: ProfileSettingsWriter = ProfileSettingsWriter(),
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.transport = transport
        self.writer = writer
        self.requestIdentity = requestIdentity
    }

    func canEdit(_ key: SettingKey) -> Bool {
        guard let identity = loadedIdentity, identity == requestIdentity() else { return false }
        return isAuthorized
            && supportedKeys.contains(key)
            && !reconcilingKeys.contains(KeyScope(identity: identity, key: key))
    }

    private func isAuthorizedForWrite(_ key: SettingKey, identity: HTTPRequestIdentity) -> Bool {
        isAuthorized
            && supportedKeys.contains(key)
            && loadedIdentity == identity
            && requestIdentity() == identity
            && !reconcilingKeys.contains(KeyScope(identity: identity, key: key))
    }

    func load() async {
        await load(preservingError: nil)
    }

    private func load(preservingError: String?) async {
        loadSequence += 1
        let sequence = loadSequence
        guard let identity = requestIdentity() else {
            isLoading = false
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
            errorMessage = nil
            return
        }
        if loadedIdentity != identity {
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
        }
        isLoading = true
        defer {
            if loadSequence == sequence {
                isLoading = false
            }
        }
        if preservingError == nil {
            errorMessage = nil
        }

        let capturedGenerations = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.map { key in
            let scope = KeyScope(identity: identity, key: key)
            return (key, keyGeneration[scope, default: 0])
        })
        let capturedSettled = Dictionary(uniqueKeysWithValues: Self.preferenceKeys.map { key in
            let scope = KeyScope(identity: identity, key: key)
            return (key, settledWrites[scope, default: 0])
        })
        let capabilitiesResult = await transport.contractCapabilities(requestIdentity: identity)
        guard !Task.isCancelled, loadSequence == sequence, requestIdentity() == identity else { return }

        guard case .available(let capabilities) = capabilitiesResult else {
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
            if case .failed(let err) = capabilitiesResult {
                errorMessage = preservingError ?? ErrorState(err).message
            }
            return
        }

        let keysSupportedByContract = Set(Self.preferenceKeys.filter { capabilities.supports($0) })
        guard !keysSupportedByContract.isEmpty else {
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
            return
        }

        do {
            let response = try await transport.effectiveValues(
                keys: Array(keysSupportedByContract),
                requestIdentity: identity
            )
            guard !Task.isCancelled, loadSequence == sequence, requestIdentity() == identity else { return }
            let byKey = response.byKey
            var resolvedKeys = Set<SettingKey>()

            func isUntouched(_ key: SettingKey) -> Bool {
                let scope = KeyScope(identity: identity, key: key)
                return keyGeneration[scope, default: 0] == capturedGenerations[key, default: 0]
                    && settledWrites[scope, default: 0] == capturedSettled[key, default: 0]
                    && pendingWrites[scope, default: 0] == 0
            }

            if keysSupportedByContract.contains(.uiNextUpMode), response.servesAll([.uiNextUpMode]) {
                resolvedKeys.insert(.uiNextUpMode)
                if isUntouched(.uiNextUpMode) {
                    let serverVal = byKey[.uiNextUpMode]?.value.stringValue.flatMap(NextUpMode.init(rawValue:)) ?? .combined
                    confirmedNextUpMode = serverVal
                    nextUpMode = serverVal
                    let scope = KeyScope(identity: identity, key: .uiNextUpMode)
                    uncertainConfirmedKeys.remove(scope)
                    reconcilingKeys.remove(scope)
                }
            }
            if keysSupportedByContract.contains(.uiNextUpNewReleasesFirst), response.servesAll([.uiNextUpNewReleasesFirst]) {
                resolvedKeys.insert(.uiNextUpNewReleasesFirst)
                if isUntouched(.uiNextUpNewReleasesFirst) {
                    let serverVal = byKey[.uiNextUpNewReleasesFirst]?.value.boolValue ?? false
                    confirmedNewReleasesFirst = serverVal
                    newReleasesFirst = serverVal
                    let scope = KeyScope(identity: identity, key: .uiNextUpNewReleasesFirst)
                    uncertainConfirmedKeys.remove(scope)
                    reconcilingKeys.remove(scope)
                }
            }
            if keysSupportedByContract.contains(.homeHideWatchedItems), response.servesAll([.homeHideWatchedItems]) {
                resolvedKeys.insert(.homeHideWatchedItems)
                if isUntouched(.homeHideWatchedItems) {
                    let serverVal = byKey[.homeHideWatchedItems]?.value.boolValue ?? false
                    confirmedHideWatchedItems = serverVal
                    hideWatchedItems = serverVal
                    let scope = KeyScope(identity: identity, key: .homeHideWatchedItems)
                    uncertainConfirmedKeys.remove(scope)
                    reconcilingKeys.remove(scope)
                }
            }

            loadedIdentity = identity
            supportedKeys = resolvedKeys
            isAuthorized = !resolvedKeys.isEmpty
            errorMessage = preservingError
            let needsReconciliation = resolvedKeys.contains { key in
                let scope = KeyScope(identity: identity, key: key)
                return reconcilingKeys.contains(scope) && pendingWrites[scope, default: 0] == 0
            }
            if needsReconciliation {
                Task { @MainActor [weak self] in
                    await self?.load(preservingError: preservingError)
                }
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, loadSequence == sequence, requestIdentity() == identity else { return }
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
            errorMessage = preservingError ?? ErrorState(error).message
        }
    }

    func setNextUpMode(_ mode: NextUpMode) {
        guard canEdit(.uiNextUpMode), mode != nextUpMode, let identity = loadedIdentity else { return }
        nextUpMode = mode
        enqueueWrite(
            key: .uiNextUpMode,
            value: .string(mode.rawValue),
            identity: identity,
            onConfirm: { self.confirmedNextUpMode = mode },
            onRevertToConfirmed: { self.nextUpMode = self.confirmedNextUpMode }
        )
    }

    func setNewReleasesFirst(_ enabled: Bool) {
        guard canEdit(.uiNextUpNewReleasesFirst), enabled != newReleasesFirst, let identity = loadedIdentity else { return }
        newReleasesFirst = enabled
        enqueueWrite(
            key: .uiNextUpNewReleasesFirst,
            value: .bool(enabled),
            identity: identity,
            onConfirm: { self.confirmedNewReleasesFirst = enabled },
            onRevertToConfirmed: { self.newReleasesFirst = self.confirmedNewReleasesFirst }
        )
    }

    func setHideWatchedItems(_ enabled: Bool) {
        guard canEdit(.homeHideWatchedItems), enabled != hideWatchedItems, let identity = loadedIdentity else { return }
        hideWatchedItems = enabled
        enqueueWrite(
            key: .homeHideWatchedItems,
            value: .bool(enabled),
            identity: identity,
            onConfirm: { self.confirmedHideWatchedItems = enabled },
            onRevertToConfirmed: { self.hideWatchedItems = self.confirmedHideWatchedItems }
        )
    }

    private func enqueueWrite(
        key: SettingKey,
        value: SettingJSONValue,
        identity: HTTPRequestIdentity,
        onConfirm: @escaping @MainActor () -> Void,
        onRevertToConfirmed: @escaping @MainActor () -> Void
    ) {
        let scope = KeyScope(identity: identity, key: key)
        let generation = keyGeneration[scope, default: 0] + 1
        keyGeneration[scope] = generation
        pendingWrites[scope, default: 0] += 1
        errorMessage = nil
        let previous = keyWriteTail[scope]
        keyWriteTail[scope] = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            var dispatched = false
            defer {
                self.pendingWrites[scope] = max(0, self.pendingWrites[scope, default: 0] - 1)
                if dispatched {
                    self.settledWrites[scope, default: 0] += 1
                }
            }
            // Skip obsolete writes superseded while waiting.
            guard self.keyGeneration[scope] == generation else { return }
            // If authorization was revoked while this latest intent was queued,
            // do not bump `settledWrites` (nothing reached the server) and keep
            // the key locked in `reconcilingKeys` until a recovery load installs
            // the authoritative server value.
            guard self.isAuthorizedForWrite(key, identity: identity) else {
                self.reconcilingKeys.insert(scope)
                return
            }
            dispatched = true
            self.activeWriteCount += 1
            self.isSaving = true
            defer {
                self.activeWriteCount = max(0, self.activeWriteCount - 1)
                self.isSaving = self.activeWriteCount > 0
            }
            do {
                try await self.writer.write(
                    key,
                    value: value,
                    profileId: identity.profileId,
                    isLatest: { [weak self] in
                        self?.keyGeneration[scope] == generation
                            && self?.isAuthorizedForWrite(key, identity: identity) == true
                    }
                )
                guard self.isAuthorizedForWrite(key, identity: identity) else { return }
                onConfirm()
                self.uncertainConfirmedKeys.remove(scope)
                self.reconcilingKeys.remove(scope)
                HomeSectionsEditorModel.refreshScope(.home)
            } catch is ProfileSettingsWriter.Superseded {
                // A superseded attempt may still have landed on the server;
                // mark the confirmed baseline uncertain until a newer write
                // succeeds or a fresh load reconciles the authoritative value.
                if self.requestIdentity() == identity, self.loadedIdentity == identity {
                    self.uncertainConfirmedKeys.insert(scope)
                }
                return
            } catch let held as ProfileSettingsWriter.HeldChange {
                // Automatic retries were exhausted and the server may already
                // hold the new value; mark the key uncertain, lock only this
                // key, and reconcile from the server instead of reverting to
                // a potentially stale confirmed baseline.
                guard self.keyGeneration[scope] == generation,
                      self.isAuthorizedForWrite(key, identity: identity) else { return }
                let message = ErrorState(held).message
                self.errorMessage = message
                self.uncertainConfirmedKeys.insert(scope)
                self.reconcilingKeys.insert(scope)
                Task { @MainActor [weak self] in
                    await self?.load(preservingError: message)
                }
            } catch {
                guard self.keyGeneration[scope] == generation,
                      self.isAuthorizedForWrite(key, identity: identity) else { return }
                let message = ErrorState(error).message
                self.errorMessage = message
                if self.uncertainConfirmedKeys.contains(scope) {
                    // Lock only this uncertain key until a fresh capability probe
                    // and authoritative effective-values read reconcile its value,
                    // without blocking confirmation of unrelated in-flight keys.
                    self.reconcilingKeys.insert(scope)
                    Task { @MainActor [weak self] in
                        await self?.load(preservingError: message)
                    }
                } else {
                    onRevertToConfirmed()
                }
            }
        }
    }
}
