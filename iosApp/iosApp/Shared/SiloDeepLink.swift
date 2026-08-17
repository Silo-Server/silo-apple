import Foundation

/// The custom URL schemes the Silo apps answer to.
///
/// `silo` is the current scheme: everything in this repo that *builds* a deep
/// link emits it, and it matches the Android client, which registers only
/// `silo`. `continuum` is the original brand's scheme. It stays registered and
/// accepted for a deprecation window because notifications already delivered
/// to a device — and any external sender still on the old brand — carry it.
enum SiloDeepLink {
    /// Scheme emitted by every deep-link builder in this repo.
    static let preferredScheme = "silo"

    /// Every scheme the apps accept, lowercased. Order is not significant.
    static let acceptedSchemes = [preferredScheme, "continuum"]

    static func isSupported(scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return acceptedSchemes.contains(scheme)
    }

    static func isSupported(_ url: URL) -> Bool {
        isSupported(scheme: url.scheme)
    }
}
