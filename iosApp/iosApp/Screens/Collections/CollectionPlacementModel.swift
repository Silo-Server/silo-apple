import Foundation
import Observation

/// Manages pinning a personal or server collection onto Home and Library pages,
/// plus household sharing (`is_shared`) for personal collections.
@Observable
@MainActor
final class CollectionPlacementModel {
    struct LibraryPlacement: Identifiable, Hashable {
        let libraryId: Int
        let libraryName: String
        var isPinned: Bool
        var id: Int { libraryId }
    }

    let collectionId: String
    let collectionTitle: String
    let isUserCollection: Bool
    let sourceLibraryId: Int?

    private(set) var isPinnedOnHome = false
    private(set) var hasLoadedHome = false
    private(set) var libraryPlacements: [LibraryPlacement] = []
    private(set) var isShared = false
    private(set) var canToggleShare = false
    private(set) var isLoading = false
    private(set) var isUpdatingHome = false
    private(set) var updatingLibraryIds = Set<Int>()
    private(set) var isUpdatingShare = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var collectionVersion: CollectionEditVersion?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var homeMutationGeneration = 0
    @ObservationIgnored private var libraryMutationGeneration: [Int: Int] = [:]
    @ObservationIgnored private var shareMutationGeneration = 0

    init(
        collectionId: String,
        title: String,
        isUserCollection: Bool,
        sourceLibraryId: Int? = nil,
        api: SiloAPI = .shared,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.collectionId = collectionId
        self.collectionTitle = title
        self.isUserCollection = isUserCollection
        self.sourceLibraryId = sourceLibraryId
        self.api = api
        self.requestIdentity = requestIdentity
    }

    func load() async {
        loadGeneration += 1
        let myLoadGen = loadGeneration
        let startIdentity = requestIdentity()
        let startHomeGen = homeMutationGeneration
        let startShareGen = shareMutationGeneration
        let startLibGens = libraryMutationGeneration
        isLoading = true
        defer {
            if loadGeneration == myLoadGen {
                isLoading = false
            }
        }
        errorMessage = nil

        async let homeRead: Result<APIv2ProfileLayoutRead, Error> = {
            do { return .success(try await api.profileLayout(scope: .home)) }
            catch { return .failure(error) }
        }()
        async let librariesRead: LibrariesResponse? = try? await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: true)
        async let editorRead: CollectionEditor<UserCollection>? = isUserCollection
            ? (try? await api.collectionEditor(id: collectionId))
            : nil

        let (homeResult, librariesResponse, editor) = await (homeRead, librariesRead, editorRead)
        guard !Task.isCancelled, loadGeneration == myLoadGen, requestIdentity() == startIdentity else { return }

        switch homeResult {
        case .success(let home):
            if !isUpdatingHome && homeMutationGeneration == startHomeGen {
                isPinnedOnHome = ProfileHomeLayout.pinnedCollectionRow(
                    collectionId: collectionId,
                    isUserCollection: isUserCollection,
                    in: home.rows
                ) != nil
                hasLoadedHome = true
            }
        case .failure(let error):
            if !isUpdatingHome && homeMutationGeneration == startHomeGen {
                hasLoadedHome = false
                errorMessage = ErrorState(error).message
            }
        }

        if let editor, !isUpdatingShare && shareMutationGeneration == startShareGen {
            collectionVersion = editor.version
            isShared = editor.value.isShared ?? false
            canToggleShare = true
        }

        if let libraries = librariesResponse?.libraries {
            // For a server collection, surface its own library first (plus other video libraries).
            let relevant: [Library]
            if let sourceLibraryId, let owning = libraries.first(where: { $0.id == sourceLibraryId }) {
                relevant = [owning] + libraries.filter { $0.id != sourceLibraryId && ($0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary) }
            } else {
                relevant = libraries.filter { $0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary }
            }

            var placements: [LibraryPlacement] = []
            await withTaskGroup(of: (Library, APIv2ProfileLayoutRead?).self) { group in
                for lib in relevant {
                    group.addTask { [api] in
                        let layout = try? await api.profileLayout(scope: .library(lib.id))
                        return (lib, layout)
                    }
                }
                var fetched: [Int: (Library, APIv2ProfileLayoutRead?)] = [:]
                for await pair in group {
                    fetched[pair.0.id] = pair
                }
                guard !Task.isCancelled, loadGeneration == myLoadGen, requestIdentity() == startIdentity else { return }
                for lib in relevant {
                    let layout = fetched[lib.id]?.1
                    if updatingLibraryIds.contains(lib.id) || libraryMutationGeneration[lib.id] != startLibGens[lib.id],
                       let existing = libraryPlacements.first(where: { $0.libraryId == lib.id }) {
                        placements.append(existing)
                        continue
                    }
                    let pinned = layout.map {
                        ProfileHomeLayout.pinnedCollectionRow(
                            collectionId: collectionId,
                            isUserCollection: isUserCollection,
                            in: $0.rows
                        ) != nil
                    } ?? false
                    placements.append(LibraryPlacement(
                        libraryId: lib.id,
                        libraryName: lib.name,
                        isPinned: pinned
                    ))
                }
            }
            guard !Task.isCancelled, loadGeneration == myLoadGen, requestIdentity() == startIdentity else { return }
            libraryPlacements = placements
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func toggleHomePin() async {
        guard hasLoadedHome, !isLoading, !isUpdatingHome else { return }
        let startIdentity = requestIdentity()
        homeMutationGeneration += 1
        isUpdatingHome = true
        defer {
            homeMutationGeneration += 1
            isUpdatingHome = false
        }
        errorMessage = nil

        let targetPinned = !isPinnedOnHome
        isPinnedOnHome = targetPinned

        do {
            // Always re-read the current layout immediately before writing so
            // edits made elsewhere since this page opened are preserved.
            let layout = try await api.profileLayout(scope: .home)
            guard !Task.isCancelled, requestIdentity() == startIdentity else { return }
            let updated = try await applyPin(targetPinned, on: layout)
            guard requestIdentity() == startIdentity else { return }
            isPinnedOnHome = ProfileHomeLayout.pinnedCollectionRow(
                collectionId: collectionId,
                isUserCollection: isUserCollection,
                in: updated.rows
            ) != nil
            HomeSectionsEditorModel.refreshScope(.home)
        } catch {
            guard requestIdentity() == startIdentity else { return }
            isPinnedOnHome = !targetPinned
            errorMessage = ErrorState(error).message
        }
    }

    func toggleLibraryPin(libraryId: Int) async {
        guard !isLoading,
              !updatingLibraryIds.contains(libraryId),
              let idx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) else { return }
        let startIdentity = requestIdentity()
        libraryMutationGeneration[libraryId, default: 0] += 1
        updatingLibraryIds.insert(libraryId)
        defer {
            libraryMutationGeneration[libraryId, default: 0] += 1
            updatingLibraryIds.remove(libraryId)
        }
        errorMessage = nil

        let targetPinned = !libraryPlacements[idx].isPinned
        libraryPlacements[idx].isPinned = targetPinned

        do {
            let layout = try await api.profileLayout(scope: .library(libraryId))
            guard !Task.isCancelled, requestIdentity() == startIdentity else { return }
            let updated = try await applyPin(targetPinned, on: layout)
            guard requestIdentity() == startIdentity else { return }
            if let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                libraryPlacements[refreshedIdx].isPinned = ProfileHomeLayout.pinnedCollectionRow(
                    collectionId: collectionId,
                    isUserCollection: isUserCollection,
                    in: updated.rows
                ) != nil
            }
            HomeSectionsEditorModel.refreshScope(.library(libraryId))
        } catch {
            guard requestIdentity() == startIdentity else { return }
            if let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                libraryPlacements[refreshedIdx].isPinned = !targetPinned
            }
            errorMessage = ErrorState(error).message
        }
    }

    func toggleShared() async {
        guard isUserCollection, !isLoading, !isUpdatingShare else { return }
        let startIdentity = requestIdentity()
        shareMutationGeneration += 1
        let myShareGen = shareMutationGeneration
        isUpdatingShare = true
        defer {
            shareMutationGeneration += 1
            isUpdatingShare = false
        }
        errorMessage = nil

        let targetShared = !isShared
        isShared = targetShared

        do {
            let version: CollectionEditVersion
            if let existing = collectionVersion {
                version = existing
            } else {
                let editor = try await api.collectionEditor(id: collectionId)
                version = editor.version
            }
            let updated = try await api.setCollectionShared(version, isShared: targetShared)
            guard requestIdentity() == startIdentity, shareMutationGeneration == myShareGen else { return }
            isShared = updated.isShared ?? targetShared
            // Re-read editor to hold the fresh ETag for subsequent toggles.
            if let fresh = try? await api.collectionEditor(id: collectionId),
               requestIdentity() == startIdentity,
               shareMutationGeneration == myShareGen {
                collectionVersion = fresh.version
            } else if requestIdentity() == startIdentity, shareMutationGeneration == myShareGen {
                collectionVersion = nil
            }
        } catch {
            guard requestIdentity() == startIdentity, shareMutationGeneration == myShareGen else { return }
            isShared = !targetShared
            collectionVersion = nil
            errorMessage = ErrorState(error).message
        }
    }

    private func matchesThisCollection(_ row: APIv2ProfileSectionSetting) -> Bool {
        let type = row.sectionType.lowercased()
        guard type == "collection" || type == "user_collection" || type == "library_collection" else {
            return false
        }
        return isUserCollection
            ? row.userCollectionId == collectionId
            : row.libraryCollectionId == collectionId
    }

    private func applyPin(
        _ pinned: Bool,
        on layout: APIv2ProfileLayoutRead
    ) async throws -> APIv2ProfileLayoutRead {
        var nextRows = layout.rows
        if pinned {
            if nextRows.contains(where: { !$0.hidden && matchesThisCollection($0) }) {
                // Already visibly pinned.
            } else if let existingIdx = nextRows.firstIndex(where: { matchesThisCollection($0) }) {
                nextRows[existingIdx].hidden = false
            } else {
                let newRow = ProfileHomeLayout.makeCollectionRow(
                    title: collectionTitle,
                    collectionId: collectionId,
                    isUserCollection: isUserCollection,
                    position: nextRows.count
                )
                nextRows.append(newRow)
            }
        } else {
            // Unpin every visible matching row (removing custom rows and hiding admin rows)
            // so a preceding hidden duplicate never blocks unpinning the visible row.
            for idx in nextRows.indices.reversed() where !nextRows[idx].hidden && matchesThisCollection(nextRows[idx]) {
                if nextRows[idx].isCustom {
                    nextRows.remove(at: idx)
                } else {
                    nextRows[idx].hidden = true
                }
            }
        }

        let overrides = ProfileHomeLayout.overrides(
            rows: nextRows,
            baseline: layout.rows,
            saved: layout.saved
        )
        try await api.saveProfileLayout(overrides, scope: layout.scope, auth: layout.auth)
        return APIv2ProfileLayoutRead(
            auth: layout.auth,
            scope: layout.scope,
            rows: nextRows,
            saved: overrides
        )
    }
}

// MARK: - Add to Collection Model

/// Loads the acting profile's personal manual collections and tracks whether
/// a specific title (`contentId`) belongs to each via `catalogItemCollectionIds`,
/// supporting 1-tap toggle and inline creation of a new collection.
@Observable
@MainActor
final class AddToCollectionModel {
    struct Entry: Identifiable, Hashable {
        let collection: UserCollection
        var containsItem: Bool
        var itemCount: Int

        var id: String { collection.id }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.collection.id == rhs.collection.id
                && lhs.collection.name == rhs.collection.name
                && lhs.containsItem == rhs.containsItem
                && lhs.itemCount == rhs.itemCount
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(collection.id)
            hasher.combine(containsItem)
            hasher.combine(itemCount)
        }
    }

    let contentId: String

    private(set) var entries: [Entry] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var busyCollectionIds = Set<String>()
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    enum CreateResult: Equatable {
        case createdAndAdded
        case createdOnly
        case failed
    }

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var mutationGeneration = 0
    @ObservationIgnored private var pendingMutations = 0
    @ObservationIgnored private var entryGeneration: [String: Int] = [:]

    init(
        contentId: String,
        api: SiloAPI = .shared,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.contentId = contentId
        self.api = api
        self.requestIdentity = requestIdentity
    }

    func load() async {
        await load(preservingEntry: nil, preservingError: nil)
    }

    private func load(preservingEntry fallbackEntry: Entry?, preservingError: String?) async {
        loadGeneration += 1
        let myLoadGen = loadGeneration
        let startMutationGen = mutationGeneration
        let startIdentity = requestIdentity()
        isLoading = true
        defer {
            if loadGeneration == myLoadGen {
                isLoading = false
            }
        }
        if preservingError == nil {
            errorMessage = nil
        }

        do {
            async let collectionsTask = api.collections()
            async let membershipTask = api.catalogItemCollectionIds(itemId: contentId)
            let (response, memberCollectionIds) = try await (collectionsTask, membershipTask)
            guard !Task.isCancelled,
                  loadGeneration == myLoadGen,
                  pendingMutations == 0,
                  mutationGeneration == startMutationGen,
                  requestIdentity() == startIdentity else { return }

            let manual = (response.collections ?? []).filter { col in
                let kind = (col.collectionType ?? "manual").lowercased()
                return kind == "manual" || kind.isEmpty
            }

            var loaded = manual.map { col in
                Entry(
                    collection: col,
                    containsItem: memberCollectionIds.contains(col.id),
                    itemCount: col.itemCount ?? 0
                )
            }
            if let fallbackEntry, !loaded.contains(where: { $0.id == fallbackEntry.id }) {
                loaded.insert(fallbackEntry, at: 0)
            }
            entries = loaded
            hasLoaded = true
            errorMessage = preservingError
        } catch {
            guard !(error is CancellationError),
                  !Task.isCancelled,
                  loadGeneration == myLoadGen,
                  pendingMutations == 0,
                  mutationGeneration == startMutationGen,
                  requestIdentity() == startIdentity else { return }
            if hasLoaded {
                hasLoaded = false
                entries = fallbackEntry.map { [$0] } ?? []
            } else if let fallbackEntry, !entries.contains(where: { $0.id == fallbackEntry.id }) {
                entries.insert(fallbackEntry, at: 0)
            }
            errorMessage = preservingError ?? ErrorState(error).message
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func toggle(collectionId: String) async {
        guard !busyCollectionIds.contains(collectionId),
              let index = entries.firstIndex(where: { $0.id == collectionId }) else { return }
        let startIdentity = requestIdentity()
        pendingMutations += 1
        mutationGeneration += 1
        entryGeneration[collectionId, default: 0] += 1
        busyCollectionIds.insert(collectionId)
        defer {
            pendingMutations = max(0, pendingMutations - 1)
            mutationGeneration += 1
            busyCollectionIds.remove(collectionId)
        }
        errorMessage = nil

        let wasIn = entries[index].containsItem
        let nextIn = !wasIn
        entries[index].containsItem = nextIn
        entries[index].itemCount = max(0, entries[index].itemCount + (nextIn ? 1 : -1))

        do {
            if nextIn {
                try await api.addItemToCollection(collectionId: collectionId, itemId: contentId, position: 0)
            } else {
                try await api.removeItemFromCollection(collectionId: collectionId, itemId: contentId)
            }
            ResponseCache.shared.remove(CacheKey.collectionItems(collectionId))
            HomeSectionsEditorModel.refreshScope(.home)
        } catch {
            guard requestIdentity() == startIdentity else { return }
            if let idx = entries.firstIndex(where: { $0.id == collectionId }) {
                entries[idx].containsItem = wasIn
                entries[idx].itemCount = max(0, entries[idx].itemCount + (wasIn ? 1 : -1))
            }
            errorMessage = ErrorState(error).message
        }
    }

    @discardableResult
    func createAndAdd(name: String) async -> CreateResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating else { return .failed }
        let startIdentity = requestIdentity()
        pendingMutations += 1
        mutationGeneration += 1
        isCreating = true
        errorMessage = nil

        var createdCollectionId: String?
        let finishMutation = {
            if let createdCollectionId {
                self.busyCollectionIds.remove(createdCollectionId)
            }
            self.pendingMutations = max(0, self.pendingMutations - 1)
            self.mutationGeneration += 1
            self.isCreating = false
        }

        let created: UserCollection
        do {
            created = try await api.createCollection(name: trimmed)
        } catch {
            finishMutation()
            guard requestIdentity() == startIdentity else { return .failed }
            errorMessage = ErrorState(error).message
            return .failed
        }

        guard requestIdentity() == startIdentity else {
            finishMutation()
            return .failed
        }

        createdCollectionId = created.id
        busyCollectionIds.insert(created.id)
        let myEntryGen = entryGeneration[created.id, default: 0] + 1
        entryGeneration[created.id] = myEntryGen

        let baseCount = created.itemCount ?? 0
        var createdEntry = Entry(collection: created, containsItem: false, itemCount: baseCount)
        if !entries.contains(where: { $0.id == created.id }) {
            entries.insert(createdEntry, at: 0)
        }

        let result: CreateResult
        var addError: String?
        do {
            try await api.addItemToCollection(collectionId: created.id, itemId: contentId, position: 0)
            guard requestIdentity() == startIdentity else {
                finishMutation()
                return .failed
            }
            if entryGeneration[created.id] == myEntryGen {
                createdEntry.containsItem = true
                createdEntry.itemCount = max(1, baseCount + 1)
                if let idx = entries.firstIndex(where: { $0.id == created.id }) {
                    entries[idx] = createdEntry
                }
            }
            ResponseCache.shared.remove(CacheKey.collectionItems(created.id))
            HomeSectionsEditorModel.refreshScope(.home)
            result = .createdAndAdded
        } catch {
            guard requestIdentity() == startIdentity else {
                finishMutation()
                return .failed
            }
            let message = ErrorState(error).message
            addError = message
            errorMessage = message
            result = .createdOnly
        }

        finishMutation()

        // If creation overlapped or followed an incomplete initial load, reload
        // the full collection list before treating the picker as loaded while
        // preserving the newly created entry and any add-item error.
        if !hasLoaded {
            await load(preservingEntry: createdEntry, preservingError: addError)
        }
        return result
    }
}
