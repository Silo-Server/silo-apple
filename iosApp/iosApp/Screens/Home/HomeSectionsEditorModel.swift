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
        let collectionId: String
        let title: String
        let libraryId: Int
        let libraryName: String
        let itemCount: Int
        let posterUrl: String?
        let posterThumbhash: String?
        let isUserCollection: Bool

        var id: String { "\(isUserCollection ? "user" : "lib"):\(collectionId)" }
    }

    let scope: ProfileSectionsScope

    private(set) var phase: Phase = .loading
    /// Committed rows in display order, hidden rows included.
    private var committedRows: [APIv2ProfileSectionSetting] = []
    /// Live drag-reorder visible row IDs, projected onto `committedRows` so
    /// visibility or membership changes that settle during a drag are never overwritten.
    private var dragDraftVisibleOrder: [String]?
    /// The single row being dragged/grabbed so committing the drag replays only
    /// that row's placement without restoring an earlier rejected reorder.
    @ObservationIgnored private var draggedRowId: String?
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
    @ObservationIgnored private var pickerCatalogCacheToken: UInt64 = 0

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let newID: () -> String
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var auth: CapturedOrdinaryRequestAuth?
    @ObservationIgnored private var saved: [APIv2SectionOverride] = []
    @ObservationIgnored private var confirmedRows: [APIv2ProfileSectionSetting] = []
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var quickActionChain: Task<Void, Never>?
    @ObservationIgnored private var quickActionGeneration = 0
    @ObservationIgnored var onLoadWaitingForQuickActions: (@MainActor () -> Void)?
    @ObservationIgnored private var pendingSaveCount = 0
    @ObservationIgnored private var saveFailureCount = 0
    @ObservationIgnored private var acknowledgedFailureCount = 0
    @ObservationIgnored private var editGeneration = 0
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pickerLoadGeneration = 0

    private struct PendingEdit {
        let generation: Int
        let applyTo: ([APIv2ProfileSectionSetting]) -> [APIv2ProfileSectionSetting]?
    }
    @ObservationIgnored private var pendingEdits: [PendingEdit] = []
    @ObservationIgnored private var pendingEditsIdentity: HTTPRequestIdentity?

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

    /// Reads the layout once every queued quick action and save has landed.
    /// Returns `true` only when this call fetched and applied fresh server state.
    @discardableResult
    func load() async -> Bool {
        var quickGen: Int
        repeat {
            quickGen = quickActionGeneration
            if quickActionChain != nil {
                onLoadWaitingForQuickActions?()
            }
            await quickActionChain?.value
        } while quickGen != quickActionGeneration && !Task.isCancelled
        guard !Task.isCancelled else { return false }
        return await loadUnlocked()
    }

    @discardableResult
    private func loadUnlocked() async -> Bool {
        var generation: Int
        repeat {
            generation = editGeneration
            await saveChain?.value
        } while generation != editGeneration
        guard !Task.isCancelled else { return false }
        loadGeneration += 1
        let myLoadGen = loadGeneration
        let startIdentity = requestIdentity()
        phase = .loading
        if saveFailureCount <= acknowledgedFailureCount {
            saveError = nil
        }
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
                confirmedRows = layout.rows
                dragDraftVisibleOrder = nil
                hasLoadedFromServer = true
                if saveFailureCount <= acknowledgedFailureCount {
                    saveError = nil
                }
                phase = .loaded
                if pendingEditsIdentity == startIdentity, !pendingEdits.isEmpty {
                    let rebased = Self.reapply(pendingEdits, to: layout.rows)
                    committedRows = rebased
                    if rebased != confirmedRows {
                        pendingSaveCount += 1
                        let previous = saveChain
                        let task = Task { @MainActor in
                            defer { self.pendingSaveCount = max(0, self.pendingSaveCount - 1) }
                            await previous?.value
                            await self.saveCurrentRows()
                        }
                        saveChain = task
                    } else {
                        pendingEdits.removeAll()
                        pendingEditsIdentity = nil
                    }
                } else {
                    pendingEdits.removeAll()
                    pendingEditsIdentity = nil
                    committedRows = layout.rows
                }
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
        let collectionsInvalidated = hasLoadedPickerCatalog
            && ResponseCache.shared.wasInvalidated(CacheKey.collections, after: pickerCatalogCacheToken)
        guard force
            || !hasLoadedPickerCatalog
            || pickerCatalogIdentity != currentIdentity
            || collectionsInvalidated else { return }
        pickerLoadGeneration += 1
        let myGen = pickerLoadGeneration
        let startIdentity = currentIdentity
        isLoadingPickerCatalog = true
        defer {
            if pickerLoadGeneration == myGen {
                isLoadingPickerCatalog = false
            }
        }

        for attempt in 0..<3 {
            let startCacheToken = ResponseCache.shared.writeToken

            async let recipesResult: Result<APIv2RecipeCatalog, Error> = {
                do { return .success(try await api.sectionRecipeCatalog()) }
                catch { return .failure(error) }
            }()
            async let personalResult: Result<CollectionsResponse, Error> = {
                do { return .success(try await api.collections()) }
                catch { return .failure(error) }
            }()
            async let librariesResult: Result<LibrariesResponse, Error> = {
                do { return .success(try await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: !force && attempt == 0)) }
                catch { return .failure(error) }
            }()

            let (fetchedRecipes, fetchedPersonal, fetchedLibraries) = await (recipesResult, personalResult, librariesResult)
            guard !Task.isCancelled, pickerLoadGeneration == myGen, requestIdentity() == startIdentity else { return }

            var allSucceeded = true
            let nextRecipeCatalog: APIv2RecipeCatalog
            switch fetchedRecipes {
            case .success(let catalog) where !catalog.categories.isEmpty:
                nextRecipeCatalog = catalog
            case .success:
                nextRecipeCatalog = .curatedFallback
            case .failure:
                nextRecipeCatalog = hasLoadedPickerCatalog ? recipeCatalog : .curatedFallback
                allSucceeded = false
            }

            let nextPersonalCollections: [UserCollection]
            let nextPersonalError: String?
            switch fetchedPersonal {
            case .success(let response):
                nextPersonalCollections = response.collections ?? []
                nextPersonalError = nil
            case .failure(let error):
                nextPersonalCollections = []
                nextPersonalError = ErrorState(error).message
                allSucceeded = false
            }

            let nextAvailableLibraries: [Library]
            let nextServerCollections: [ServerCollectionOption]
            let nextServerError: String?
            switch fetchedLibraries {
            case .success(let response):
                let libraries = response.libraries
                nextAvailableLibraries = libraries
                var collected: [ServerCollectionOption] = []
                var libraryErrors = 0
                var firstLibraryError: Error?
                await withTaskGroup(of: Result<[ServerCollectionOption], Error>.self) { group in
                    for library in libraries {
                        group.addTask { [api] in
                            do {
                                let response = try await api.libraryCollections(libraryId: library.id)
                                // Preserve `isUserCollection` so household-shared personal
                                // collections surfaced inside a library's `user_collections`
                                // group remain addable and serialize as `user_collection_id`.
                                let mapped = response.collections.map { col in
                                    ServerCollectionOption(
                                        collectionId: col.id,
                                        title: col.name,
                                        libraryId: library.id,
                                        libraryName: library.name,
                                        itemCount: col.itemCount ?? 0,
                                        posterUrl: col.posterUrl,
                                        posterThumbhash: col.posterThumbhash,
                                        isUserCollection: col.kind == .userCollections
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
                let ownPersonalIds = Set(nextPersonalCollections.map(\.id))
                var seen = Set<String>()
                nextServerCollections = collected
                    .filter { option in
                        if option.isUserCollection && ownPersonalIds.contains(option.collectionId) {
                            return false
                        }
                        return seen.insert(option.id).inserted
                    }
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                if libraryErrors > 0 {
                    nextServerError = ErrorState(firstLibraryError ?? URLError(.cannotLoadFromNetwork)).message
                    allSucceeded = false
                } else {
                    nextServerError = nil
                }
            case .failure(let error):
                nextAvailableLibraries = []
                nextServerCollections = []
                nextServerError = ErrorState(error).message
                allSucceeded = false
            }

            if ResponseCache.shared.wasInvalidated(CacheKey.collections, after: startCacheToken) {
                if attempt < 2 {
                    continue
                }
                let retryMessage = ErrorState(URLError(.cannotLoadFromNetwork)).message
                hasLoadedPickerCatalog = false
                pickerCatalogIdentity = nil
                personalCollectionsError = retryMessage
                serverCollectionsError = retryMessage
                return
            }

            recipeCatalog = nextRecipeCatalog
            personalCollections = nextPersonalCollections
            personalCollectionsError = nextPersonalError
            availableLibraries = nextAvailableLibraries
            serverCollections = nextServerCollections
            serverCollectionsError = nextServerError
            hasLoadedPickerCatalog = allSucceeded
            pickerCatalogIdentity = allSucceeded ? startIdentity : nil
            pickerCatalogCacheToken = startCacheToken
            return
        }
    }

    // MARK: - Queries

    private static func normalizedRecipeConfig(
        _ config: [String: SettingJSONValue]?
    ) -> [String: SettingJSONValue]? {
        guard var config, !config.isEmpty else { return nil }
        if case .array(let values)? = config["filter_library_ids"] {
            let ints = values.compactMap { value -> Int? in
                if case .int(let n) = value { return n }
                return nil
            }
            if ints.count == values.count {
                let uniqueSorted = Array(Set(ints)).sorted().map { SettingJSONValue.int($0) }
                config["filter_library_ids"] = .array(uniqueSorted)
            }
        }
        return config
    }

    static func matchesRecipe(
        _ row: APIv2ProfileSectionSetting,
        sectionType: String,
        params: [String: SettingJSONValue]
    ) -> Bool {
        guard row.sectionType.lowercased() == sectionType.lowercased() else { return false }
        let rowConfig = normalizedRecipeConfig(row.config)
        let targetConfig = normalizedRecipeConfig(params)
        return rowConfig == targetConfig
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
        let visible = visibleRows
        let orderedIds = {
            var reordered = visible
            reordered.move(fromOffsets: source, toOffset: destination)
            return reordered.map(\.id)
        }()
        return applyEdit { rows in
            let next = Self.applyingVisibleOrder(orderedIds, to: rows)
            return next == rows ? nil : next
        }
    }

    /// Slides a visible row by `offset` (e.g. -1 up, +1 down) within visible slots,
    /// capturing the intended neighbor row so a replay after an earlier rejected
    /// save never substitutes a different neighbor at the same offset.
    @discardableResult
    func moveVisible(id: String, by offset: Int) -> Task<Void, Never> {
        let visible = visibleRows
        guard let index = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(index + offset) else { return Task {} }
        let targetId = visible[index + offset].id
        let movingDown = offset > 0
        return applyEdit { rows in
            Self.reorderVisibleSlots(in: rows, transform: { currentVisible in
                guard let fromIndex = currentVisible.firstIndex(where: { $0.id == id }),
                      let targetIndex = currentVisible.firstIndex(where: { $0.id == targetId }) else { return false }
                if movingDown {
                    guard fromIndex < targetIndex else { return false }
                    let row = currentVisible.remove(at: fromIndex)
                    currentVisible.insert(row, at: targetIndex)
                } else {
                    guard fromIndex > targetIndex else { return false }
                    let row = currentVisible.remove(at: fromIndex)
                    currentVisible.insert(row, at: targetIndex)
                }
                return true
            })
        }
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
        draggedRowId = id
        dragDraftVisibleOrder = visible.map(\.id)
        return true
    }

    /// Discards an active drag/grab draft without persisting it.
    func cancelDraggedOrder() {
        dragDraftVisibleOrder = nil
        draggedRowId = nil
    }

    /// Persists the final placement of the dragged row after a live drag or tvOS
    /// grab ends (no-op if unchanged). Replays only the dragged row's placement
    /// relative to its drop anchor so an earlier rejected reorder is never restored.
    @discardableResult
    func commitDraggedOrder() -> Task<Void, Never> {
        guard let order = dragDraftVisibleOrder else { return Task {} }
        let movedId = draggedRowId
        dragDraftVisibleOrder = nil
        draggedRowId = nil
        guard let movedId, let movedIndex = order.firstIndex(of: movedId) else {
            return applyEdit { rows in
                let next = Self.applyingVisibleOrder(order, to: rows)
                return next == rows ? nil : next
            }
        }
        let anchorAfterId = movedIndex + 1 < order.count ? order[movedIndex + 1] : nil
        let anchorBeforeId = movedIndex > 0 ? order[movedIndex - 1] : nil
        return applyEdit { rows in
            Self.reorderVisibleSlots(in: rows, transform: { currentVisible in
                guard let fromIndex = currentVisible.firstIndex(where: { $0.id == movedId }) else { return false }
                let row = currentVisible.remove(at: fromIndex)
                if let anchorAfterId,
                   let afterIndex = currentVisible.firstIndex(where: { $0.id == anchorAfterId }) {
                    currentVisible.insert(row, at: afterIndex)
                } else if let anchorBeforeId,
                          let beforeIndex = currentVisible.firstIndex(where: { $0.id == anchorBeforeId }) {
                    currentVisible.insert(row, at: beforeIndex + 1)
                } else {
                    currentVisible.insert(row, at: min(movedIndex, currentVisible.count))
                }
                return true
            })
        }
    }

    /// Moves any row to the top of the visible stack (keeping hidden rows anchored
    /// when the target is already visible, or unhiding and inserting at the top if hidden).
    @discardableResult
    func moveToTop(id: String) -> Task<Void, Never> {
        applyEdit { rows in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
            if !rows[index].hidden {
                return Self.reorderVisibleSlots(in: rows, transform: { visible in
                    guard let visibleIndex = visible.firstIndex(where: { $0.id == id }),
                          visibleIndex > 0 else { return false }
                    let row = visible.remove(at: visibleIndex)
                    visible.insert(row, at: 0)
                    return true
                })
            }
            var next = rows
            var row = next.remove(at: index)
            row.hidden = false
            next.insert(row, at: 0)
            return next
        }
    }

    /// Moves a visible row to the bottom of the visible slots without moving hidden rows.
    @discardableResult
    func moveToBottom(id: String) -> Task<Void, Never> {
        applyEdit { rows in
            Self.reorderVisibleSlots(in: rows, transform: { visible in
                guard let index = visible.firstIndex(where: { $0.id == id }),
                      index < visible.count - 1 else { return false }
                let row = visible.remove(at: index)
                visible.append(row)
                return true
            })
        }
    }

    @discardableResult
    func setHidden(_ hidden: Bool, id: String) -> Task<Void, Never> {
        applyEdit { rows in
            guard let index = rows.firstIndex(where: { $0.id == id }),
                  rows[index].hidden != hidden else { return nil }
            var next = rows
            next[index].hidden = hidden
            return next
        }
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
        // Capture any currently matching hidden row to prefer on replay; keep
        // the full Add intent so if an optimistic match rolls back, rebasing
        // still creates the requested row.
        let preferredId: String? = (!featured && itemLimit == 20)
            ? committedRows.first(where: { row in
                row.hidden
                    && Self.matchesRecipe(row, sectionType: sectionType, params: nonEmptyConfig ?? [:])
                    && row.displayTitle.caseInsensitiveCompare(title) == .orderedSame
            })?.id
            : nil
        let id = newID()
        return applyEdit { rows in
            if let preferredId, let existingIdx = rows.firstIndex(where: { $0.id == preferredId }) {
                guard rows[existingIdx].hidden else { return nil }
                var next = rows
                next[existingIdx].hidden = false
                return next
            }
            if !featured && itemLimit == 20,
               let existingIdx = rows.firstIndex(where: { row in
                   row.hidden
                       && Self.matchesRecipe(row, sectionType: sectionType, params: nonEmptyConfig ?? [:])
                       && row.displayTitle.caseInsensitiveCompare(title) == .orderedSame
               }) {
                var next = rows
                next[existingIdx].hidden = false
                return next
            }
            guard !rows.contains(where: { $0.id == id }) else { return nil }
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
            var next = rows
            next.append(newRow)
            return next
        }
    }

    @discardableResult
    func addCollectionRow(
        collectionId: String,
        title: String,
        isUserCollection: Bool,
        itemLimit: Int = 20,
        featured: Bool = false
    ) -> Task<Void, Never> {
        let preferredId: String? = {
            guard !featured && itemLimit == 20,
                  let existing = ProfileHomeLayout.matchingCollectionRow(
                      collectionId: collectionId,
                      isUserCollection: isUserCollection,
                      in: committedRows
                  ),
                  existing.hidden,
                  existing.displayTitle.caseInsensitiveCompare(title) == .orderedSame else {
                return nil
            }
            return existing.id
        }()
        let id = newID()
        return applyEdit { rows in
            if let preferredId, let existingIdx = rows.firstIndex(where: { $0.id == preferredId }) {
                guard rows[existingIdx].hidden else { return nil }
                var next = rows
                next[existingIdx].hidden = false
                return next
            }
            if !featured && itemLimit == 20,
               let existingIdx = rows.firstIndex(where: { row in
                   row.hidden
                       && ProfileHomeLayout.matchingCollectionRow(
                           collectionId: collectionId,
                           isUserCollection: isUserCollection,
                           in: [row]
                       ) != nil
                       && row.displayTitle.caseInsensitiveCompare(title) == .orderedSame
               }) {
                var next = rows
                next[existingIdx].hidden = false
                return next
            }
            guard !rows.contains(where: { $0.id == id }) else { return nil }
            let newRow = ProfileHomeLayout.makeCollectionRow(
                id: id,
                title: title,
                collectionId: collectionId,
                isUserCollection: isUserCollection,
                position: rows.count,
                itemLimit: itemLimit,
                featured: featured
            )
            var next = rows
            next.append(newRow)
            return next
        }
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
        let id = newID()
        return applyEdit { rows in
            guard !rows.contains(where: { $0.id == id }) else { return nil }
            let newRow = APIv2ProfileSectionSetting(
                id: id,
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
            var next = rows
            next.append(newRow)
            return next
        }
    }

    @discardableResult
    func removeCustomRow(id: String) -> Task<Void, Never> {
        applyEdit { rows in
            guard let index = rows.firstIndex(where: { $0.id == id && $0.isCustom }) else { return nil }
            var next = rows
            next.remove(at: index)
            return next
        }
    }

    struct QuickActionResult: Equatable, Sendable {
        let succeeded: Bool
        let errorMessage: String?
    }

    /// Serializes a Home feed quick action's fresh layout read, mutation, and save
    /// so two rapid context-menu actions never supersede each other's read, and
    /// aborts if the active profile/server changes before the mutation runs.
    func performQuickAction(
        _ mutation: @escaping @MainActor (HomeSectionsEditorModel) -> Task<Void, Never>
    ) async -> QuickActionResult {
        let requestedIdentity = requestIdentity()
        quickActionGeneration += 1
        let previous = quickActionChain
        let task = Task<QuickActionResult, Never> { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.requestIdentity() == requestedIdentity else {
                return QuickActionResult(succeeded: false, errorMessage: nil)
            }
            let loaded = await self.loadUnlocked()
            guard !Task.isCancelled,
                  loaded,
                  self.phase == .loaded,
                  self.requestIdentity() == requestedIdentity else {
                let message: String? = if self.requestIdentity() == requestedIdentity, !Task.isCancelled {
                    self.saveError ?? ErrorState(URLError(.cannotLoadFromNetwork)).message
                } else {
                    nil
                }
                return QuickActionResult(succeeded: false, errorMessage: message)
            }
            await mutation(self).value
            var gen: Int
            repeat {
                gen = self.editGeneration
                await self.saveChain?.value
            } while gen != self.editGeneration || self.pendingSaveCount > 0
            guard self.requestIdentity() == requestedIdentity else {
                return QuickActionResult(succeeded: false, errorMessage: nil)
            }
            let message = self.saveError
            return QuickActionResult(succeeded: message == nil, errorMessage: message)
        }
        quickActionChain = Task { _ = await task.value }
        return await task.value
    }

    /// Waits for any queued row saves to settle before closing Customize Mode.
    /// Returns `false` if any unacknowledged save failed (either right before
    /// Done or during the waited batch, even if a later save succeeded) so the
    /// editor stays open once to show the failure; a subsequent Done tap with no
    /// new failure acknowledges it and closes cleanly. Pass `acknowledgeFailureIf`
    /// to skip acknowledging when the caller will not display this editor's error.
    func waitForPendingSaves(acknowledgeFailureIf shouldAcknowledge: (() -> Bool)? = nil) async -> Bool {
        let failureCountAtTap = saveFailureCount
        var generation: Int
        repeat {
            generation = editGeneration
            await saveChain?.value
        } while generation != editGeneration || pendingSaveCount > 0
        if saveFailureCount > acknowledgedFailureCount || saveFailureCount > failureCountAtTap {
            if shouldAcknowledge?() ?? true {
                acknowledgedFailureCount = saveFailureCount
            }
            return false
        }
        return true
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
                self.auth = nil
                self.saved = []
                self.confirmedRows = []
                self.committedRows = []
                self.pendingEdits.removeAll()
                self.pendingEditsIdentity = nil
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
                self.auth = nil
                self.saved = []
                self.confirmedRows = []
                self.committedRows = []
                self.pendingEdits.removeAll()
                self.pendingEditsIdentity = nil
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
                confirmedRows = layout.rows
                if pendingEditsIdentity == expectedIdentity, !pendingEdits.isEmpty {
                    committedRows = Self.reapply(pendingEdits, to: layout.rows)
                } else {
                    pendingEdits.removeAll()
                    pendingEditsIdentity = nil
                    committedRows = layout.rows
                }
                dragDraftVisibleOrder = nil
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

    private static func reapply(
        _ edits: [PendingEdit],
        to base: [APIv2ProfileSectionSetting]
    ) -> [APIv2ProfileSectionSetting] {
        edits.reduce(base) { current, edit in
            edit.applyTo(current) ?? current
        }
    }

    private func applyEdit(
        _ transform: @escaping ([APIv2ProfileSectionSetting]) -> [APIv2ProfileSectionSetting]?
    ) -> Task<Void, Never> {
        guard phase == .loaded, !isResetting,
              let next = transform(committedRows),
              next != committedRows else { return Task {} }
        dragDraftVisibleOrder = nil
        committedRows = next
        if pendingSaveCount == 0 {
            saveError = nil
            acknowledgedFailureCount = saveFailureCount
        }
        editGeneration += 1
        let gen = editGeneration
        let identity = requestIdentity()
        if pendingEditsIdentity != identity {
            pendingEdits.removeAll()
            pendingEditsIdentity = identity
        }
        pendingEdits.append(PendingEdit(generation: gen, applyTo: transform))
        pendingSaveCount += 1
        let previous = saveChain
        let task = Task { @MainActor in
            defer { self.pendingSaveCount = max(0, self.pendingSaveCount - 1) }
            await previous?.value
            await self.saveCurrentRows()
        }
        saveChain = task
        return task
    }

    private func saveCurrentRows() async {
        guard phase == .loaded, hasLoadedFromServer, let auth else { return }
        guard committedRows != confirmedRows else {
            pendingEdits.removeAll { $0.generation <= editGeneration }
            if pendingEdits.isEmpty { pendingEditsIdentity = nil }
            return
        }
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
            pendingEdits.removeAll { $0.generation <= sentGeneration }
            if pendingEdits.isEmpty { pendingEditsIdentity = nil }
            if saveFailureCount == acknowledgedFailureCount {
                saveError = nil
            }
            Self.refreshScope(scope)
        } catch {
            guard requestIdentity() == startIdentity else { return }
            let message = ErrorState(error).message
            saveFailureCount += 1
            pendingEdits.removeAll { $0.generation <= sentGeneration }
            if pendingEdits.isEmpty { pendingEditsIdentity = nil }
            if APIv2MutationOutcome(error).mayHaveApplied {
                // PUT may have committed on the server before the response was
                // lost; clear the stale baseline and reconcile from the server
                // without invalidating or discarding newer queued edits. Any
                // edits newer than `sentGeneration` stay in `pendingEdits`, get
                // rebased over the authoritative reload, and are sent by the
                // next queued save in `saveChain`.
                self.auth = nil
                saved = []
                confirmedRows = []
                if pendingEdits.isEmpty {
                    committedRows = []
                }
                dragDraftVisibleOrder = nil
                hasLoadedFromServer = false
                phase = .loading
                saveError = message
                Self.refreshScope(scope)
                await reloadAfterReset(expectedIdentity: startIdentity, preservingError: message)
            } else {
                // Definite rejection: restore confirmedRows (or rebase newer
                // queued edits onto confirmedRows) without clobbering an active
                // drag draft.
                if editGeneration == sentGeneration {
                    committedRows = confirmedRows
                } else {
                    committedRows = Self.reapply(pendingEdits, to: confirmedRows)
                }
                saveError = message
            }
        }
    }

    enum RefreshNotificationKey {
        static let libraryId = "libraryId"
        static let collectionId = "collectionId"
    }

    static func refreshScope(_ scope: ProfileSectionsScope) {
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        var userInfo: [AnyHashable: Any]? = nil
        if case .library(let libraryId) = scope {
            StartupContentPrefetcher.invalidateLibrarySectionsInFlight(libraryId: libraryId)
            ResponseCache.shared.remove(CacheKey.librarySections(libraryId))
            userInfo = [RefreshNotificationKey.libraryId: libraryId]
        }
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil, userInfo: userInfo)
    }

    /// Invalidates Home and all Library section reads/caches when collection
    /// membership changes and notifies mounted feeds (which coalesce or defer
    /// reloads when off-screen).
    static func refreshCollectionMembership(collectionId: String) {
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        StartupContentPrefetcher.invalidateAllLibrarySectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        ResponseCache.shared.removeAll(withPrefix: "library:")
        NotificationCenter.default.post(
            name: .homeSectionsShouldRefresh,
            object: nil,
            userInfo: [RefreshNotificationKey.collectionId: collectionId]
        )
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
    private(set) var queuedWriteCount = 0
    private(set) var recoveryLoadCount = 0
    private(set) var errorMessage: String?

    var hasPendingWrites: Bool { queuedWriteCount > 0 || recoveryLoadCount > 0 }
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

    private struct DeferredWrite {
        let generation: Int
        let value: SettingJSONValue
    }

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
    @ObservationIgnored private var deferredWrites: [KeyScope: DeferredWrite] = [:]
    @ObservationIgnored private var keyWriteTail: [KeyScope: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeWriteCount = 0
    @ObservationIgnored private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var writeFailureCount = 0
    @ObservationIgnored private var acknowledgedFailureCount = 0

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

    var hasReconcilingKeys: Bool {
        guard let identity = requestIdentity() else { return false }
        return reconcilingKeys.contains { $0.identity == identity }
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

        let startWriteFailureCount = writeFailureCount
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
            switch capabilitiesResult {
            case .unavailable, .serverUpgradeRequired:
                // Server authoritatively does not support profile-scoped settings;
                // drop any owed writes and release locks for this identity.
                for key in Self.preferenceKeys {
                    let scope = KeyScope(identity: identity, key: key)
                    deferredWrites.removeValue(forKey: scope)
                    reconcilingKeys.remove(scope)
                }
            case .failed(let err):
                if writeFailureCount == startWriteFailureCount {
                    errorMessage = preservingError ?? ErrorState(err).message
                }
                if deferredWrites.contains(where: { $0.key.identity == identity })
                    || reconcilingKeys.contains(where: { $0.identity == identity }) {
                    writeFailureCount += 1
                }
            case .available:
                break
            }
            return
        }

        let keysSupportedByContract = Set(Self.preferenceKeys.filter { capabilities.supports($0) })
        guard !keysSupportedByContract.isEmpty else {
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
            for key in Self.preferenceKeys {
                let scope = KeyScope(identity: identity, key: key)
                deferredWrites.removeValue(forKey: scope)
                reconcilingKeys.remove(scope)
            }
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
            var deferredToDispatch: [(SettingKey, DeferredWrite)] = []

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
                    let scope = KeyScope(identity: identity, key: .uiNextUpMode)
                    uncertainConfirmedKeys.remove(scope)
                    reconcilingKeys.remove(scope)
                    if let deferred = deferredWrites.removeValue(forKey: scope),
                       deferred.generation == keyGeneration[scope] {
                        deferredToDispatch.append((.uiNextUpMode, deferred))
                    } else {
                        nextUpMode = serverVal
                    }
                }
            }
            if keysSupportedByContract.contains(.uiNextUpNewReleasesFirst), response.servesAll([.uiNextUpNewReleasesFirst]) {
                resolvedKeys.insert(.uiNextUpNewReleasesFirst)
                if isUntouched(.uiNextUpNewReleasesFirst) {
                    let serverVal = byKey[.uiNextUpNewReleasesFirst]?.value.boolValue ?? false
                    confirmedNewReleasesFirst = serverVal
                    let scope = KeyScope(identity: identity, key: .uiNextUpNewReleasesFirst)
                    uncertainConfirmedKeys.remove(scope)
                    reconcilingKeys.remove(scope)
                    if let deferred = deferredWrites.removeValue(forKey: scope),
                       deferred.generation == keyGeneration[scope] {
                        deferredToDispatch.append((.uiNextUpNewReleasesFirst, deferred))
                    } else {
                        newReleasesFirst = serverVal
                    }
                }
            }
            if keysSupportedByContract.contains(.homeHideWatchedItems), response.servesAll([.homeHideWatchedItems]) {
                resolvedKeys.insert(.homeHideWatchedItems)
                if isUntouched(.homeHideWatchedItems) {
                    let serverVal = byKey[.homeHideWatchedItems]?.value.boolValue ?? false
                    confirmedHideWatchedItems = serverVal
                    let scope = KeyScope(identity: identity, key: .homeHideWatchedItems)
                    uncertainConfirmedKeys.remove(scope)
                    reconcilingKeys.remove(scope)
                    if let deferred = deferredWrites.removeValue(forKey: scope),
                       deferred.generation == keyGeneration[scope] {
                        deferredToDispatch.append((.homeHideWatchedItems, deferred))
                    } else {
                        hideWatchedItems = serverVal
                    }
                }
            }

            for key in Self.preferenceKeys where !resolvedKeys.contains(key) {
                let scope = KeyScope(identity: identity, key: key)
                deferredWrites.removeValue(forKey: scope)
                reconcilingKeys.remove(scope)
            }

            loadedIdentity = identity
            supportedKeys = resolvedKeys
            isAuthorized = !resolvedKeys.isEmpty
            let hadNewerWriteFailure = writeFailureCount != startWriteFailureCount
            if !hadNewerWriteFailure {
                errorMessage = preservingError
                if preservingError == nil && deferredToDispatch.isEmpty {
                    acknowledgedFailureCount = writeFailureCount
                }
            }

            for (key, deferred) in deferredToDispatch {
                applyOptimistic(deferred.value, for: key)
                enqueueWrite(
                    key: key,
                    value: deferred.value,
                    identity: identity
                )
            }

            let needsReconciliation = resolvedKeys.contains { key in
                let scope = KeyScope(identity: identity, key: key)
                return reconcilingKeys.contains(scope) && pendingWrites[scope, default: 0] == 0
            }
            if needsReconciliation {
                scheduleRecoveryLoad(
                    for: identity,
                    preservingError: hadNewerWriteFailure ? errorMessage : preservingError
                )
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, loadSequence == sequence, requestIdentity() == identity else { return }
            isAuthorized = false
            supportedKeys = []
            loadedIdentity = nil
            if writeFailureCount == startWriteFailureCount {
                errorMessage = preservingError ?? ErrorState(error).message
            }
            if deferredWrites.contains(where: { $0.key.identity == identity })
                || reconcilingKeys.contains(where: { $0.identity == identity }) {
                writeFailureCount += 1
            }
        }
    }

    private func applyOptimistic(_ value: SettingJSONValue, for key: SettingKey) {
        switch key {
        case .uiNextUpMode:
            if let mode = value.stringValue.flatMap(NextUpMode.init(rawValue:)) {
                nextUpMode = mode
            }
        case .uiNextUpNewReleasesFirst:
            if let enabled = value.boolValue {
                newReleasesFirst = enabled
            }
        case .homeHideWatchedItems:
            if let enabled = value.boolValue {
                hideWatchedItems = enabled
            }
        default:
            break
        }
    }

    private func confirm(_ value: SettingJSONValue, for key: SettingKey) {
        switch key {
        case .uiNextUpMode:
            if let mode = value.stringValue.flatMap(NextUpMode.init(rawValue:)) {
                confirmedNextUpMode = mode
            }
        case .uiNextUpNewReleasesFirst:
            if let enabled = value.boolValue {
                confirmedNewReleasesFirst = enabled
            }
        case .homeHideWatchedItems:
            if let enabled = value.boolValue {
                confirmedHideWatchedItems = enabled
            }
        default:
            break
        }
    }

    private func revertToConfirmed(for key: SettingKey) {
        switch key {
        case .uiNextUpMode:
            nextUpMode = confirmedNextUpMode
        case .uiNextUpNewReleasesFirst:
            newReleasesFirst = confirmedNewReleasesFirst
        case .homeHideWatchedItems:
            hideWatchedItems = confirmedHideWatchedItems
        default:
            break
        }
    }

    func setNextUpMode(_ mode: NextUpMode) {
        guard canEdit(.uiNextUpMode), mode != nextUpMode, let identity = loadedIdentity else { return }
        nextUpMode = mode
        enqueueWrite(
            key: .uiNextUpMode,
            value: .string(mode.rawValue),
            identity: identity
        )
    }

    func setNewReleasesFirst(_ enabled: Bool) {
        guard canEdit(.uiNextUpNewReleasesFirst), enabled != newReleasesFirst, let identity = loadedIdentity else { return }
        newReleasesFirst = enabled
        enqueueWrite(
            key: .uiNextUpNewReleasesFirst,
            value: .bool(enabled),
            identity: identity
        )
    }

    func setHideWatchedItems(_ enabled: Bool) {
        guard canEdit(.homeHideWatchedItems), enabled != hideWatchedItems, let identity = loadedIdentity else { return }
        hideWatchedItems = enabled
        enqueueWrite(
            key: .homeHideWatchedItems,
            value: .bool(enabled),
            identity: identity
        )
    }

    /// Waits for any queued preference writes (including recovery loads and
    /// retried deferred writes) to settle before closing Options.
    /// Returns `false` once when any unacknowledged write failed so the user
    /// sees `errorMessage`; a subsequent Done tap with no new failure closes cleanly.
    func waitForPendingWrites() async -> Bool {
        let failureCountAtTap = writeFailureCount
        while queuedWriteCount > 0 || recoveryLoadCount > 0 {
            await withCheckedContinuation { continuation in
                writeWaiters.append(continuation)
            }
        }
        if writeFailureCount > acknowledgedFailureCount || writeFailureCount > failureCountAtTap {
            acknowledgedFailureCount = writeFailureCount
            return false
        }
        return true
    }

    private func resumeWriteWaitersIfIdle() {
        guard queuedWriteCount == 0, recoveryLoadCount == 0, !writeWaiters.isEmpty else { return }
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func scheduleRecoveryLoad(
        for expectedIdentity: HTTPRequestIdentity,
        preservingError: String?
    ) {
        recoveryLoadCount += 1
        Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.recoveryLoadCount = max(0, self.recoveryLoadCount - 1)
                    self.resumeWriteWaitersIfIdle()
                }
            }
            guard let self, self.requestIdentity() == expectedIdentity else { return }
            await self.load(preservingError: preservingError)
        }
    }

    private func enqueueWrite(
        key: SettingKey,
        value: SettingJSONValue,
        identity: HTTPRequestIdentity
    ) {
        let scope = KeyScope(identity: identity, key: key)
        let generation = keyGeneration[scope, default: 0] + 1
        keyGeneration[scope] = generation
        deferredWrites.removeValue(forKey: scope)
        if queuedWriteCount == 0 && recoveryLoadCount == 0 {
            errorMessage = nil
            acknowledgedFailureCount = writeFailureCount
        }
        queuedWriteCount += 1
        pendingWrites[scope, default: 0] += 1
        let previous = keyWriteTail[scope]
        keyWriteTail[scope] = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            var dispatched = false
            var shouldScheduleRecoveryLoad = false
            defer {
                self.pendingWrites[scope] = max(0, self.pendingWrites[scope, default: 0] - 1)
                if dispatched {
                    self.settledWrites[scope, default: 0] += 1
                }
                if shouldScheduleRecoveryLoad, self.requestIdentity() == identity {
                    // Increment `recoveryLoadCount` before decrementing `queuedWriteCount`
                    // so Done never observes an idle gap before the recovery load retries
                    // an owed deferred write.
                    self.scheduleRecoveryLoad(for: identity, preservingError: self.errorMessage)
                }
                self.queuedWriteCount = max(0, self.queuedWriteCount - 1)
                self.resumeWriteWaitersIfIdle()
            }
            // Skip obsolete writes superseded while waiting.
            guard self.keyGeneration[scope] == generation else { return }
            // If authorization is temporarily unavailable (including after a
            // profile switch or while this key is reconciling), retain the
            // user's latest intent as pure data partitioned by `scope`, lock
            // the key, and schedule a recovery load if `identity` is still
            // active. Once `load()` confirms authorization for `identity`, it
            // retries this owed write automatically.
            guard self.isAuthorizedForWrite(key, identity: identity) else {
                self.deferredWrites[scope] = DeferredWrite(
                    generation: generation,
                    value: value
                )
                self.reconcilingKeys.insert(scope)
                if self.requestIdentity() == identity {
                    shouldScheduleRecoveryLoad = true
                }
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
                    requestIdentity: identity,
                    isLatest: { [weak self] in
                        self?.keyGeneration[scope] == generation
                            && self?.isAuthorizedForWrite(key, identity: identity) == true
                    }
                )
                if self.requestIdentity() == identity {
                    HomeSectionsEditorModel.refreshScope(.home)
                }
                guard self.isAuthorizedForWrite(key, identity: identity) else {
                    self.reconcilingKeys.insert(scope)
                    if self.requestIdentity() == identity {
                        shouldScheduleRecoveryLoad = true
                    }
                    return
                }
                self.confirm(value, for: key)
                self.uncertainConfirmedKeys.remove(scope)
                self.reconcilingKeys.remove(scope)
            } catch is ProfileSettingsWriter.Superseded {
                // A superseded attempt may still have landed on the server;
                // mark the confirmed baseline uncertain until a newer write
                // succeeds or a fresh load reconciles the authoritative value.
                // When no newer write exists for this key (e.g. authorization
                // dropped mid-backoff), lock the key and schedule reconciliation
                // so a Retry load cannot re-enable editing over unsaved state.
                self.uncertainConfirmedKeys.insert(scope)
                guard self.keyGeneration[scope] == generation else { return }
                self.reconcilingKeys.insert(scope)
                if self.requestIdentity() == identity {
                    shouldScheduleRecoveryLoad = true
                }
                return
            } catch let held as ProfileSettingsWriter.HeldChange {
                // Automatic retries were exhausted and the server may already
                // hold the new value; record uncertainty even if a newer write
                // superseded this generation, and lock + reconcile if latest.
                self.uncertainConfirmedKeys.insert(scope)
                guard self.keyGeneration[scope] == generation else { return }
                let message = ErrorState(held).message
                self.reconcilingKeys.insert(scope)
                if self.requestIdentity() == identity {
                    self.writeFailureCount += 1
                    self.errorMessage = message
                    shouldScheduleRecoveryLoad = true
                }
            } catch {
                guard self.keyGeneration[scope] == generation else { return }
                let message = ErrorState(error).message
                if self.requestIdentity() == identity {
                    self.writeFailureCount += 1
                    self.errorMessage = message
                }
                if !self.isAuthorizedForWrite(key, identity: identity)
                    || self.uncertainConfirmedKeys.contains(scope) {
                    // Authorization was unavailable when this rejection arrived
                    // (so an in-flight recovery read may skip installing this key
                    // because `settledWrites` incremented), or an earlier write
                    // left server state uncertain. Lock the key in `reconcilingKeys`
                    // so it cannot become editable with a stale optimistic value
                    // before an authoritative reload reconciles it.
                    self.reconcilingKeys.insert(scope)
                    if self.requestIdentity() == identity {
                        shouldScheduleRecoveryLoad = true
                    }
                } else {
                    self.revertToConfirmed(for: key)
                }
            }
        }
    }
}
