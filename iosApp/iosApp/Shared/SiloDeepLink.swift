import Foundation

/// The custom URL scheme the Silo apps answer to.
///
/// `silo` is the only scheme: everything in this repo that *builds* a deep link
/// emits it, it is the only one registered in either Info.plist, and it matches
/// the Android client, which registers only `silo`. The pre-rename scheme is no
/// longer registered, so the system never routes it here and links carrying it
/// are rejected.
enum SiloDeepLink {
    /// Scheme emitted by every deep-link builder in this repo.
    static let preferredScheme = "silo"

    /// Every scheme the apps accept, lowercased. Order is not significant.
    static let acceptedSchemes = [preferredScheme]

    static func isSupported(scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return acceptedSchemes.contains(scheme)
    }

    static func isSupported(_ url: URL) -> Bool {
        isSupported(scheme: url.scheme)
    }
}
