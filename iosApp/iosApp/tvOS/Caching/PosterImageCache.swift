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
/// - Background decoding + downsampling to the actual render size
/// - A prefetcher the grid can use to warm posters N rows ahead
///
/// The pipeline is installed as the `ImagePipeline.shared` at first access so
/// every `LazyImage` / `ImagePipeline.shared` caller picks it up automatically.
enum PosterImageCache {
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

            // Decode on a background queue — never block the main thread.
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

        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }
    #endif
}
