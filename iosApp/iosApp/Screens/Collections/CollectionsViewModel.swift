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
    private(set) var supportsGroups = false
    private(set) var editorVersion: CollectionEditVersion?
    private(set) var editorCurrentName: String?
    private(set) var editorNeedsReload = false
    private(set) var isSaving = false
    private let api: SiloAPI


    init(api: SiloAPI = .shared) {
        self.api = api
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
        didSet { groupError = nil; editorVersion = nil; editorCurrentName = nil; editorNeedsReload = false }
    }
    /// Error message scoped to the currently-open group action sheet.
    /// Cleared on success, on dismissal, and when a new action starts.
    var groupError: String?

    enum GroupAction: Identifiable {
        case create
        case rename(CollectionGroup)
        case delete(CollectionGroup)
        case move(UserCollection)
        case deleteCollection(UserCollection)

        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let g): return "rename:\(g.id)"
            case .delete(let g): return "delete:\(g.id)"
            case .move(let c): return "move:\(c.id)"
            case .deleteCollection(let c): return "delete-collection:\(c.id)"
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
        supportsGroups = (try? await api.collectionCapabilities().groups) ?? false
        do {
            let response: CollectionsResponse = try await api.collections()
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
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        do {
            let _: UserCollection = try await api.createCollection(
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
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            guard let version = editorVersion, !editorNeedsReload else { return }
            try await api.deleteCollection(version: version)
            pendingGroupAction = nil
            collections.removeAll { $0.id == id }
            rebuildSections()
            writeBackCache()
        } catch let err {
            handleEditorError(err, fallback: "Failed to delete collection")
        }
    }

    // MARK: - Groups

    func createGroup(name: String) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            groupError = "Name is required"
            return
        }
        do {
            let created = try await api.createCollectionGroup(name: trimmed)
            groups = sortGroups(groups + [created])
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            handleEditorError(err, fallback: "Failed to add group")
        }
    }

    func renameGroup(id: String, name: String) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            groupError = "Name is required"
            return
        }
        guard let version = editorVersion, !editorNeedsReload else { return }
        do {
            let updated = try await api.renameCollectionGroup(version: version, name: trimmed)
            if let i = groups.firstIndex(where: { $0.id == id }) {
                groups[i] = updated
            }
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            handleEditorError(err, fallback: "Failed to rename group")
        }
    }

    func deleteGroup(id: String) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard let version = editorVersion, !editorNeedsReload else { return }
        do {
            try await api.deleteCollectionGroup(version: version)
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
            handleEditorError(err, fallback: "Failed to delete group")
        }
    }

    func moveCollection(id: String, toGroupId targetGroupId: String?) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard let version = editorVersion, !editorNeedsReload else { return }
        do {
            let updated = try await api.moveCollectionToGroup(version: version, groupId: targetGroupId)
            if let i = collections.firstIndex(where: { $0.id == id }) {
                collections[i] = updated
            }
            rebuildSections()
            writeBackCache()
            pendingGroupAction = nil
        } catch let err {
            handleEditorError(err, fallback: "Failed to move collection")
        }
    }

    /// Called once when a dialog opens, or explicitly by its Reload button.
    /// Draft text and selected destination remain owned by the sheet.
    func reloadEditor() async {
        guard let action = pendingGroupAction else { return }
        editorVersion = nil
        groupError = nil
        do {
            switch action {
            case .create: return
            case .rename(let group), .delete(let group):
                let editor = try await api.collectionGroupEditor(id: group.id)
                guard pendingGroupAction?.id == action.id else { return }
                editorVersion = editor.version
                editorCurrentName = editor.value.name
            case .move(let collection), .deleteCollection(let collection):
                let editor = try await api.collectionEditor(id: collection.id)
                guard pendingGroupAction?.id == action.id else { return }
                editorVersion = editor.version
                editorCurrentName = editor.value.name
            }
            editorNeedsReload = false
        } catch {
            guard pendingGroupAction?.id == action.id else { return }
            groupError = error.localizedDescription
        }
    }

    private func handleEditorError(_ error: Error, fallback: String) {
        if case APIv2Error.problem(let problem) = error, problem.status == 412 {
            editorNeedsReload = true
            groupError = "This collection changed elsewhere. Your edits are kept. Reload the current version and review before trying again."
        } else {
            groupError = groupErrorMessage(error, fallback: fallback)
        }
    }

    private func groupErrorMessage(_ err: Error, fallback: String) -> String {
        let message = err.localizedDescription
        return message.isEmpty ? fallback : message
    }
}
