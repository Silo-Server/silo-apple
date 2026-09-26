import Foundation
import OSLog

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

/// Whether this account can use collection groups, from
/// `GET /api/v2/collections/capabilities`. Stores without group support
/// (SQLite user stores) answer every group operation with 501.
enum CollectionGroupSupport: Equatable {
    case checking
    case available
    case unavailable
    /// The capability read failed. Group controls stay hidden and the page
    /// offers a retry; this is not a verdict that groups are unsupported.
    case unknown(String)
}

@Observable
@MainActor
class CollectionsViewModel {
    private(set) var collections: [UserCollection] = []
    private(set) var groups: [CollectionGroup] = []
    /// Cached output of rebuildSections(). Recomputed whenever [collections]
    /// or [groups] change — never on every view body access.
    private(set) var sections: [UserCollectionSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?
    private(set) var groupSupport: CollectionGroupSupport = .checking
    private let api: SiloAPI

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "collections")

    init(api: SiloAPI = .shared) {
        self.api = api
        if let cached: CollectionsResponse = ResponseCache.shared.get(CacheKey.collections) {
            collections = cached.collections ?? []
            groups = sortGroups(cached.groups ?? [])
            rebuildSections()
        }
    }

    var canManageGroups: Bool { groupSupport == .available }

    // Create-collection sheet
    var showCreateSheet = false {
        didSet { createError = nil }
    }
    var newCollectionName = ""
    /// Error message scoped to the create-collection sheet.
    var createError: String?

    // Group action sheets
    var pendingGroupAction: GroupAction? {
        didSet {
            sheetGeneration += 1
            groupError = nil
            editorVersion = nil
            editorNeedsReload = false
            isLoadingEditor = false
        }
    }
    /// Identifies the open sheet. Every change of `pendingGroupAction` bumps
    /// it, so a write whose sheet was dismissed before the answer came back
    /// can't show its outcome in, or close, the sheet opened after it.
    private var sheetGeneration = 0
    /// Error message scoped to the currently-open group action sheet.
    /// Cleared on success, on dismissal, and when a new action starts.
    var groupError: String?
    /// The version the open sheet edits: read when the sheet opens and again
    /// only when the user reloads. Every edit sends its `If-Match`.
    private(set) var editorVersion: CollectionEditVersion?
    /// The edit can't be sent until the user reloads: the item changed
    /// elsewhere (412), or an earlier attempt has an unknown outcome.
    private(set) var editorNeedsReload = false
    private(set) var isLoadingEditor = false
    /// One write at a time. Creates and edits are never replayed, so a
    /// second tap must not send a second request.
    private(set) var isSaving = false

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

        /// Edits of an existing collection or group need its current version.
        var needsEditor: Bool {
            if case .create = self { return false }
            return true
        }
    }

    /// Whether the open sheet can send its change now.
    var canSubmitGroupAction: Bool {
        guard let action = pendingGroupAction, !isSaving else { return false }
        return !action.needsEditor || (editorVersion != nil && !editorNeedsReload)
    }

    func loadCollections() async {
        if collections.isEmpty && groups.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil
        async let support: Void = refreshGroupSupport()
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
        await support
        isLoading = false
        isRefreshing = false
    }

    /// Re-reads group support after a failed capability read.
    func retryGroupSupport() async {
        groupSupport = .checking
        await refreshGroupSupport()
    }

    /// A failed read keeps an answer this page already has; without one it
    /// leaves a retryable state instead of deciding groups are unsupported.
    private func refreshGroupSupport() async {
        do {
            let capabilities = try await api.collectionCapabilities()
            groupSupport = capabilities.supportsGroups ? .available : .unavailable
        } catch {
            switch groupSupport {
            case .available, .unavailable: break
            case .checking, .unknown:
                groupSupport = .unknown("Collection groups couldn't be checked.")
            }
        }
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
        guard !name.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        createError = nil
        do {
            _ = try await api.createCollection(name: name)
            newCollectionName = ""
            showCreateSheet = false
            // Drop the cached snapshot so the upcoming loadCollections()
            // is forced to fetch fresh (the new collection isn't in the
            // local arrays yet).
            ResponseCache.shared.remove(CacheKey.collections)
            await loadCollections()
        } catch let err {
            createError = createFailureMessage(err, fallback: "Failed to create collection")
            // A lost answer may still have created it; show the list as it is.
            if Self.outcomeIsUncertain(err) { await loadCollections() }
        }
    }

    // MARK: - Editors

    /// Reads the version the open sheet edits. Runs when the sheet opens
    /// and when the user taps Reload; never on its own after a failure.
    func loadEditor() async {
        guard let action = pendingGroupAction, action.needsEditor else { return }
        editorVersion = nil
        groupError = nil
        isLoadingEditor = true
        do {
            switch action {
            case .create:
                break
            case .rename(let group), .delete(let group):
                let editor = try await api.collectionGroupEditor(id: group.id)
                guard pendingGroupAction?.id == action.id else { return }
                replaceGroup(editor.value)
                editorVersion = editor.version
            case .move(let collection), .deleteCollection(let collection):
                let editor = try await api.collectionEditor(id: collection.id)
                guard pendingGroupAction?.id == action.id else { return }
                replaceCollection(editor.value)
                editorVersion = editor.version
            }
            editorNeedsReload = false
        } catch let err {
            guard pendingGroupAction?.id == action.id else { return }
            if Self.problem(err)?.status == 404 {
                // Gone since the list was read (possibly by an earlier
                // attempt whose answer was lost): show the list as it is.
                pendingGroupAction = nil
                await loadCollections()
                return
            }
            editorNeedsReload = true
            groupError = groupErrorMessage(err, fallback: "Failed to load the current version")
        }
        isLoadingEditor = false
    }

    func deleteCollection(id: String) async {
        guard let edit = beginEdit() else { return }
        defer { isSaving = false }
        do {
            try await api.deleteCollection(edit.version)
            collections.removeAll { $0.id == id }
            rebuildSections()
            writeBackCache()
            closeSheet(edit.sheet)
        } catch let err {
            await handleEditFailure(err, fallback: "Failed to delete collection", sheet: edit.sheet)
        }
    }

    // MARK: - Groups

    func createGroup(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            groupError = "Name is required"
            return
        }
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let sheet = sheetGeneration
        do {
            let created = try await api.createCollectionGroup(name: trimmed)
            groups = sortGroups(groups + [created])
            rebuildSections()
            writeBackCache()
            closeSheet(sheet)
        } catch let err {
            if markGroupsUnsupported(err, sheet: sheet) { return }
            if sheet == sheetGeneration {
                groupError = createFailureMessage(err, fallback: "Failed to add group")
            }
            if Self.outcomeIsUncertain(err) { await loadCollections() }
        }
    }

    func renameGroup(id: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            groupError = "Name is required"
            return
        }
        guard let edit = beginEdit() else { return }
        defer { isSaving = false }
        do {
            let updated = try await api.renameCollectionGroup(edit.version, name: trimmed)
            replaceGroup(updated)
            writeBackCache()
            closeSheet(edit.sheet)
        } catch let err {
            await handleEditFailure(err, fallback: "Failed to rename group", sheet: edit.sheet)
        }
    }

    func deleteGroup(id: String) async {
        guard let edit = beginEdit() else { return }
        defer { isSaving = false }
        do {
            try await api.deleteCollectionGroup(edit.version)
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
            closeSheet(edit.sheet)
        } catch let err {
            await handleEditFailure(err, fallback: "Failed to delete group", sheet: edit.sheet)
        }
    }

    func moveCollection(id: String, toGroupId targetGroupId: String?) async {
        guard let edit = beginEdit() else { return }
        defer { isSaving = false }
        do {
            let updated = try await api.moveCollection(edit.version, toGroupId: targetGroupId)
            replaceCollection(updated)
            writeBackCache()
            closeSheet(edit.sheet)
        } catch let err {
            await handleEditFailure(err, fallback: "Failed to move collection", sheet: edit.sheet)
        }
    }

    // MARK: - Outcomes

    /// The version to send and the sheet sending it, with `isSaving` set, or
    /// nil when the sheet has no current version or a write is already running.
    private func beginEdit() -> (version: CollectionEditVersion, sheet: Int)? {
        guard canSubmitGroupAction, let version = editorVersion else { return nil }
        isSaving = true
        return (version, sheetGeneration)
    }

    /// Closes the sheet that started a successful write, if it is still open.
    private func closeSheet(_ sheet: Int) {
        if sheet == sheetGeneration { pendingGroupAction = nil }
    }

    /// A failed edit keeps the sheet and its draft. A stale version (412), a
    /// missing precondition (428), or an unknown outcome all require a
    /// reload before the edit can be sent again; nothing is resent here.
    /// A 404 means the item is gone, as it does for Reload: close and re-read.
    /// When the user dismissed the sheet mid-write, only an outcome that
    /// leaves the list stale acts, by re-reading it.
    private func handleEditFailure(_ err: Error, fallback: String, sheet: Int) async {
        if markGroupsUnsupported(err, sheet: sheet) { return }
        let status = Self.problem(err)?.status
        if status == 404 {
            closeSheet(sheet)
            await loadCollections()
            return
        }
        guard sheet == sheetGeneration else {
            if Self.outcomeIsUncertain(err) { await loadCollections() }
            return
        }
        switch status {
        case 412:
            editorNeedsReload = true
            groupError = "This changed on another device. Reload to see the current version; your edits are kept."
        case 428:
            Self.logger.error("Collection edit sent without a precondition: \(String(describing: err), privacy: .public)")
            editorNeedsReload = true
            groupError = "Reload the current version before trying again."
        default:
            if Self.outcomeIsUncertain(err) {
                Self.logger.warning("Collection edit outcome unknown: \(String(describing: err), privacy: .public)")
                editorNeedsReload = true
                groupError = "Silo couldn't confirm this change. Reload to check whether it was saved before trying again."
            } else {
                groupError = groupErrorMessage(err, fallback: fallback)
            }
        }
    }

    /// A 501 `capability_unsupported` means this store has no groups, even
    /// if the capability read said otherwise: hide the group controls.
    private func markGroupsUnsupported(_ err: Error, sheet: Int) -> Bool {
        guard let problem = Self.problem(err), problem.status == 501 else { return false }
        groupSupport = .unavailable
        if sheet == sheetGeneration {
            groupError = problem.detail.isEmpty ? "Collection groups aren't available on this server." : problem.detail
        }
        return true
    }

    private func createFailureMessage(_ err: Error, fallback: String) -> String {
        if Self.outcomeIsUncertain(err) {
            Self.logger.warning("Collection create outcome unknown: \(String(describing: err), privacy: .public)")
            return "Silo couldn't confirm this was created. Check the list before trying again."
        }
        return groupErrorMessage(err, fallback: fallback)
    }

    private func replaceCollection(_ collection: UserCollection) {
        guard let i = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[i] = collection
        rebuildSections()
    }

    private func replaceGroup(_ group: CollectionGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i] = group
        groups = sortGroups(groups)
        rebuildSections()
    }

    private static func problem(_ err: Error) -> APIv2Problem? {
        if case APIv2Error.problem(let problem) = err { return problem }
        return nil
    }

    /// Whether a failed write may have been applied: it was sent and no
    /// answer came back, the server accepted it and the answer couldn't be
    /// read, or the owner changed after it was sent. See
    /// `APIv2MutationOutcome`.
    static func outcomeIsUncertain(_ err: Error) -> Bool {
        APIv2MutationOutcome(err).mayHaveApplied
    }

    private func groupErrorMessage(_ err: Error, fallback: String) -> String {
        let message = err.localizedDescription
        return message.isEmpty ? fallback : message
    }
}
