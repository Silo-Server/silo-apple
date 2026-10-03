import Foundation

/// A navigation constraint, independent of optional user-selected filter facets.
enum LibraryVideoScope: String, Hashable {
    case movie, series

    func contains(_ type: String) -> Bool {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch self {
        case .movie: return ["movie", "movies", "film"].contains(type)
        case .series: return ["series", "show", "shows", "tv", "episode"].contains(type)
        }
    }

    func section(_ original: ResolvedSection, items: [SectionItem]) -> ResolvedSection {
        ResolvedSection(id: original.id, sectionType: original.sectionType, title: original.title,
                        featured: original.featured, itemLimit: original.itemLimit, totalCount: nil,
                        isCustom: original.isCustom, customized: original.customized, items: items)
    }

    /// Overlap at most three shelves, preserving layout order and each shelf's cursor chain.
    func refillSections<Cursor>(
        _ originals: [ResolvedSection],
        loadPage: @escaping @Sendable (ResolvedSection, Cursor?) async throws -> LibraryScopedPage<Cursor>
    ) async throws -> [(section: ResolvedSection, incomplete: Bool)] {
        let refillAt: @Sendable (Int) async throws -> (Int, ResolvedSection, Bool) = { index in
            let result = try await refill(originals[index]) { cursor in
                try await loadPage(originals[index], cursor)
            }
            return (index, result.section, result.incomplete)
        }
        return try await withThrowingTaskGroup(of: (Int, ResolvedSection, Bool).self) { group in
            var nextIndex = min(3, originals.count)
            for index in 0..<nextIndex {
                group.addTask { try await refillAt(index) }
            }
            var results = originals.map { (section: $0, incomplete: false) }
            while let (index, section, incomplete) = try await group.next() {
                results[index] = (section, incomplete)
                try Task.checkCancellation()
                if nextIndex < originals.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask { try await refillAt(index) }
                }
            }
            return results
        }
    }

    /// Section queries reject type overlays. Preserve source order while filling a typed shelf.
    func refill<Cursor>(
        _ original: ResolvedSection,
        loadPage: (Cursor?) async throws -> LibraryScopedPage<Cursor>
    ) async throws -> (section: ResolvedSection, incomplete: Bool) {
        let initial = original.items.filter { contains($0.type) }
        let target = min(100, original.itemLimit.flatMap { $0 > 0 ? $0 : nil } ?? max(20, original.items.count))
        func result(_ items: [SectionItem], incomplete: Bool = false) -> (ResolvedSection, Bool) {
            (section(original, items: Array(items.prefix(target))), incomplete)
        }
        if initial.count >= target || (original.totalCount ?? Int.max) <= original.items.count {
            return result(initial)
        }
        let originals = Dictionary(original.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visible: [SectionItem] = []
        var seen = Set<String>()
        var originalSnapshotIsValid = true
        var cursor: Cursor?
        for _ in 0..<8 {
            try Task.checkCancellation()
            let page: LibraryScopedPage<Cursor>
            do {
                page = try await loadPage(cursor)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if case HTTPError.requestIdentityChanged = error { throw error }
                if case HTTPError.authorityChanged = error { throw error }
                // Inline fallback belongs to the original window, never a restarted one.
                if originalSnapshotIsValid {
                    for item in initial where seen.insert(item.id).inserted { visible.append(item) }
                }
                return result(visible, incomplete: true)
            }
            // A restarted cursor is a new ordering; don't combine its cards with the old window.
            if page.startsOver {
                visible.removeAll()
                seen.removeAll()
                originalSnapshotIsValid = false
            }
            for item in page.items where contains(item.type) && seen.insert(item.id).inserted {
                visible.append(originalSnapshotIsValid ? (originals[item.id] ?? item) : item)
            }
            if visible.count >= target || page.next == nil { return result(visible) }
            if page.items.isEmpty { return result(visible, incomplete: true) }
            cursor = page.next
        }
        return result(visible, incomplete: true)
    }
}

struct LibraryScopedPage<Cursor> {
    var items: [SectionItem]
    var next: Cursor?
    var startsOver = false
}
