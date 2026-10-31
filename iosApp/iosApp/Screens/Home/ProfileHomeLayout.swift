import Foundation

/// The profile's own Home layout as the server stores it: one override set
/// per profile and page, the same layout the web app's Home Screen settings
/// and an admin's per-profile Home sections card edit. Home itself only
/// renders `/api/v2/home/sections` in server order; nothing here is kept on
/// the device.
enum ProfileHomeLayout {
    /// The override set to save after the profile reordered or showed/hid
    /// rows. `rows` is the full settings list in its new display order with
    /// each row's new `hidden` flag; `baseline` is the list as last read or
    /// saved; `saved` is what the profile saved before.
    ///
    /// Positions are written only once the profile orders the page: when
    /// `rows` changes the order of `baseline`, or an admin row's saved
    /// override already pins a position. Until then the page keeps following
    /// the admin's order (the server uses a saved position whenever one is
    /// present), so a show/hide stores only visibility, and an admin row
    /// without a saved override gets one only when it is hidden. This matches
    /// the web editor's `buildSectionOverrides`.
    ///
    /// The save replaces the profile's whole override set, so this keeps
    /// everything else it saved: a row's saved override is copied unchanged
    /// except for its position and visibility, and saved overrides for rows
    /// not in the list (removed rows, for one) are kept as they are.
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

        let ordered = sharedOrder(rows, baseline) != sharedOrder(baseline, rows)
            || saved.contains { !$0.sectionId.isEmpty && $0.position != nil }

        var used = Set<Int>()
        var result: [APIv2SectionOverride] = []
        for (position, row) in rows.enumerated() {
            let key = row.isCustom ? "custom:\(row.id)" : "section:\(row.id)"
            guard let index = savedIndex[key] else {
                // A profile-built row exists only through its saved override;
                // without one there is nothing to rebuild it from.
                guard !row.isCustom, ordered || row.hidden else { continue }
                result.append(APIv2SectionOverride(id: newID(), sectionId: row.id,
                                                   position: ordered ? position : nil, hidden: row.hidden))
                continue
            }
            used.insert(index)
            var override = saved[index]
            if override.id.isEmpty { override.id = newID() }
            if ordered { override.position = position }
            override.hidden = row.hidden
            result.append(override)
        }

        let latestPerKey = Set(savedIndex.values)
        for (index, override) in saved.enumerated() where !used.contains(index) && latestPerKey.contains(index) {
            result.append(override)
        }
        return result
    }

    /// The ids of `a` in order, keeping only the ids `b` also has.
    private static func sharedOrder(_ a: [APIv2ProfileSectionSetting], _ b: [APIv2ProfileSectionSetting]) -> [String] {
        let ids = Set(b.map(\.id))
        return a.map(\.id).filter { ids.contains($0) }
    }

    private static func matchKey(_ override: APIv2SectionOverride) -> String {
        override.sectionId.isEmpty ? "custom:\(override.id)" : "section:\(override.sectionId)"
    }
}
