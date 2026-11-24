import Foundation

/// Poster and synopsis a TV adds to its control state, so a controller with no
/// catalog access of its own (Home Assistant) can show real artwork. The TV
/// resolves them with its own sign-in; the poster URL is absolute and signed,
/// so the controller downloads it from Silo or the CDN without credentials.
struct SiloControlNowPlayingMetadata: Equatable, Sendable {
    let posterUrl: String?
    let overview: String?

    /// 2:3 artwork: an episode's own poster is its 16:9 still, which spoiler
    /// protection may hide, so episodes send only the series poster. The
    /// synopsis falls back to the series when the episode has none.
    init(item: ItemDetail, series: ItemDetail?) {
        posterUrl = SiloMediaType.isEpisode(item.type)
            ? Self.nonEmpty(series?.posterUrl)
            : Self.nonEmpty(item.posterUrl)
        overview = Self.nonEmpty(item.overview) ?? Self.nonEmpty(series?.overview)
    }

    init(posterUrl: String?, overview: String?) {
        self.posterUrl = posterUrl
        self.overview = overview
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// When a signed artwork URL stops working.
enum SiloControlArtworkExpiry {
    /// How long before expiry the TV fetches a re-signed URL.
    static let refreshMargin: TimeInterval = 10 * 60
    /// Re-check interval for a URL whose expiry can't be read (Cloudflare
    /// token URLs). Public URLs never expire but cost one cheap request.
    static let unknownExpiryRefresh: TimeInterval = 30 * 60
    /// Floor between fetches, so a URL that is already stale can't spin.
    static let minimumRefresh: TimeInterval = 60

    /// Silo's `exp` (Unix seconds) or S3's `X-Amz-Date` + `X-Amz-Expires`.
    static func expiry(of urlString: String) -> Date? {
        guard let items = URLComponents(string: urlString)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        if let exp = value("exp").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: exp)
        }
        if let signedAt = value("X-Amz-Date").flatMap(amzDate),
           let lifetime = value("X-Amz-Expires").flatMap(TimeInterval.init) {
            return signedAt.addingTimeInterval(lifetime)
        }
        return nil
    }

    /// Whether `urlString` still has more than `refreshMargin` left.
    static func isFresh(_ urlString: String?, now: Date = Date()) -> Bool {
        guard let urlString, let expiry = expiry(of: urlString) else { return true }
        return expiry.timeIntervalSince(now) > refreshMargin
    }

    /// Seconds until the TV should fetch a re-signed poster URL, or nil when
    /// there is no poster to keep alive.
    static func refreshDelay(for urlString: String?, now: Date = Date()) -> TimeInterval? {
        guard let urlString else { return nil }
        guard let expiry = expiry(of: urlString) else { return unknownExpiryRefresh }
        return max(expiry.timeIntervalSince(now) - refreshMargin, minimumRefresh)
    }

    private static func amzDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: value)
    }
}

/// Keeps `SiloControlNowPlayingMetadata` for the title the TV is playing:
/// resolves it when the title changes, re-fetches before the poster URL
/// expires, and drops it when playback stops or moves to another title.
@MainActor
final class SiloControlNowPlayingMetadataResolver {
    /// Loads metadata for a content ID. `allowCached` is false on a refresh,
    /// when the cached copy's signed URL is the one about to expire.
    typealias Loader = @MainActor (_ contentId: String, _ allowCached: Bool) async -> SiloControlNowPlayingMetadata?

    private(set) var contentId: String?
    private var resolved: SiloControlNowPlayingMetadata?
    private var task: Task<Void, Never>?
    private let load: Loader
    private let now: () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    /// Called when metadata for the tracked title arrives or is re-signed.
    var onChange: (() -> Void)?

    init(load: @escaping Loader = SiloControlNowPlayingMetadataResolver.loadFromCatalog,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.load = load
        self.now = now
        self.sleep = sleep
    }

    /// Metadata for `contentId`, or nil while it loads or for another title.
    /// A poster URL past its expiry is withheld until a refresh replaces it.
    func metadata(for contentId: String?) -> SiloControlNowPlayingMetadata? {
        guard let contentId, contentId == self.contentId, let resolved else { return nil }
        if let poster = resolved.posterUrl,
           let expiry = SiloControlArtworkExpiry.expiry(of: poster), expiry <= now() {
            return SiloControlNowPlayingMetadata(posterUrl: nil, overview: resolved.overview)
        }
        return resolved
    }

    /// Follows the playing title. Safe to call on every state tick. Dropping
    /// the old title's metadata does not call `onChange`: the caller is
    /// already building the state that leaves it out.
    func track(contentId newId: String?) {
        let newId = newId?.isEmpty == false ? newId : nil
        guard newId != contentId else { return }
        task?.cancel()
        task = nil
        contentId = newId
        resolved = nil
        guard let newId else { return }
        task = Task { @MainActor [weak self] in
            await self?.run(contentId: newId)
        }
    }

    private func run(contentId: String) async {
        var allowCached = true
        while !Task.isCancelled {
            let fetched = await load(contentId, allowCached)
            guard !Task.isCancelled, self.contentId == contentId else { return }
            // A failed refresh keeps the last URL; it may still have time left.
            if let fetched, fetched != resolved {
                resolved = fetched
                onChange?()
            }
            // Nothing yet: retry soon, so one failed request doesn't leave
            // the title without artwork.
            let delay = resolved == nil
                ? SiloControlArtworkExpiry.minimumRefresh
                : SiloControlArtworkExpiry.refreshDelay(for: resolved?.posterUrl, now: now())
            guard let delay else { return }
            try? await sleep(delay)
            allowCached = false
        }
    }

    /// Cache first, so the TV usually adds no request; the network when the
    /// cached copy is missing or its poster URL is close to expiring.
    static func loadFromCatalog(contentId: String, allowCached: Bool) async -> SiloControlNowPlayingMetadata? {
        guard let item = await itemDetail(contentId, allowCached: allowCached) else { return nil }
        var series: ItemDetail?
        if SiloMediaType.isEpisode(item.type), let seriesId = item.seriesId, !seriesId.isEmpty {
            // A failed series lookup counts as a failed load, so the resolver
            // retries it (or keeps the last result) instead of settling for
            // an episode without its poster.
            guard let fetched = await itemDetail(seriesId, allowCached: allowCached) else { return nil }
            series = fetched
        }
        return SiloControlNowPlayingMetadata(item: item, series: series)
    }

    private static func itemDetail(_ contentId: String, allowCached: Bool) async -> ItemDetail? {
        let key = CacheKey.itemDetail(contentId)
        if allowCached, let cached: ItemDetail = ResponseCache.shared.get(key),
           SiloControlArtworkExpiry.isFresh(cached.posterUrl) {
            return cached
        }
        let writeToken = ResponseCache.shared.writeToken
        guard let fetched = try? await MetadataRequestPool.shared.itemDetail(contentId: contentId) else {
            return nil
        }
        ResponseCache.shared.set(fetched, for: key, fetchedAt: writeToken)
        return fetched
    }
}
