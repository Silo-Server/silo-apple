import Foundation

/// The app's custom URL scheme, shared with the Android clients and the
/// server's web pages.
///
/// Silo servers are self-hosted on arbitrary domains, so universal links
/// cannot reach the app; `silo://` is the one route in that works for every
/// deployment. Links that name a server carry it as a `server` query item.
///
/// Builds before the rename emitted `continuum://`, and the system may still
/// hold such links (Top Shelf items, delivered notifications, Live
/// Activities), so that scheme stays registered and is accepted as an alias.
enum SiloURLScheme {
    static let current = "silo"
    static let legacy = "continuum"

    static func isAppURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == current || scheme == legacy
    }
}
