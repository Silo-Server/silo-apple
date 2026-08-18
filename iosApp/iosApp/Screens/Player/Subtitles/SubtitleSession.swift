//
//  SubtitleSession.swift
//  Silo (iOS + tvOS)
//
//  Session-level coordinator for subtitle sources. Owns the mapping from
//  `PlayerTrack` selection (both embedded FFmpeg streams and server-
//  provided sidecar URLs) to the libass-backed `SubtitleRenderer`. Also
//  owns the sidecar fetch tasks and the in-session content cache.
//
//  Lives for the lifetime of one playback session. Held by
//  `AVPlayerBackend` via a strong reference; torn down on dispose.
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
    let isDefault: Bool?
    let isHearingImpaired: Bool?
    let fontBundleUrl: URL?
    /// Absolute URL (server URL already resolved against the relative
    /// path that came back from `/playback/start`).
    let url: URL

    init(
        index: Int,
        language: String?,
        codec: String?,
        label: String?,
        source: String?,
        forced: Bool?,
        isDefault: Bool? = nil,
        isHearingImpaired: Bool? = nil,
        fontBundleUrl: URL? = nil,
        url: URL
    ) {
        self.index = index
        self.language = language
        self.codec = codec
        self.label = label
        self.source = source
        self.forced = forced
        self.isDefault = isDefault
        self.isHearingImpaired = isHearingImpaired
        self.fontBundleUrl = fontBundleUrl
        self.url = url
    }
}

final class SubtitleSession {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "SubtitleSession"
    )

    private let renderer: SubtitleRenderer
    private let fetcher: SidecarSubtitleFetcher

    private struct InstalledConvertedSidecar {
        let urlIndex: Int
        let format: SubtitleFormat
        /// Whether the track has Arabic cues at all. Only these need
        /// regenerating on a font-family change: a Latin-only track tracks
        /// the new family through the live `FONT_NAME` override, while an
        /// Arabic track may need a fallback style the old family didn't.
        let containsArabicCues: Bool
        /// Value of `installedSidecarGeneration` when this entry was
        /// written. A reinstall that reconverted outside the lock must
        /// re-check it before installing (see `installSidecarContent`).
        let generation: UInt64
    }

    /// Guards the lock-free mutable session state (`sidecarDescriptors`,
    /// `sidecarCache`, `fetchTasks`, `installedConvertedSidecars`,
    /// `liveSlots`, `stylingParams`). Mirrors the `handleLock` idiom in
    /// `SubtitleRenderer`.
    ///
    /// Callers reach this session from different queues — the backend's
    /// live methods from main while `AVPlayerEmbeddedSubtitleExtractor`
    /// mutates the same fields from a global queue — so caller
    /// serialization is not sufficient.
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

    /// Bump the slot's generation and return the new value. Call for every
    /// change to what occupies the slot, clears included, so an in-flight
    /// reinstall can detect that its target is gone. Caller holds `lock`.
    @discardableResult
    private func bumpInstalledGenerationLocked(_ slot: SubtitleSlot) -> UInt64 {
        let next = (installedSidecarGeneration[slot] ?? 0) &+ 1
        installedSidecarGeneration[slot] = next
        return next
    }

    /// Forget the converted sidecar occupying the slot. Caller holds `lock`.
    private func clearInstalledSidecarLocked(_ slot: SubtitleSlot) {
        installedConvertedSidecars.removeValue(forKey: slot)
        bumpInstalledGenerationLocked(slot)
    }

    /// Forget everything occupying the slot — live flag, bitmap cue store
    /// and converted sidecar. Caller holds `lock`.
    private func clearSlotOccupancyLocked(_ slot: SubtitleSlot) {
        _ = liveSlots.remove(slot)
        bitmapCueStores.removeValue(forKey: slot)
        clearInstalledSidecarLocked(slot)
    }

    /// Sidecar descriptors keyed by their server-assigned URL index.
    /// Populated once on playback start; read on demand when the user
    /// selects a sidecar track. Guarded by `lock`.
    private var sidecarDescriptors: [Int: SidecarSubtitleDescriptor] = [:]

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

    /// Converted sidecar currently installed in each libass slot. This is
    /// enough to regenerate its synthetic styles from `sidecarCache` when
    /// the user changes font family without refetching the track.
    /// Guarded by `lock`.
    private var installedConvertedSidecars: [SubtitleSlot: InstalledConvertedSidecar] = [:]

    /// Monotonic per-slot counter, bumped on every mutation of the slot's
    /// installed-track state — installs and clears alike. Guarded by `lock`.
    private var installedSidecarGeneration: [SubtitleSlot: UInt64] = [:]

    /// Slots currently driven by a live AI subtitle track (cues streamed
    /// in via `feedLiveCue`). A live track must NOT be flushed on seek —
    /// re-feeding past cues isn't possible once they've streamed by — so
    /// `flushOnSeek()` skips these slots. Cleared in `teardown()`.
    /// Guarded by `lock`.
    private var liveSlots: Set<SubtitleSlot> = []

    /// Current user styling parameters. Snapshot updated by the backend
    /// when `applySubtitleStyling` is called. Guarded by `lock`.
    private var stylingParams: SubtitleStylingOverride.Parameters = .default

    /// Monotonic counter bumped on every `stylingParams` change. A
    /// conversion runs off a snapshot taken outside `lock`, so the install
    /// gate re-checks this to reject a document generated from styling the
    /// user has since replaced. Guarded by `lock`.
    private var stylingGeneration: UInt64 = 0

    /// Serial queue for font-change reinstalls. Reconverting a
    /// feature-length sidecar is O(cues) and must not run on the settings
    /// caller's queue. Serial rather than concurrent so a rapid sequence of
    /// font changes across both slots can't fan out into simultaneous
    /// whole-file conversions; slot independence makes the ordering
    /// immaterial either way.
    private let reinstallQueue = DispatchQueue(
        label: "org.siloserver.silo.subtitle-session.reinstall",
        qos: .userInitiated
    )

    /// Per-slot cue stores for bitmap subtitle tracks (PGS/DVD). Bitmap
    /// tracks bypass libass entirely: the extractor feeds ready CGImage
    /// cues into the slot's store and the backend's display-link pump
    /// composites the active set onto the overlay. Presence of a store
    /// marks the slot as bitmap-driven. Guarded by `lock`; the stores
    /// themselves carry their own lock, so they are safe to mutate after
    /// snapshotting the reference.
    private var bitmapCueStores: [SubtitleSlot: BitmapSubtitleCueStore] = [:]

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

    /// Handle on the underlying renderer — exposed so the backend can
    /// drive display-link ticks and overlay views can read the current
    /// frame size bookkeeping.
    var underlyingRenderer: SubtitleRenderer { renderer }

    // MARK: - Configuration

    func applyStyling(_ params: SubtitleStylingOverride.Parameters) {
        let reinstallations: [(
            slot: SubtitleSlot,
            sidecar: InstalledConvertedSidecar,
            content: String
        )] = withLock {
            let fontFamilyChanged = stylingParams.fontFamilyName != params.fontFamilyName
            if stylingParams != params {
                stylingParams = params
                stylingGeneration &+= 1
            }
            guard fontFamilyChanged else { return [] }
            return installedConvertedSidecars.compactMap { slot, sidecar in
                // Latin-only tracks track the new family through the live
                // FONT_NAME override. A track with Arabic cues always needs
                // reconversion: the new family may need a fallback style the
                // old one didn't (or vice versa), and the override would
                // otherwise flatten Arabic onto a non-covering family.
                guard sidecar.containsArabicCues,
                      let content = sidecarCache[sidecar.urlIndex] else { return nil }
                return (slot, sidecar, content)
            }
        }
        renderer.applySettings(params)
        // Reconversion is unbounded work on the caller's queue (player
        // settings / UI), so it lands on `reinstallQueue`. Arriving late is
        // safe: the install gate rejects the document if the slot's
        // generation moved (track switched or closed) or if the styling
        // generation moved (a newer conversion supersedes this one).
        for reinstallation in reinstallations {
            reinstallQueue.async { [weak self] in
                self?.installSidecarContent(
                    content: reinstallation.content,
                    codecHint: nil,
                    urlIndex: reinstallation.sidecar.urlIndex,
                    slot: reinstallation.slot,
                    knownFormat: reinstallation.sidecar.format,
                    requiredGeneration: reinstallation.sidecar.generation
                )
            }
        }
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
    /// Called from the embedded-subtitle extractor on its own queue.
    func openEmbedded(
        slot: SubtitleSlot,
        isNativeASS: Bool,
        extradata: UnsafePointer<UInt8>?,
        extradataSize: Int
    ) {
        cancelFetchTask(for: slot)
        withLock { clearSlotOccupancyLocked(slot) }
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
            openSyntheticStyledTrack(slot: slot)
        }
    }

    /// Create a non-native libass track in the slot from Silo's controlled
    /// synthetic ASS header. The styling snapshot is taken under `lock`,
    /// which is released before the renderer call.
    private func openSyntheticStyledTrack(slot: SubtitleSlot) {
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
            return
        }

        cancelFetchTask(for: slot)
        withLock { clearSlotOccupancyLocked(slot) }

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
        let cached = withLock { sidecarCache[urlIndex] }
        let localFetcher = fetcher
        let task = Task { [weak self] in
            do {
                async let fontAttachments = Self.fetchFontAttachments(
                    for: descriptor,
                    with: localFetcher
                )
                let result: (content: String, format: SubtitleFormat?)
                if let cached {
                    result = (cached, nil)
                } else {
                    let fetched = try await localFetcher.fetch(
                        url: descriptor.url,
                        preferredFormatHint: Self.codecToFormat(descriptor.codec)
                    )
                    result = (fetched.content, fetched.format)
                }
                guard let self else { return }
                if Task.isCancelled { return }

                for attachment in await fontAttachments {
                    self.registerEmbeddedFont(name: attachment.name, data: attachment.data)
                }

                Self.logger.info(
                    "[CMP-SUB] fetched sidecar index=\(urlIndex, privacy: .public) slot=\(slot.rawValue, privacy: .public) format=\(String(describing: result.format), privacy: .public) chars=\(result.content.count, privacy: .public)"
                )
                self.withLock { self.sidecarCache[urlIndex] = result.content }
                self.installSidecarContent(
                    content: result.content,
                    codecHint: descriptor.codec,
                    urlIndex: urlIndex,
                    slot: slot,
                    knownFormat: result.format
                )
            } catch {
                Self.logger.warning("sidecar fetch failed: \(String(describing: error), privacy: .public)")
            }
        }
        withLock { fetchTasks[slot] = task }
    }

    private static func fetchFontAttachments(
        for descriptor: SidecarSubtitleDescriptor,
        with fetcher: SidecarSubtitleFetcher
    ) async -> [SubtitleFontAttachment] {
        guard let url = descriptor.fontBundleUrl else { return [] }
        do {
            return try await fetcher.fetchFontBundle(url: url)
        } catch {
            logger.warning(
                "sidecar font bundle fetch failed: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Close the given slot. Drops the libass track and cancels any
    /// in-flight fetch.
    func closeSlot(_ slot: SubtitleSlot) {
        cancelFetchTask(for: slot)
        withLock { clearSlotOccupancyLocked(slot) }
        renderer.dropTrack(slot: slot)
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
            clearSlotOccupancyLocked(slot)
            bitmapCueStores[slot] = BitmapSubtitleCueStore(
                retentionSeconds: retentionSeconds,
                maxCueCount: maxCueCount
            )
        }
        renderer.dropTrack(slot: slot)
        Self.logger.info(
            "[CMP-SUB] opened bitmap track slot=\(slot.rawValue, privacy: .public) retention=\(retentionSeconds, privacy: .public) maxCues=\(maxCueCount, privacy: .public)"
        )
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

    /// Called by the embedded-subtitle extractor for each decoded
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
        withLock {
            bitmapCueStores.removeValue(forKey: slot)
            clearInstalledSidecarLocked(slot)
        }
        openSyntheticStyledTrack(slot: slot)
        withLock { _ = liveSlots.insert(slot) }
        Self.logger.info(
            "[CMP-SUB] opened live AI track slot=\(slot.rawValue, privacy: .public) label=\(label ?? "nil", privacy: .public) lang=\(language ?? "nil", privacy: .public)"
        )
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
        withLock {
            _ = liveSlots.remove(slot)
            clearInstalledSidecarLocked(slot)
        }
        renderer.dropTrack(slot: slot)
    }

    // MARK: - Lifecycle

    /// Stop all fetches, drop all tracks. Called on backend dispose.
    func teardown() {
        // Snapshot + clear all guarded state under the lock, then cancel
        // the captured tasks and drop renderer tracks outside it.
        let tasks = withLock { () -> [Task<Void, Never>] in
            let snapshot = Array(fetchTasks.values)
            fetchTasks.removeAll()
            sidecarCache.removeAll()
            sidecarDescriptors.removeAll()
            for slot in SubtitleSlot.allCases { clearInstalledSidecarLocked(slot) }
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

    /// Convert (if needed) and install sidecar content into a slot.
    ///
    /// - Parameter requiredGeneration: set by the font-change reinstall
    ///   path, which reconverts outside the lock. The install is abandoned
    ///   unless the slot still holds the same installed entry it did when
    ///   the reinstall was planned — otherwise a concurrent
    ///   `closeSlot`/`openSidecar`/`openLive`/`openBitmapTrack`/
    ///   `openEmbedded` would be undone by a late install.
    private func installSidecarContent(
        content: String,
        codecHint: String?,
        urlIndex: Int,
        slot: SubtitleSlot,
        knownFormat: SubtitleFormat? = nil,
        requiredGeneration: UInt64? = nil
    ) {
        enum InstallOutcome {
            case installed
            /// The slot no longer holds the entry this install targeted.
            case abandoned
            /// Styling changed under the conversion; convert again.
            case restyled
        }

        let format = knownFormat ?? Self.codecToFormat(codecHint) ?? .vtt
        let isNativeASS = (format == .ass)

        // Conversion bakes the styling snapshot into the document's header
        // and style selection, and it runs outside `lock`. A font change
        // landing in that window would otherwise install a document carrying
        // the old families — permanently, since this is a fresh install with
        // no reinstall scheduled for it, and the live FONT_NAME override is
        // suppressed while `preservesScriptSpecificFonts` is set. Reconvert
        // instead. Terminates because each retry requires the user to have
        // changed styling again, and those changes are human-paced.
        while true {
            // Cheap pre-gate: a reinstall whose target entry is already gone
            // has nothing to install, so skip the O(cues) conversion below.
            // This does not replace the identical check inside the install
            // block — that one is the authoritative one, because the slot can
            // still be closed or reinstalled while the conversion runs outside
            // `lock`. This only avoids paying for work that is already known
            // to be wasted, which is the common case when styling changes
            // arrive faster than conversions finish.
            if let requiredGeneration {
                let stillCurrent = withLock {
                    installedSidecarGeneration[slot] == requiredGeneration
                        && installedConvertedSidecars[slot] != nil
                }
                if !stillCurrent { return }
            }

            let assDocument: String
            let preservesScriptSpecificFonts: Bool
            let containsArabicCues: Bool
            /// nil for authored ASS: it is passed through unmodified, so no
            /// styling snapshot is embedded in it.
            let conversionStylingGeneration: UInt64?
            switch format {
            case .ass:
                assDocument = content
                preservesScriptSpecificFonts = false
                containsArabicCues = false
                conversionStylingGeneration = nil
            case .vtt, .srt:
                let (params, generation) = withLock { (stylingParams, stylingGeneration) }
                let hasArabicFallbackStyle = SubtitleStylingOverride
                    .arabicFallbackFontName(params: params) != nil
                let conversion = VTTToASSConverter.convert(
                    vtt: content,
                    header: SubtitleStylingOverride.syntheticHeader(
                        params: params,
                        slot: slot
                    ),
                    hasArabicFallbackStyle: hasArabicFallbackStyle
                )
                assDocument = conversion.assDocument
                preservesScriptSpecificFonts = conversion.usedArabicFallbackStyle
                containsArabicCues = conversion.containsArabicCues
                conversionStylingGeneration = generation
            }

            // Bookkeeping, staleness checks, and the install must be atomic
            // with respect to slot changes: releasing the lock first would let
            // a concurrent close/open slip between them and be resurrected by
            // this install. Safe to hold `lock` here specifically because
            // `installFullASS` only enqueues onto the renderer's serial
            // `sessionQueue` and never calls back into the session — unlike the
            // `.sync` renderer calls the lock's contract warns about. Ordering
            // then follows from that queue: any later user action enqueues its
            // renderer work after ours.
            let outcome = withLock { () -> InstallOutcome in
                if let requiredGeneration,
                   installedSidecarGeneration[slot] != requiredGeneration
                    || installedConvertedSidecars[slot] == nil {
                    return .abandoned
                }
                if let conversionStylingGeneration,
                   conversionStylingGeneration != stylingGeneration {
                    return .restyled
                }

                if isNativeASS {
                    clearInstalledSidecarLocked(slot)
                } else {
                    installedConvertedSidecars[slot] = InstalledConvertedSidecar(
                        urlIndex: urlIndex,
                        format: format,
                        containsArabicCues: containsArabicCues,
                        generation: bumpInstalledGenerationLocked(slot)
                    )
                }

                renderer.installFullASS(
                    slot: slot,
                    assDocument: assDocument,
                    isNativeASS: isNativeASS,
                    preservesScriptSpecificFonts: preservesScriptSpecificFonts
                )
                return .installed
            }
            switch outcome {
            case .abandoned:
                return
            case .restyled:
                // The slot generation is untouched by a rejected install, so
                // `requiredGeneration` stays valid for the next pass.
                continue
            case .installed:
                break
            }

            let stats = Self.dialogueStats(in: assDocument)
            let nowSeconds = currentPositionSecondsProvider?() ?? -1
            Self.logger.info(
                "[CMP-SUB] installed sidecar slot=\(slot.rawValue, privacy: .public) format=\(String(describing: format), privacy: .public) nativeASS=\(isNativeASS, privacy: .public) assChars=\(assDocument.count, privacy: .public) dialogueCount=\(stats.count, privacy: .public) first=\(stats.first ?? "nil", privacy: .public) last=\(stats.last ?? "nil", privacy: .public) now=\(nowSeconds, privacy: .public)"
            )
            return
        }
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
