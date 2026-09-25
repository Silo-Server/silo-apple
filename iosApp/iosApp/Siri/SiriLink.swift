#if os(iOS) || os(tvOS)
import Foundation

/// The app links Siri's intents hand their requests to.
///
/// - `silo://search?q=<term>` opens Search with `term` filled in.
/// - `silo://play?q=<title>` plays the one library title matching `title`,
///   or opens Search for it when the match isn't clear.
/// - `silo://play?id=<contentId>&kind=movie|series&q=<title>` plays a title
///   Siri already identified; `title` is the Search fallback.
/// - Either play link with `&device=tv` (iOS) plays on a Silo Apple TV.
///
/// Routing through a link gives Siri requests the same authentication,
/// profile-lock, and cold-launch queueing every other link gets in
/// `ContentView`. `silo://play/<contentId>` is a different link: it names
/// an exact item and has a path instead of a query.
enum SiriLink: Equatable {
    case search(term: String)
    case play(title: String, onTV: Bool)
    case playTitle(contentId: String, title: String, isSeries: Bool, onTV: Bool)

    static let searchHost = "search"
    static let playHost = "play"
    private static let termQueryItem = "q"
    private static let idQueryItem = "id"
    private static let kindQueryItem = "kind"
    private static let seriesKind = "series"
    private static let movieKind = "movie"
    private static let deviceQueryItem = "device"
    private static let tvDevice = "tv"

    var url: URL? {
        var components = URLComponents()
        components.scheme = SiloURLScheme.current
        var items: [URLQueryItem]
        let onTV: Bool
        switch self {
        case .search(let term):
            components.host = Self.searchHost
            components.queryItems = [URLQueryItem(name: Self.termQueryItem, value: term)]
            return components.url
        case .play(let title, let tv):
            items = [URLQueryItem(name: Self.termQueryItem, value: title)]
            onTV = tv
        case .playTitle(let contentId, let title, let isSeries, let tv):
            items = [
                URLQueryItem(name: Self.idQueryItem, value: contentId),
                URLQueryItem(name: Self.kindQueryItem, value: isSeries ? Self.seriesKind : Self.movieKind),
                URLQueryItem(name: Self.termQueryItem, value: title),
            ]
            onTV = tv
        }
        components.host = Self.playHost
        if onTV {
            items.append(URLQueryItem(name: Self.deviceQueryItem, value: Self.tvDevice))
        }
        components.queryItems = items
        return components.url
    }

    /// Nil when `url` is not a Siri link. A search link with a blank term is
    /// still a search link (Search opens empty); a play link needs a title
    /// or an id.
    init?(url: URL) {
        guard SiloURLScheme.isAppURL(url),
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String {
            items.first { $0.name == name }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let term = value(Self.termQueryItem)

        switch host {
        case Self.searchHost:
            self = .search(term: term)
        case Self.playHost:
            // `silo://play/<contentId>` is the exact-item link.
            guard url.pathComponents.count <= 1 else { return nil }
            let onTV = value(Self.deviceQueryItem).lowercased() == Self.tvDevice
            let contentId = value(Self.idQueryItem)
            if !contentId.isEmpty {
                self = .playTitle(
                    contentId: contentId,
                    title: term,
                    isSeries: value(Self.kindQueryItem).lowercased() == Self.seriesKind,
                    onTV: onTV
                )
            } else if !term.isEmpty {
                self = .play(title: term, onTV: onTV)
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}
#endif
