import Foundation

/// One card in the merged "Trailers & More" rail: either a remote provider
/// video (YouTube) or a locally-scanned extras file.
///
/// `Identifiable` ids are stable across refetches — remotes key off the
/// site reference, locals off their own `contentId` — so SwiftUI keeps card
/// identity when a poll swaps in a new `ItemDetail`. The two cases are
/// namespaced so a local extra whose contentId happens to collide with a
/// YouTube key cannot shadow it.
enum TrailerRailEntry: Identifiable, Hashable {
    case remote(ItemVideo)
    case local(ItemExtra)

    var id: String {
        switch self {
        case .remote(let video): return "remote:\(video.site):\(video.siteKey)"
        case .local(let extra): return "local:\(extra.contentId)"
        }
    }

    /// Shared kind vocabulary across both cases (`trailer`, `featurette`, …).
    var kind: String {
        switch self {
        case .remote(let video): return video.kind
        case .local(let extra): return extra.kind
        }
    }

    /// Card title. Falls back to the kind label when the server has no name
    /// for the entry (both `name` and `title` are `omitempty`).
    var title: String {
        switch self {
        case .remote(let video):
            let name = video.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
            return ExtraKindLabels.label(for: video.kind)
        case .local(let extra):
            let title = extra.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty { return title }
            return ExtraKindLabels.label(for: extra.kind)
        }
    }
}

/// Pure shaping + URL construction for the detail page's trailers rail.
/// Deliberately free of SwiftUI so both the phone and TV rails render the
/// same list from the same rules, and so it is testable headless.
enum TrailerRail {
    /// The only remote site the clients can play. Everything else the
    /// server may store (vimeo, …) is dropped rather than rendered as a
    /// card that cannot open.
    static let supportedSite = "youtube"

    /// The remote videos a rail can actually render, in server order.
    ///
    /// Shared with ``TrailerFetchCoordinator``: its "did the refresh find
    /// something" check has to count exactly what the user would see appear,
    /// or a fetch that returns only unplayable sites reads as a success and
    /// nothing new shows up.
    static func supportedVideos(_ videos: [ItemVideo]?) -> [ItemVideo] {
        (videos ?? []).filter { $0.site.lowercased() == supportedSite }
    }

    /// Merge an item's remote videos and local extras into one ordered rail.
    ///
    /// Remote videos come first — the server already sorts them for display
    /// (trailers first, official first) and that order is preserved verbatim
    /// — then local extras in server order. When `allowRemote` is false
    /// (e.g. tvOS without the YouTube app installed) remote entries are
    /// dropped entirely, leaving a local-extras-only rail.
    static func entries(
        videos: [ItemVideo]?,
        extras: [ItemExtra]?,
        allowRemote: Bool
    ) -> [TrailerRailEntry] {
        var result: [TrailerRailEntry] = []
        if allowRemote {
            result.append(contentsOf: supportedVideos(videos).map { TrailerRailEntry.remote($0) })
        }
        if let extras {
            result.append(contentsOf: extras.map { TrailerRailEntry.local($0) })
        }
        return result
    }

    // MARK: - Remote URLs

    /// YouTube's still thumbnail for a video. `hqdefault` is the largest
    /// size guaranteed to exist for every video (maxresdefault 404s on
    /// older uploads).
    static func thumbnailURL(siteKey: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(siteKey)/hqdefault.jpg")
    }

    /// Deep link into the installed YouTube app on every Apple platform.
    ///
    /// The full web URL with only the scheme swapped — NOT the iOS-style
    /// short form `youtube://watch?v=`. The tvOS YouTube app ignores the
    /// short form (opens on its home screen, id dropped); the full-URL
    /// form starts the video. Verified on Apple TV 4K hardware (2nd gen,
    /// tvOS 26, Aug 2026); same format Home Assistant documents for its
    /// Apple TV deep links.
    static func youtubeDeepLinkURL(siteKey: String) -> URL? {
        URL(string: "youtube://www.youtube.com/watch?v=\(siteKey)")
    }

    /// Public watch page used when no installed app accepts the YouTube
    /// custom scheme. The system opens this in the default browser.
    static func youtubeWatchURL(siteKey: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(siteKey)")
    }
}
