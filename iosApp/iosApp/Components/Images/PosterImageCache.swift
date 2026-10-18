import Foundation
import Nuke
#if canImport(UIKit)
import UIKit
#endif

/// The app-wide Nuke pipeline and the rules every artwork request follows.
///
/// - Decoded images live in a memory cache sized per platform; raw bytes live
///   in a 1 GB disk cache keyed by URL, which serves every decode size.
///   Revisioned artwork is keyed without its signature (`ArtworkCacheKey`),
///   so a re-signed URL reuses both caches.
/// - Artwork is decoded by ImageIO straight to a size on a fixed ladder just
///   above the size it is drawn at, so a w1000 poster is never decoded at full
///   resolution for a 176 pt card, and cards a few points apart share a decode.
/// - Any decode of a URL already in memory that is large enough is painted
///   immediately (see `cachedVariant`), so artwork seen once never shows its
///   placeholder again when it reappears at another size.
enum PosterImageCache {
    // MARK: - Decode sizes

    /// Longest decoded edge in pixels: 128 × 2^(n/3), each step about 26%
    /// above the last, up to 4096.
    private static let decodeLadder: [CGFloat] = (0...15).map { (step: Int) -> CGFloat in
        let exponent = CGFloat(step) / 3
        return (128 * pow(CGFloat(2), exponent)).rounded()
    }

    /// The decode size for artwork drawn at `pointSize`: its pixel size with
    /// the longest edge rounded up to the ladder, aspect ratio kept.
    static func decodePixelSize(forPointSize pointSize: CGSize, scale: CGFloat) -> CGSize? {
        let width = pointSize.width * scale
        let height = pointSize.height * scale
        let longest = max(width, height)
        guard longest.isFinite, width > 0, height > 0 else { return nil }
        let step = decodeLadder.first { $0 >= longest } ?? longest.rounded(.up)
        let factor = step / longest
        return CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
    }

    /// The screen scale for decodes requested outside a view.
    @MainActor static var displayScale: CGFloat {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.scale }
            .max() ?? 2
        #else
        2
        #endif
    }

    /// Longest edge, in pixels, for palette sampling decodes.
    static let paletteSampleMaxPixelSize: Float = 64

    // MARK: - Requests

    /// Aspect-fill ImageIO thumbnail decode for artwork drawn at `pointSize`.
    /// ImageIO never upscales, so a small source keeps its native size.
    static func displayRequest(
        url: URL,
        pointSize: CGSize,
        scale: CGFloat,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest? {
        guard let pixelSize = decodePixelSize(forPointSize: pointSize, scale: scale) else { return nil }
        var request = ImageRequest(artwork: url, priority: priority)
        request.thumbnail = displayThumbnail(pixelSize)
        ArtworkVariants.shared.record(request.imageID, pixelSize: pixelSize)
        return request
    }

    private static func displayThumbnail(_ pixelSize: CGSize) -> ImageRequest.ThumbnailOptions {
        ImageRequest.ThumbnailOptions(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
    }

    /// Cheap request for average-color / palette sampling.
    static func paletteSampleRequest(for url: URL) -> ImageRequest {
        var request = ImageRequest(artwork: url, priority: .low)
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: paletteSampleMaxPixelSize)
        return request
    }

    /// The best decode of `url` already in memory for drawing at `pixelSize`:
    /// the smallest one at least that large, else the largest smaller one.
    /// `isSufficient` says whether it is at least `pixelSize`. A memory-cache
    /// lookup per known size; cheap enough for a view body.
    static func cachedVariant(
        of url: URL,
        for pixelSize: CGSize
    ) -> (image: PlatformImage, isSufficient: Bool)? {
        // Resolve the cache identity once; only the decode size varies below.
        var request = ImageRequest(artwork: url)
        var best: (image: PlatformImage, area: CGFloat, isSufficient: Bool)?
        for size in ArtworkVariants.shared.sizes(forImageID: request.imageID) {
            let isSufficient = size.width >= pixelSize.width && size.height >= pixelSize.height
            let area = size.width * size.height
            if let best, best.isSufficient, !isSufficient { continue }
            if let best, best.isSufficient == isSufficient,
               isSufficient ? area >= best.area : area <= best.area { continue }
            request.thumbnail = displayThumbnail(size)
            guard let image = ImagePipeline.shared.cache[request]?.image else {
                continue
            }
            best = (image, area, isSufficient)
        }
        return best.map { ($0.image, $0.isSufficient) }
    }

    // MARK: - Warming

    /// Warm artwork that is about to be drawn at `pointSize` into memory, so
    /// its view paints it on the first frame.
    @MainActor
    static func prefetchArtwork(_ urls: [URL], pointSize: CGSize) {
        let requests = warmRequests(urls, pointSize: pointSize)
        guard !requests.isEmpty else { return }
        prefetcher.startPrefetching(with: requests)
    }

    @MainActor
    static func stopPrefetchingArtwork(_ urls: [URL], pointSize: CGSize) {
        let requests = warmRequests(urls, pointSize: pointSize)
        guard !requests.isEmpty else { return }
        prefetcher.stopPrefetching(with: requests)
    }

    /// Warm each card's artwork at the size that card draws it.
    @MainActor
    static func prefetchArtwork(_ artwork: [CardArtwork]) {
        let requests = warmRequests(artwork)
        guard !requests.isEmpty else { return }
        prefetcher.startPrefetching(with: requests)
    }

    @MainActor
    static func stopPrefetchingArtwork(_ artwork: [CardArtwork]) {
        let requests = warmRequests(artwork)
        guard !requests.isEmpty else { return }
        prefetcher.stopPrefetching(with: requests)
    }

    @MainActor
    private static func warmRequests(_ urls: [URL], pointSize: CGSize) -> [ImageRequest] {
        let scale = displayScale
        return urls.compactMap { displayRequest(url: $0, pointSize: pointSize, scale: scale) }
    }

    @MainActor
    private static func warmRequests(_ artwork: [CardArtwork]) -> [ImageRequest] {
        let scale = displayScale
        return artwork.compactMap { card in
            URL(string: card.url).flatMap { displayRequest(url: $0, pointSize: card.pointSize, scale: scale) }
        }
    }

    /// Longest decoded edge, in pixels, of Now Playing artwork: the lock
    /// screen's full-width player on the largest iPhone (about 430 pt at
    /// 3×). An original can be 3840 px wide; this keeps its decode near 4 MB
    /// instead of 30 MB during playback.
    static let nowPlayingArtworkMaxPixelSize: Float = 1280

    /// Now Playing artwork, decoded no larger than the system draws it and
    /// kept out of the memory cache: playback keeps decoded-image memory low,
    /// and the published artwork already holds the image.
    static func nowPlayingArtworkRequest(for url: URL) -> ImageRequest {
        var request = ImageRequest(artwork: url, options: [.disableMemoryCacheWrites])
        request.thumbnail = ImageRequest.ThumbnailOptions(maxPixelSize: nowPlayingArtworkMaxPixelSize)
        return request
    }

    /// Warm artwork bytes into the disk cache only, for art further from the
    /// screen; whatever size it is later drawn at decodes locally.
    static func prefetchArtworkData(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        dataPrefetcher.startPrefetching(with: artworkRequests(urls))
    }

    /// Full-size requests under each URL's artwork cache identity.
    private static func artworkRequests(_ urls: some Sequence<URL>) -> [ImageRequest] {
        urls.map { ImageRequest(artwork: $0) }
    }

    private static let prefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(
            pipeline: ImagePipeline.shared,
            destination: .memoryCache,
            maxConcurrentRequestCount: 4
        )
        prefetcher.priority = .normal
        return prefetcher
    }()

    private static let dataPrefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(
            pipeline: ImagePipeline.shared,
            destination: .diskCache,
            maxConcurrentRequestCount: 4
        )
        prefetcher.priority = .low
        return prefetcher
    }()

    // MARK: - Pipeline

    private static var memoryWarningObserver: NSObjectProtocol?

    /// Call once at app launch before any SwiftUI view renders.
    static func install() {
        #if DEBUG
        // os_signpost intervals for every fetch, decode, and processing step
        // (subsystem "com.github.kean.Nuke"), visible in Instruments.
        ImagePipeline.Configuration.isSignpostLoggingEnabled = true
        #endif
        ImagePipeline.shared = makePipeline()
        installMemoryPressureObserverIfNeeded()
    }

    /// Drop decoded images while preserving the disk cache. Playback is the
    /// only surface where poster reuse is invisible but memory headroom is
    /// tight, especially on 3 GB Apple TV hardware.
    static func trimDecodedMemory() {
        // Queued warm-ups would refill the cache straight away.
        prefetcher.stopPrefetching()
        ImagePipeline.shared.cache.removeAll(caches: .memory)
    }

    /// Builds before the continuum → silo rename kept the disk cache under
    /// this name. Reclaim the space off the main thread.
    private static func removeLegacyDataCache() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let legacy = caches.appendingPathComponent("com.continuum.app.apple.posters", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private static func makePipeline() -> ImagePipeline {
        ImagePipeline { config in
            // The DataCache below is the only disk cache. Nuke's default
            // loader would also write every response to a Foundation URLCache.
            config.dataLoader = {
                let session = URLSessionConfiguration.default
                session.urlCache = nil
                return LocalRouteDataLoader(loader: DataLoader(configuration: session))
            }()

            let memoryCache = ImageCache()
            memoryCache.costLimit = decodedMemoryCacheBudgetBytes
            memoryCache.countLimit = decodedImageCountLimit
            config.imageCache = memoryCache

            removeLegacyDataCache()
            if let dataCache = try? DataCache(name: "org.siloserver.silo.posters") {
                dataCache.sizeLimit = 1_024 * 1024 * 1024
                config.dataCache = dataCache
            }

            // Thumbnail decodes do the whole decode + downsample in the
            // decoding stage, so give it more than Nuke's default of one slot:
            // with one, every poster in a freshly revealed row waits in line.
            config.imageDecodingQueue.maxConcurrentOperationCount = 3
            config.imageDecompressingQueue.maxConcurrentOperationCount = 2
            config.dataLoadingQueue.maxConcurrentOperationCount = 8
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

    #if os(tvOS)
    // MARK: - tvOS hero backdrops

    /// Root-hero backdrop warmer for the cards beside a rested marquee
    /// selection. Data-only: a hero backdrop decodes to about 18 MB at 4K, and
    /// decoding the neighbours would evict dozens of posters on 3 GB Apple
    /// TVs. The bytes remove the network round trip, the dominant cost of a
    /// rested swap; the one decode happens when the backdrop is requested.
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
    /// once per rested selection, never per focus change.
    @MainActor
    static func warmNeighborBackdrops(_ urlStrings: [String]) {
        var seen = Set<URL>()
        let urls = urlStrings
            .compactMap { $0.isEmpty ? nil : URL(string: $0) }
            .filter { seen.insert($0).inserted }
        let stale = warmedNeighborBackdropURLs.subtracting(urls)
        let fresh = urls.filter { !warmedNeighborBackdropURLs.contains($0) }
        warmedNeighborBackdropURLs = seen
        if !stale.isEmpty { neighborBackdropPrefetcher.stopPrefetching(with: artworkRequests(stale)) }
        if !fresh.isEmpty { neighborBackdropPrefetcher.startPrefetching(with: artworkRequests(fresh)) }
    }

    /// The box every title logo fits inside: the Home marquee's, the largest
    /// place one is drawn (the library marquee, detail hero and its loading
    /// state draw inside it). One decode serves them all, so the logo a
    /// marquee showed is already in memory when its detail opens.
    static let titleLogoPointBox = CGSize(
        width: SiloTheme.Skyline.marqueeLogoMaxWidth,
        height: SiloTheme.Skyline.marqueeLogoMaxHeightHome
    )

    /// The request every title logo view issues: an aspect-fit decode to
    /// `titleLogoPointBox` on this display. An original logo can be 3840 px
    /// wide; its unprocessed decode would hold tens of megabytes.
    @MainActor
    static func titleLogoRequest(for url: URL, priority: ImageRequest.Priority = .normal) -> ImageRequest {
        let scale = displayScale
        var request = ImageRequest(artwork: url, priority: priority)
        request.thumbnail = ImageRequest.ThumbnailOptions(
            size: CGSize(width: titleLogoPointBox.width * scale, height: titleLogoPointBox.height * scale),
            unit: .pixels,
            contentMode: .aspectFit
        )
        return request
    }

    /// Warm title logos into memory at the size their views decode them, so
    /// a marquee paints its logo on the first frame.
    @MainActor
    static func prefetchTitleLogos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls.map { titleLogoRequest(for: $0) })
    }

    @MainActor
    static func cancelNeighborBackdropWarmup() {
        guard !warmedNeighborBackdropURLs.isEmpty else { return }
        neighborBackdropPrefetcher.stopPrefetching(with: artworkRequests(warmedNeighborBackdropURLs))
        warmedNeighborBackdropURLs.removeAll()
    }

    /// A movie's cast rail is part of the first detail viewport; warm the
    /// first screenful of portraits at the size `TVDetailCastRail` draws them.
    /// Series cast sits further down its page and loads lazily.
    @MainActor
    static func prefetchVisibleMovieCast(for detail: ItemDetail) {
        guard detail.type == "movie", let cast = detail.cast else { return }

        var urls: [URL] = []
        var seen = Set<String>()
        for member in cast {
            guard urls.count < 8 else { break }
            guard let value = member.photoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value),
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }

        prefetchArtwork(urls, pointSize: TVDetailCastRail.photoSize)
    }

    /// The request `TVRootHeroBackdrop` issues for a hero backdrop, so a warm
    /// decode and the display share one memory-cache entry.
    @MainActor
    static func heroBackdropRequest(
        for url: URL,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest? {
        let pointSize = TVBackdropArtworkLayout.artworkSize(
            forViewportWidth: TVBackdropArtworkLayout.viewportWidth
        )
        return displayRequest(url: url, pointSize: pointSize, scale: displayScale, priority: priority)
    }

    /// Fetch and decode one hero backdrop and sample its tint, concurrently.
    /// Used by the marquee while a row-change scroll holds the visible swap:
    /// the user is waiting on exactly this image, so it runs at high priority
    /// and cancels with the caller's task.
    @MainActor
    static func warmHeroBackdrop(_ url: URL) async {
        let request = heroBackdropRequest(for: url, priority: .high)
        async let image: Void = {
            guard let request else { return }
            _ = try? await ImagePipeline.shared.image(for: request)
        }()
        async let tint: Void = { _ = await HeroBackdropPalette.tints(for: url) }()
        _ = await (image, tint)
    }
    #endif
}

/// Which decode sizes have been requested for each artwork, so a view can
/// find a decode already in memory without knowing who requested it. Keyed by
/// cache identity, so a re-signed URL finds its earlier decodes. Bounded;
/// presence is always confirmed against the memory cache itself.
final class ArtworkVariants: @unchecked Sendable {
    static let shared = ArtworkVariants()

    private final class Sizes {
        var values: [CGSize] = []
    }

    private let lock = NSLock()
    private let sizesByImageID: NSCache<NSString, Sizes> = {
        let cache = NSCache<NSString, Sizes>()
        cache.countLimit = 4_000
        return cache
    }()

    /// `imageID` is the request's cache identity (`ImageRequest.imageID`).
    func record(_ imageID: String?, pixelSize: CGSize) {
        guard let imageID else { return }
        let key = imageID as NSString
        lock.withLock {
            if let sizes = sizesByImageID.object(forKey: key) {
                if !sizes.values.contains(pixelSize) {
                    sizes.values.append(pixelSize)
                }
            } else {
                let sizes = Sizes()
                sizes.values = [pixelSize]
                sizesByImageID.setObject(sizes, forKey: key)
            }
        }
    }

    func sizes(for url: URL) -> [CGSize] {
        sizes(forImageID: ArtworkCacheKey.imageID(for: url))
    }

    func sizes(forImageID imageID: String?) -> [CGSize] {
        guard let imageID else { return [] }
        return lock.withLock { sizesByImageID.object(forKey: imageID as NSString)?.values ?? [] }
    }
}
