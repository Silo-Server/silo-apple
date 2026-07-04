//
//  SubtitleSession.swift
//  Continuum (iOS + tvOS)
//
//  Session-level coordinator for subtitle sources. Owns the mapping from
//  `PlayerTrack` selection (both embedded FFmpeg streams and server-
//  provided sidecar URLs) to the libass-backed `SubtitleRenderer`. Also
//  owns the sidecar fetch tasks and the in-session content cache.
//
//  Lives for the lifetime of one playback session. Held by `PlayerCore`
//  via a strong reference; torn down in `PlayerCore.dispose`.
//

import Foundation
import OSLog

/// Descriptor for a server-provided sidecar subtitle track. Copied
/// verbatim from `Networking/Models.swift` / `SubtitleUrl` into a
/// local struct so the subtitle layer doesn't pull in the full
/// playback-session model graph.
struct SidecarSubtitleDescriptor: Hashable {
    let index: Int
    let language: String?
    let codec: String?
    let label: String?
    let source: String?
    let forced: Bool?
    /// Absolute URL (server URL already resolved against the relative
    /// path that came back from `/playback/start`).
    let url: URL
}

final class SubtitleSession {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "SubtitleSession"
    )

    private let renderer: SubtitleRenderer
    private let fetcher: SidecarSubtitleFetcher

    /// Guards the lock-free mutable session state (`sidecarDescriptors`,
    /// `sidecarCache`, `fetchTasks`, `liveSlots`, `stylingParams`). Mirrors
    /// the `handleLock` idiom in `SubtitleRenderer`.
    ///
    /// The two playback backends call into this session from different
    /// queues — the CoreMedia route from `PlayerCore.controlQueue`, the
    /// AVPlayer route's live methods from main while
    /// `AVPlayerEmbeddedSubtitleExtractor` mutates the same fields from a
    /// global queue — so caller serialization is not sufficient.
    ///
    /// CRITICAL: hold this lock ONLY around field access. Snapshot the
    /// needed values under the lock, release, THEN call into `renderer.*`
    /// (the renderer has its own `sessionQueue`, some calls run `.sync`) or
    /// across any `await`. Never hold this lock across a renderer call or a
    /// suspension point — doing so risks deadlock against `sessionQueue`.
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Sidecar descriptors keyed by their server-assigned URL index.
    /// Populated once on playback start; read on demand when the user
    /// selects a sidecar track. Guarded by `lock`.
    private var sidecarDescriptors: [Int: SidecarSubtitleDescriptor] = [:]
    var hasRegisteredSidecars: Bool {
        withLock { !sidecarDescriptors.isEmpty }
    }

    /// Caller-supplied way to read the current playback position in
    /// seconds. Used for subtitle diagnostics and future seek-aware
    /// fetch paths.
    var currentPositionSecondsProvider: (() -> Double)?

    /// In-flight or completed sidecar content. Prevents re-fetching a
    /// track the user toggles on/off repeatedly. Cleared on teardown.
    /// Guarded by `lock`.
    private var sidecarCache: [Int: String] = [:]

    /// Active per-slot fetch Task so switching tracks cancels the
    /// previous fetch cleanly. Guarded by `lock`.
    private var fetchTasks: [SubtitleSlot: Task<Void, Never>] = [:]

    /// Slots currently driven by a live AI subtitle track (cues streamed
    /// in via `feedLiveCue`). A live track must NOT be flushed on seek —
    /// re-feeding past cues isn't possible once they've streamed by — so
    /// `flushOnSeek()` skips these slots. Cleared in `teardown()`.
    /// Guarded by `lock`.
    private var liveSlots: Set<SubtitleSlot> = []

    /// Current user styling parameters. Snapshot updated by PlayerCore
    /// when `applySubtitleStyling` is called. Guarded by `lock`.
    private var stylingParams: SubtitleStylingOverride.Parameters = .default

    /// Per-slot cue stores for bitmap subtitle tracks (PGS/DVD). Bitmap
    /// tracks bypass libass entirely: the extractor feeds ready CGImage
    /// cues into the slot's store and the backend's display-link pump
    /// composites the active set onto the overlay. Presence of a store
    /// marks the slot as bitmap-driven. Guarded by `lock`; the stores
    /// themselves carry their own lock, so they are safe to mutate after
    /// snapshotting the reference.
    private var bitmapCueStores: [SubtitleSlot: BitmapSubtitleCueStore] = [:]

    /// Fires on main when a slot's loading status changes.
    var onStatusChange: ((SubtitleSlot, SubtitleLoadStatus) -> Void)?

    /// Fires on main when sidecar tracks have been registered and the
    /// VM should extend `subtitleTracks` with the synthesised entries.
    var onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)?

    init(
        renderer: SubtitleRenderer = SubtitleRenderer(),
        fetcher: SidecarSubtitleFetcher = SidecarSubtitleFetcher()
    ) {
        self.renderer = renderer
        self.fetcher = fetcher
    }

    /// Handle on the underlying renderer — exposed so PlayerCore can
    /// drive display-link ticks and overlay views can read the current
    /// frame size bookkeeping.
    var underlyingRenderer: SubtitleRenderer { renderer }

    // MARK: - Configuration

    func applyStyling(_ params: SubtitleStylingOverride.Parameters) {
        withLock { stylingParams = params }
        renderer.applySettings(params)
    }

    var currentParams: SubtitleStylingOverride.Parameters {
        withLock { stylingParams }
    }

    // MARK: - Sidecar track registry

    /// Register sidecar tracks returned by the playback-start session.
    /// Fires `onSidecarTracksRegistered` on main so the VM can append
    /// synthesised `PlayerTrack` entries to `subtitleTracks`.
    func registerSidecarTracks(_ descriptors: [SidecarSubtitleDescriptor]) {
        withLock {
            sidecarDescriptors.removeAll()
            for d in descriptors {
                sidecarDescriptors[d.index] = d
            }
        }
        Self.logger.info(
            "[CMP-SUB] session registered sidecar descriptors=\(descriptors.count, privacy: .public) indices=\(descriptors.map { String($0.index) }.joined(separator: ","), privacy: .public)"
        )
        let snapshot = descriptors
        DispatchQueue.main.async { [weak self] in
            self?.onSidecarTracksRegistered?(snapshot)
        }
    }

    // MARK: - Track switching

    /// Open an embedded FFmpeg subtitle track in the given slot.
    /// `extradata`/`extradataSize` are from the `AVCodecContext` —
    /// they carry the ASS `[Script Info]` + `[V4+ Styles]` block
    /// (either authored, for native ASS, or FFmpeg-synthesized for
    /// SRT/WebVTT/MOVTEXT codecs).
    ///
    /// Called from `PlayerCore` on its control queue.
    func openEmbedded(
        slot: SubtitleSlot,
        isNativeASS: Bool,
        extradata: UnsafePointer<UInt8>?,
        extradataSize: Int
    ) {
        cancelFetchTask(for: slot)
        withLock {
            _ = liveSlots.remove(slot)
            bitmapCueStores.removeValue(forKey: slot)
        }
        if isNativeASS {
            renderer.createTrack(
                slot: slot,
                isNativeASS: true,
                extradata: extradata,
                extradataSize: extradataSize
            )
        } else {
            // FFmpeg synthesizes ASS headers for embedded SRT/WebVTT/MOVTEXT
            // with codec-specific PlayRes/font defaults. Feed the same
            // controlled header used by external text sidecars so appearance
            // does not change when switching subtitle source types.
            let params = withLock { stylingParams }
            let header = SubtitleStylingOverride.syntheticHeader(
                params: params,
                slot: slot
            )
            Data(header.utf8).withUnsafeBytes { raw in
                renderer.createTrack(
                    slot: slot,
                    isNativeASS: false,
                    extradata: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    extradataSize: raw.count
                )
            }
        }
        publishStatus(slot: slot, .ready)
    }

    /// Open a sidecar subtitle track (server URL) in the given slot.
    /// Starts an async fetch; when the content arrives it's fed to the
    /// renderer (converted from VTT/SRT to ASS if needed).
    ///
    /// All controlled sidecar text formats are installed into libass. ASS /
    /// SSA are passed through as authored documents; SRT, VTT, and MOV_TEXT
    /// are converted into a generated ASS document first.
    func openSidecar(urlIndex: Int, slot: SubtitleSlot) {
        guard let descriptor = withLock({ sidecarDescriptors[urlIndex] }) else {
            Self.logger.warning("openSidecar: no descriptor for index \(urlIndex)")
            publishStatus(slot: slot, .error("Subtitle track not found"))
            return
        }

        cancelFetchTask(for: slot)
        withLock {
            _ = liveSlots.remove(slot)
            bitmapCueStores.removeValue(forKey: slot)
        }
        publishStatus(slot: slot, .fetching)

        // The server/CDN subtitle endpoint can buffer text responses long
        // enough that URLSession.AsyncBytes never yields a first cue before
        // playback has moved on. Use the buffered path for now so SRT/VTT
        // sidecars reliably become renderable; true streaming can be restored
        // once the endpoint is proven to flush cue lines progressively.
        Self.logger.info(
            "[CMP-SUB] open sidecar index=\(urlIndex, privacy: .public) slot=\(slot.rawValue, privacy: .public) codec=\(descriptor.codec ?? "nil", privacy: .public) streaming=false"
        )

        openSidecarBuffered(urlIndex: urlIndex, descriptor: descriptor, slot: slot)
    }

    private func openSidecarBuffered(
        urlIndex: Int,
        descriptor: SidecarSubtitleDescriptor,
        slot: SubtitleSlot
    ) {
        // Fast path: cached.
        if let cached = withLock({ sidecarCache[urlIndex] }) {
            installSidecarContent(
                content: cached,
                codecHint: descriptor.codec,
                url: descriptor.url,
                slot: slot
            )
            return
        }

        let localFetcher = fetcher
        let task = Task { [weak self] in
            do {
                let result = try await localFetcher.fetch(
                    url: descriptor.url,
                    preferredFormatHint: Self.codecToFormat(descriptor.codec)
                )
                guard let self else { return }
                if Task.isCancelled { return }

                Self.logger.info(
                    "[CMP-SUB] fetched sidecar index=\(urlIndex, privacy: .public) slot=\(slot.rawValue, privacy: .public) format=\(String(describing: result.format), privacy: .public) chars=\(result.content.count, privacy: .public)"
                )
                self.withLock { self.sidecarCache[urlIndex] = result.content }
                self.installSidecarContent(
                    content: result.content,
                    codecHint: descriptor.codec,
                    url: descriptor.url,
                    slot: slot,
                    knownFormat: result.format
                )
            } catch {
                Self.logger.warning("sidecar fetch failed: \(String(describing: error), privacy: .public)")
                self?.publishStatus(slot: slot, .error("Couldn't load subtitle"))
            }
        }
        withLock { fetchTasks[slot] = task }
    }

    /// Close the given slot. Drops the libass track and cancels any
    /// in-flight fetch.
    func closeSlot(_ slot: SubtitleSlot) {
        cancelFetchTask(for: slot)
        withLock {
            _ = liveSlots.remove(slot)
            bitmapCueStores.removeValue(forKey: slot)
        }
        renderer.dropTrack(slot: slot)
        publishStatus(slot: slot, .idle)
    }

    /// Called on seek so libass clears cached events past the new
    /// position. Does not affect fetch state. Live AI slots are skipped:
    /// their cues are streamed once and can't be re-fed, so flushing them
    /// on seek would silently lose already-delivered captions.
    func flushOnSeek() {
        // Snapshot live-slot membership under the lock, then call the
        // renderer outside it (never hold `lock` across a renderer call).
        let (primaryIsLive, secondaryIsLive, bitmapStores) = withLock {
            (
                liveSlots.contains(.primary),
                liveSlots.contains(.secondary),
                Array(bitmapCueStores.values)
            )
        }
        if !primaryIsLive {
            renderer.flushTrack(slot: .primary)
        }
        if !secondaryIsLive {
            renderer.flushTrack(slot: .secondary)
        }
        // Bitmap stores always flush: the extractor restarts its decode
        // loop at the seek target and re-feeds whatever should be visible.
        for store in bitmapStores {
            store.clear()
        }
    }

    // MARK: - Bitmap subtitle tracks

    /// Whether any slot currently carries a bitmap subtitle track.
    var hasActiveBitmapTrack: Bool {
        withLock { !bitmapCueStores.isEmpty }
    }

    /// Open a bitmap subtitle track (PGS/DVD) in the given slot. Replaces
    /// any libass/live track occupying the slot; cue delivery then happens
    /// via `feedBitmapCues`.
    ///
    /// Called by `AVPlayerEmbeddedSubtitleExtractor` from its decode queue.
    /// `retentionSeconds`/`maxCueCount` size the cue store. The default
    /// (30 s / 128) suits the extractor, which decodes at the playhead so
    /// its newest cue is always near "now". The loopback demuxer tap feeds
    /// from the producer's read head — bounded ahead of the playhead by
    /// the produce-ahead byte gate but still tens of seconds — so it opens
    /// a wider window; otherwise the store prunes every cue between the
    /// playhead and the frontier before playback reaches it.
    func openBitmapTrack(
        slot: SubtitleSlot,
        retentionSeconds: Double = 30,
        maxCueCount: Int = 128
    ) {
        cancelFetchTask(for: slot)
        withLock {
            _ = liveSlots.remove(slot)
            bitmapCueStores[slot] = BitmapSubtitleCueStore(
                retentionSeconds: retentionSeconds,
                maxCueCount: maxCueCount
            )
        }
        renderer.dropTrack(slot: slot)
        Self.logger.info(
            "[CMP-SUB] opened bitmap track slot=\(slot.rawValue, privacy: .public) retention=\(retentionSeconds, privacy: .public) maxCues=\(maxCueCount, privacy: .public)"
        )
        publishStatus(slot: slot, .ready)
    }

    /// Deliver decoded cues for the slot's bitmap track. `trimActiveAt`
    /// carries PGS event semantics — every composition (including an empty
    /// clear event) supersedes whatever is on screen, so any still-active
    /// stored cue is trimmed to end at that timestamp. No-op when the slot
    /// isn't bitmap-driven (a stale decode loop racing a track switch).
    func feedBitmapCues(
        slot: SubtitleSlot,
        cues: [BitmapSubtitleCue],
        trimActiveAt: Double?
    ) {
        guard let store = withLock({ bitmapCueStores[slot] }) else { return }
        store.apply(cues: cues, trimActiveAt: trimActiveAt)
    }

    /// Bitmap cues visible at `seconds` across both slots, secondary
    /// first so a dual-subtitle setup composites the primary on top.
    func activeBitmapCues(at seconds: Double) -> [BitmapSubtitleCue] {
        let (secondary, primary) = withLock {
            (bitmapCueStores[.secondary], bitmapCueStores[.primary])
        }
        var active: [BitmapSubtitleCue] = []
        if let secondary {
            active.append(contentsOf: secondary.activeCues(at: seconds))
        }
        if let primary {
            active.append(contentsOf: primary.activeCues(at: seconds))
        }
        return active
    }

    // MARK: - Embedded event feed

    /// Called by `PlayerCore.decodeSubtitlePacket` for each decoded
    /// packet. `eventText` is the raw `rect.ass` string from FFmpeg
    /// (the Dialogue event content, not the whole `Dialogue:` line).
    func feedEmbedded(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        renderer.feedChunk(
            slot: slot,
            eventText: eventText,
            startMs: startMs,
            durationMs: durationMs
        )
    }

    /// Register an embedded font from an FFmpeg `AVMEDIA_TYPE_ATTACHMENT`
    /// stream. Called on file open.
    func registerEmbeddedFont(name: String, data: Data) {
        renderer.addEmbeddedFont(name: name, data: data)
    }

    // MARK: - Live AI subtitle track

    /// Open a synthetic, empty, user-styled libass track in the given slot
    /// to receive live AI subtitle cues. The track is created from the
    /// same synthetic ASS header (`[Script Info]` + `[V4+ Styles]` Default
    /// style + `[Events]`) that the controlled embedded/sidecar text path
    /// uses, so live cues inherit the user's subtitle styling and render
    /// identically. Cues are then appended one at a time via
    /// `feedLiveCue` (→ `ass_process_chunk`).
    ///
    /// This is the live counterpart of `openEmbedded(isNativeASS: false)`,
    /// minus an upstream decoder: nothing decodes packets, the controller
    /// feeds cues directly.
    ///
    /// - Parameters:
    ///   - slot: target slot. Live AI cues land in `.primary` in v1.
    ///   - label: optional human label (currently unused by the renderer;
    ///     accepted for parity with the embedded/sidecar open calls and to
    ///     keep the call sites self-documenting).
    ///   - language: optional ISO language tag (also informational).
    func openLive(slot: SubtitleSlot, label: String? = nil, language: String? = nil) {
        cancelFetchTask(for: slot)
        withLock { bitmapCueStores.removeValue(forKey: slot) }
        let params = withLock { stylingParams }
        let header = SubtitleStylingOverride.syntheticHeader(
            params: params,
            slot: slot
        )
        Data(header.utf8).withUnsafeBytes { raw in
            renderer.createTrack(
                slot: slot,
                isNativeASS: false,
                extradata: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                extradataSize: raw.count
            )
        }
        withLock { _ = liveSlots.insert(slot) }
        Self.logger.info(
            "[CMP-SUB] opened live AI track slot=\(slot.rawValue, privacy: .public) label=\(label ?? "nil", privacy: .public) lang=\(language ?? "nil", privacy: .public)"
        )
        publishStatus(slot: slot, .ready)
    }

    /// Append a single live AI cue to the live track in the given slot.
    /// `eventText` must be the `ass_process_chunk` event body produced by
    /// `LiveSubtitleTrack` (the FFmpeg `rect.ass` chunk format —
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`,
    /// with Start/End carried separately as `startMs`/`durationMs`).
    func feedLiveCue(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        guard withLock({ liveSlots.contains(slot) }) else { return }
        renderer.feedChunk(
            slot: slot,
            eventText: eventText,
            startMs: startMs,
            durationMs: durationMs
        )
    }

    /// Close the live track in the given slot. Drops the libass track and
    /// clears the live-slot flag. Safe to call on a slot that isn't live.
    func closeLive(slot: SubtitleSlot) {
        withLock { _ = liveSlots.remove(slot) }
        renderer.dropTrack(slot: slot)
        publishStatus(slot: slot, .idle)
    }

    /// Whether the given slot is currently a live AI track.
    func isLiveSlot(_ slot: SubtitleSlot) -> Bool {
        withLock { liveSlots.contains(slot) }
    }

    // MARK: - Lifecycle

    /// Stop all fetches, drop all tracks. Called by `PlayerCore.dispose`.
    func teardown() {
        // Snapshot + clear all guarded state under the lock, then cancel
        // the captured tasks and drop renderer tracks outside it.
        let tasks = withLock { () -> [Task<Void, Never>] in
            let snapshot = Array(fetchTasks.values)
            fetchTasks.removeAll()
            sidecarCache.removeAll()
            sidecarDescriptors.removeAll()
            liveSlots.removeAll()
            bitmapCueStores.removeAll()
            return snapshot
        }
        for task in tasks { task.cancel() }
        renderer.dropAllTracks()
    }

    // MARK: - Internals

    private func cancelFetchTask(for slot: SubtitleSlot) {
        let task = withLock { () -> Task<Void, Never>? in
            let existing = fetchTasks[slot]
            fetchTasks[slot] = nil
            return existing
        }
        task?.cancel()
    }

    private func publishStatus(slot: SubtitleSlot, _ status: SubtitleLoadStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(slot, status)
        }
    }

    private func installSidecarContent(
        content: String,
        codecHint: String?,
        url: URL,
        slot: SubtitleSlot,
        knownFormat: SubtitleFormat? = nil
    ) {
        let format = knownFormat ?? Self.codecToFormat(codecHint) ?? .vtt
        let isNativeASS = (format == .ass)

        let assDocument: String
        switch format {
        case .ass:
            assDocument = content
        case .vtt, .srt:
            let params = withLock { stylingParams }
            assDocument = VTTToASSConverter.convert(
                vtt: content,
                header: SubtitleStylingOverride.syntheticHeader(
                    params: params,
                    slot: slot
                )
            )
        }

        renderer.installFullASS(
            slot: slot,
            assDocument: assDocument,
            isNativeASS: isNativeASS
        )
        let stats = Self.dialogueStats(in: assDocument)
        let nowSeconds = currentPositionSecondsProvider?() ?? -1
        Self.logger.info(
            "[CMP-SUB] installed sidecar slot=\(slot.rawValue, privacy: .public) format=\(String(describing: format), privacy: .public) nativeASS=\(isNativeASS, privacy: .public) assChars=\(assDocument.count, privacy: .public) dialogueCount=\(stats.count, privacy: .public) first=\(stats.first ?? "nil", privacy: .public) last=\(stats.last ?? "nil", privacy: .public) now=\(nowSeconds, privacy: .public)"
        )
        publishStatus(slot: slot, .ready)
    }

    private static func dialogueStats(in assDocument: String) -> (count: Int, first: String?, last: String?) {
        var count = 0
        var first: String?
        var last: String?
        assDocument.enumerateLines { line, _ in
            guard line.hasPrefix("Dialogue:") else { return }
            count += 1
            let parts = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return }
            let range = "\(parts[1])-\(parts[2])"
            if first == nil { first = range }
            last = range
        }
        return (count, first, last)
    }

    /// Map a server-supplied codec hint (e.g. `"ass"`, `"subrip"`,
    /// `"webvtt"`) to the format the sidecar response is likely to be.
    /// Used as a fallback when the HTTP response doesn't carry a useful
    /// Content-Type, and as an initial expectation for the fetcher.
    static func codecToFormat(_ codec: String?) -> SubtitleFormat? {
        guard let c = codec?.lowercased() else { return nil }
        switch c {
        case "ass", "ssa":            return .ass
        case "subrip", "srt":         return .srt
        case "webvtt", "vtt", "mov_text", "movtext":
            return .vtt
        default:
            return nil
        }
    }
}
