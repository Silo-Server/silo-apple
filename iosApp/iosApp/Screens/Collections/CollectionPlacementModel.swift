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
    private(set) var libraryPlacements: [LibraryPlacement] = []
    private(set) var isShared = false
    private(set) var canToggleShare = false
    private(set) var isLoading = false
    private(set) var isUpdatingHome = false
    private(set) var updatingLibraryIds = Set<Int>()
    private(set) var isUpdatingShare = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private var homeLayout: APIv2ProfileLayoutRead?
    @ObservationIgnored private var libraryLayouts: [Int: APIv2ProfileLayoutRead] = [:]
    @ObservationIgnored private var collectionVersion: CollectionEditVersion?

    init(
        collectionId: String,
        title: String,
        isUserCollection: Bool,
        sourceLibraryId: Int? = nil,
        api: SiloAPI = .shared
    ) {
        self.collectionId = collectionId
        self.collectionTitle = title
        self.isUserCollection = isUserCollection
        self.sourceLibraryId = sourceLibraryId
        self.api = api
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        async let homeRead: APIv2ProfileLayoutRead? = try? await api.profileLayout(scope: .home)
        async let librariesRead: LibrariesResponse? = try? await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: true)
        async let editorRead: CollectionEditor<UserCollection>? = isUserCollection
            ? (try? await api.collectionEditor(id: collectionId))
            : nil

        let (home, librariesResponse, editor) = await (homeRead, librariesRead, editorRead)
        if let home {
            homeLayout = home
            isPinnedOnHome = ProfileHomeLayout.pinnedCollectionRow(
                collectionId: collectionId,
                isUserCollection: isUserCollection,
                in: home.rows
            ) != nil
        }

        if let editor {
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
                for lib in relevant {
                    let layout = fetched[lib.id]?.1
                    if let layout {
                        libraryLayouts[lib.id] = layout
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
            libraryPlacements = placements
        }
    }

    func toggleHomePin() async {
        guard !isUpdatingHome else { return }
        isUpdatingHome = true
        defer { isUpdatingHome = false }
        errorMessage = nil

        let targetPinned = !isPinnedOnHome
        isPinnedOnHome = targetPinned

        do {
            let layout: APIv2ProfileLayoutRead
            if let cached = homeLayout {
                layout = cached
            } else {
                layout = try await api.profileLayout(scope: .home)
            }
            let updated = try await applyPin(targetPinned, on: layout)
            homeLayout = updated
            isPinnedOnHome = ProfileHomeLayout.pinnedCollectionRow(
                collectionId: collectionId,
                isUserCollection: isUserCollection,
                in: updated.rows
            ) != nil
            HomeSectionsEditorModel.refreshScope(.home)
        } catch {
            isPinnedOnHome = !targetPinned
            errorMessage = "Couldn't update Home placement. \(ErrorState(error).message)"
        }
    }

    func toggleLibraryPin(libraryId: Int) async {
        guard !updatingLibraryIds.contains(libraryId),
              let idx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) else { return }
        updatingLibraryIds.insert(libraryId)
        defer { updatingLibraryIds.remove(libraryId) }
        errorMessage = nil

        let targetPinned = !libraryPlacements[idx].isPinned
        libraryPlacements[idx].isPinned = targetPinned

        do {
            let layout: APIv2ProfileLayoutRead
            if let cached = libraryLayouts[libraryId] {
                layout = cached
            } else {
                layout = try await api.profileLayout(scope: .library(libraryId))
            }
            let updated = try await applyPin(targetPinned, on: layout)
            libraryLayouts[libraryId] = updated
            if let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                libraryPlacements[refreshedIdx].isPinned = ProfileHomeLayout.pinnedCollectionRow(
                    collectionId: collectionId,
                    isUserCollection: isUserCollection,
                    in: updated.rows
                ) != nil
            }
            HomeSectionsEditorModel.refreshScope(.library(libraryId))
        } catch {
            if let refreshedIdx = libraryPlacements.firstIndex(where: { $0.libraryId == libraryId }) {
                libraryPlacements[refreshedIdx].isPinned = !targetPinned
            }
            errorMessage = "Couldn't update library placement. \(ErrorState(error).message)"
        }
    }

    func toggleShared() async {
        guard isUserCollection, !isUpdatingShare else { return }
        isUpdatingShare = true
        defer { isUpdatingShare = false }
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
            isShared = updated.isShared ?? targetShared
            // Re-read editor to hold the fresh ETag for subsequent toggles.
            if let fresh = try? await api.collectionEditor(id: collectionId) {
                collectionVersion = fresh.version
            } else {
                collectionVersion = nil
            }
        } catch {
            isShared = !targetShared
            collectionVersion = nil
            errorMessage = "Couldn't update sharing. \(ErrorState(error).message)"
        }
    }

    private func applyPin(
        _ pinned: Bool,
        on layout: APIv2ProfileLayoutRead
    ) async throws -> APIv2ProfileLayoutRead {
        var nextRows = layout.rows
        if pinned {
            if let existingIdx = nextRows.firstIndex(where: { row in
                let type = row.sectionType.lowercased()
                guard type == "collection" || type == "user_collection" || type == "library_collection" else {
                    return false
                }
                return isUserCollection
                    ? row.userCollectionId == collectionId
                    : row.libraryCollectionId == collectionId
            }) {
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
            if let existingIdx = nextRows.firstIndex(where: { row in
                let type = row.sectionType.lowercased()
                guard type == "collection" || type == "user_collection" || type == "library_collection" else {
                    return false
                }
                return isUserCollection
                    ? row.userCollectionId == collectionId
                    : row.libraryCollectionId == collectionId
            }) {
                if nextRows[existingIdx].isCustom {
                    nextRows.remove(at: existingIdx)
                } else {
                    nextRows[existingIdx].hidden = true
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
/// a specific title (`contentId`) belongs to each, supporting 1-tap toggle and
/// inline creation of a new collection.
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
    private(set) var isLoading = false
    private(set) var busyCollectionIds = Set<String>()
    private(set) var isCreating = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let api: SiloAPI

    init(contentId: String, api: SiloAPI = .shared) {
        self.contentId = contentId
        self.api = api
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let response = try await api.collections()
            let manual = (response.collections ?? []).filter { col in
                let kind = (col.collectionType ?? "manual").lowercased()
                return kind == "manual" || kind.isEmpty
            }

            var membership: [String: Bool] = [:]
            await withTaskGroup(of: (String, Bool).self) { group in
                for col in manual {
                    group.addTask { [api, contentId] in
                        let cards = try? await api.collectionItems(collectionId: col.id)
                        let has = cards?.items.contains(where: { $0.contentId == contentId }) ?? false
                        return (col.id, has)
                    }
                }
                for await (id, has) in group {
                    membership[id] = has
                }
            }

            entries = manual.map { col in
                Entry(
                    collection: col,
                    containsItem: membership[col.id] ?? false,
                    itemCount: col.itemCount ?? 0
                )
            }
        } catch {
            errorMessage = "Couldn't load collections. \(ErrorState(error).message)"
        }
    }

    func toggle(collectionId: String) async {
        guard !busyCollectionIds.contains(collectionId),
              let index = entries.firstIndex(where: { $0.id == collectionId }) else { return }
        busyCollectionIds.insert(collectionId)
        defer { busyCollectionIds.remove(collectionId) }
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
            if let idx = entries.firstIndex(where: { $0.id == collectionId }) {
                entries[idx].containsItem = wasIn
                entries[idx].itemCount = max(0, entries[idx].itemCount + (wasIn ? 1 : -1))
            }
            errorMessage = "Couldn't update collection. \(ErrorState(error).message)"
        }
    }

    @discardableResult
    func createAndAdd(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating else { return false }
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil

        do {
            let created = try await api.createCollection(name: trimmed)
            try await api.addItemToCollection(collectionId: created.id, itemId: contentId, position: 0)
            entries.insert(Entry(collection: created, containsItem: true, itemCount: 1), at: 0)
            ResponseCache.shared.remove(CacheKey.collectionItems(created.id))
            HomeSectionsEditorModel.refreshScope(.home)
            return true
        } catch {
            errorMessage = "Couldn't create collection. \(ErrorState(error).message)"
            return false
        }
    }
}
