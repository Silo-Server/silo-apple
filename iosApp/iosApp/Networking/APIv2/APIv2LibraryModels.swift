import Foundation

extension LibraryCollectionsResponse {
    /// Maps the v2 Collections tab onto the sections the library screens
    /// render. Admin groups show as regular collections and
    /// `user_collections` groups as personal ones; any other group kind also
    /// resolves as regular, as on Android, so it is never read as personal.
    /// Groups keep the server's display order, and the ungrouped bucket goes
    /// after every group whose sort order does not exceed its own.
    init(_ tab: APIv2LibraryCollectionTab) {
        if tab.groups.isEmpty, tab.ungrouped == nil {
            // Groups are not configured: the curated list is the whole tab.
            let flat = tab.collections.map {
                LibraryCollection(id: $0.id, name: $0.title, collectionType: $0.collectionType,
                                  itemCount: $0.itemCount, posterUrl: $0.posterUrl.isEmpty ? nil : $0.posterUrl,
                                  posterThumbhash: $0.posterThumbhash, kind: .regular)
            }
            self.init(collections: flat, sections: [])
            return
        }

        let definitions = Dictionary(tab.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func cards(_ values: [APIv2LibraryCollectionCard], kind: LibraryCollectionKind) -> [LibraryCollection] {
            values.map {
                LibraryCollection(
                    id: $0.id,
                    name: $0.title,
                    collectionType: definitions[$0.id]?.collectionType,
                    itemCount: $0.itemCount,
                    posterUrl: $0.posterUrl.isEmpty ? nil : $0.posterUrl,
                    posterThumbhash: $0.posterThumbhash,
                    kind: kind,
                    creatorProfileId: $0.creatorProfileId
                )
            }
        }

        var sections = tab.groups.map { group -> LibraryCollectionSection in
            let kind: LibraryCollectionKind = group.kind == "user_collections" ? .userCollections : .regular
            return LibraryCollectionSection(id: group.id, name: group.name, kind: kind,
                                            collections: cards(group.collections, kind: kind))
        }
        if let ungrouped = tab.ungrouped, !ungrouped.collections.isEmpty {
            let section = LibraryCollectionSection(id: "__ungrouped__", name: "", kind: .regular,
                                                   collections: cards(ungrouped.collections, kind: .regular))
            let position = tab.groups.filter { $0.sortOrder <= ungrouped.sortOrder }.count
            sections.insert(section, at: position)
        }

        var seen = Set<String>()
        let flat = sections.flatMap(\.collections).filter { seen.insert($0.id).inserted }
        self.init(collections: flat, sections: sections)
    }
}
