import Foundation

/// `GET /api/v2/shuffles/capabilities`. Shuffle is offered only when the
/// server reports it available and the scope kind is listed.
struct APIv2ShuffleCapability: Decodable, Equatable, Sendable {
    let state: String
    let allowed: Bool?
    let scopeKinds: [String]?

    var isAvailable: Bool { state == "available" && allowed != false }

    func supports(_ kind: ShuffleScopeKind) -> Bool {
        isAvailable && (scopeKinds ?? []).contains(kind.rawValue)
    }
}

/// What a shuffle draws its picks from.
enum ShuffleScopeKind: String, Codable, Sendable {
    case library
    case series
    case season
    case libraryCollection = "library_collection"
    case userCollection = "user_collection"
}

struct ShuffleScopeRequest: Encodable, Equatable, Sendable {
    let kind: ShuffleScopeKind
    let id: String
}

/// A running shuffle: the item to play now and the server's pick to follow
/// it. `next` equals `current` only when one item in the scope can play.
struct APIv2Shuffle: Decodable, Equatable, Sendable {
    struct Scope: Decodable, Equatable, Sendable {
        let kind: String
        let id: String
        let title: String
        /// A season scope's series title.
        let parentTitle: String?
    }

    let id: String
    let scope: Scope
    let current: ShuffleItem
    let next: ShuffleItem

    /// Names what the shuffle draws from: "Movies", "Breaking Bad · Season 2".
    var scopeLabel: String {
        if let parent = scope.parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !parent.isEmpty {
            return "\(parent) · \(scope.title)"
        }
        return scope.title
    }

    /// The pick that follows `current`, or nil when the scope has only the
    /// item that is playing.
    var upcoming: ShuffleItem? {
        next.contentId == current.contentId ? nil : next
    }
}

/// The catalog item card fields a shuffle pick needs to play and announce.
struct ShuffleItem: Decodable, Equatable, Sendable {
    let contentId: String
    let type: String
    let title: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let overview: String?
    let runtime: Int?
    let releaseDate: String?
    @ArtworkURL var posterUrl: String? = nil
    let posterThumbhash: String?
    @ArtworkURL var backdropUrl: String? = nil
    let backdropThumbhash: String?

    var isEpisode: Bool { SiloMediaType.isEpisode(type) }
}

/// Owner-visible shuffle failures. Other errors pass through unchanged.
enum ShuffleError: Error, Equatable {
    /// `404`: the profile cannot see the scope or the shuffle.
    case notFound
    /// `409`: nothing in the scope can play.
    case nothingToPlay

    static func classify(_ error: Error) -> ShuffleError? {
        guard case APIv2Error.problem(let problem) = error else { return nil }
        switch problem.status {
        case 404: return .notFound
        case 409: return .nothingToPlay
        default: return nil
        }
    }
}
