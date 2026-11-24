import Foundation
import Observation

extension Notification.Name {
    /// Posted with the affected collection's `String` ID when an item is added
    /// to or removed from a personal collection, so an open `CollectionDetailView`
    /// reloads its grid immediately.
    static let collectionItemsDidChange = Notification.Name("collectionItemsDidChange")
}

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
    private(set) var collectionTitle: String?
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
    @ObservationIgnored private var titleGeneration = 0
    @ObservationIgnored private var homeMutationGeneration = 0
    @ObservationIgnored private var libraryMutationGeneration: [Int: Int] = [:]
    @ObservationIgnored private var shareMutationGeneration = 0

    init(
        collectionId: String,
        title: String?,
        isUserCollection: Bool,
        sourceLibraryId: Int? = nil,
        api: SiloAPI = .shared,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity
    ) {
        self.collectionId = collectionId
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.collectionTitle = (trimmed?.isEmpty == false) ? trimmed : nil
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
        let startTitleGen = titleGeneration
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
                let canonicalName = editor.value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !canonicalName.isEmpty && titleGeneration == startTitleGen {
                    titleGeneration += 1
                    collectionTitle = canonicalName
                }
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
                let fresh = try? await api.profileLayout(scope: .home)
                guard requestIdentity() == startIdentity else { return }
                if let fresh {
                    isPinnedOnHome = ProfileHomeLayout.pinnedCollectionRow(
                        collectionId: collectionId,
                        isUserCollection: isUserCollection,
                        in: fresh.rows
                    ) != nil
                    hasLoadedHome = true
                } else {
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
                let fresh = try? await api.profileLayout(scope: .library(libraryId))
                guard requestIdentity() == startIdentity else { return }
                if let fresh,
                   let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                    libraryPlacements[refreshedIdx].isPinned = ProfileHomeLayout.pinnedCollectionRow(
                        collectionId: collectionId,
                        isUserCollection: isUserCollection,
                        in: fresh.rows
                    ) != nil
                    libraryPlacements[refreshedIdx].hasLoaded = true
                } else if let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
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
            let fresh = try? await api.collectionEditor(id: collectionId)
            guard requestIdentity() == startIdentity, shareMutationGeneration == myShareGen else { return }
            if let fresh {
                collectionVersion = fresh.version
                isShared = fresh.value.isShared ?? isShared
                shareLoadFailed = false
            } else {
                collectionVersion = nil
            }
        } catch {
            guard requestIdentity() == startIdentity, shareMutationGeneration == myShareGen else { return }
            let message = ErrorState(error).message
            let fresh = try? await api.collectionEditor(id: collectionId)
            guard requestIdentity() == startIdentity, shareMutationGeneration == myShareGen else { return }
            if let fresh {
                collectionVersion = fresh.version
                isShared = fresh.value.isShared ?? !targetShared
                shareLoadFailed = false
            } else {
                isShared = !targetShared
                collectionVersion = nil
                if APIv2MutationOutcome(error).mayHaveApplied {
                    canToggleShare = false
                    shareLoadFailed = true
                }
            }
            errorMessage = message
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
                let rowTitle = try await resolveCollectionTitle()
                let newRow = ProfileHomeLayout.makeCollectionRow(
                    title: rowTitle,
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

    private func resolveCollectionTitle() async throws -> String {
        if let existing = collectionTitle, !existing.isEmpty {
            return existing
        }
        if isUserCollection {
            let startIdentity = requestIdentity()
            let startTitleGen = titleGeneration
            let editor = try? await api.collectionEditor(id: collectionId)
            guard !Task.isCancelled, requestIdentity() == startIdentity else {
                throw CancellationError()
            }
            if titleGeneration != startTitleGen, let existing = collectionTitle, !existing.isEmpty {
                return existing
            }
            if let canonicalName = editor?.value.name.trimmingCharacters(in: .whitespacesAndNewlines),
               !canonicalName.isEmpty {
                if titleGeneration == startTitleGen {
                    titleGeneration += 1
                    collectionTitle = canonicalName
                }
                return canonicalName
            }
        }
        return AppLanguage.string(.collectionsCollection)
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
    private(set) var activeMutationCount = 0
    /// True after a collection creation request failed with an ambiguous outcome
    /// (response lost; server may have created it) until a list reread settles.
    private(set) var hasUncertainCreation = false
    private(set) var errorMessage: String?

    var hasPendingMutations: Bool { activeMutationCount > 0 }

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
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var mutationFailureCount = 0
    @ObservationIgnored private var acknowledgedFailureCount = 0

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
            if preservingError == nil {
                acknowledgedFailureCount = mutationFailureCount
            }
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
        acknowledgedFailureCount = mutationFailureCount
    }

    /// Waits for any in-flight membership toggle or collection creation (including
    /// follow-up reconciliation reads) to finish before dismissing the sheet.
    /// Returns `false` once when any unacknowledged mutation failed so the user
    /// sees the error; a subsequent Done tap with no new failure dismisses cleanly.
    func waitForPendingMutations() async -> Bool {
        let failureCountAtTap = mutationFailureCount
        while activeMutationCount > 0 {
            await withCheckedContinuation { continuation in
                mutationWaiters.append(continuation)
            }
        }
        if mutationFailureCount > acknowledgedFailureCount || mutationFailureCount > failureCountAtTap {
            acknowledgedFailureCount = mutationFailureCount
            return false
        }
        return true
    }

    private func beginMutation() {
        if activeMutationCount == 0 {
            errorMessage = nil
            acknowledgedFailureCount = mutationFailureCount
        }
        activeMutationCount += 1
    }

    private func endMutation() {
        activeMutationCount = max(0, activeMutationCount - 1)
        guard activeMutationCount == 0, !mutationWaiters.isEmpty else { return }
        let waiters = mutationWaiters
        mutationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    @discardableResult
    func startToggle(collectionId: String) -> Task<Void, Never> {
        guard !busyCollectionIds.contains(collectionId),
              let index = entries.firstIndex(where: { $0.id == collectionId }) else { return Task {} }
        beginMutation()
        let startIdentity = requestIdentity()
        pendingMutations += 1
        mutationGeneration += 1
        entryGeneration[collectionId, default: 0] += 1
        busyCollectionIds.insert(collectionId)

        let wasIn = entries[index].containsItem
        let previousItemCount = entries[index].itemCount
        let nextIn = !wasIn
        entries[index].containsItem = nextIn
        entries[index].itemCount = max(0, previousItemCount + (nextIn ? 1 : -1))

        return Task { @MainActor in
            defer { self.endMutation() }
            var releasedMutation = false
            let releaseMutationAccounting = {
                guard !releasedMutation else { return }
                releasedMutation = true
                self.pendingMutations = max(0, self.pendingMutations - 1)
                self.mutationGeneration += 1
                self.busyCollectionIds.remove(collectionId)
            }
            defer { releaseMutationAccounting() }

            guard !Task.isCancelled, self.requestIdentity() == startIdentity else { return }

            var toggleError: String?
            do {
                if nextIn {
                    try await self.api.addItemToCollection(collectionId: collectionId, itemId: self.contentId, position: 0)
                } else {
                    try await self.api.removeItemFromCollection(collectionId: collectionId, itemId: self.contentId)
                }
                ResponseCache.shared.remove(CacheKey.collectionItems(collectionId))
                ResponseCache.shared.removeAll(withPrefix: CacheKey.catalogCollectionItems(collectionId))
                ResponseCache.shared.remove(CacheKey.collections)
                HomeSectionsEditorModel.refreshCollectionMembership(collectionId: collectionId)
                if self.requestIdentity() == startIdentity {
                    NotificationCenter.default.post(name: .collectionItemsDidChange, object: collectionId)
                }
            } catch {
                if self.requestIdentity() == startIdentity {
                    let message = ErrorState(error).message
                    self.mutationFailureCount += 1
                    toggleError = message
                    self.errorMessage = message
                    if !APIv2MutationOutcome(error).mayHaveApplied {
                        if let idx = self.entries.firstIndex(where: { $0.id == collectionId }) {
                            self.entries[idx].containsItem = wasIn
                            self.entries[idx].itemCount = previousItemCount
                        }
                    } else {
                        // The server may have committed the membership change before
                        // the response was lost; invalidate caches and reconcile from
                        // the server once all pending mutations settle.
                        ResponseCache.shared.remove(CacheKey.collectionItems(collectionId))
                        ResponseCache.shared.removeAll(withPrefix: CacheKey.catalogCollectionItems(collectionId))
                        ResponseCache.shared.remove(CacheKey.collections)
                        HomeSectionsEditorModel.refreshCollectionMembership(collectionId: collectionId)
                        NotificationCenter.default.post(name: .collectionItemsDidChange, object: collectionId)
                        self.needsReconciliation = true
                        self.pendingReconciliationError = message
                    }
                }
            }

            let currentEntry = self.entries.first(where: { $0.id == collectionId })
            releaseMutationAccounting()

            guard self.pendingMutations == 0, self.requestIdentity() == startIdentity else { return }
            if self.needsReconciliation {
                await self.load(preservingEntry: nil, preservingError: self.pendingReconciliationError ?? toggleError)
            } else if !self.hasLoaded {
                // If this toggle invalidated an in-flight recovery reload while the full
                // list was still incomplete, schedule a fresh reload so existing collections
                // and Retry state reconcile cleanly.
                await self.load(preservingEntry: currentEntry, preservingError: toggleError)
            }
        }
    }

    func toggle(collectionId: String) async {
        await startToggle(collectionId: collectionId).value
    }

    @discardableResult
    func startCreateAndAdd(name: String) -> Task<CreateResult, Never> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating, !hasUncertainCreation else { return Task { .failed } }
        beginMutation()
        let startIdentity = requestIdentity()
        pendingMutations += 1
        mutationGeneration += 1
        isCreating = true

        return Task { @MainActor in
            defer { self.endMutation() }
            defer { self.isCreating = false }

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

            guard !Task.isCancelled, self.requestIdentity() == startIdentity else {
                releaseMutationAccounting()
                return .failed
            }

            let created: UserCollection
            do {
                created = try await self.api.createCollection(name: trimmed)
            } catch {
                releaseMutationAccounting()
                guard self.requestIdentity() == startIdentity else { return .failed }
                let message = ErrorState(error).message
                self.mutationFailureCount += 1
                self.errorMessage = message
                if APIv2MutationOutcome(error).mayHaveApplied {
                    // POST may have created the collection on the server; reread
                    // the list before allowing another POST to prevent duplicates.
                    self.hasUncertainCreation = true
                    self.needsReconciliation = true
                    self.pendingReconciliationError = message
                    if self.pendingMutations == 0 {
                        await self.load(preservingEntry: nil, preservingError: message)
                    }
                    return .uncertain
                }
                return .failed
            }

            guard self.requestIdentity() == startIdentity else {
                releaseMutationAccounting()
                return .failed
            }

            ResponseCache.shared.remove(CacheKey.collections)
            createdCollectionId = created.id
            self.busyCollectionIds.insert(created.id)
            let myEntryGen = self.entryGeneration[created.id, default: 0] + 1
            self.entryGeneration[created.id] = myEntryGen

            let baseCount = created.itemCount ?? 0
            var createdEntry = Entry(collection: created, containsItem: false, itemCount: baseCount)
            if !self.entries.contains(where: { $0.id == created.id }) {
                self.entries.insert(createdEntry, at: 0)
            }

            let result: CreateResult
            var addError: String?
            do {
                try await self.api.addItemToCollection(collectionId: created.id, itemId: self.contentId, position: 0)
                guard self.requestIdentity() == startIdentity else {
                    releaseMutationAccounting()
                    return .failed
                }
                if self.entryGeneration[created.id] == myEntryGen {
                    createdEntry.containsItem = true
                    createdEntry.itemCount = max(1, baseCount + 1)
                    if let idx = self.entries.firstIndex(where: { $0.id == created.id }) {
                        self.entries[idx] = createdEntry
                    }
                }
                ResponseCache.shared.remove(CacheKey.collectionItems(created.id))
                ResponseCache.shared.removeAll(withPrefix: CacheKey.catalogCollectionItems(created.id))
                ResponseCache.shared.remove(CacheKey.collections)
                HomeSectionsEditorModel.refreshCollectionMembership(collectionId: created.id)
                NotificationCenter.default.post(name: .collectionItemsDidChange, object: created.id)
                result = .createdAndAdded
            } catch {
                guard self.requestIdentity() == startIdentity else {
                    releaseMutationAccounting()
                    return .failed
                }
                let message = ErrorState(error).message
                self.mutationFailureCount += 1
                addError = message
                self.errorMessage = message
                if APIv2MutationOutcome(error).mayHaveApplied {
                    ResponseCache.shared.remove(CacheKey.collectionItems(created.id))
                    ResponseCache.shared.removeAll(withPrefix: CacheKey.catalogCollectionItems(created.id))
                    ResponseCache.shared.remove(CacheKey.collections)
                    HomeSectionsEditorModel.refreshCollectionMembership(collectionId: created.id)
                    NotificationCenter.default.post(name: .collectionItemsDidChange, object: created.id)
                    self.needsReconciliation = true
                    self.pendingReconciliationError = message
                }
                result = .createdOnly
            }

            // Release mutation accounting before the follow-up reload so `load()` can
            // apply, while `isCreating` stays true (via defer) until this call returns.
            releaseMutationAccounting()

            if self.pendingMutations == 0 {
                if self.needsReconciliation {
                    await self.load(preservingEntry: nil, preservingError: self.pendingReconciliationError ?? addError)
                } else if !self.hasLoaded {
                    await self.load(preservingEntry: createdEntry, preservingError: addError)
                }
            }
            return result
        }
    }

    @discardableResult
    func createAndAdd(name: String) async -> CreateResult {
        await startCreateAndAdd(name: name).value
    }
}
