import AetherEngine
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog

/// Load-scoped ASS presentation. Selection changes fence both font downloads
/// and rendered frames; no completed work from an outgoing track can reappear.
@MainActor
final class ASSSubtitleSession: ObservableObject {
    @Published private(set) var frame: ASSSubtitleRenderer.Frame?
    @Published private(set) var isLoadingFonts = false
    @Published private(set) var failureMessage: String?

    private let engine: AetherEngine
    private let fontLoader: @Sendable (URLRequest) async throws -> [FontAttachment]
    private var renderer = ASSSubtitleRenderer()
    private var subscriptions: Set<AnyCancellable> = []
    private var events: [ASSSubtitleRenderer.Event] = []
    private var clockSample: (source: Double, item: Double)?
    private weak var clockPlayer: AVPlayer?
    private var fontTask: Task<Void, Never>?
    private var fontRequests: [Int: URLRequest] = [:]
    private var fontCache: [URL: [FontAttachment]] = [:]
    private var selectedFonts: [FontAttachment] = []
    private var fontSelection: Int?
    private var generation: UInt64 = 0
    private var fontGeneration: UInt64 = 0
    private var cueRevision: UInt64 = 0
    private var enabled = false
    private var didRecordFrame = false
    private var timelineOffset: Double = 0
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "ASSSubtitles")

    init(engine: AetherEngine,
         fontLoader: @escaping @Sendable (URLRequest) async throws -> [FontAttachment] = { try await ASSSubtitleSession.loadFonts($0) }) {
        self.engine = engine
        self.fontLoader = fontLoader
        engine.$activeSubtitleTrackIndex.removeDuplicates().sink { [weak self] _ in
            self?.clearSelection()
        }.store(in: &subscriptions)
        engine.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            cueRevision &+= 1
            generation &+= 1
            events = ASSSubtitleRenderer.Event.events(from: cues)
            if cues.isEmpty {
                renderer = ASSSubtitleRenderer()
                frame = nil
            }
        }.store(in: &subscriptions)
        engine.clock.$sourceTime.sink { [weak self] time in
            guard let self else { return }
            clockPlayer = engine.currentAVPlayer
            if let itemTime = clockPlayer?.currentTime().seconds, itemTime.isFinite {
                clockSample = (time, itemTime)
            } else {
                clockSample = nil
            }
        }.store(in: &subscriptions)
    }

    deinit { fontTask?.cancel() }

    var handlesCurrentTrack: Bool {
        guard let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else {
            return false
        }
        return ["ass", "ssa"].contains(track.codec.lowercased())
    }

    func beginLoad(timelineOffset: Double) {
        enabled = false
        self.timelineOffset = timelineOffset
        fontRequests = [:]
        fontCache = [:]
        clearSelection()
    }

    func finishLoad() { enabled = true }

    func stop() {
        enabled = false
        fontRequests = [:]
        fontCache = [:]
        clearSelection()
    }

    func registerFontRequest(_ request: URLRequest, trackID: Int) {
        guard fontRequests[trackID] != request else { return }
        fontRequests[trackID] = request
        if fontSelection == trackID { clearSelection() }
    }

    private func clearSelection() {
        generation &+= 1
        fontGeneration &+= 1
        fontTask?.cancel()
        fontTask = nil
        fontSelection = nil
        selectedFonts = []
        isLoadingFonts = false
        failureMessage = nil
        didRecordFrame = false
        frame = nil
        renderer = ASSSubtitleRenderer()
    }

    /// Called by the visible overlay, with at most one frame in flight. The
    /// engine's source clock follows the displayed frame even during seeks.
    func render(size: CGSize, scale: CGFloat, delaySeconds: Double) async {
        guard enabled, handlesCurrentTrack,
              let track = engine.subtitleTracks.first(where: { $0.id == engine.activeSubtitleTrackIndex }) else {
            if frame != nil { frame = nil }
            return
        }
        if fontSelection != track.id { prepareFonts(trackID: track.id) }
        guard !isLoadingFonts, failureMessage == nil else { return }
        let header = track.isExternal ? engine.sidecarASSHeader : track.assHeader
        guard let header, !header.isEmpty else {
            if frame != nil { frame = nil }
            if !engine.isLoadingSubtitles {
                reportFailure("Subtitle data couldn’t be loaded. Turn subtitles off and on to retry.",
                              error: URLError(.cannotDecodeContentData))
            }
            return
        }
        let epoch = generation
        let worker = renderer
        let time = Self.renderTime(engineTime: renderedSourceTime,
                                   timelineOffset: timelineOffset, isExternal: track.isExternal,
                                   delaySeconds: delaySeconds)
        do {
            let rendered = try await worker.render(header: header, fonts: selectedFonts,
                                                   events: events, revision: cueRevision, time: time, size: size, scale: scale)
            guard !Task.isCancelled, epoch == generation, enabled else { return }
            if frame?.image !== rendered?.image { frame = rendered }
            if !didRecordFrame, rendered != nil, events.contains(where: { $0.start <= time && time < $0.end }) {
                didRecordFrame = true
                #if os(iOS) || os(tvOS)
                DiagTrace.breadcrumb(.essential, category: .playback, tag: "ASSSubtitles",
                    message: "Local ASS frame ready: events=\(events.count) fonts=\(selectedFonts.count) source=\(track.isExternal ? "sidecar" : "embedded")")
                #endif
            }
        } catch {
            guard epoch == generation else { return }
            reportFailure("Subtitles couldn’t be rendered.", error: error)
        }
    }

    private var renderedSourceTime: Double {
        // Aether publishes the parked picture clock every 100 ms. Sample the
        // same AVPlayer between ticks for smooth karaoke/motion, but never
        // extrapolate through a seek, stall, player replacement, or clock seam.
        guard !engine.isSeeking, !engine.isBuffering,
              let player = engine.currentAVPlayer, player === clockPlayer,
              let sample = clockSample else { return engine.clock.sourceTime }
        let delta = player.currentTime().seconds - sample.item
        guard delta.isFinite, (0...0.15).contains(delta) else { return engine.clock.sourceTime }
        return sample.source + delta
    }

    nonisolated static func renderTime(engineTime: Double, timelineOffset: Double,
                           isExternal: Bool, delaySeconds: Double) -> Double {
        engineTime + (isExternal ? timelineOffset : 0) - delaySeconds
    }

    private func prepareFonts(trackID: Int) {
        fontSelection = trackID
        if !engine.fontAttachments.isEmpty {
            selectedFonts = engine.fontAttachments
            return
        }
        guard let request = fontRequests[trackID], let url = request.url else { return }
        if let cached = fontCache[url] {
            selectedFonts = cached
            return
        }
        isLoadingFonts = true
        let epoch = fontGeneration
        let loader = fontLoader
        fontTask = Task { [weak self] in
            do {
                let fonts = try await loader(request)
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
        frame = nil
        failureMessage = message
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(.essential, category: .playback, tag: "ASSSubtitles", message: message)
        #endif
        let underlying = error as NSError
        Self.logger.error("ASS subtitle failure domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public)")
    }

    nonisolated static func loadFonts(_ request: URLRequest) async throws -> [FontAttachment] {
        var request = request
        request.timeoutInterval = 20
        let data: Data
        if let url = request.url, url.isFileURL {
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

    nonisolated static func decodeFonts(_ data: Data) throws -> [FontAttachment] {
        struct Item: Decodable { let name: String; let data: Data }
        guard data.count <= 48 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        let items = try JSONDecoder().decode([Item].self, from: data)
        guard items.count <= 64, items.allSatisfy({ !$0.name.isEmpty && !$0.data.isEmpty }),
              items.reduce(0, { $0 + $1.data.count }) <= 32 * 1_024 * 1_024 else {
            throw URLError(.cannotDecodeContentData)
        }
        return items.map { FontAttachment(filename: $0.name, mimeType: "", data: $0.data) }
    }
}
