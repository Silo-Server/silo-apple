#if os(iOS) || os(tvOS)
import Foundation

/// The app links Siri's intents hand their spoken words to.
///
/// - `silo://search?q=<term>` opens Search with `term` filled in.
/// - `silo://play?q=<title>` plays the one library title matching `title`,
///   or opens Search for it when the match isn't clear.
/// - `silo://play?q=<title>&device=tv` (iOS) plays it on a Silo Apple TV.
///
/// Routing through a link gives Siri requests the same authentication,
/// profile-lock, and cold-launch queueing every other link gets in
/// `ContentView`. `silo://play/<contentId>` is a different link: it names
/// an exact item and has a path instead of a query.
enum SiriLink: Equatable {
    case search(term: String)
    case play(title: String, onTV: Bool)

    static let searchHost = "search"
    static let playHost = "play"
    private static let termQueryItem = "q"
    private static let deviceQueryItem = "device"
    private static let tvDevice = "tv"

    var url: URL? {
        var components = URLComponents()
        components.scheme = SiloURLScheme.current
        switch self {
        case .search(let term):
            components.host = Self.searchHost
            components.queryItems = [URLQueryItem(name: Self.termQueryItem, value: term)]
        case .play(let title, let onTV):
            components.host = Self.playHost
            components.queryItems = [URLQueryItem(name: Self.termQueryItem, value: title)]
            if onTV {
                components.queryItems?.append(URLQueryItem(name: Self.deviceQueryItem, value: Self.tvDevice))
            }
        }
        return components.url
    }

    /// Nil when `url` is not a Siri link. A search link with a blank term is
    /// still a search link (Search opens empty); a play link needs a title.
    init?(url: URL) {
        guard SiloURLScheme.isAppURL(url),
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        let term = items.first { $0.name == Self.termQueryItem }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch host {
        case Self.searchHost:
            self = .search(term: term)
        case Self.playHost:
            // `silo://play/<contentId>` is the exact-item link.
            guard url.pathComponents.count <= 1, !term.isEmpty else { return nil }
            let device = items.first { $0.name == Self.deviceQueryItem }?.value?.lowercased()
            self = .play(title: term, onTV: device == Self.tvDevice)
        default:
            return nil
        }
    }
}
#endif
