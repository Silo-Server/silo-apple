import Foundation

/// The profile's own page layout as the server stores it: one override set
/// per profile and page (Home or Library), the same layout the web app's
/// Home Screen settings and an admin's per-profile Home sections card edit.
/// Home itself only renders `/api/v2/home/sections` in server order; nothing
/// here is kept on the device.
enum ProfileHomeLayout {
    /// The override set to save after the profile reordered, showed/hid, added,
    /// or removed rows. `rows` is the full settings list in its new display
    /// order with each row's new `hidden` flag; `baseline` is the list as last
    /// read or saved; `saved` is what the profile saved before.
    ///
    /// **CRITICAL RULE (from PR #878)**: Positions are written only once the
    /// profile orders the page: when `rows` changes the order of `baseline`, or
    /// an admin row's saved override already pins a position. Until then the
    /// page keeps following the admin's order (the server uses a saved position
    /// whenever one is present), so a show/hide stores only visibility, and an
    /// admin row without a saved override gets one only when it is hidden.
    ///
    /// User-added rows (`isCustom == true`) exist through their saved override
    /// (with `isUserAdded: true`, `sectionId: ""`). Removing a user-added row
    /// from `rows` omits its override from the saved array so the server deletes
    /// it. Saved overrides for admin rows not in `rows` (such as removed rows)
    /// are preserved unchanged.
    static func overrides(
        rows: [APIv2ProfileSectionSetting],
        baseline: [APIv2ProfileSectionSetting],
        saved: [APIv2SectionOverride],
        newID: () -> String = { UUID().uuidString.lowercased() }
    ) -> [APIv2SectionOverride] {
        // The server applies the last override saved for a section, so the
        // last one wins here too; earlier duplicates are superseded.
        var savedIndex: [String: Int] = [:]
        for (index, override) in saved.enumerated() {
            savedIndex[matchKey(override)] = index
        }

        // Matches the web client's `buildSectionOverrides`: positions follow the
        // list only once the profile orders the page. Until then admin rows keep
        // the admin's positions and user-added rows keep their own, which may
        // sit between sparse admin positions (0, 10, 20…), so rewriting them to
        // list indices would move them past admin rows.
        let ordered = sharedOrder(rows, baseline) != sharedOrder(baseline, rows)
            || saved.contains { !$0.sectionId.isEmpty && $0.position != nil }
            || movedNewRow(rows, baseline)

        var used = Set<Int>()
        var result: [APIv2SectionOverride] = []
        for (position, row) in rows.enumerated() {
            let key = row.isCustom ? "custom:\(row.id)" : "section:\(row.id)"
            guard let index = savedIndex[key] else {
                if row.isCustom {
                    // Newly added user row not yet in `saved`.
                    result.append(APIv2SectionOverride(
                        id: row.id.isEmpty ? newID() : row.id,
                        sectionId: "",
                        position: ordered ? position : row.position,
                        hidden: row.hidden,
                        featured: row.featured ? true : nil,
                        itemLimit: row.itemLimit > 0 ? row.itemLimit : nil,
                        isUserAdded: true,
                        userSectionType: row.sectionType,
                        userTitle: row.title,
                        userConfig: row.config
                    ))
                    continue
                }
                guard ordered || row.hidden else { continue }
                result.append(APIv2SectionOverride(
                    id: newID(),
                    sectionId: row.id,
                    position: ordered ? position : nil,
                    hidden: row.hidden
                ))
                continue
            }
            used.insert(index)
            var override = saved[index]
            if override.id.isEmpty { override.id = newID() }
            if ordered {
                override.position = position
            } else if row.isCustom && override.position == nil {
                override.position = row.position
            }
            override.hidden = row.hidden
            result.append(override)
        }

        let latestPerKey = Set(savedIndex.values)
        for (index, override) in saved.enumerated() where !used.contains(index) && latestPerKey.contains(index) {
            // Removing a user-added row omits its override from the saved array.
            if override.isUserAdded || override.sectionId.isEmpty { continue }
            result.append(override)
        }
        return result
    }

    /// The position for a row appended at the bottom of the page: one past the
    /// highest position on it, like the web client's `nextAppendPosition`.
    /// Admin positions can be sparse, so the row count would land the new row
    /// above existing rows.
    static func nextAppendPosition(after rows: [APIv2ProfileSectionSetting]) -> Int {
        (rows.map(\.position).max() ?? -1) + 1
    }

    /// Finds an active (non-hidden) collection row matching `collectionId`.
    static func pinnedCollectionRow(
        collectionId: String,
        isUserCollection: Bool,
        in rows: [APIv2ProfileSectionSetting]
    ) -> APIv2ProfileSectionSetting? {
        rows.first { row in
            guard !row.hidden else { return false }
            let type = row.sectionType.lowercased()
            guard type == "collection" || type == "user_collection" || type == "library_collection" else {
                return false
            }
            if isUserCollection {
                return row.userCollectionId == collectionId
            }
            return row.libraryCollectionId == collectionId
        }
    }

    /// Finds any collection row (even hidden) matching `collectionId`.
    static func matchingCollectionRow(
        collectionId: String,
        isUserCollection: Bool,
        in rows: [APIv2ProfileSectionSetting]
    ) -> APIv2ProfileSectionSetting? {
        rows.first { row in
            let type = row.sectionType.lowercased()
            guard type == "collection" || type == "user_collection" || type == "library_collection" else {
                return false
            }
            if isUserCollection {
                return row.userCollectionId == collectionId
            }
            return row.libraryCollectionId == collectionId
        }
    }

    /// Builds a new profile-owned collection row setting.
    static func makeCollectionRow(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        collectionId: String,
        isUserCollection: Bool,
        position: Int,
        itemLimit: Int = 20,
        featured: Bool = false
    ) -> APIv2ProfileSectionSetting {
        let key = isUserCollection ? "user_collection_id" : "library_collection_id"
        return APIv2ProfileSectionSetting(
            id: id,
            sectionType: "collection",
            title: title,
            defaultTitle: title,
            featured: featured,
            itemLimit: itemLimit,
            hidden: false,
            isCustom: true,
            customized: true,
            position: position,
            config: [key: .string(collectionId)]
        )
    }

    /// Whether a row added since `baseline` was read has moved: rows are added
    /// at the bottom with rising positions, so any other placement is the
    /// profile's own ordering (the web client's `movedNewRow`).
    private static func movedNewRow(
        _ rows: [APIv2ProfileSectionSetting],
        _ baseline: [APIv2ProfileSectionSetting]
    ) -> Bool {
        let known = Set(baseline.map(\.id))
        guard let firstNew = rows.firstIndex(where: { !known.contains($0.id) }) else { return false }
        var previous: Int?
        for row in rows[firstNew...] {
            if known.contains(row.id) { return true }
            if let previous, row.position < previous { return true }
            previous = row.position
        }
        return false
    }

    /// The ids of `a` in order, keeping only the ids `b` also has.
    private static func sharedOrder(
        _ a: [APIv2ProfileSectionSetting],
        _ b: [APIv2ProfileSectionSetting]
    ) -> [String] {
        let ids = Set(b.map(\.id))
        return a.map(\.id).filter { ids.contains($0) }
    }

    private static func matchKey(_ override: APIv2SectionOverride) -> String {
        override.sectionId.isEmpty ? "custom:\(override.id)" : "section:\(override.sectionId)"
    }
}
