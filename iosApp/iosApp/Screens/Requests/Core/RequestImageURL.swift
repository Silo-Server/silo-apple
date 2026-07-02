import Foundation

/// TMDB image sizes used by the requests UI. The server hands back raw TMDB
/// paths (`/abc123.jpg`); clients build CDN URLs directly, matching the web
/// app (`tmdbImageURL` in `mediaRequests.ts`) and Android — there is no
/// server-side proxy for these.
enum RequestImageSize: String {
    case poster = "w342"
    case backdrop = "w1280"
}

enum RequestImageURL {
    private static let base = "https://image.tmdb.org/t/p/"

    /// Builds a TMDB image URL from a raw path. Passes through values that
    /// are already absolute URLs (defensive, mirrors Android's
    /// `requestImageUrl`); returns nil for blank or malformed paths.
    static func build(_ path: String?, size: RequestImageSize) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        guard path.hasPrefix("/") else { return nil }
        return base + size.rawValue + path
    }
}
