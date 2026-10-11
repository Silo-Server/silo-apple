import AetherEngine
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog

/// Load-scoped ASS presentation. Selection changes fence both font downloads
/// and rendered frames; no completed work from an outgoing track can reappear.
@MainActor
@Observable
final class ASSSubtitleSession {
    /// The layer the overlay view hosts. Replaced when the video's clock
    /// changes, which happens with the player item or playback path.
    private(set) var overlayLayer: CALayer?
    private(set) var isLoadingFonts = false
    private(set) var failureMessage: String?
    /// Bumped on every selection reset, including engine track switches, so
    /// views that read `handlesCurrentTrack` re-evaluate even while paused.
    private var selectionRevision: UInt64 = 0

    private let engine: AetherEngine
    /// While it holds, the overlay keeps the outgoing cues through the reload
    /// of the showing track instead of clearing.
    @ObservationIgnored var cueHold: SubtitleCueHold?
    /// Whether the overlay stays up while `trackID` reloads.
    private func holdsCues(for trackID: Int?) -> Bool {
        cueHold?.holds(.primary, trackID: trackID) == true
    }
    private let fontLoader: @Sendable (URLRequest, HTTPRequestAuthorization?) async throws -> [FontAttachment]
    @ObservationIgnored private let schedule: ASSFrameSchedule
    @ObservationIgnored private let presenter: ASSOverlayPresenter
    @ObservationIgnored private var sink: ASSOverlaySink?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    /// The engine's latest primary cues, parsed into ASS event lines on the
    /// next step so tracks libass never draws (SRT, PGS, VTT) skip the parse.
    @ObservationIgnored private var feed = CueFeed()
    @ObservationIgnored private var sentCueRevision: UInt64?
    /// Parsed event lines by Aether cue id, kept with the text they came
    /// from: a reloaded sidecar numbers its cues from zero again.
    @ObservationIgnored private var parsedLines: [Int: (raw: String, lines: [String])] = [:]
    /// Recent `item time - source time` readings for paths without a frame
    /// map, so one sampled reading cannot move the overlay.
    @ObservationIgnored private var leadSamples: [Double] = []
    @ObservationIgnored private var leadSeconds: Double?
    @ObservationIgnored private var fontTask: Task<Void, Never>?
    private struct FontRequest: Equatable {
        let request: URLRequest
        let authorization: HTTPRequestAuthorization?
    }
    @ObservationIgnored private var fontRequests: [Int: FontRequest] = [:]
    @ObservationIgnored private var fontCache: [URL: [FontAttachment]] = [:]
    @ObservationIgnored private var selectedFonts: [FontAttachment] = []
    @ObservationIgnored private var fontSelection: Int?
    /// Moves on with every selection, header, or load change. The layer
    /// accepts only the current generation's canvases.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var fontGeneration: UInt64 = 0
    /// The header the presenter has for `generation`; nil until it is loaded.
    @ObservationIgnored private var loadedHeader: String?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var didRecordFrame = false
    @ObservationIgnored private var timelineOffset: Double = 0
    @ObservationIgnored private var stats = RenderStats()
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "ASSSubtitles")

    /// Libass renders at most this many pixels. A 4K output shows a 1080p
    /// canvas scaled up: rendering signs at four times the area costs four
    /// times the time and canvas memory.
    nonisolated static let maximumCanvasPixels: Double = 1_920 * 1_080

    init(engine: AetherEngine,
         fontLoader: @escaping @Sendable (URLRequest, HTTPRequestAuthorization?) async throws -> [FontAttachment] = {
             try await ASSSubtitleSession.loadFonts($0, authorization: $1)
         }) {
        let schedule = ASSFrameSchedule()
        self.engine = engine
        self.fontLoader = fontLoader
        self.schedule = schedule
        presenter = ASSOverlayPresenter(schedule: schedule, axisMap: { [weak engine] in
            engine?.presentationAxisMap ?? PresentationAxisMap()
        })
        engine.setNativeVideoFrameTimeObserver { schedule.record($0) }
        engine.setSoftwareVideoFrameTimeObserver { schedule.record($0) }
        // Published values arrive before the property changes, so pass the
        // new index along.
        engine.$activeSubtitleTrackIndex.removeDuplicates().sink { [weak self] trackID in
            self?.clearSelection(showing: trackID)
        }.store(in: &subscriptions)
        engine.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            feed.publish(cues, held: holdsCues(for: self.engine.activeSubtitleTrackIndex))
        }.store(in: &subscriptions)
        engine.$isLoadingSubtitles.removeDuplicates().sink { [weak self] loading in
            guard let self, !loading else { return }
            feed.loadingFinished(with: self.engine.subtitleCues)
        }.store(in: &subscriptions)
        engine.clock.$sourceTime.sink { [weak self] time in
            self?.sampleLead(sourceTime: time)
        }.store(in: &subscriptions)
    }

    deinit { fontTask?.cancel() }

    var handlesCurrentTrack: Bool {
        _ = selectionRevision
        return activeASSTrack != nil
    }

    /// The selected primary track when libass draws it.
    private var activeASSTrack: TrackInfo? {
        guard let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }),
              ["ass", "ssa"].contains(track.codec.lowercased()) else { return nil }
        return track
    }

    private func header(of track: TrackInfo) -> String? {
        track.isExternal ? engine.sidecarASSHeader : track.assHeader
    }

    func beginLoad(timelineOffset: Double) {
        stop()
        self.timelineOffset = timelineOffset
        // Frame times and the measured lead describe the outgoing item's clock.
        schedule.removeAll()
        resetLead()
    }

    func finishLoad() { enabled = true }

    func stop() {
        enabled = false
        fontRequests = [:]
        fontCache = [:]
        clearSelection(showing: nil)
    }

    func registerFontRequest(_ request: URLRequest, trackID: Int, authorization: HTTPRequestAuthorization? = nil) {
        let resource = FontRequest(request: request, authorization: authorization)
        guard fontRequests[trackID] != resource else { return }
        fontRequests[trackID] = resource
        if fontSelection == trackID { clearSelection(showing: engine.activeSubtitleTrackIndex) }
    }

    private func clearSelection(showing trackID: Int?) {
        selectionRevision &+= 1
        fontGeneration &+= 1
        fontTask?.cancel()
        fontTask = nil
        fontSelection = nil
        selectedFonts = []
        isLoadingFonts = false
        failureMessage = nil
        didRecordFrame = false
        guard !holdsCues(for: trackID) else { return }
        parsedLines = [:]
        // Clear the layer now. The next step loads the new selection.
        advanceGeneration()
        sink?.flush(removingImage: true)
    }

    /// Starts a generation: the presenter reloads the selection and its cues,
    /// and the layer refuses canvases a step still rendering for an older one
    /// queues after this.
    private func advanceGeneration() {
        generation &+= 1
        loadedHeader = nil
        sentCueRevision = nil
        feed.dropReplacement()
        sink?.accept(generation: generation)
    }

    /// Called by the visible overlay when it (re)appears: whatever the layer
    /// queued while hidden is stale, so the next step starts a new one.
    func overlayWillAppear() {
        sink?.flush(removingImage: true)
        sink = nil
        overlayLayer = nil
    }

    /// Called repeatedly by the visible overlay. Each call renders the frames
    /// due shortly on the presenter's actor and queues them on the video clock.
    func step(size: CGSize, scale: CGFloat, delaySeconds: Double) async {
        guard enabled, let track = activeASSTrack else {
            if loadedHeader != nil {
                advanceGeneration()
                sink?.flush(removingImage: true)
                await presenter.reset()
            }
            return
        }
        if fontSelection != track.id { prepareFonts(trackID: track.id) }
        guard !isLoadingFonts, failureMessage == nil else { return }
        guard let header = header(of: track), !header.isEmpty else {
            if !engine.isLoadingSubtitles {
                reportFailure("Subtitle data couldn’t be loaded. Turn subtitles off and on to retry.",
                              error: URLError(.cannotDecodeContentData))
            }
            return
        }
        guard let canvas = Self.canvas(for: size, scale: scale) else { return }
        guard let sink = sinkForCurrentClock() else {
            await presenter.attach(nil)
            return
        }
        // Everything above runs before the first await. A step that resumes
        // after a newer selection began stops at the next check.
        let update = presenterUpdate(header: header)
        let epoch = generation
        await presenter.attach(sink)
        guard await send(update, epoch: epoch), enabled else { return }
        let timing = ASSOverlayPresenter.Timing(
            canvas: canvas,
            cueOffset: Self.cueOffset(timelineOffset: timelineOffset, isExternal: track.isExternal,
                                      delaySeconds: delaySeconds),
            axis: clockAxis,
            frameInterval: Self.frameInterval(fps: engine.sourceVideoFrameRate))
        do {
            let report = try await presenter.step(timing, generation: epoch)
            guard epoch == generation, enabled else { return }
            record(report, canvas: canvas, isExternal: track.isExternal)
        } catch {
            guard epoch == generation else { return }
            reportFailure("Subtitles couldn’t be rendered.", error: error)
        }
    }

    /// Renders the subtitles at a cue time without queuing them, for tests and
    /// diagnostics.
    func snapshot(cueTime: Double, size: CGSize, scale: CGFloat) async throws -> CVPixelBuffer? {
        guard let track = activeASSTrack, let canvas = Self.canvas(for: size, scale: scale) else { return nil }
        if fontSelection != track.id { prepareFonts(trackID: track.id) }
        guard let header = header(of: track) else { return nil }
        let update = presenterUpdate(header: header)
        let epoch = generation
        guard await send(update, epoch: epoch) else { return nil }
        let buffer = try await presenter.snapshot(cueTime: cueTime, canvas: canvas, generation: epoch)
        return epoch == generation ? buffer : nil
    }

    /// What the presenter lacks of the current selection.
    private struct PresenterUpdate {
        var load: (header: String, fonts: [FontAttachment])?
        var cues: (cues: [ASSSubtitleRenderer.Cue], revision: UInt64, replacing: Bool)?
    }

    /// Settles what the presenter must show, without awaiting. A header that
    /// changes under the same selection starts a new generation.
    private func presenterUpdate(header: String) -> PresenterUpdate {
        var update = PresenterUpdate()
        if let loadedHeader, loadedHeader != header { advanceGeneration() }
        if loadedHeader == nil {
            loadedHeader = header
            update.load = (header, selectedFonts)
        }
        if sentCueRevision != feed.revision {
            let revision = feed.revision
            sentCueRevision = revision
            update.cues = (parsedCues(), revision, feed.takeReplacement(through: revision))
        }
        return update
    }

    /// Hands `update` to the presenter. Returns false once a newer generation
    /// has begun, so the caller stops.
    private func send(_ update: PresenterUpdate, epoch: UInt64) async -> Bool {
        if let load = update.load {
            await presenter.load(generation: epoch, header: load.header, fonts: load.fonts)
            guard epoch == generation else { return false }
        }
        if let cues = update.cues {
            await presenter.updateCues(cues.cues, revision: cues.revision, replacing: cues.replacing)
        }
        return epoch == generation
    }

    /// The overlay layer follows the clock the video is presented on: the
    /// software path's synchronizer, or the player item's timebase.
    private func sinkForCurrentClock() -> ASSOverlaySink? {
        let timebase = engine.softwarePresentationTimebase ?? engine.currentAVPlayerItem?.timebase
        if timebase !== sink?.timebase {
            resetLead()
            sink = timebase.map { ASSOverlaySink(timebase: $0, generation: generation) }
            overlayLayer = sink?.layer
        }
        return sink
    }

    private var clockAxis: ASSOverlayPresenter.ClockAxis {
        if engine.softwarePresentationTimebase != nil { return .source }
        if !engine.presentationAxisMap.isEmpty { return .nativeItem }
        return .item(leadSeconds: leadSeconds ?? 0)
    }

    /// Paths without Aether's axis map (remote HLS) relate the item clock to
    /// the source clock through Aether's published picture time.
    private func sampleLead(sourceTime: Double) {
        guard let item = engine.currentAVPlayerItem?.currentTime().seconds, item.isFinite, sourceTime.isFinite,
              !engine.isSeeking else { return }
        leadSamples.append(item - sourceTime)
        if leadSamples.count > 9 { leadSamples.removeFirst(leadSamples.count - 9) }
        let median = leadSamples.sorted()[leadSamples.count / 2]
        // A frame's worth of sampling jitter must not flush the overlay.
        if leadSeconds.map({ abs($0 - median) > 0.05 }) ?? true { leadSeconds = median }
    }

    private func resetLead() {
        leadSamples = []
        leadSeconds = nil
    }

    private func parsedCues() -> [ASSSubtitleRenderer.Cue] {
        var cache: [Int: (raw: String, lines: [String])] = [:]
        cache.reserveCapacity(feed.cues.count)
        let cues = feed.cues.compactMap { cue -> ASSSubtitleRenderer.Cue? in
            guard case .text(let raw) = cue.body,
                  ASSSubtitleRenderer.Cue.hasUsableWindow(start: cue.startTime, end: cue.endTime) else { return nil }
            let lines = parsedLines[cue.id].flatMap { $0.raw == raw ? $0.lines : nil }
                ?? ASSSubtitleRenderer.Cue.lines(fromRaw: raw)
            cache[cue.id] = (raw, lines)
            guard !lines.isEmpty else { return nil }
            return ASSSubtitleRenderer.Cue(id: cue.id, start: cue.startTime, end: cue.endTime, lines: lines)
        }
        parsedLines = cache
        return cues
    }

    /// The primary cues as Aether publishes them, and which revision of them
    /// replaces what libass holds rather than adding to it.
    struct CueFeed {
        private(set) var cues: [SubtitleCue] = []
        private(set) var revision: UInt64 = 0
        /// The first revision of a reload held under the outgoing cues. It
        /// replaces every event the presenter has, including ones that ended
        /// long ago, which ordinary pruning keeps for a backward seek.
        private var replacementRevision: UInt64?
        /// A held reload's empty publication that nothing has superseded yet.
        private var heldEmpty = false

        /// A publication from Aether. Aether clears a track's cues when it
        /// starts loading it; while a reload of the showing track holds, that
        /// empty publication keeps the outgoing cues up until the new ones arrive.
        mutating func publish(_ cues: [SubtitleCue], held: Bool) {
            if cues.isEmpty, held {
                heldEmpty = true
                replacementRevision = revision &+ 1
            } else {
                accept(cues)
            }
        }

        /// Aether finished loading the primary track. A held reload that ended
        /// with no cues published nothing that passed the hold, so take what
        /// Aether holds now.
        mutating func loadingFinished(with cues: [SubtitleCue]) {
            if heldEmpty { accept(cues) }
        }

        /// Whether `revision` replaces every event rather than adding to them.
        mutating func takeReplacement(through revision: UInt64) -> Bool {
            guard let replacementRevision, revision >= replacementRevision else { return false }
            self.replacementRevision = nil
            return true
        }

        /// A new generation re-ingests every cue anyway.
        mutating func dropReplacement() { replacementRevision = nil }

        private mutating func accept(_ cues: [SubtitleCue]) {
            self.cues = cues
            revision &+= 1
            heldEmpty = false
        }
    }

    nonisolated static func cueOffset(timelineOffset: Double, isExternal: Bool, delaySeconds: Double) -> Double {
        (isExternal ? timelineOffset : 0) - delaySeconds
    }

    nonisolated static func frameInterval(fps: Double?) -> Double {
        guard let fps, fps.isFinite, (10...240).contains(fps) else { return 1_001.0 / 24_000.0 }
        return 1 / fps
    }

    nonisolated static func canvas(for size: CGSize, scale: CGFloat) -> ASSSubtitleRenderer.Canvas? {
        var width = Double(size.width * scale), height = Double(size.height * scale)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let area = width * height
        if area > maximumCanvasPixels {
            let factor = (maximumCanvasPixels / area).squareRoot()
            width *= factor
            height *= factor
        }
        let canvas = ASSSubtitleRenderer.Canvas(width: Int(width.rounded()), height: Int(height.rounded()))
        return canvas.isValid ? canvas : nil
    }

    private struct RenderStats {
        var frames = 0
        var reportedFrames = 0
        var renderSeconds: Double = 0
        var slowest: Double = 0
        var since = ContinuousClock.now
    }

    private func record(_ report: ASSOverlayPresenter.Step, canvas: ASSSubtitleRenderer.Canvas, isExternal: Bool) {
        if !didRecordFrame, report.drewSomething {
            didRecordFrame = true
            #if os(iOS) || os(tvOS)
            DiagTrace.breadcrumb(.essential, category: .playback, tag: "ASSSubtitles",
                message: "Local ASS frame ready: events=\(feed.cues.count) fonts=\(selectedFonts.count) source=\(isExternal ? "sidecar" : "embedded")")
            #endif
        }
        stats.frames += report.renderedFrames
        stats.reportedFrames += report.reportedFrames
        stats.renderSeconds += report.renderSeconds
        stats.slowest = max(stats.slowest, report.slowestRenderSeconds)
        guard ContinuousClock.now - stats.since >= .seconds(10) else { return }
        if stats.frames > 0 {
            let average = stats.renderSeconds / Double(stats.frames) * 1_000
            let clock = switch clockAxis {
            case .source: "software"
            case .nativeItem: "native"
            case .item: "item"
            }
            Self.logger.info("""
                ASS overlay frames=\(self.stats.frames, privacy: .public) \
                reported=\(self.stats.reportedFrames, privacy: .public) \
                avg=\(average, format: .fixed(precision: 2), privacy: .public)ms \
                slowest=\(self.stats.slowest * 1_000, format: .fixed(precision: 2), privacy: .public)ms \
                canvas=\(canvas.width, privacy: .public)x\(canvas.height, privacy: .public) \
                clock=\(clock, privacy: .public)
                """)
        }
        stats = RenderStats()
    }

    private func prepareFonts(trackID: Int) {
        fontSelection = trackID
        if !engine.fontAttachments.isEmpty {
            selectedFonts = engine.fontAttachments
            return
        }
        guard let resource = fontRequests[trackID], let url = resource.request.url else { return }
        if let cached = fontCache[url] {
            selectedFonts = cached
            return
        }
        isLoadingFonts = true
        let epoch = fontGeneration
        let loader = fontLoader
        fontTask = Task { [weak self] in
            do {
                let fonts = try await loader(resource.request, resource.authorization)
                guard let self, !Task.isCancelled, epoch == fontGeneration else { return }
                fontCache[url] = fonts
                selectedFonts = fonts
                isLoadingFonts = false
            } catch {
                guard let self, !Task.isCancelled, epoch == fontGeneration else { return }
                isLoadingFonts = false
                reportFailure("Subtitle fonts couldn’t be loaded. Turn subtitles off and on to retry.", error: error)
            }
        }
    }

    private func reportFailure(_ message: String, error: Error) {
        sink?.flush(removingImage: true)
        failureMessage = message
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(.essential, category: .playback, tag: "ASSSubtitles", message: message)
        #endif
        let underlying = error as NSError
        Self.logger.error("ASS subtitle failure domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public)")
    }

    nonisolated static func loadFonts(_ request: URLRequest, authorization: HTTPRequestAuthorization? = nil) async throws -> [FontAttachment] {
        var request = request
        request.timeoutInterval = 20
        let data: Data
        if let authorization {
            guard let url = request.url else { throw URLError(.badURL) }
            data = try await authorization.data(from: url, maximumBytes: 48 * 1_024 * 1_024)
        } else if let url = request.url, url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            data = body
        }
        return try decodeFonts(data)
    }

    /// `GET /api/v2/stream/{session_id}/subtitles/{track}/fonts` answers with
    /// the shared collection envelope, `{"items": [{"name", "data"}]}`.
    nonisolated static func decodeFonts(_ data: Data) throws -> [FontAttachment] {
        struct Item: Decodable { let name: String; let data: Data }
        struct Bundle: Decodable { let items: [Item] }
        guard data.count <= 48 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        let items = try JSONDecoder().decode(Bundle.self, from: data).items
        guard items.count <= 64, items.allSatisfy({ !$0.name.isEmpty && !$0.data.isEmpty }),
              items.reduce(0, { $0 + $1.data.count }) <= 32 * 1_024 * 1_024 else {
            throw URLError(.cannotDecodeContentData)
        }
        return items.map { FontAttachment(filename: $0.name, mimeType: "", data: $0.data) }
    }
}
