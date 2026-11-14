#if !os(tvOS)
import Foundation
import Nuke
#if canImport(UIKit)
import UIKit
#endif

/// The detail page a card's tap opens, as far as the page's cache keys need
/// it. `libraryId` is part of every item key, so it must be the one the tap
/// passes.
struct DetailPrewarmTarget: Hashable, Sendable {
    let contentId: String
    let libraryId: Int?
    /// The season a Continue Watching card opens its series on.
    var resumeSeasonNumber: Int? = nil

    /// A Home card (`HomeCardTap`): a resume card opens an episode's series
    /// on the episode's season (`AppRouter.presentContinueWatchingDetail`);
    /// every other card opens its own page.
    static func homeCard(_ item: SectionItem, opensResumeContext: Bool, libraryId: Int?) -> Self? {
        if opensResumeContext, let context = SeriesDetailContext(item: item) {
            return Self(
                contentId: context.seriesContentId,
                libraryId: libraryId,
                resumeSeasonNumber: context.seasonNumber
            )
        }
        return rowCard(item, libraryId: libraryId)
    }

    /// A `MediaRow` card, which on iOS and macOS opens its own page
    /// (`MediaCard`, `EpisodeThumbCard`).
    static func rowCard(_ item: SectionItem, libraryId: Int?) -> Self? {
        guard !item.contentId.isEmpty else { return nil }
        return Self(contentId: item.contentId, libraryId: libraryId)
    }
}

/// What `DetailPrewarmer` reads and fetches through. `live` is the app's;
/// tests inject their own.
struct DetailPrewarmEnvironment {
    var fetchDetail: @Sendable (_ contentId: String, _ libraryId: Int?) async throws -> ItemDetail
    var fetchSeasons: @Sendable (_ seriesId: String, _ libraryId: Int?) async throws -> SeasonsResponse
    var fetchEpisodes: @Sendable (_ seriesId: String, _ season: Int, _ libraryId: Int?) async throws -> EpisodesResponse
    var fetchWatchDetail: @Sendable (_ contentId: String, _ libraryId: Int?) async throws -> WatchDetail
    /// Who requests go out as. Nil when signed out.
    var captureOwner: @Sendable () async -> CapturedOrdinaryRequestAuth?
    var warmArtwork: @MainActor (ItemDetail) async -> DetailPrewarmArtwork.Result
    /// Drop decodes `warmArtwork` put in memory.
    var releaseArtwork: @MainActor ([ImageRequest]) -> Void
    /// A connection that costs data, including Low Data Mode.
    var isMetered: @MainActor () -> Bool
    var isLowPower: @MainActor () -> Bool
    var isDisabled: @MainActor () -> Bool
    var now: @MainActor () -> ContinuousClock.Instant = { .now }

    static var live: Self {
        Self(
            fetchDetail: { try await MetadataRequestPool.shared.itemDetail(contentId: $0, libraryId: $1) },
            fetchSeasons: { try await MetadataRequestPool.shared.seasons(seriesId: $0, libraryId: $1) },
            fetchEpisodes: {
                try await MetadataRequestPool.shared.episodes(seriesId: $0, seasonNumber: $1, libraryId: $2)
            },
            fetchWatchDetail: { try await MetadataRequestPool.shared.watchDetail(contentId: $0, libraryId: $1) },
            captureOwner: { await TokenStore.shared.captureOrdinaryRequestAuth() },
            warmArtwork: { await DetailPrewarmArtwork.warm($0) },
            releaseArtwork: { requests in
                for request in requests {
                    ImagePipeline.shared.cache.removeCachedImage(for: request, caches: .memory)
                }
            },
            // Covers mobile data, expensive hotspots and Low Data Mode on
            // iPhone and iPad; a Mac always reads unmetered.
            isMetered: { PlaybackNetworkMonitor.shared.isMetered },
            isLowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            isDisabled: {
                #if DEBUG
                DetailLoadTrace.prewarmDisabled
                #else
                false
                #endif
            }
        )
    }
}

/// Fetches the detail page of cards that stay on screen into the caches the
/// page hydrates from, so a tap paints the fetched detail, its seasons and
/// episodes or playback metadata, and its hero artwork on the first frame.
///
/// - A card counts once it has stayed on screen for `settle`; one scrolled
///   away sooner is dropped. At most `maxConcurrent` items load at once,
///   newest offer first, from a queue of at most `maxPending`.
/// - Nothing loads on a metered or constrained connection, in Low Power
///   Mode, signed out, or while the offering window shows a detail page or
///   the player.
/// - JSON goes through `MetadataRequestPool`, so a tap during a prewarm
///   joins its request. A running prewarm is never cancelled for scrolling,
///   so it cannot take down a request the opened page has joined; once the
///   page is open the prewarm stops writing and leaves the item to it.
/// - Writes are fenced by `ResponseCache.writeToken` and by the request
///   owner, so a response that crossed an invalidation or a profile switch
///   is dropped.
/// - `ResponseCache` keeps item entries until a memory warning, so the
///   prewarmer remembers the `maxTracked` items it fetched and removes the
///   oldest ones the user never opened, except their favorite and
///   watchlist flags, which a card can rewrite after the prewarm. Hero
///   decodes in memory are kept for the newest `maxDecoded` items only.
/// - An item it evicted, or whose detail request failed, is not fetched
///   again for `coolDown`, unless its metadata is invalidated meanwhile
///   (`ResponseCache.removeItemMetadata`, after the user acted on it).
/// - Whenever `ResponseCache` drops the whole `item:` family (sign-out,
///   account, server or profile change, metadata language, memory warning)
///   it forgets everything and stops what is queued and running.
/// - The opened page still refetches everything, as for any cached detail.
@MainActor
final class DetailPrewarmer {
    static let shared = DetailPrewarmer()

    struct Limits {
        var settle: Duration = .milliseconds(400)
        var maxConcurrent = 2
        var maxPending = 12
        var maxTracked = 40
        var maxDecoded = 4
        /// Cards remembered as on screen, as a guard against an appear
        /// without its disappear.
        var maxVisible = 48
        /// How long an evicted or failed item is left alone. Long enough
        /// that scrolling back over the same rows, usually seconds to a
        /// minute apart, sends nothing, and that an unreachable server is
        /// asked about each card at most a few times an hour; short enough
        /// that a card the user is still browsing near after a few minutes
        /// is warm again. A missed prewarm only costs the page its
        /// pre-fetched first frame.
        var coolDown: Duration = .seconds(5 * 60)
        /// Evicted or failed items remembered for the cool-down.
        var maxAttempted = 200
        /// Opened items remembered so their entries are never evicted.
        var maxOpened = 200
    }

    struct Stats: Equatable {
        var items = 0
        var jsonRequests = 0
        var imageRequests = 0
        var imageBytes = 0
    }

    private struct Visible {
        var count: Int
        var isBusy: @MainActor () -> Bool
    }

    private struct Tracked {
        let target: DetailPrewarmTarget
        let keys: [String]
    }

    private let environment: DetailPrewarmEnvironment
    private let limits: Limits

    private var visible: [DetailPrewarmTarget: Visible] = [:]
    /// Oldest first; mirrors `visible`'s keys.
    private var visibleOrder: [DetailPrewarmTarget] = []
    private var settling: [DetailPrewarmTarget: Task<Void, Never>] = [:]
    /// Oldest first; the newest starts first.
    private(set) var pending: [DetailPrewarmTarget] = []
    private var running: [DetailPrewarmTarget: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Items a detail page opened, whose entries are never evicted. Oldest
    /// first, at most `maxOpened`.
    private var opened: [String] = []
    /// Evicted or failed items, and when. Oldest first, at most
    /// `maxAttempted`.
    private var attempted: [(target: DetailPrewarmTarget, at: ContinuousClock.Instant)] = []
    /// Items whose page opened while their prewarm ran. That prewarm writes
    /// nothing more: the page adopts the joined responses itself.
    private var ownedByPage: Set<String> = []
    /// Oldest first.
    private var tracked: [Tracked] = []
    private var decoded: [(contentId: String, requests: [ImageRequest])] = []
    private(set) var stats = Stats()

    private var observers: CacheObservers?

    init(environment: DetailPrewarmEnvironment = .live, limits: Limits = Limits()) {
        self.environment = environment
        self.limits = limits
        observers = CacheObservers(
            familyDropped: { [weak self] in self?.resetBookkeeping() },
            itemRemoved: { [weak self] contentId in self?.attempted.removeAll { $0.target.contentId == contentId } }
        )
    }

    var runningTargets: Set<DetailPrewarmTarget> { Set(running.keys) }
    var settlingTargets: Set<DetailPrewarmTarget> { Set(settling.keys) }
    var trackedTargets: [DetailPrewarmTarget] { tracked.map(\.target) }
    var openedCount: Int { opened.count }
    var attemptedTargets: [DetailPrewarmTarget] { attempted.map(\.target) }

    // MARK: Offers

    /// A card that opens `target` came on screen in the window `router`
    /// drives.
    func offer(_ target: DetailPrewarmTarget?, router: AppRouter) {
        guard let target else { return }
        offer(target) { [weak router] in router?.isShowingDetailOrPlayer ?? true }
    }

    func offer(_ target: DetailPrewarmTarget, isBusy: @escaping @MainActor () -> Bool) {
        if var entry = visible[target] {
            entry.count += 1
            entry.isBusy = isBusy
            visible[target] = entry
        } else {
            visible[target] = Visible(count: 1, isBusy: isBusy)
            visibleOrder.append(target)
            if visibleOrder.count > limits.maxVisible {
                forget(visibleOrder.removeFirst())
            }
        }
        scheduleSettle(target)
    }

    /// The card that offered `target` left the screen.
    func withdraw(_ target: DetailPrewarmTarget?) {
        guard let target, var entry = visible[target] else { return }
        entry.count -= 1
        if entry.count > 0 {
            visible[target] = entry
        } else {
            forget(target)
        }
    }

    /// Offer again every card still on screen, after whatever held them back
    /// (a detail page, a reset) is gone.
    func reofferVisible() {
        #if DEBUG
        // The benchmark taps the cards it opened before again; offered last,
        // they start first rather than being dropped from a full queue.
        let visited = DetailLoadTrace.visitedContentIds
        let order = visibleOrder.filter { !visited.contains($0.contentId) }
            + visibleOrder.filter { visited.contains($0.contentId) }
        #else
        let order = visibleOrder
        #endif
        for target in order { scheduleSettle(target) }
    }

    /// A detail page for `contentId` opened. It owns the item's cache
    /// entries from now on: a prewarm still running stops writing, and the
    /// entries are never evicted.
    func noteOpened(contentId: String) {
        opened.removeAll { $0 == contentId }
        opened.append(contentId)
        if opened.count > limits.maxOpened { opened.removeFirst(opened.count - limits.maxOpened) }
        if running.keys.contains(where: { $0.contentId == contentId }) {
            ownedByPage.insert(contentId)
        }
        tracked.removeAll { $0.target.contentId == contentId }
        decoded.removeAll { $0.contentId == contentId }
    }

    /// Forget everything fetched and in flight, keeping `stats` and the
    /// cards on screen. Runs whenever `ResponseCache` drops the `item:`
    /// family, and for the benchmark's cold reset.
    func resetBookkeeping() {
        for task in settling.values { task.cancel() }
        settling = [:]
        for entry in running.values { entry.task.cancel() }
        running = [:]
        pending = []
        tracked = []
        decoded = []
        opened = []
        attempted = []
        ownedByPage = []
    }

    private func forget(_ target: DetailPrewarmTarget) {
        visible[target] = nil
        visibleOrder.removeAll { $0 == target }
        settling.removeValue(forKey: target)?.cancel()
        pending.removeAll { $0 == target }
    }

    // MARK: Scheduling

    private func scheduleSettle(_ target: DetailPrewarmTarget) {
        guard settling[target] == nil, running[target] == nil, !pending.contains(target) else { return }
        guard !isCached(target) else {
            touch(target)
            return
        }
        guard !isCoolingDown(target) else { return }
        settling[target] = Task { [weak self, settle = limits.settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.settled(target)
        }
    }

    private func settled(_ target: DetailPrewarmTarget) {
        settling[target] = nil
        guard visible[target] != nil, !isCached(target), !isCoolingDown(target) else { return }
        pending.append(target)
        if pending.count > limits.maxPending { pending.removeFirst() }
        pump()
    }

    private func pump() {
        while running.count < limits.maxConcurrent, let target = pending.last {
            if isHeldBack(target) {
                // The cards are offered again once nothing holds them back.
                pending = []
                return
            }
            pending.removeLast()
            guard !isCached(target), !isCoolingDown(target) else { continue }
            start(target)
        }
    }

    private func isHeldBack(_ target: DetailPrewarmTarget) -> Bool {
        environment.isDisabled()
            || environment.isMetered()
            || environment.isLowPower()
            || visible[target]?.isBusy() ?? false
    }

    private func start(_ target: DetailPrewarmTarget) {
        let id = UUID()
        let task = Task { [weak self] in
            await self?.prewarm(target)
            guard let self, self.running[target]?.id == id else { return }
            self.running[target] = nil
            if !self.running.keys.contains(where: { $0.contentId == target.contentId }) {
                self.ownedByPage.remove(target.contentId)
            }
            self.pump()
        }
        running[target] = (id, task)
    }

    private func isCached(_ target: DetailPrewarmTarget) -> Bool {
        let cached: ItemDetail? = ResponseCache.shared.get(
            CacheKey.itemDetail(target.contentId, libraryId: target.libraryId)
        )
        return cached != nil
    }

    /// Evicted or failed within `coolDown`.
    private func isCoolingDown(_ target: DetailPrewarmTarget) -> Bool {
        let now = environment.now()
        attempted.removeAll { now - $0.at >= limits.coolDown }
        return attempted.contains { $0.target == target }
    }

    private func noteAttempted(_ target: DetailPrewarmTarget) {
        attempted.removeAll { $0.target == target }
        attempted.append((target, environment.now()))
        if attempted.count > limits.maxAttempted { attempted.removeFirst(attempted.count - limits.maxAttempted) }
    }

    // MARK: Prewarm

    private func prewarm(_ target: DetailPrewarmTarget) async {
        #if DEBUG
        let started = ContinuousClock.now
        #endif
        let token = ResponseCache.shared.writeToken
        guard let owner = await environment.captureOwner(), owner.profileId != nil else { return }
        let id = target.contentId
        let libraryId = target.libraryId
        var requests = 0
        var keys: [String] = []
        defer { stats.jsonRequests += requests }

        requests += 1
        let fetched: ItemDetail
        do {
            fetched = try await environment.fetchDetail(id, libraryId)
        } catch {
            // Not for a reset or a page that took the item over.
            if !Task.isCancelled, !ownedByPage.contains(id) { noteAttempted(target) }
            return
        }
        guard await mayWrite(id, owner: owner) else { return }
        var detail = fetched
        let detailKey = CacheKey.itemDetail(id, libraryId: libraryId)
        guard write(detail, for: detailKey, token: token) else { return }
        keys.append(detailKey)
        if let userState = detail.userState {
            // As `loadDetail` writes it. A favorite or watchlist change made
            // on the card meanwhile wrote this key already, and wins. Left
            // out of `keys`: a card can write it again after this, and
            // eviction must not take that with the prewarm's entries.
            let userStateKey = CacheKey.itemUserState(id)
            let existing: UserItemState? = ResponseCache.shared.get(userStateKey)
            if existing == nil {
                _ = write(
                    UserItemState(isFavorite: userState.isFavorite, inWatchlist: userState.inWatchlist),
                    for: userStateKey, token: token
                )
            }
        }

        async let artwork = environment.warmArtwork(fetched)

        if detail.type == "series" {
            requests += 1
            if let seasons = try? await environment.fetchSeasons(id, libraryId),
               await mayWrite(id, owner: owner) {
                let seasonsKey = CacheKey.itemSeasons(id, libraryId: libraryId)
                if write(seasons, for: seasonsKey, token: token) { keys.append(seasonsKey) }
                // The season the page opens on: the resume card's, else (or
                // when it is missing) the page's own pick, as
                // `ItemDetailViewModel.preferredInitialSeason` makes it.
                let sorted = seasons.seasons.sortedForDisplay()
                let season = target.resumeSeasonNumber.flatMap { number in
                    sorted.first { $0.seasonNumber == number }
                } ?? sorted.preferredResumeSeason()
                if let season {
                    requests += 1
                    if let episodes = try? await environment.fetchEpisodes(id, season.seasonNumber, libraryId),
                       await mayWrite(id, owner: owner) {
                        let episodesKey = CacheKey.itemEpisodes(
                            seriesId: id, seasonNumber: season.seasonNumber, libraryId: libraryId
                        )
                        if write(episodes, for: episodesKey, token: token) { keys.append(episodesKey) }
                    }
                }
            }
        } else if detail.supportsPlaybackMetadata {
            requests += 1
            if let watchDetail = try? await environment.fetchWatchDetail(id, libraryId),
               await mayWrite(id, owner: owner) {
                let watchKey = CacheKey.itemWatchDetail(id, libraryId: libraryId)
                if write(watchDetail, for: watchKey, token: token) {
                    keys.append(watchKey)
                    // The detail as an opened page caches it once `/watch`
                    // answers, so the versions paint on the first frame.
                    detail = detail.applyingPlaybackMetadata(watchDetail)
                    _ = write(detail, for: detailKey, token: token)
                }
            }
        }

        let warmed = await artwork
        stats.imageRequests += warmed.requests
        stats.imageBytes += warmed.bytes
        #if DEBUG
        DetailLoadTrace.notePrewarmedArtwork(warmed.firstLoaded)
        #endif
        guard !Task.isCancelled, !ownedByPage.contains(id) else { return }
        stats.items += 1
        #if DEBUG
        DetailLoadTrace.logPrewarm(
            contentId: id, elapsed: ContinuousClock.now - started,
            requests: requests + warmed.requests, stats: stats
        )
        #endif
        // A page opened before lets this refill what it lost, but its
        // entries stay out of eviction.
        guard !opened.contains(id) else { return }
        if !warmed.decoded.isEmpty { trackDecoded(id, warmed.decoded) }
        track(Tracked(target: target, keys: keys))
    }

    /// Whether a response for `contentId` may still be cached: not
    /// cancelled, the page not opened, and requests still going out as
    /// `owner`.
    private func mayWrite(_ contentId: String, owner: CapturedOrdinaryRequestAuth) async -> Bool {
        guard !Task.isCancelled, !ownedByPage.contains(contentId) else { return false }
        guard let current = await environment.captureOwner(),
              current.sameCredentialIdentity(as: owner) else { return false }
        return !Task.isCancelled && !ownedByPage.contains(contentId)
    }

    /// Caches `value` unless `key` was invalidated after `token`. Returns
    /// whether it was written.
    private func write<T>(_ value: T, for key: String, token: UInt64) -> Bool {
        ResponseCache.shared.set(value, for: key, fetchedAt: token)
        let stored: T? = ResponseCache.shared.get(key)
        return stored != nil
    }

    // MARK: Bounds

    private func touch(_ target: DetailPrewarmTarget) {
        guard let index = tracked.firstIndex(where: { $0.target == target }) else { return }
        tracked.append(tracked.remove(at: index))
    }

    private func track(_ entry: Tracked) {
        tracked.removeAll { $0.target == entry.target }
        tracked.append(entry)
        while tracked.count > limits.maxTracked {
            let evicted = tracked.removeFirst()
            // Opened items left `tracked` when they opened.
            for key in evicted.keys { ResponseCache.shared.remove(key) }
            // Its card may well still be on screen; fetching it again now
            // would only evict the next oldest.
            noteAttempted(evicted.target)
        }
    }

    private func trackDecoded(_ contentId: String, _ requests: [ImageRequest]) {
        decoded.removeAll { $0.contentId == contentId }
        decoded.append((contentId, requests))
        while decoded.count > limits.maxDecoded {
            environment.releaseArtwork(decoded.removeFirst().requests)
        }
    }
}

/// Subscribes a prewarmer to `ResponseCache`'s drops for as long as it
/// lives.
private final class CacheObservers {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    init(familyDropped: @escaping @MainActor () -> Void, itemRemoved: @escaping @MainActor (String) -> Void) {
        let center = NotificationCenter.default
        // `ResponseCache` posts on the main actor, so these run in the call
        // that dropped the entries.
        tokens.append(center.addObserver(forName: .responseCacheItemFamilyDropped, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { familyDropped() }
        })
        tokens.append(center.addObserver(forName: .responseCacheItemMetadataRemoved, object: nil, queue: nil) { note in
            guard let contentId = note.userInfo?[ResponseCache.contentIdKey] as? String else { return }
            MainActor.assumeIsolated { itemRemoved(contentId) }
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

/// The hero artwork a detail page draws, fetched ahead of a tap.
@MainActor
enum DetailPrewarmArtwork {
    struct Result {
        var requests = 0
        /// Bytes downloaded; artwork already on disk counts nothing.
        var bytes = 0
        /// Decodes put in memory, released when newer items replace them.
        var decoded: [ImageRequest] = []
        #if DEBUG
        /// Requests for artwork that was not on disk before, which the
        /// benchmark's cold reset evicts.
        var firstLoaded: [ImageRequest] = []
        #endif
    }

    /// The backdrop's original bytes go to disk, which every size the page
    /// draws (the hero, the blurred page fill, the tint sample) decodes from.
    /// On an iPhone in portrait the hero and logo are also decoded into
    /// memory at the size the compact hero draws them, about 9 MB for the
    /// backdrop, so the hero paints full size on the first frame; on other
    /// layouts the size is not known ahead, so only the bytes are fetched.
    static func warm(_ detail: ItemDetail) async -> Result {
        var result = Result()
        let sizes = compactHeroSizes()
        var artwork: [(URL, CGSize?)] = []
        if let hero = heroURL(for: detail) { artwork.append((hero, sizes?.hero)) }
        if let logo = logoURL(for: detail) { artwork.append((logo, sizes?.logo)) }
        let scale = PosterImageCache.displayScale
        let cache = ImagePipeline.shared.cache
        for (url, pointSize) in artwork {
            let original = ImageRequest(artwork: url, priority: .low)
            let wasOnDisk = cache.containsData(for: original)
            if !wasOnDisk {
                guard let loaded = try? await ImagePipeline.shared.data(for: original) else { continue }
                let (data, response) = loaded
                #if DEBUG
                result.firstLoaded.append(original)
                #endif
                if response != nil {
                    result.requests += 1
                    result.bytes += data.count
                }
            }
            guard let pointSize,
                  let request = PosterImageCache.displayRequest(
                      url: url, pointSize: pointSize, scale: scale, priority: .low
                  ),
                  !cache.containsCachedImage(for: request, caches: .memory) else { continue }
            guard (try? await ImagePipeline.shared.image(for: request)) != nil else { continue }
            result.decoded.append(request)
            #if DEBUG
            if !wasOnDisk { result.firstLoaded.append(request) }
            #endif
        }
        return result
    }

    /// As `PhoneDetailHero` resolves its artwork: the backdrop, else the
    /// poster.
    private static func heroURL(for detail: ItemDetail) -> URL? {
        url(detail.backdropUrl) ?? url(detail.posterUrl)
    }

    private static func logoURL(for detail: ItemDetail) -> URL? {
        guard TitleArtPreferences.shared.showsTitleArt else { return nil }
        return url(detail.logoUrl)
    }

    private static func url(_ value: String?) -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: value)
    }

    /// The point sizes the compact hero draws its artwork and logo at in the
    /// key window, or nil off an iPhone held in portrait.
    ///
    /// A detail card's own page lays its hero out at the window's width
    /// from the start (`detailPageWidthHint`). A page pushed inside the card
    /// first lays it out at the height for a 390 pt page, until it has
    /// measured its width, so of that size and the measured one this picks
    /// the larger decode. Both round to the same ladder step on current
    /// iPhones, where the larger one is enough for either.
    private static func compactHeroSizes() -> (hero: CGSize, logo: CGSize)? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow) else { return nil }
        let width = window.bounds.width
        guard width > 0, window.bounds.height > width else { return nil }
        let scale = PosterImageCache.displayScale
        let heroHeights = [width, 0].map { PhoneDetailHeroLayout.compactArtworkHeight(forWidth: $0) }
        let hero = largestDecode(heroHeights.map { CGSize(width: width, height: $0) }, scale: scale)
        let logoWidth = width - 2 * PhoneDetailHeroLayout.compactTitleInset
        let logo = largestDecode(
            heroHeights.map {
                CGSize(width: logoWidth, height: PhoneDetailHeroLayout.compactLogoHeight(forArtworkHeight: $0))
            },
            scale: scale
        )
        guard let hero, let logo else { return nil }
        return (hero, logo)
        #else
        return nil
        #endif
    }

    private static func largestDecode(_ pointSizes: [CGSize], scale: CGFloat) -> CGSize? {
        pointSizes.max { lhs, rhs in
            let lhsPixels = PosterImageCache.decodePixelSize(forPointSize: lhs, scale: scale) ?? .zero
            let rhsPixels = PosterImageCache.decodePixelSize(forPointSize: rhs, scale: scale) ?? .zero
            return lhsPixels.width * lhsPixels.height < rhsPixels.width * rhsPixels.height
        }
    }
}
#endif
