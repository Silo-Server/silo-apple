import Foundation

enum ContinuumDeepLink: Equatable {
    case downloads
    case item(contentId: String)
    case play(contentId: String)

    static func parse(_ url: URL) -> ContinuumDeepLink? {
        guard url.scheme?.lowercased() == "continuum",
              let host = url.host?.lowercased() else {
            return nil
        }

        if host == "downloads" {
            return .downloads
        }

        let contentId = url.pathComponents
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentId, !contentId.isEmpty else { return nil }

        switch host {
        case "item": return .item(contentId: contentId)
        case "play": return .play(contentId: contentId)
        default: return nil
        }
    }
}
