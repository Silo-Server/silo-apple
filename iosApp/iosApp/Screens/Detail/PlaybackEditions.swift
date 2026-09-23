import Foundation

/// Groups a content's file versions into editions (Director's Cut, Theatrical,
/// …) and resolves the edition that owns a given file. The server's
/// `edition_key` is the stable grouping identity; display uses `edition_raw`,
/// then "Standard".
/// A version with no edition label is grouped under "Standard".
enum PlaybackEditions {
    struct Edition: Identifiable, Hashable {
        let id: String          // normalized (lowercased) key
        let label: String       // display name
        let versions: [FileVersion]
    }

    /// Distinct editions in first-seen order.
    static func editions(from versions: [FileVersion]) -> [Edition] {
        var order: [String] = []
        var groups: [String: [FileVersion]] = [:]
        var labels: [String: String] = [:]
        for version in versions {
            let key = normalizedKey(for: version)
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
                labels[key] = version.editionDisplayLabel
            }
            groups[key]?.append(version)
        }
        return order.map { key in
            Edition(
                id: key,
                label: labels[key] ?? "Standard",
                versions: groups[key] ?? []
            )
        }
    }

    /// The edition that owns `fileId`, if any.
    static func edition(forFileId fileId: Int?, in versions: [FileVersion]) -> Edition? {
        guard let fileId else { return nil }
        return editions(from: versions).first { edition in
            edition.versions.contains { $0.fileId == fileId }
        }
    }

    private static func normalizedKey(for version: FileVersion) -> String {
        let key = version.editionKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !key.isEmpty { return key }
        return version.editionDisplayLabel.lowercased()
    }
}
