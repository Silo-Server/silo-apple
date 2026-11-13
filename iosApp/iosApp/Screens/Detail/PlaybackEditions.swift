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
                label: labels[key] ?? standardLabel,
                versions: groups[key] ?? []
            )
        }
    }

    /// The label of a version with no named edition. It is data as well as
    /// text: `FileVersion.editionDisplayLabel` returns it and the download
    /// sheet compares against it, so it stays English and is translated only
    /// where it is shown.
    static let standardLabel = "Standard" // i18n-ignore: compared edition value; shown through displayLabel

    /// An edition label as shown: the catalog's "Standard" for the unnamed
    /// edition, otherwise the label from the file.
    static func displayLabel(_ label: String, locale: Locale) -> String {
        label == standardLabel ? AppLanguage.string(.detailEditionStandard, locale: locale) : label
    }

    /// The edition that owns `fileId`, if any.
    static func edition(forFileId fileId: Int?, in versions: [FileVersion]) -> Edition? {
        guard let fileId else { return nil }
        return editions(from: versions).first { edition in
            edition.versions.contains { $0.fileId == fileId }
        }
    }

    /// The edition whose key is `key` (an `Edition.id` or a server
    /// `edition_key`), if any.
    static func edition(forKey key: String?, in versions: [FileVersion]) -> Edition? {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !key.isEmpty else { return nil }
        return editions(from: versions).first { $0.id == key }
    }

    private static func normalizedKey(for version: FileVersion) -> String {
        let key = version.editionKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !key.isEmpty { return key }
        return version.editionDisplayLabel.lowercased()
    }
}
