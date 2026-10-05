import Foundation
import Nuke

/// The identity artwork is cached under, so a re-signed URL for bytes
/// already on disk or in memory does not download them again.
///
/// The server signs `/api/v2/artwork/<key>` with `exp` and `sig` query items
/// and re-signs URLs as they age. A revisioned key names immutable bytes: its
/// file name carries a content revision between the variant and the
/// extension (`…/poster/w500.<revision>.webp`), and the server re-signs it
/// once per UTC day and serves it `immutable`. Any other key
/// (`…/poster/w500.webp`) can be replaced in place, is re-signed every 15
/// minutes, and is served `no-cache`, so it keeps its full URL as its
/// identity.
enum ArtworkCacheKey {
    private static let artworkRoute = "/api/v2/artwork/"
    private static let signatureItems: Set<String> = ["exp", "sig"]

    /// The URL without its signature for revisioned Silo artwork, with any
    /// other query items sorted. Nil for every other URL.
    static func stableImageID(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.percentEncodedPath.hasPrefix(artworkRoute),
              isRevisioned(key: String(components.path.dropFirst(artworkRoute.count))) else {
            return nil
        }
        let kept = (components.percentEncodedQueryItems ?? [])
            .filter { !signatureItems.contains($0.name) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        components.fragment = nil
        return components.string
    }

    /// The identity Nuke caches `url` under.
    static func imageID(for url: URL) -> String {
        stableImageID(for: url) ?? url.absoluteString
    }

    /// Matches the server's revision rule: the file name without its final
    /// extension has a dot followed by a non-empty revision.
    static func isRevisioned(key: String) -> Bool {
        let name = key.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        let stem = name.lastIndex(of: ".").map { name[..<$0] } ?? name
        guard let dot = stem.firstIndex(of: ".") else { return false }
        return stem.index(after: dot) < stem.endIndex
    }
}

extension ImageRequest {
    /// A request for artwork at `url`, cached under its stable identity
    /// (see `ArtworkCacheKey`). Every artwork request goes through this so
    /// views, warm-ups, and cache lookups agree on the key.
    init(artwork url: URL, priority: Priority = .normal, options: Options = []) {
        self.init(url: url, priority: priority, options: options)
        if let stableID = ArtworkCacheKey.stableImageID(for: url) {
            imageID = stableID
        }
    }
}
