import Foundation

/// Session memory for request detail pages, so opening a title the app has
/// already seen paints its final layout on the first frame instead of
/// building itself as reads land.
///
/// It holds two things, keyed by media type + TMDB id:
/// - the title detail (`RequestMediaDetail`) from the last read or prefetch;
/// - the signed-in user's own request records, from every `/requests/mine`
///   read — the status is known before the page asks.
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
    private var seeds: [Key: RequestMediaResult] = [:]
    /// Titles waiting to be warmed, shared by every list that asked.
    private var prefetchQueue: [(key: Key, api: SiloAPI)] = []
    private var prefetchTask: Task<Void, Never>?
    /// Bumped by `clear()`: a drain from the previous session stops at its
    /// next step instead of consuming the next session's queue.
    private var generation = 0

    /// Bounded so a long browsing session can't grow without limit.
    private static let detailLimit = 80
    /// Rows warmed per list read: roughly the first screenful and a bit.
    static let prefetchCount = 10

    // MARK: - Reads

    func ownRecord(_ key: Key) -> MediaRequest? { ownRecords[key] }

    /// A page to show before the detail read answers: the cached detail, or
    /// one built from what a card or record already carried.
    func firstFrameDetail(_ key: Key) -> RequestMediaDetail? {
        if let detail = details[key] { return detail }
        if let seed = seeds[key] { return Self.provisionalDetail(from: seed) }
        if let record = ownRecords[key] {
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
        let byTitle = Dictionary(grouping: records) { Key(mediaType: $0.mediaType, tmdbId: $0.tmdbId) }
        ownRecords = byTitle.compactMapValues(Self.currentRecord)
    }

    /// The one of a title's requests that speaks for it: the newest active
    /// one, otherwise the newest overall. Nil when that newest one was
    /// cancelled, so an older decline or failure doesn't come back.
    static func currentRecord(among records: [MediaRequest]) -> MediaRequest? {
        let older: (MediaRequest, MediaRequest) -> Bool = { $0.createdAt < $1.createdAt }
        if let active = records.filter({ $0.outcome == .active }).max(by: older) { return active }
        guard let newest = records.max(by: older), newest.outcome != .cancelled else { return nil }
        return newest
    }

    func storeOwnRecord(_ record: MediaRequest) {
        let key = Key(mediaType: record.mediaType, tmdbId: record.tmdbId)
        if record.outcome == .cancelled {
            ownRecords.removeValue(forKey: key)
        } else {
            ownRecords[key] = record
        }
    }

    /// A follow toggle: the next first frame of the title, from the cached
    /// detail or a card's seed, shows the new state.
    func applyTitleState(_ update: RequestTitleStateUpdate) {
        let key = Key(mediaType: update.mediaType, tmdbId: update.tmdbId)
        details[key]?.request = update.request
        seeds[key]?.request = update.request
    }

    func seed(_ result: RequestMediaResult) {
        seeds[Key(mediaType: result.mediaType, tmdbId: result.tmdbId)] = result
    }

    func clear() {
        generation &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchQueue.removeAll()
        details.removeAll()
        detailOrder.removeAll()
        ownRecords.removeAll()
        seeds.removeAll()
    }

    // MARK: - Prefetch

    /// Warms detail and artwork for the first rows of a list, one read at a
    /// time and only for titles not already cached, so opening any of them
    /// lands on the finished page. Lists that load together share one
    /// queue, so a later list adds its titles instead of dropping an
    /// earlier list's.
    func prefetch(_ records: [MediaRequest], api: SiloAPI = .shared) {
        let keys = records
            .map { Key(mediaType: $0.mediaType, tmdbId: $0.tmdbId) }
            .filter { details[$0] == nil && ($0.mediaType == .movie || $0.mediaType == .series) }
        var seen = Set<Key>()
        let unique = keys.filter { seen.insert($0).inserted }
        let queued = Set(prefetchQueue.map(\.key))
        let batch = unique.prefix(Self.prefetchCount).filter { !queued.contains($0) }
        guard !batch.isEmpty else { return }

        Self.warmArtwork(records.prefix(Self.prefetchCount).flatMap {
            [($0.backdropPath, .backdrop), ($0.posterPath, .poster)]
        })
        prefetchQueue.append(contentsOf: batch.map { (key: $0, api: api) })
        guard prefetchTask == nil else { return }
        prefetchTask = Task { [weak self] in
            await self?.drainPrefetchQueue()
        }
    }

    private func drainPrefetchQueue() async {
        let session = generation
        while !Task.isCancelled, session == generation, !prefetchQueue.isEmpty {
            let (key, api) = prefetchQueue.removeFirst()
            guard details[key] == nil,
                  let detail = try? await api.requestsDetail(mediaType: key.mediaType, tmdbId: key.tmdbId),
                  !Task.isCancelled, session == generation else { continue }
            store(detail)
            Self.warmArtwork([(detail.backdropPath, .backdrop)])
        }
        // `clear()` already dropped a cancelled task; a new one may run.
        if !Task.isCancelled, session == generation { prefetchTask = nil }
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
