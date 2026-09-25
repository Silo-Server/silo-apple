#if os(iOS) || os(tvOS)
import Foundation

/// `silo://search?q=<term>` opens Search with `term` filled in.
///
/// Siri's in-app search (`SearchInSiloIntent`) hands its term to the app
/// through this link, so a Siri request shares the authentication,
/// profile-lock, and cold-launch queueing every other link gets in
/// `ContentView`.
enum SiriSearchLink {
    static let host = "search"
    private static let termQueryItem = "q"

    static func url(term: String) -> URL? {
        var components = URLComponents()
        components.scheme = SiloURLScheme.current
        components.host = host
        components.queryItems = [URLQueryItem(name: termQueryItem, value: term)]
        return components.url
    }

    /// The trimmed search term, empty when the link carries none, or nil
    /// when `url` is not a search link.
    static func term(from url: URL) -> String? {
        guard SiloURLScheme.isAppURL(url),
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?
            .first { $0.name == termQueryItem }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
#endif
