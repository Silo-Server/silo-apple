import Foundation

/// One section of the user's personal-collections page: a named group
/// or the anonymous Ungrouped bucket plus the collections it contains.
struct UserCollectionSection: Identifiable, Hashable {
    /// Stable identity — the group id for named sections, `nil` only for
    /// Ungrouped. Hashable wraps it via [id].
    let groupId: String?
    let name: String
    let collections: [UserCollection]

    var id: String { groupId ?? "__ungrouped__" }

    static func == (lhs: UserCollectionSection, rhs: UserCollectionSection) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.collections.map(\.id) == rhs.collections.map(\.id)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(collections.map(\.id))
    }
}

@Observable
@MainActor
class CollectionsViewModel {
    private(set) var collections: [UserCollection] = []
    private(set) var groups: [CollectionGroup] = []
    /// Cached output of [buildSections]. Recomputed whenever [collections]
    /// or [groups] change — never on every view body access.
    private(set) var sections: [UserCollectionSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    init() {
        if let cached: CollectionsResponse = ResponseCache.shared.get(CacheKey.collections) {
            collections = cached.collections ?? []
            groups = sortGroups(cached.groups ?? [])
            rebuildSections()
        }
    }

    // Create-collection sheet
    var showCreateSheet = false
    var newCollectionName = ""

    // Group action sheets
    var pendingGroupAction: GroupAction? {
        didSet { groupError = nil }
    }
    /// Error message scoped to the currently-open group action sheet.
    /// Cleared on success, on dismissal, and when a new action starts.
    var groupError: String?

    enum GroupAction: Identifiable {
        case create
        case rename(CollectionGroup)
        case delete(CollectionGroup)
        case move(UserCollection)

        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let g): return "rename:\(g.id)"
            case .delete(let g): return "delete:\(g.id)"
            case .move(let c): return "move:\(c.id)"
            }
        }
    }

    func loadCollections() async {
        if collections.isEmpty && groups.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil
        do {
            let response: CollectionsResponse = try await SiloAPI.shared.collections()
            ResponseCache.shared.set(response, for: CacheKey.collections)
            collections = response.collections ?? []
            groups = sortGroups(response.groups ?? [])
            rebuildSections()
        } catch let err {
            if collections.isEmpty && groups.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
        isRefreshing = false
    }

    /// Mutations write through the cache so a returning visit lands on
    /// the post-mutation state. Called from every successful add / move /
    /// rename / delete path.
    private func writeBackCache() {
        ResponseCache.shared.set(
            CollectionsResponse(collections: collections, groups: groups),
            for: CacheKey.collections
        )
    }

    private func sortGroups(_ groups: [CollectionGroup]) -> [CollectionGroup] {
        groups.sorted { lhs, rhs in
            let l = lhs.sortOrder ?? 0
            let r = rhs.sortOrder ?? 0
            if l != r { return l < r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Builds the rendered section list — named groups in `sortOrder`
    /// order, followed by Ungrouped. Empty Ungrouped is hidden whenever
    /// at least one named group exists, matching the web app. Relies on
    /// [groups] being pre-sorted at assignment time.
    private func rebuildSections() {
        let byGroup = Dictionary(grouping: collections) { $0.groupId }
        var result: [UserCollectionSection] = []
        for g in groups {
            let items = (byGroup[g.id] ?? []).sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            result.append(UserCollectionSection(groupId: g.id, name: g.name, collections: items))
        }
        let ungrouped = (byGroup[nil] ?? []).sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
        if !ungrouped.isEmpty || groups.isEmpty {
            result.append(UserCollectionSection(groupId: nil, name: "Ungrouped", collections: ungrouped))
        }
        sections = result
    }

    func createCollection() async {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        do {
            let _: UserCollection = try await SiloAPI.shared.createCollection(
                name: name, collectionType: "manual"
            )
            newCollectionName = ""
            showCreateSheet = false
            // Drop the cached snapshot so the upcoming loadCollections()
            // is forced to fetch fresh (the new collection isn't in the
            // local arrays yet).
            ResponseCache.shared.remove(CacheKey.collections)
            await loadCollections()
        } catch let err {
            self.error = ErrorState(err)
        }
    }

    func deleteCollection(id: String) async {
        do {
            try await SiloAPI.shared.deleteCollection(id: id)
            collections.removeAll { $0.id == id }
            rebuildSections()
            writeBackCache()
        } catch let err {
            self.error = ErrorState(err)
        }
    }

    // MARK: - Groups

    func createGroup(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            groupError = "Name is required"
            return
        }
        do {
            let created = try await SiloAPI.shared.createCollectionGroup(name: trimmed)
            groups = sortGroups(groups + [created])
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            groupError = groupErrorMessage(err, fallback: "Failed to add group")
        }
    }

    func renameGroup(id: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            groupError = "Name is required"
            return
        }
        do {
            let updated = try await SiloAPI.shared.renameCollectionGroup(id: id, name: trimmed)
            if let i = groups.firstIndex(where: { $0.id == id }) {
                groups[i] = updated
            }
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            groupError = groupErrorMessage(err, fallback: "Failed to rename group")
        }
    }

    func deleteGroup(id: String) async {
        do {
            try await SiloAPI.shared.deleteCollectionGroup(id: id)
            groups.removeAll { $0.id == id }
            // Collections in the deleted group fall back to Ungrouped.
            collections = collections.map { c in
                guard c.groupId == id else { return c }
                return UserCollection(
                    id: c.id,
                    name: c.name,
                    collectionType: c.collectionType,
                    createdAt: c.createdAt,
                    description: c.description,
                    groupId: nil,
                    sortOrder: c.sortOrder,
                    itemCount: c.itemCount,
                    posterUrl: c.posterUrl,
                    posterThumbhash: c.posterThumbhash,
                    includeInServerCollections: c.includeInServerCollections
                )
            }
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            groupError = groupErrorMessage(err, fallback: "Failed to delete group")
        }
    }

    func moveCollection(id: String, toGroupId targetGroupId: String?) async {
        do {
            let updated = try await SiloAPI.shared.moveCollectionToGroup(id: id, groupId: targetGroupId)
            if let i = collections.firstIndex(where: { $0.id == id }) {
                collections[i] = updated
            }
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            groupError = groupErrorMessage(err, fallback: "Failed to move collection")
        }
    }

    private func groupErrorMessage(_ err: Error, fallback: String) -> String {
        let message = err.localizedDescription
        return message.isEmpty ? fallback : message
    }
}
