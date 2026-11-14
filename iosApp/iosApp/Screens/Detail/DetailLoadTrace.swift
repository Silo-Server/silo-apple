#if DEBUG
import Foundation
import Nuke
import os
#if os(iOS)
import UIKit
#endif

/// Times one detail page visit from the tap that opened it, for benchmarking
/// how fast the page fills in. Off unless the app launches with
/// `-detailLoadTrace`.
///
/// Each milestone is logged once per visit as
/// `DLT <contentId> <milestone> <ms since tap>` under the `perf.detail`
/// category, and appended to `tmp/detail-load-trace.log`.
///
/// With `-detailLoadTraceCold`, closing a page drops the item metadata held
/// in memory and the artwork detail visits and `DetailPrewarmer` loaded, then
/// has the prewarmer start over on the cards still on screen, so the next tap
/// measures a title never opened before, prewarmed as a real first visit
/// would be. Artwork the source screen loaded for its cards stays cached.
/// `-detailPrewarmOff` turns the prewarmer off, to measure without it.
///
/// Each completed prewarm logs `DLT prewarm <contentId> <ms> <requests>`,
/// followed by the running cost (`DLT prewarm_total ...`).
@MainActor
enum DetailLoadTrace {
    enum Milestone: String {
        /// The page view was created.
        case viewInit = "view_init"
        /// The page drew anything, even an empty background.
        case pageAppear = "page_appear"
        /// The page has a title and metadata to draw, from any source.
        case detailFirst = "detail_first"
        /// The title and metadata are on screen.
        case contentAppear = "content_appear"
        /// The hero shows artwork, at any resolution.
        case backdropFirst = "backdrop_first"
        /// The hero shows artwork at the size it is drawn.
        case backdropFull = "backdrop_full"
        /// Core Animation finished committing the first UI update that began
        /// after `contentAppear`: the frame holding the content has gone to
        /// the render server. `onAppear` runs while UIKit lays out the
        /// presentation, after that update's commit, so the content reaches
        /// the screen with the next one.
        case contentCommit = "content_commit"
        /// When UIKit expected that frame on screen
        /// (`UIUpdateInfo.estimatedPresentationTime`).
        case contentPresent = "content_present"
        /// As `contentCommit` and `contentPresent`, for `backdropFull`.
        case backdropFullCommit = "backdrop_full_commit"
        case backdropFullPresent = "backdrop_full_present"
        /// The catalog response is on screen.
        case detailNetwork = "detail_network"
        /// Versions, tracks and resume state from `/watch` are on screen.
        case playbackMetadata = "playback_metadata"
        case seasons
        case episodes
        case loadDone = "load_done"
    }

    static let isEnabled = CommandLine.arguments.contains("-detailLoadTrace")
    private static let resetsCaches = CommandLine.arguments.contains("-detailLoadTraceCold")
    static let prewarmDisabled = CommandLine.arguments.contains("-detailPrewarmOff")
    /// Opens pages without the card's data, as they opened before seeding,
    /// so one build can measure the old first paint with the newer markers.
    static let seedDisabled = CommandLine.arguments.contains("-detailSeedOff")
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "perf.detail")

    private static var contentId: String?
    private static var start: ContinuousClock.Instant?
    private static var reached: Set<Milestone> = []
    private static var heroArtwork: Set<String> = []
    /// Hero artwork named by a fetched detail, as opposed to a card seed.
    /// Only this counts toward `backdropFull`.
    private static var fullHeroArtwork: Set<String> = []
    /// Hero artwork this visit has drawn at the size it is shown.
    private static var shownFullSize: Set<String> = []
    /// True from a tap until its page closes.
    private static var isVisitOpen = false
    /// Artwork detail visits and the prewarmer loaded since the last cold
    /// reset, which the next one evicts.
    private static var loadedArtwork: [ImageRequest] = []
    /// Hero artwork a card seed named, with the decodes of it in memory when
    /// it was first named. The bytes and those decodes belong to the source
    /// screen; any decode added during the visit is the page's.
    private static var seedArtworkAtTap: [String: (url: URL, decodes: [CGSize])] = [:]

    static func begin(contentId: String, libraryId: Int? = nil) {
        guard isEnabled else { return }
        isVisitOpen = true
        visitedContentIds.insert(contentId)
        heroArtwork = []
        fullHeroArtwork = []
        shownFullSize = []
        reached = []
        self.contentId = contentId
        start = ContinuousClock.now
        write("tap", milliseconds: 0)
        #if os(iOS)
        reachedBeforeCommit = []
        observeCommits()
        #endif
        let cached: ItemDetail? = ResponseCache.shared.get(CacheKey.itemDetail(contentId, libraryId: libraryId))
        writeLine("DLTX \(contentId) detail_cached_at_tap \(cached != nil)")
    }

    /// The detail card closed. A cold run resets here rather than at the
    /// next tap, so the prewarmer has the time between taps to fetch the
    /// next page again.
    static func detailDismissed() {
        guard isEnabled else { return }
        isVisitOpen = false
        guard resetsCaches else {
            loadedArtwork = []
            seedArtworkAtTap = [:]
            return
        }
        for (url, decodesAtTap) in seedArtworkAtTap.values {
            for request in decodesInMemory(of: url) where !decodesAtTap.contains(request.size) {
                ImagePipeline.shared.cache.removeCachedImage(for: request.request, caches: .memory)
            }
        }
        seedArtworkAtTap = [:]
        ResponseCache.shared.clearMemory(withPrefix: "item:")
        var remaining = 0
        for request in loadedArtwork {
            ImagePipeline.shared.cache.removeCachedImage(for: request, caches: .all)
            // The decode above is keyed by its size; the downloaded bytes
            // and the tint sample are keyed by the artwork alone.
            if let url = request.url {
                ImagePipeline.shared.cache.removeCachedImage(for: ImageRequest(artwork: url), caches: .all)
                ImagePipeline.shared.cache.removeCachedImage(
                    for: PosterImageCache.paletteSampleRequest(for: url), caches: .all
                )
            }
            if ImagePipeline.shared.cache.containsCachedImage(for: request, caches: .all) { remaining += 1 }
        }
        logger.notice("DLT cold reset: dropped \(loadedArtwork.count) artwork, \(remaining) still cached")
        loadedArtwork = []
        #if !os(tvOS)
        DetailPrewarmer.shared.resetBookkeeping()
        #endif
    }

    /// Artwork a prewarm downloaded, for the next cold reset.
    static func notePrewarmedArtwork(_ requests: [ImageRequest]) {
        guard isEnabled else { return }
        loadedArtwork.append(contentsOf: requests)
    }

    #if !os(tvOS)
    static func logPrewarm(contentId: String, elapsed: Duration, requests: Int, stats: DetailPrewarmer.Stats) {
        guard isEnabled else { return }
        writeLine("DLT prewarm \(contentId) \(String(format: "%.1f", milliseconds(elapsed))) \(requests)")
        writeLine(
            "DLT prewarm_total items=\(stats.items) json=\(stats.jsonRequests) "
                + "images=\(stats.imageRequests) image_bytes=\(stats.imageBytes)"
        )
    }
    #endif

    static func mark(_ milestone: Milestone) {
        guard isEnabled, let start, reached.insert(milestone).inserted else { return }
        write(milestone.rawValue, milliseconds: milliseconds(ContinuousClock.now - start))
    }

    #if os(iOS)
    /// Watches UI updates passively, without requesting any.
    private static var updateLink: UIUpdateLink?
    /// Milestones reached before the current UI update began to commit.
    private static var reachedBeforeCommit: Set<Milestone> = []
    private static var startMediaTime: CFTimeInterval = 0

    private static func observeCommits() {
        startMediaTime = CACurrentMediaTime()
        guard updateLink == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let link = UIUpdateLink(windowScene: scene)
        link.addAction(to: .beforeCATransactionCommit) { _, _ in
            reachedBeforeCommit = reached
        }
        link.addAction(to: .afterCATransactionCommit) { _, info in
            commitFinished(estimatedPresentation: info.estimatedPresentationTime)
        }
        link.isEnabled = true
        updateLink = link
    }

    private static func commitFinished(estimatedPresentation: CFTimeInterval) {
        guard isVisitOpen else { return }
        let pairs: [(Milestone, Milestone, Milestone)] = [
            (.contentAppear, .contentCommit, .contentPresent),
            (.backdropFull, .backdropFullCommit, .backdropFullPresent),
        ]
        for (shown, commit, present) in pairs
        where reachedBeforeCommit.contains(shown) && !reached.contains(commit) {
            mark(commit)
            if reached.insert(present).inserted {
                write(present.rawValue, milliseconds: (estimatedPresentation - startMediaTime) * 1_000)
            }
        }
    }
    #endif

    /// Contents the benchmark has opened this launch. The prewarmer offers
    /// their cards last after a cold reset, so they are fetched first and
    /// the next tap on one measures a prewarmed page.
    private(set) static var visitedContentIds: Set<String> = []

    /// Names the artwork the hero draws, so its load can be told apart from
    /// every other image on the page. A card seed's artwork counts toward
    /// `backdropFirst` only; `backdropFull` needs the fetched detail's.
    static func registerHeroArtwork(_ url: String?, isProvisional: Bool) {
        guard isEnabled, let url, let identity = identity(of: url) else { return }
        if heroArtwork.insert(identity).inserted, isProvisional, let parsed = URL(string: url),
           seedArtworkAtTap[identity] == nil {
            seedArtworkAtTap[identity] = (parsed, decodesInMemory(of: parsed).map(\.size))
        }
        if !isProvisional {
            fullHeroArtwork.insert(identity)
            // The fetched detail kept the artwork the seed already drew at
            // full size, so its view reports nothing more.
            if shownFullSize.contains(identity) { mark(.backdropFull) }
        }
    }

    /// The display decodes of `url` in memory, by pixel size.
    private static func decodesInMemory(of url: URL) -> [(size: CGSize, request: ImageRequest)] {
        let base = ImageRequest(artwork: url)
        return ArtworkVariants.shared.sizes(forImageID: base.imageID).compactMap { size in
            var request = base
            request.thumbnail = ImageRequest.ThumbnailOptions(size: size, unit: .pixels, contentMode: .aspectFill)
            return ImagePipeline.shared.cache.containsCachedImage(for: request, caches: .memory)
                ? (size, request) : nil
        }
    }

    static func artworkShown(url: String, request: ImageRequest?, isFullSize: Bool) {
        guard isEnabled, isVisitOpen, start != nil, let identity = identity(of: url) else { return }
        // A card seed's artwork belongs to the source screen, which a cold
        // reset leaves cached.
        let isSeedArtwork = heroArtwork.contains(identity) && !fullHeroArtwork.contains(identity)
        if isFullSize, let request, !isSeedArtwork { loadedArtwork.append(request) }
        guard heroArtwork.contains(identity) else { return }
        mark(.backdropFirst)
        if isFullSize { shownFullSize.insert(identity) }
        if isFullSize, fullHeroArtwork.contains(identity) { mark(.backdropFull) }
    }

    private static func identity(of url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        return ArtworkCacheKey.imageID(for: parsed)
    }

    private static func milliseconds(_ elapsed: Duration) -> Double {
        Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func write(_ milestone: String, milliseconds: Double) {
        writeLine("DLT \(contentId ?? "-") \(milestone) \(String(format: "%.1f", milliseconds))")
    }

    /// Lines go to the file on a background queue: opening and writing it
    /// on the main thread took a few milliseconds of the frames being timed.
    private static let fileQueue = DispatchQueue(label: "org.siloserver.silo.detail-load-trace")

    private static func writeLine(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        fileQueue.async {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("detail-load-trace.log")
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }
}
#endif
