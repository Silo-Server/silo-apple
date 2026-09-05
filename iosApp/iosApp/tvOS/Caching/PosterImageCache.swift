import Foundation
import Nuke
#if canImport(UIKit)
import UIKit
#endif

/// Centralized Nuke `ImagePipeline` for the Apple client apps.
///
/// Poster-heavy browse/detail surfaces re-request the same images many times
/// during a session. Stock `AsyncImage` has no persistent cache, which causes
/// visible flicker and re-downloads when the user scrolls back. This pipeline
/// gives us:
///
/// - A decoded memory cache sized for the platform's playback headroom
/// - 1 GB on-disk data cache keyed by URL
/// - ImageIO thumbnail decoding straight to the render size, so a w780
///   poster is never decoded at full resolution just to draw a 176 pt card
/// - A prefetcher the grid can use to warm posters N rows ahead
///
/// The pipeline is installed as the `ImagePipeline.shared` at first access so
/// every `LazyImage` / `ImagePipeline.shared` caller picks it up automatically.
enum PosterImageCache {
    /// Longest edge, in pixels, of the decode the prefetchers park in the
    /// memory cache for poster, still, cover, and portrait artwork. Sized to
    /// cover every Skyline landing card at the display's native scale
    /// (Apple TV 4K renders at 2x: a 176 pt dense poster is 528 px tall), so
    /// the warmed decode paints at least as sharp as the card's own request.
    /// About 1.1 MB for a 2:3 poster at 2x, so a whole warmed feed still fits
    /// the constrained tvOS budget instead of evicting itself. Library grid
    /// cards are larger and keep their own decode.
    static let cardWarmMaxPixelSize: Float = Float(320 * displayScale)

    /// Native display scale used to turn point sizes into decode pixel sizes
    /// off the main thread. `UITraitCollection.current` reports 0 outside a
    /// UIKit context, so read the screen directly.
    static let displayScale: CGFloat = {
        #if canImport(UIKit)
        return max(1, UIScreen.main.scale)
        #else
        return 2
        #endif
    }()

    /// Longest edge, in pixels, for palette sampling decodes.
    static let paletteSampleMaxPixelSize: Float = 64

    // MARK: - Requests

    /// Display request that decodes directly at `pixelSize` (aspect-fill
    /// cover) through ImageIO's thumbnail path. Decoding at the target size
    /// costs a fraction of the CPU and memory of decoding the full image and
    /// resizing it, and the result needs no separate decompression pass.
    /// ImageIO never upscales, so a small source stays at its native size.
    static func displayRequest(url: URL, pixelSize: CGSize, priority: ImageRequest.Priority = .normal) -> ImageRequest {
        var request = ImageRequest(url: url, priority: priority)
        request.thumbnail = ImageRequest.ThumbnailOptions(
            size: pixelSize,
            unit: .pixels,
            contentMode: .aspectFill
        )
        return request
    }

    /// The request the prefetchers warm for card artwork. Cards look this key
    /// up synchronously on their first frame (`warmedCardImage(for:)`).
    static func cardWarmRequest(for url: URL) -> ImageRequest {
        var request = ImageRequest(url: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: cardWarmMaxPixelSize)
        return request
    }

    /// Cheap request for average-color / palette sampling.
    static func paletteSampleRequest(for url: URL) -> ImageRequest {
        var request = ImageRequest(url: url, priority: .low)
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: paletteSampleMaxPixelSize)
        return request
    }

    /// Synchronous memory-cache lookup of a warmed card decode. Cheap
    /// dictionary access, safe to call from a view body.
    static func warmedCardImage(for url: URL) -> PlatformImage? {
        ImagePipeline.shared.cache[cardWarmRequest(for: url)]?.image
    }

    /// Warm card artwork (posters, stills, covers, portraits, avatars) into
    /// the memory cache at the shared card size.
    static func prefetchCardArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls.map(cardWarmRequest(for:)))
    }

    static func stopPrefetchingCardArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.stopPrefetching(with: urls.map(cardWarmRequest(for:)))
    }

    #if os(tvOS)
    /// Low-priority exact-size working set for the focused Home row. Home rows
    /// contain 20 cards, so warming the complete row removes the cold boundary
    /// that otherwise appears after card 16. Cached results remain under
    /// Nuke's normal memory LRU; only unfinished work from the prior row is
    /// cancelled.
    private static let homeRowCardPrefetchLimit = 20
    private static let homeRowCardPrefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(
            pipeline: ImagePipeline.shared,
            destination: .memoryCache,
            maxConcurrentRequestCount: 2
        )
        prefetcher.priority = .low
        return prefetcher
    }()
    private struct HomeRowCardWarmKey: Equatable {
        let url: URL
        let pixelSize: CGSize
    }
    @MainActor private static var homeRowCardWarmKeys: [HomeRowCardWarmKey] = []

    @MainActor
    static func warmHomeRowCardArtwork(_ candidates: [URL], pointSize: CGSize) {
        let pixelSize = CGSize(
            width: pointSize.width * displayScale,
            height: pointSize.height * displayScale
        )
        var seen = Set<URL>()
        let keys = candidates
            .filter { seen.insert($0).inserted }
            .prefix(homeRowCardPrefetchLimit)
            .map { HomeRowCardWarmKey(url: $0, pixelSize: pixelSize) }
        guard keys != homeRowCardWarmKeys else { return }

        let stale = homeRowCardWarmKeys.filter { !keys.contains($0) }
        let fresh = keys.filter { !homeRowCardWarmKeys.contains($0) }
        homeRowCardWarmKeys = keys

        if !stale.isEmpty {
            homeRowCardPrefetcher.stopPrefetching(with: stale.map(homeRowCardRequest(for:)))
        }
        if !fresh.isEmpty {
            homeRowCardPrefetcher.startPrefetching(with: fresh.map(homeRowCardRequest(for:)))
        }
    }

    @MainActor
    static func cancelHomeRowCardWarmup() {
        guard !homeRowCardWarmKeys.isEmpty else { return }
        homeRowCardPrefetcher.stopPrefetching(
            with: homeRowCardWarmKeys.map(homeRowCardRequest(for:))
        )
        homeRowCardWarmKeys.removeAll()
    }

    private static func homeRowCardRequest(for key: HomeRowCardWarmKey) -> ImageRequest {
        displayRequest(url: key.url, pixelSize: key.pixelSize, priority: .low)
    }
    #endif

    /// Warm full-size artwork under its bare-URL key. Only for art whose
    /// consumers read the unprocessed decode synchronously (marquee logos).
    static func prefetchOriginalArtwork(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }

    #if os(tvOS)
    /// A movie's cast rail is part of the first detail viewport, but its
    /// portraits used to begin loading only after SwiftUI mounted each card.
    /// Warm just the first screenful through the same shared Nuke pipeline as
    /// the hero artwork. `ImagePrefetcher` queues these requests and returns
    /// immediately, so detail navigation and first paint never wait on them.
    private static let visibleMovieCastPortraitLimit = 8
    #endif

    private static var memoryWarningObserver: NSObjectProtocol?

    /// Call once at app launch before any SwiftUI view renders.
    static func install() {
        #if DEBUG
        // os_signpost intervals for every fetch, decode, and processing step
        // (subsystem "com.github.kean.Nuke"). Visible in Instruments'
        // os_signpost track and via `log stream` on a debug device build.
        ImagePipeline.Configuration.isSignpostLoggingEnabled = true
        #endif
        ImagePipeline.shared = makePipeline()
        installMemoryPressureObserverIfNeeded()
    }

    /// Drop decoded images while preserving the disk cache. Playback is the
    /// only surface where poster reuse is invisible but memory headroom is
    /// tight, especially on 3 GB Apple TV hardware.
    static func trimDecodedMemory() {
        ImagePipeline.shared.cache.removeAll(caches: .memory)
    }

    private static func makePipeline() -> ImagePipeline {
        return ImagePipeline { config in
            // Nuke's default loader also routes every response through a
            // 150 MB Foundation URLCache, so each image was written to flash
            // twice (URLCache + the DataCache below) and validated twice on
            // every read. The DataCache is the only disk cache we want.
            config.dataLoader = {
                let session = URLSessionConfiguration.default
                session.urlCache = nil
                return DataLoader(configuration: session)
            }()

            // Memory cache for decoded UIImages.
            let memoryCache = ImageCache()
            memoryCache.costLimit = decodedMemoryCacheBudgetBytes
            memoryCache.countLimit = decodedImageCountLimit
            config.imageCache = memoryCache

            // On-disk cache for raw image data.
            if let dataCache = try? DataCache(name: "com.continuum.app.apple.posters") {
                dataCache.sizeLimit = 1_024 * 1024 * 1024  // 1 GB
                config.dataCache = dataCache
            }

            // Thumbnail decodes do the whole decode + downsample in the
            // decoding stage and skip decompression, so give that stage the
            // two slots decompression used to have. Nuke's default of one
            // serialises every poster in a freshly revealed row.
            config.imageDecodingQueue.maxConcurrentOperationCount = 2
            config.imageDecompressingQueue.maxConcurrentOperationCount = 2
        }
    }

    private static var decodedMemoryCacheBudgetBytes: Int {
        #if os(tvOS)
        return isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 160 * 1024 * 1024
        #else
        return 256 * 1024 * 1024
        #endif
    }

    private static var decodedImageCountLimit: Int {
        #if os(tvOS)
        return isConstrainedMemoryDevice ? 180 : 280
        #else
        return 400
        #endif
    }

    private static var isConstrainedMemoryDevice: Bool {
        ProcessInfo.processInfo.physicalMemory <= 3_500_000_000
    }

    private static func installMemoryPressureObserverIfNeeded() {
        #if canImport(UIKit)
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            trimDecodedMemory()
        }
        #endif
    }

    /// Shared prefetcher. Grid rows enqueue upcoming poster URLs here to warm
    /// the pipeline before those rows are rendered.
    static let prefetcher: ImagePrefetcher = {
        let p = ImagePrefetcher(pipeline: ImagePipeline.shared, destination: .memoryCache)
        p.priority = .normal
        return p
    }()

    #if os(tvOS)
    /// Root-hero backdrop warmer for the cards beside a rested marquee
    /// selection. Bounded to a handful of URLs and low priority so visible
    /// cards and the rested backdrop itself always win the pipeline.
    ///
    /// Data-only on purpose: tvOS receives w1920 backdrops, which decode to
    /// roughly 8 MB each. Decoding four of those per rest into a 96 MB
    /// memory budget on 3 GB Apple TVs would evict dozens of posters and
    /// keep the two-wide decompression queue busy while the user is still
    /// navigating. Pulling only the bytes into the disk cache removes the
    /// network round trip — the dominant cost of a rested swap — and leaves
    /// the single decode to the moment the backdrop is actually requested.
    private static let neighborBackdropPrefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(
            pipeline: ImagePipeline.shared,
            destination: .diskCache,
            maxConcurrentRequestCount: 2
        )
        prefetcher.priority = .low
        return prefetcher
    }()
    @MainActor private static var warmedNeighborBackdropURLs: Set<URL> = []

    /// Replace the neighbour window: cancel URLs that fell out of it and
    /// start only the ones not already in flight, in the order given. Called
    /// once per rested selection, never per focus change, so a roll across a
    /// row queues nothing.
    @MainActor
    static func warmNeighborBackdrops(_ urlStrings: [String]) {
        var seen = Set<URL>()
        let urls = urlStrings
            .compactMap { $0.isEmpty ? nil : URL(string: $0) }
            .filter { seen.insert($0).inserted }
        let stale = warmedNeighborBackdropURLs.subtracting(urls)
        let fresh = urls.filter { !warmedNeighborBackdropURLs.contains($0) }
        warmedNeighborBackdropURLs = seen
        if !stale.isEmpty { neighborBackdropPrefetcher.stopPrefetching(with: Array(stale)) }
        if !fresh.isEmpty { neighborBackdropPrefetcher.startPrefetching(with: fresh) }
    }

    @MainActor
    static func cancelNeighborBackdropWarmup() {
        guard !warmedNeighborBackdropURLs.isEmpty else { return }
        neighborBackdropPrefetcher.stopPrefetching(with: Array(warmedNeighborBackdropURLs))
        warmedNeighborBackdropURLs.removeAll()
    }

    /// Prefetch only movie portraits. Series cast lives farther down its page
    /// and deliberately keeps the normal lazy-loading path.
    static func prefetchVisibleMovieCast(for detail: ItemDetail) {
        guard detail.type == "movie", let cast = detail.cast else { return }

        var urls: [URL] = []
        var seen = Set<String>()
        for member in cast {
            guard urls.count < visibleMovieCastPortraitLimit else { break }
            guard let value = member.photoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value),
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }

        prefetchCardArtwork(urls)
    }

    /// Warm the root hero backdrops the marquee will display, decoded at the
    /// exact size `TVRootHeroBackdrop` requests so the first rested backdrop
    /// is a straight memory-cache hit with no second decode.
    static func prefetchHeroBackdrops(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls.map { heroBackdropRequest(for: $0) })
    }

    /// The exact request `TVRootHeroBackdrop` issues for a hero backdrop, so
    /// a warm decode and the display share one memory-cache key.
    static func heroBackdropRequest(
        for url: URL,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest {
        let pointSize = TVBackdropArtworkLayout.artworkSize(
            forViewportWidth: TVBackdropArtworkLayout.viewportWidth
        )
        let pixelSize = CGSize(
            width: pointSize.width * displayScale,
            height: pointSize.height * displayScale
        )
        return displayRequest(url: url, pixelSize: pixelSize, priority: priority)
    }

    /// Fetch and decode one hero backdrop at display size and sample its
    /// tint, concurrently. Used by the marquee while a row-change scroll
    /// holds the visible swap: the user is waiting on exactly this image, so
    /// it runs at high priority and cancels with the caller's task.
    static func warmHeroBackdrop(_ url: URL) async {
        async let image: Void = {
            _ = try? await ImagePipeline.shared.image(
                for: heroBackdropRequest(for: url, priority: .high)
            )
        }()
        async let tint: Void = { _ = await HeroBackdropPalette.tintColor(for: url) }()
        _ = await (image, tint)
    }
    #endif
}
