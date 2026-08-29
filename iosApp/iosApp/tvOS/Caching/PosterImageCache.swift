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
        var config = ImagePipeline.Configuration()

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

        #if os(iOS) || os(tvOS)
        return ImagePipeline(
            configuration: config,
            delegate: PosterImagePipelineDiagnostics.shared
        )
        #else
        return ImagePipeline(configuration: config)
        #endif
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
}
