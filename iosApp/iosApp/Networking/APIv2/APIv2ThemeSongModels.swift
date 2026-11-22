import Foundation

/// One owner's ordered local theme audio (`themes` on the v2 item detail).
/// An empty set keeps the requested item's ID and an empty `items` array.
struct ThemeSongSet: Codable, Equatable, Hashable, Sendable {
    let ownerId: String
    let items: [ThemeSong]
}

struct ThemeSong: Codable, Equatable, Hashable, Sendable {
    let id: String
    let title: String?
    let durationSeconds: Int?
    let container: String?
}

/// `GET /api/v2/catalog/themes/capabilities`.
struct APIv2ThemeSongsCapability: Decodable, Equatable, Sendable {
    let state: String
    let allowed: Bool?
    /// `routed` (audio may come from a proxy origin) or `local_direct_play`.
    let delivery: String?
    /// Whether the server can convert a theme this client cannot decode.
    let transcode: Bool?

    var isAvailable: Bool { state == "available" && allowed != false }
}

/// One container and codec pair for `accepted_formats`.
struct APIv2ThemeAudioFormat: Encodable, Equatable, Sendable {
    let container: String
    let audioCodec: String
}

/// The wire answer to `POST .../themes/{theme_id}/playback`. `url` is a
/// short-lived credential: it stays out of logs, caches and descriptions.
struct APIv2ThemePlayback: Decodable, Sendable {
    let url: String
    let delivery: String?
    let contentType: String?
}

/// Where to play one theme. The signed URL lives only here and in the audio
/// player; every description of this value omits it.
struct ThemeMusicGrant: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let url: URL
    /// A converted theme is a progressive stream with no byte ranges, so a loop
    /// replays it with a fresh grant instead of seeking back.
    let isConverted: Bool

    var description: String { "ThemeMusicGrant(converted: \(isConverted))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["isConverted": isConverted]) }
}
