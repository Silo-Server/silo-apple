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
        var hasLoaded: Bool = true
        var id: Int { libraryId }
    }

    var hasFailedLibraryPlacement: Bool {
        libraryDiscoveryFailed || libraryPlacements.contains { !$0.hasLoaded }
    }

    var hasFailedLoad: Bool {
        !hasLoadedHome || hasFailedLibraryPlacement || shareLoadFailed
    }

    let collectionId: String
    let collectionTitle: String
    let isUserCollection: Bool
    let sourceLibraryId: Int?

    private(set) var isPinnedOnHome = false
    private(set) var hasLoadedHome = false
    private(set) var libraryPlacements: [LibraryPlacement] = []
    private(set) var libraryDiscoveryFailed = false
    private(set) var isShared = false
    private(set) var canToggleShare = false
    private(set) var shareLoadFailed = false
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
        async let librariesRead: Result<LibrariesResponse, Error> = {
            do { return .success(try await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: true)) }
            catch { return .failure(error) }
        }()
        async let editorRead: Result<CollectionEditor<UserCollection>, Error>? = isUserCollection
            ? await {
                do { return .success(try await api.collectionEditor(id: collectionId)) }
                catch { return .failure(error) }
            }()
            : nil

        let (homeResult, librariesResult, editorResult) = await (homeRead, librariesRead, editorRead)
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

        if let editorResult, !isUpdatingShare && shareMutationGeneration == startShareGen {
            switch editorResult {
            case .success(let editor):
                collectionVersion = editor.version
                isShared = editor.value.isShared ?? false
                canToggleShare = true
                shareLoadFailed = false
            case .failure:
                collectionVersion = nil
                canToggleShare = false
                shareLoadFailed = true
            }
        }

        switch librariesResult {
        case .success(let librariesResponse):
            libraryDiscoveryFailed = false
            let libraries = librariesResponse.libraries
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
                        isPinned: pinned,
                        hasLoaded: layout != nil
                    ))
                }
            }
            guard !Task.isCancelled, loadGeneration == myLoadGen, requestIdentity() == startIdentity else { return }
            libraryPlacements = placements
        case .failure:
            libraryDiscoveryFailed = true
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
            let message = ErrorState(error).message
            if APIv2MutationOutcome(error).mayHaveApplied {
                HomeSectionsEditorModel.refreshScope(.home)
                if let fresh = try? await api.profileLayout(scope: .home),
                   requestIdentity() == startIdentity {
                    isPinnedOnHome = ProfileHomeLayout.pinnedCollectionRow(
                        collectionId: collectionId,
                        isUserCollection: isUserCollection,
                        in: fresh.rows
                    ) != nil
                    hasLoadedHome = true
                } else if requestIdentity() == startIdentity {
                    isPinnedOnHome = false
                    hasLoadedHome = false
                }
            } else {
                isPinnedOnHome = !targetPinned
            }
            errorMessage = message
        }
    }

    func toggleLibraryPin(libraryId: Int) async {
        guard !isLoading,
              !updatingLibraryIds.contains(libraryId),
              let idx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }),
              libraryPlacements[idx].hasLoaded else { return }
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
            let message = ErrorState(error).message
            if APIv2MutationOutcome(error).mayHaveApplied {
                HomeSectionsEditorModel.refreshScope(.library(libraryId))
                if let fresh = try? await api.profileLayout(scope: .library(libraryId)),
                   requestIdentity() == startIdentity,
                   let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                    libraryPlacements[refreshedIdx].isPinned = ProfileHomeLayout.pinnedCollectionRow(
                        collectionId: collectionId,
                        isUserCollection: isUserCollection,
                        in: fresh.rows
                    ) != nil
                    libraryPlacements[refreshedIdx].hasLoaded = true
                } else if requestIdentity() == startIdentity,
                          let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                    libraryPlacements[refreshedIdx].isPinned = false
                    libraryPlacements[refreshedIdx].hasLoaded = false
                }
            } else if let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                libraryPlacements[refreshedIdx].isPinned = !targetPinned
            }
            errorMessage = message
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
                isShared = fresh.value.isShared ?? isShared
                shareLoadFailed = false
            } else if requestIdentity() == startIdentity, shareMutationGeneration == myShareGen {
                collectionVersion = nil
            }
        } catch {
            guard requestIdentity() == startIdentity, shareMutationGeneration == myShareGen else { return }
            if let fresh = try? await api.collectionEditor(id: collectionId),
               requestIdentity() == startIdentity,
               shareMutationGeneration == myShareGen {
                collectionVersion = fresh.version
                isShared = fresh.value.isShared ?? !targetShared
                shareLoadFailed = false
            } else if requestIdentity() == startIdentity, shareMutationGeneration == myShareGen {
                isShared = !targetShared
                collectionVersion = nil
                if APIv2MutationOutcome(error).mayHaveApplied {
                    canToggleShare = false
                    shareLoadFailed = true
                }
            }
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
    /// True after a collection creation request failed with an ambiguous outcome
    /// (response lost; server may have created it) until a list reread settles.
    private(set) var hasUncertainCreation = false
    private(set) var errorMessage: String?

    enum CreateResult: Equatable {
        case createdAndAdded
        case createdOnly
        case uncertain
        case failed
    }

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private let requestIdentity: @MainActor () -> HTTPRequestIdentity?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var mutationGeneration = 0
    @ObservationIgnored private var pendingMutations = 0
    @ObservationIgnored private var entryGeneration: [String: Int] = [:]
    @ObservationIgnored private var needsReconciliation = false
    @ObservationIgnored private var pendingReconciliationError: String?

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
            hasUncertainCreation = false
            needsReconciliation = false
            pendingReconciliationError = nil
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
            needsReconciliation = false
            pendingReconciliationError = nil
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
        errorMessage = nil

        let wasIn = entries[index].containsItem
        let previousItemCount = entries[index].itemCount
        let nextIn = !wasIn
        entries[index].containsItem = nextIn
        entries[index].itemCount = max(0, previousItemCount + (nextIn ? 1 : -1))

        var toggleError: String?
        do {
            if nextIn {
                try await api.addItemToCollection(collectionId: collectionId, itemId: contentId, position: 0)
            } else {
                try await api.removeItemFromCollection(collectionId: collectionId, itemId: contentId)
            }
            ResponseCache.shared.remove(CacheKey.collectionItems(collectionId))
            HomeSectionsEditorModel.refreshScope(.home)
        } catch {
            if requestIdentity() == startIdentity {
                let message = ErrorState(error).message
                toggleError = message
                errorMessage = message
                if !APIv2MutationOutcome(error).mayHaveApplied {
                    if let idx = entries.firstIndex(where: { $0.id == collectionId }) {
                        entries[idx].containsItem = wasIn
                        entries[idx].itemCount = previousItemCount
                    }
                } else {
                    // The server may have committed the membership change before
                    // the response was lost; invalidate caches and reconcile from
                    // the server once all pending mutations settle.
                    ResponseCache.shared.remove(CacheKey.collectionItems(collectionId))
                    HomeSectionsEditorModel.refreshScope(.home)
                    needsReconciliation = true
                    pendingReconciliationError = message
                }
            }
        }

        let currentEntry = entries.first(where: { $0.id == collectionId })
        pendingMutations = max(0, pendingMutations - 1)
        mutationGeneration += 1
        busyCollectionIds.remove(collectionId)

        guard pendingMutations == 0, requestIdentity() == startIdentity else { return }
        if needsReconciliation {
            await load(preservingEntry: nil, preservingError: pendingReconciliationError ?? toggleError)
        } else if !hasLoaded {
            // If this toggle invalidated an in-flight recovery reload while the full
            // list was still incomplete, schedule a fresh reload so existing collections
            // and Retry state reconcile cleanly.
            await load(preservingEntry: currentEntry, preservingError: toggleError)
        }
    }

    @discardableResult
    func createAndAdd(name: String) async -> CreateResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating, !hasUncertainCreation else { return .failed }
        let startIdentity = requestIdentity()
        pendingMutations += 1
        mutationGeneration += 1
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil

        var createdCollectionId: String?
        var releasedMutation = false
        let releaseMutationAccounting = {
            guard !releasedMutation else { return }
            releasedMutation = true
            if let createdCollectionId {
                self.busyCollectionIds.remove(createdCollectionId)
            }
            self.pendingMutations = max(0, self.pendingMutations - 1)
            self.mutationGeneration += 1
        }
        defer { releaseMutationAccounting() }

        let created: UserCollection
        do {
            created = try await api.createCollection(name: trimmed)
        } catch {
            releaseMutationAccounting()
            guard requestIdentity() == startIdentity else { return .failed }
            let message = ErrorState(error).message
            errorMessage = message
            if APIv2MutationOutcome(error).mayHaveApplied {
                // POST may have created the collection on the server; reread
                // the list before allowing another POST to prevent duplicates.
                hasUncertainCreation = true
                needsReconciliation = true
                pendingReconciliationError = message
                if pendingMutations == 0 {
                    await load(preservingEntry: nil, preservingError: message)
                }
                return .uncertain
            }
            return .failed
        }

        guard requestIdentity() == startIdentity else {
            releaseMutationAccounting()
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
                releaseMutationAccounting()
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
                releaseMutationAccounting()
                return .failed
            }
            let message = ErrorState(error).message
            addError = message
            errorMessage = message
            if APIv2MutationOutcome(error).mayHaveApplied {
                ResponseCache.shared.remove(CacheKey.collectionItems(created.id))
                ResponseCache.shared.remove(CacheKey.collections)
                HomeSectionsEditorModel.refreshScope(.home)
                needsReconciliation = true
                pendingReconciliationError = message
            }
            result = .createdOnly
        }

        // Release mutation accounting before the follow-up reload so `load()` can
        // apply, while `isCreating` stays true (via defer) until this call returns.
        releaseMutationAccounting()

        if pendingMutations == 0 {
            if needsReconciliation {
                await load(preservingEntry: nil, preservingError: pendingReconciliationError ?? addError)
            } else if !hasLoaded {
                await load(preservingEntry: createdEntry, preservingError: addError)
            }
        }
        return result
    }
}
