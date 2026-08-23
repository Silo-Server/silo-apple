import AetherEngine
import CoreGraphics
import Foundation

/// Owns disposable still extraction for the active Aether load generation.
///
/// Silo's controls speak in source-media time while Aether's still APIs use
/// the active player/transport axis. Keeping the conversion and generation
/// fences here prevents a late frame from a replaced V3 plan appearing over
/// the next item. Cache-backed native stills are preferred because they do
/// not open a second connection; software playback falls back to Aether's
/// session-coupled `FrameExtractor` over the exact load URL and headers.
@MainActor
final class AetherScrubPreviewProvider {
    struct Preview {
        let image: CGImage
        let sourceTime: Double
    }

    var onPreview: ((Preview?) -> Void)?

    private static let requestDebounce: Duration = .milliseconds(80)
    private static let thumbnailWidth = 480

    private struct PendingRequest {
        let sourceTime: Double
        let playerTime: Double
        let extractor: FrameExtractor?
        let sessionGeneration: UInt64
        let requestGeneration: UInt64
    }

    private let engine: AetherEngine
    private var activeSpec: AetherLoadSpec?
    private var extractor: FrameExtractor?
    private var sessionGeneration: UInt64 = 0
    private var requestGeneration: UInt64 = 0
    private var pendingRequest: PendingRequest?
    private var workerTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var shutdownTasks: [UUID: Task<Void, Never>] = [:]

    init(engine: AetherEngine) {
        self.engine = engine
    }

    /// Binds previews to a successfully loaded Aether generation. The
    /// explicit URL/header overload is intentional: it guarantees an
    /// authenticated V3 transport is extracted with the same inputs that
    /// were validated by `AetherLoadSpec`.
    func activate(_ spec: AetherLoadSpec) {
        endSession()
        sessionGeneration &+= 1
        activeSpec = spec
        extractor = engine.makeFrameExtractor(
            url: spec.sourceURL,
            httpHeaders: spec.options.httpHeaders
        )
    }

    /// Starts one interaction. Prewarming is elective and Aether will yield
    /// it while playback is starved; the first requested still is therefore
    /// never allowed to compete with startup/recovery media.
    func begin(atSourceTime sourceTime: Double) {
        guard let spec = activeSpec else { return }
        onPreview?(nil)
        if !engine.supportsCacheBackedStills {
            if extractor == nil {
                extractor = engine.makeFrameExtractor(
                    url: spec.sourceURL,
                    httpHeaders: spec.options.httpHeaders
                )
            }
        }
        if !engine.supportsCacheBackedStills, let extractor {
            prewarmTask?.cancel()
            prewarmTask = Task {
                await extractor.prewarm()
            }
        }
        request(atSourceTime: sourceTime)
    }

    /// Requests only the latest scrub target. The short trailing debounce,
    /// single pending slot, and prompt extractor shutdown bound work during a
    /// fast drag. Both session and request generations fence late cache/decode
    /// results before publication.
    ///
    /// Targets the loaded transport cannot express — chiefly a backward scrub
    /// before a re-anchored HLS plan's `timeline_offset_seconds` — are dropped
    /// with a neutral (nil) publication. Converting them through
    /// `playerPosition(forSourceTime:)` clamps to player time 0, which would
    /// present the transport's first frame as if it were the requested source
    /// moment. Only a server replan can produce a transport containing them,
    /// and server-backed preview fetching is out of scope here.
    func request(atSourceTime sourceTime: Double) {
        guard sourceTime.isFinite, sourceTime >= 0 else {
            // An invalid target still supersedes whatever was decoding: fence
            // the in-flight result and clear the published preview, or a stale
            // frame can land after this newer request.
            requestGeneration &+= 1
            pendingRequest = nil
            onPreview?(nil)
            return
        }
        guard let spec = activeSpec else {
            return
        }

        requestGeneration &+= 1
        onPreview?(nil)
        guard case let .local(playerTime) = spec.timeline.seekDisposition(
            forSourceTime: sourceTime
        ) else {
            pendingRequest = nil
            return
        }
        pendingRequest = PendingRequest(
            sourceTime: sourceTime,
            playerTime: playerTime,
            extractor: extractor,
            sessionGeneration: sessionGeneration,
            requestGeneration: requestGeneration
        )
        if workerTask == nil {
            workerTask = Task { @MainActor [weak self] in
                await self?.runRequestWorker()
            }
        }
    }

    func endInteraction() {
        requestGeneration &+= 1
        pendingRequest = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        onPreview?(nil)
        retireExtractor()
    }

    /// Detaches the active load immediately and begins prompt asynchronous
    /// teardown. The returned task lets final player cleanup await the
    /// extractor's decode-queue shutdown without blocking the main actor.
    @discardableResult
    func endSession() -> Task<Void, Never>? {
        sessionGeneration &+= 1
        endInteraction()
        activeSpec = nil
        let extractorShutdowns = Array(shutdownTasks.values)
        let requestWorker = workerTask
        guard !extractorShutdowns.isEmpty || requestWorker != nil else { return nil }
        return Task {
            for task in extractorShutdowns {
                await task.value
            }
            await requestWorker?.value
        }
    }

    /// One worker means at most one cache decode or independent-reader pull
    /// is in flight. Requests arriving during that await replace the single
    /// pending slot, so a drag is bounded to one active + one latest target.
    private func runRequestWorker() async {
        defer { workerTask = nil }
        while pendingRequest != nil {
            try? await Task.sleep(for: Self.requestDebounce)
            guard let request = pendingRequest else { continue }
            pendingRequest = nil
            guard sessionGeneration == request.sessionGeneration else { continue }

            let playerTime = request.playerTime
            let image: CGImage?
            if engine.supportsCacheBackedStills {
                // A nil is expected when the requested native segment is not
                // resident. Do not fall through to a second network reader:
                // that breaks single-connection/debrid sources.
                image = await engine.scrubThumbnail(
                    atSeconds: playerTime,
                    maxWidth: Self.thumbnailWidth
                )
            } else if let extractor = request.extractor {
                image = await extractor.thumbnail(
                    at: playerTime,
                    maxWidth: Self.thumbnailWidth
                )
            } else {
                image = nil
            }

            guard sessionGeneration == request.sessionGeneration,
                  requestGeneration == request.requestGeneration else {
                continue
            }
            onPreview?(image.map {
                Preview(image: $0, sourceTime: request.sourceTime)
            })
        }
    }

    private func retireExtractor() {
        guard let extractor else { return }
        self.extractor = nil
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await extractor.shutdown()
            self?.shutdownTasks.removeValue(forKey: id)
        }
        shutdownTasks[id] = task
    }
}
