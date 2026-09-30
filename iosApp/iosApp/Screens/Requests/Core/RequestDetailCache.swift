import Foundation

/// Session memory for request detail pages, so opening a title the app has
/// already seen paints its final layout on the first frame instead of
/// building itself as reads land.
///
/// It holds three things, keyed by media type + TMDB id:
/// - the title detail (`RequestMediaDetail`) from the last read or prefetch;
/// - the signed-in user's own request records, from every `/requests/mine`
///   read — the status is known before the page asks;
/// - admin records from the approval queue.
///
/// A tap seeds it too: a card carries enough of the title for a
/// provisional page when no detail has been read yet. Every page still
/// refreshes from the server; this only decides the first frame.
///
/// Profile-scoped: `RequestsEventBus.reset()` clears it on sign-out and
/// profile or server switches.
@MainActor
final class RequestDetailCache {
    static let shared = RequestDetailCache()

    /// Tests use their own instance; the app shares one.
    init() {}

    struct Key: Hashable {
        let mediaType: RequestMediaType
        let tmdbId: Int
    }

    private var details: [Key: RequestMediaDetail] = [:]
    private var detailOrder: [Key] = []
    private var ownRecords: [Key: MediaRequest] = [:]
    private var moderationRecords: [Key: MediaRequest] = [:]
    private var seeds: [Key: RequestMediaResult] = [:]
    private var prefetchTask: Task<Void, Never>?

    /// Bounded so a long browsing session can't grow without limit.
    private static let detailLimit = 80
    /// Rows warmed per list read: roughly the first screenful and a bit.
    static let prefetchCount = 10

    // MARK: - Reads

    func detail(_ key: Key) -> RequestMediaDetail? { details[key] }
    func ownRecord(_ key: Key) -> MediaRequest? { ownRecords[key] }
    func moderationRecord(_ key: Key) -> MediaRequest? { moderationRecords[key] }

    /// A page to show before the detail read answers: the cached detail, or
    /// one built from what a card or record already carried.
    func firstFrameDetail(_ key: Key) -> RequestMediaDetail? {
        if let detail = details[key] { return detail }
        if let seed = seeds[key] { return Self.provisionalDetail(from: seed) }
        if let record = ownRecords[key] ?? moderationRecords[key] {
            return Self.provisionalDetail(from: record)
        }
        return nil
    }

    // MARK: - Writes

    func store(_ detail: RequestMediaDetail) {
        let key = Key(mediaType: detail.mediaType, tmdbId: detail.tmdbId)
        details[key] = detail
        detailOrder.removeAll { $0 == key }
        detailOrder.append(key)
        if detailOrder.count > Self.detailLimit {
            details.removeValue(forKey: detailOrder.removeFirst())
        }
    }

    /// A complete `/requests/mine` read. Replaces what was known, so a
    /// cancelled request no longer seeds a page.
    func storeOwnRecords(_ records: [MediaRequest]) {
        var next: [Key: MediaRequest] = [:]
        for record in records where record.outcome != .cancelled {
            let key = Key(mediaType: record.mediaType, tmdbId: record.tmdbId)
            // Newest wins when a title was requested more than once.
            if let existing = next[key], existing.createdAt > record.createdAt { continue }
            next[key] = record
        }
        ownRecords = next
    }

    func storeOwnRecord(_ record: MediaRequest) {
        let key = Key(mediaType: record.mediaType, tmdbId: record.tmdbId)
        if record.outcome == .cancelled {
            ownRecords.removeValue(forKey: key)
        } else {
            ownRecords[key] = record
        }
    }

    func storeModerationRecords(_ records: [MediaRequest]) {
        var next: [Key: MediaRequest] = [:]
        for record in records {
            next[Key(mediaType: record.mediaType, tmdbId: record.tmdbId)] = record
        }
        moderationRecords = next
    }

    func seed(_ result: RequestMediaResult) {
        seeds[Key(mediaType: result.mediaType, tmdbId: result.tmdbId)] = result
    }

    func clear() {
        prefetchTask?.cancel()
        prefetchTask = nil
        details.removeAll()
        detailOrder.removeAll()
        ownRecords.removeAll()
        moderationRecords.removeAll()
        seeds.removeAll()
    }

    // MARK: - Prefetch

    /// Warms detail and artwork for the first rows of a list, one read at a
    /// time and only for titles not already cached, so opening any of them
    /// lands on the finished page. Replaces an earlier prefetch in flight.
    func prefetch(_ records: [MediaRequest], api: SiloAPI = .shared) {
        let keys = records
            .map { Key(mediaType: $0.mediaType, tmdbId: $0.tmdbId) }
            .filter { details[$0] == nil && ($0.mediaType == .movie || $0.mediaType == .series) }
        var unique: [Key] = []
        for key in keys where !unique.contains(key) { unique.append(key) }
        let batch = Array(unique.prefix(Self.prefetchCount))
        guard !batch.isEmpty else { return }

        Self.warmArtwork(records.prefix(Self.prefetchCount).flatMap {
            [($0.backdropPath, .backdrop), ($0.posterPath, .poster)]
        })
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            for key in batch {
                guard !Task.isCancelled else { return }
                guard self?.details[key] == nil,
                      let detail = try? await api.requestsDetail(mediaType: key.mediaType, tmdbId: key.tmdbId),
                      !Task.isCancelled else { continue }
                self?.store(detail)
                Self.warmArtwork([(detail.backdropPath, .backdrop)])
            }
        }
    }

    /// Pulls artwork bytes into the shared disk cache, so the detail hero
    /// decodes locally at whatever size it asks for.
    private static func warmArtwork(_ artwork: [(path: String?, size: RequestImageSize)]) {
        #if !os(macOS)
        let urls = artwork.compactMap { path, size in
            RequestImageURL.build(path, size: size).flatMap(URL.init(string:))
        }
        PosterImageCache.prefetchArtworkData(urls)
        #endif
    }

    // MARK: - Provisional detail

    static func provisionalDetail(from result: RequestMediaResult) -> RequestMediaDetail {
        RequestMediaDetail(
            mediaType: result.mediaType, tmdbId: result.tmdbId, imdbId: nil, tvdbId: nil,
            title: result.title, tagline: nil, overview: result.overview,
            posterPath: result.posterPath, backdropPath: result.backdropPath,
            releaseDate: result.releaseDate, year: result.year, runtime: nil, genres: nil,
            voteAverage: result.voteAverage, voteCount: nil, contentRating: nil,
            numberOfSeasons: nil, numberOfEpisodes: nil, networks: nil, director: nil,
            creators: nil, recommendations: nil, availability: result.availability,
            libraryContentId: result.libraryContentId, request: result.request
        )
    }

    static func provisionalDetail(from record: MediaRequest) -> RequestMediaDetail {
        RequestMediaDetail(
            mediaType: record.mediaType, tmdbId: record.tmdbId, imdbId: nil, tvdbId: nil,
            title: record.title, tagline: nil, overview: record.overview,
            posterPath: record.posterPath, backdropPath: record.backdropPath,
            releaseDate: nil, year: record.year, runtime: nil, genres: nil,
            voteAverage: nil, voteCount: nil, contentRating: nil,
            numberOfSeasons: nil, numberOfEpisodes: nil, networks: nil, director: nil,
            creators: nil, recommendations: nil,
            availability: record.state == .available ? .available : .missing,
            libraryContentId: record.libraryContentId,
            request: RequestState(
                status: record.status,
                state: record.state,
                requestable: false,
                reason: "already_requested",
                requestId: record.id
            )
        )
    }
}
