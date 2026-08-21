import Foundation

/// The local HLS pipeline behind one `.siloLoopback` session: the segment
/// store, the loopback HTTP server, the producing writer (plus its
/// demand-driven restarts) and the session directory they share.
///
/// This host owns that lifecycle glue and nothing else. `AVPlayerBackend`
/// keeps items and observers, the display-criteria write → settle → attach
/// ordering, the initial-video-display gate, audio session, PiP/AirPlay
/// policy, seek deadlines, every recovery ladder, and the subtitle plane —
/// the cue tap this host hands the writer belongs to the backend because its
/// cue store is keyed to the SOURCE and deliberately outlives a session.
///
/// Isolation matches the adapter's: the class is not actor isolated,
/// `requestProducerRestart` is `@MainActor`, and the writer's mux thread and
/// the server's resolver queue hop to main inside this host, so a callback
/// never crosses an isolation boundary the backend did not already expect.
///
/// Identity runs on two levels. The host's own is the object: the backend
/// owns exactly one live host and re-checks `loopbackHost === host` in each
/// closure it installs, and `teardown()` latches `isTornDown` and nils every
/// closure. Inside the host it is the producer generation `adoptProducer`
/// mints: a restart stops the retiring writer by flag without joining its mux
/// thread, so only the tag each callback carries can tell that writer's late
/// events from the successor's.
final class LocalHLSHost {
    /// A VOD plan together with the source it was resolved for.
    ///
    /// Source-keyed, not session-keyed: `loopbackVODPlan` /
    /// `loopbackVODPlanSourceURL` deliberately survived
    /// `teardownMediaPipeline` so a reanchor (which tears the session down)
    /// hands its writer the same segment grid instead of re-harvesting one —
    /// `LoopbackSegmentWriter.vodPlanProvidedAtInit` takes a materially
    /// different startup path. The backend carries this value from a retiring
    /// host into the next one.
    struct ResolvedVODPlan {
        let plan: LoopbackSegmentPlan
        let sourceURL: URL

        /// The plan when it belongs to `sourceURL`, nil otherwise — the
        /// `vodPlanForCurrentSource` guard.
        func matching(_ sourceURL: URL) -> LoopbackSegmentPlan? {
            self.sourceURL == sourceURL ? plan : nil
        }
    }

    private static let vodSegmentMissWaitSeconds: Double = 8.0
    /// How far past a running producer's base a fetch counts as "covered" —
    /// the producer's forward march will deliver it without a restart.
    private static let vodProducerCoverageWindow = 8
    /// How far past the produced head a fetch may ride the running
    /// producer's march. One segment for the natural next-in-line fetch,
    /// plus one for AVPlayer's concurrent lookahead.
    private static let vodProducerMarchAllowance = 2

    /// Monotonic tag handed to `LoopbackSegmentStore(generation:)`. The store
    /// only prints it and reports it in its stats; nothing keys behaviour off
    /// it.
    private static var nextStoreGeneration: UInt64 = 0

    /// `SILO_KEEP_DV_HLS` as the environment has it. Read once per host, at
    /// creation — nothing mutates the environment.
    static var keepArtifactsFromEnvironment: Bool {
        let raw = ProcessInfo.processInfo.environment["SILO_KEEP_DV_HLS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    // MARK: - Session configuration

    let sessionSpec: LoopbackSessionSpec
    let sessionDirectory: URL
    let keepArtifacts: Bool
    private let storeMemoryBudgetBytes: Int
    private let storeSpillPolicy: LoopbackSegmentStore.SpillPolicy
    private let vodRetentionBudgetBytes: Int64
    private let serverExposure: LoopbackSegmentServer.Exposure

    // MARK: - Pulled from the backend by the writer/server

    /// AVPlayer's current local playlist time, supplied by the adapter.
    /// Nothing in the producer reads it: the writer paces on the store's
    /// consumer window instead.
    private let playbackPositionProvider: () -> Double?
    private let isSourceOutageActive: () -> Bool
    /// The backend's source-keyed subtitle cue tap. Handed to every producer,
    /// including restarts, so a restarted writer keeps filling the same store.
    private let subtitleTap: (URL) -> LoopbackSubtitleTap?
    /// AVPlayer's external-playback state, for the first-segment URL choice.
    var isExternalPlaybackActive: (() -> Bool)?
    /// The backend's first-segment gate: not disposed and no item attached yet.
    var canAttachFirstSegment: (() -> Bool)?
    /// Whether the HDR10+ badge has already flipped: the per-packet SEI scan
    /// is installed only while it has not.
    var hasDetectedHDR10Plus: (() -> Bool)?

    // MARK: - Pushed to the backend

    /// The first segment is served and the playlist URL is chosen. Everything
    /// after this — display criteria, the settle wait, the item attach — is
    /// the backend's.
    var onFirstSegmentReady: (((url: URL, playlistName: String, usesExternalURL: Bool)) -> Void)?
    /// The producer resolved the segment plan (main queue).
    var onSegmentPlanResolved: ((LoopbackSegmentPlan) -> Void)?
    /// Source read rate and total bytes read (main queue).
    var onSourceDownloadStats: ((Double?, Int64?) -> Void)?
    /// Generated-HLS facts after every playlist publish (main queue).
    var onGeneratedMediaStats: ((LoopbackSegmentWriter.GeneratedMediaStats) -> Void)?
    /// Session-axis second the bridged-audio encoder anchored at (main queue).
    var onBridgedAudioAnchored: ((Double) -> Void)?
    /// HDR10+ dynamic metadata seen in the video bitstream (main queue).
    var onHDR10PlusMetadataDetected: (() -> Void)?
    /// Bitmap subtitle streams the writer can serve (main queue).
    var onBitmapSubtitleTapTracks: (([Int]) -> Void)?
    /// Decoded bitmap cues. Fired on the writer's mux thread, exactly as the
    /// writer fires it.
    var onBitmapSubtitleTapCue: ((Int, [BitmapSubtitleCue], Double?) -> Void)?
    /// The producer reached EOF or failed (main queue).
    var onFinished: ((Error?) -> Void)?
    /// No LAN address for an engaged AirPlay receiver.
    var onExternalPlaybackHandoffAbandoned: (() -> Void)?
    /// Server bind failure or an unusable playlist URL.
    var onFailure: ((PlaybackFailure) -> Void)?

    // MARK: - Pipeline

    private var segmentWriter: LoopbackSegmentWriter?
    private var segmentServer: LoopbackSegmentServer?
    private var segmentStore: LoopbackSegmentStore?
    /// The plan resolved for this source, seeded from the retired session's
    /// and republished whenever a producer resolves one.
    private(set) var resolvedVODPlan: ResolvedVODPlan?
    /// The raw resolved plan, matching the backend's former `loopbackVODPlan`
    /// (no source check — `vodPlanForCurrentSource` is the checked reader).
    var vodPlan: LoopbackSegmentPlan? { resolvedVODPlan?.plan }
    private(set) var restartCoalescer: LoopbackRestartCoalescer
    private(set) var activeVODWriterBaseIndex: Int?
    /// Highest segment index the running producer has actually finalized.
    /// Coverage decisions ride the march only when the target is within
    /// `vodProducerMarchAllowance` of THIS, not of the static base — with
    /// 30–70 MB long-GOP segments the march moves at 3–6 s per segment, and
    /// "within 8 of base" left a seek's fetch waiting out the full miss
    /// deadline into a 404 (living-room frozen-video seeks).
    private(set) var activeVODWriterHeadIndex: Int?
    /// The spec the running (or next) producer is built from: the session's
    /// spec for the first one, `reanchored(at:)` for every restart. It mirrors
    /// the backend's `currentSourceStrategy` spec, which cannot change while a
    /// host lives — a strategy change goes through `load` → teardown → a new
    /// host.
    private var writerSpec: LoopbackSessionSpec
    /// The bitmap subtitle stream the producer decodes for the backend's tap,
    /// or nil for none. Owned here so the running writer and every writer a
    /// restart builds after it carry the same selection.
    private(set) var selectedBitmapSubtitleStream: Int?
    private(set) var isTornDown = false
    /// Producer identity. Every writer `adoptProducer` takes on is tagged
    /// with the value this counter holds after its start, and a writer
    /// callback acts only while its tag is still current. Bumped for every
    /// producer AND once more at teardown, so a retiring writer — stopped by
    /// flag, never joined — matches nothing.
    ///
    /// Lock-held because writer callbacks arrive on the mux thread as well as
    /// on main: `onVODProducerAnchored` re-seeds the store synchronously,
    /// before its hop, and the bitmap cue tap never hops at all.
    private let producerGenerationLock = NSLock()
    private var producerGeneration: UInt64 = 0

    init(
        sessionSpec: LoopbackSessionSpec,
        sessionDirectory: URL,
        keepArtifacts: Bool,
        storeMemoryBudgetBytes: Int,
        storeSpillPolicy: LoopbackSegmentStore.SpillPolicy,
        vodRetentionBudgetBytes: Int64,
        serverExposure: LoopbackSegmentServer.Exposure,
        carriedVODPlan: ResolvedVODPlan?,
        restartCoalescer: LoopbackRestartCoalescer = LoopbackRestartCoalescer(),
        playbackPositionProvider: @escaping () -> Double?,
        isSourceOutageActive: @escaping () -> Bool,
        subtitleTap: @escaping (URL) -> LoopbackSubtitleTap?
    ) {
        self.sessionSpec = sessionSpec
        self.writerSpec = sessionSpec
        self.sessionDirectory = sessionDirectory
        self.keepArtifacts = keepArtifacts
        self.storeMemoryBudgetBytes = storeMemoryBudgetBytes
        self.storeSpillPolicy = storeSpillPolicy
        self.vodRetentionBudgetBytes = vodRetentionBudgetBytes
        self.serverExposure = serverExposure
        self.resolvedVODPlan = carriedVODPlan
        self.restartCoalescer = restartCoalescer
        self.playbackPositionProvider = playbackPositionProvider
        self.isSourceOutageActive = isSourceOutageActive
        self.subtitleTap = subtitleTap
    }

    // MARK: - Start

    /// Builds the store and the server, then starts the first producer behind
    /// the server's bind. Main-thread only, and not actor isolated — exactly
    /// like the `startSiloLoopback` it came from, which `load(strategy:)`
    /// calls synchronously.
    func start() {
        Self.nextStoreGeneration &+= 1
        let generation = Self.nextStoreGeneration
        let sessionDir = sessionDirectory

        let debugDirectory = keepArtifacts ? sessionDir : nil
        cmpLog("[CMP-HLS-STORE] vod retention budgetBytes=\(vodRetentionBudgetBytes)")
        let store = LoopbackSegmentStore(
            generation: generation,
            memoryBudgetBytes: storeMemoryBudgetBytes,
            spillPolicy: storeSpillPolicy,
            vodRetentionBudgetBytes: vodRetentionBudgetBytes,
            debugDirectory: debugDirectory
        )
        segmentStore = store
        if keepArtifacts {
            cmpLog("[CMP-AVP] preserving local DV artifacts due to SILO_KEEP_DV_HLS=1 dir=\(sessionDir.path)")
        }

        let server = LoopbackSegmentServer(segmentStore: store, exposure: serverExposure)
        // A miss under the static VOD playlist means "not produced (yet) or
        // pruned": request a coalesced producer restart on main, then wait —
        // bounded — for the bytes. Runs on the server's resolver queue; the
        // store is thread-safe.
        server.vodSegmentMissResolver = { [weak self, weak store] index in
            guard let store else { return .missing }
            Task { @MainActor [weak self] in
                self?.requestProducerRestart(atSegmentIndex: index)
            }
            return store.waitForSegment(
                named: LoopbackSegmentStore.segmentName(index),
                deadline: Date().addingTimeInterval(Self.vodSegmentMissWaitSeconds)
            )
        }
        // Stash the server immediately so a synchronous teardown (e.g. fast
        // user dismiss) can find and cancel the still-binding listener.
        segmentServer = server

        // Server bind goes through `withCheckedThrowingContinuation` rather
        // than blocking the main actor on a 2 s semaphore. Defer writer setup
        // until bind completes; if the user disposes the backend or switches
        // sessions in the meantime, bail before touching state.
        Task { @MainActor [weak self] in
            do {
                try await server.start()
            } catch {
                guard let self else { return }
                // The server's catch arm already cancelled the listener; null
                // out our reference so callers don't trip on a cancelled
                // server still hanging off `segmentServer`.
                if self.segmentServer === server {
                    self.segmentServer = nil
                }
                guard !self.isTornDown else { return }
                self.onFailure?(
                    .loopbackServerBindFailed(detail: String(describing: error))
                )
                return
            }
            guard let self, !self.isTornDown else {
                server.stop()
                return
            }
            self.startWriter()
        }
    }

    // MARK: - Producer

    @MainActor
    private func startWriter(vodBaseIndex: Int = 0, recycledInput: LoopbackInputHandoff? = nil) {
        guard let segmentStore else { return }
        let spec = writerSpec
        let writer = LoopbackSegmentWriter(
            sessionSpec: spec,
            outputDirectory: sessionDirectory,
            segmentStore: segmentStore,
            vodPlan: vodPlanForCurrentSource(spec: spec),
            vodBaseIndex: vodBaseIndex,
            recycledInputHandoff: recycledInput
        )
        adoptProducer(writer, spec: spec, vodBaseIndex: vodBaseIndex)
        writer.start()
    }

    /// Makes `writer` the producer this host listens to, and installs its
    /// callbacks.
    ///
    /// Producer identity is minted here and nowhere else: every callback
    /// below carries the generation this call opens and acts only while that
    /// generation is still current. It has to. `requestProducerRestart` stops
    /// the retiring writer by flag and does not join its mux thread, so that
    /// thread keeps emitting for a while — untagged, its events would drag
    /// the store's consumer window back to the retired base, overwrite the
    /// successor's coverage bookkeeping or plan, and fail the successor's
    /// session with the error its own cancellation produced. The tag is the
    /// single owner of that decision; there is no second latch.
    ///
    /// Kept apart from the writer's construction so the tests can drive the
    /// callbacks with writers they never start.
    @MainActor
    func adoptProducer(
        _ writer: LoopbackSegmentWriter,
        spec: LoopbackSessionSpec,
        vodBaseIndex: Int
    ) {
        let generation = beginProducerGeneration()
        let store = segmentStore
        let tap = subtitleTap(spec.sourceURL)
        writer.isSourceOutageActive = isSourceOutageActive
        // The text tap is source-keyed and deliberately outlives a producer:
        // it dedups the region a restart re-reads, so a draining writer's
        // cues are cues this source's store already wants. No tag needed.
        writer.onSubtitleTapTracks = { [weak tap] infos in
            tap?.registerTracks(infos)
        }
        writer.onSubtitleTapCue = { [weak tap] cue in
            tap?.ingest(cue)
        }
        writer.onBitmapSubtitleTapTracks = { [weak self] indices in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.onBitmapSubtitleTapTracks?(indices)
            }
        }
        // Mux thread; the writer only decodes (and therefore only emits)
        // while a stream is selected, and SubtitleSession serialises feeds
        // on its own queue — same pattern as the extractor's decode thread.
        // Tagged on that thread: bitmap cues carry a positional trim, so a
        // retired producer's would rewrite the plane under the successor.
        writer.onBitmapSubtitleTapCue = { [weak self] streamIndex, cues, trimActiveAt in
            guard let self, self.isCurrentProducer(generation) else { return }
            self.onBitmapSubtitleTapCue?(streamIndex, cues, trimActiveAt)
        }
        // Selection survives producer restarts: every new writer inherits it.
        writer.setBitmapSubtitleTapStream(selectedBitmapSubtitleStream)
        activeVODWriterBaseIndex = vodBaseIndex
        activeVODWriterHeadIndex = vodBaseIndex - 1
        // Seed the consumer window at the producer's base so a resumed
        // or restarted session isn't parked by backpressure before the
        // player's first fetch declares a real target.
        store?.declareVODTarget(vodBaseIndex)
        // A resume-first session anchors itself once the plan resolves;
        // re-seed from the writer's TRUE base or the producer parks
        // against a window still sitting at 0 while AVPlayer's resume
        // fetches strand (the living-room resume startup timeout). The seed
        // is synchronous on the mux thread, so the tag is checked there too.
        writer.onVODProducerAnchored = { [weak self, weak store] base in
            guard let self, self.isCurrentProducer(generation) else { return }
            store?.declareVODTarget(base)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.activeVODWriterBaseIndex = base
                self.activeVODWriterHeadIndex = base - 1
            }
        }
        // Produced-head tracking for the restart coverage decision:
        // a fetch may only ride the running march when it's within
        // vodProducerMarchAllowance of what has actually been written.
        writer.onSegmentAppended = { [weak self] segmentIndex, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.activeVODWriterHeadIndex = max(
                    self.activeVODWriterHeadIndex ?? segmentIndex,
                    segmentIndex
                )
            }
        }
        writer.onSegmentPlanResolved = { [weak self] plan in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.resolvedVODPlan = ResolvedVODPlan(
                    plan: plan,
                    sourceURL: spec.sourceURL
                )
                self.segmentServer?.setVODSegmentCount(plan.segmentCount)
                // The item timeline's origin is the plan anchor; the initial
                // media-time seek (pendingStartTime) converts through this
                // offset, and plan resolution always precedes item creation.
                self.onSegmentPlanResolved?(plan)
            }
        }
        writer.onFirstSegmentReady = { [weak self] playlistName in
            DispatchQueue.main.async {
                guard let self, self.isCurrentProducer(generation) else { return }
                self.handleFirstSegmentReady(playlistName: playlistName)
            }
        }
        writer.onFinished = { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.onFinished?(error)
            }
        }
        writer.onSourceDownloadStats = { [weak self] bitsPerSecond, totalBytesRead in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.onSourceDownloadStats?(bitsPerSecond, totalBytesRead)
            }
        }
        writer.onGeneratedMediaStats = { [weak self] generatedStats in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.onGeneratedMediaStats?(generatedStats)
            }
        }
        writer.onBridgedAudioAnchored = { [weak self] seconds in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown,
                      self.isCurrentProducer(generation) else { return }
                self.onBridgedAudioAnchored?(seconds)
            }
        }
        // HDR10+ badge: install the one-shot SEI scan only for plain HEVC PQ
        // sessions whose label currently reads "HDR10" and has not flipped.
        // DV Profile 8 sources keep their validated labels (scan not installed).
        if spec.videoMode == .passthroughHEVC,
           spec.manifestMetadata.videoRange != "HLG",
           spec.manifestMetadata.videoRange != "SDR",
           !(hasDetectedHDR10Plus?() ?? false) {
            writer.onHDR10PlusMetadataDetected = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isTornDown,
                          self.isCurrentProducer(generation) else { return }
                    self.onHDR10PlusMetadataDetected?()
                }
            }
        }
        segmentWriter = writer
    }

    /// Opens a producer generation, retiring every older one, and returns the
    /// tag the new producer's callbacks carry.
    private func beginProducerGeneration() -> UInt64 {
        producerGenerationLock.lock()
        defer { producerGenerationLock.unlock() }
        producerGeneration &+= 1
        return producerGeneration
    }

    /// Retires the running producer without starting another — teardown's
    /// half of the same tag.
    private func retireProducerGeneration() {
        producerGenerationLock.lock()
        producerGeneration &+= 1
        producerGenerationLock.unlock()
    }

    /// Whether the producer tagged `generation` is still the one this host
    /// listens to. Read from the mux thread as well as from main, hence the
    /// lock.
    private func isCurrentProducer(_ generation: UInt64) -> Bool {
        producerGenerationLock.lock()
        defer { producerGenerationLock.unlock() }
        return producerGeneration == generation
    }

    /// The segment plan resolved for THIS source. Restarted producers receive
    /// it so every session reproduces the same segment grid the static
    /// playlist advertises.
    private func vodPlanForCurrentSource(spec: LoopbackSessionSpec) -> LoopbackSegmentPlan? {
        resolvedVODPlan?.matching(spec.sourceURL)
    }

    /// Swaps the producer (writer only — the store, server, and player item
    /// all survive) to anchor at the requested plan segment. Coalesced: one
    /// in-flight swap, newest pending target wins, self-target guarded.
    @MainActor
    func requestProducerRestart(atSegmentIndex index: Int, authoritative: Bool = false) {
        guard !isTornDown,
              let plan = vodPlanForCurrentSource(spec: sessionSpec),
              plan.segmentCount > 0,
              segmentStore != nil else { return }
        let target = max(0, min(index, plan.segmentCount - 1))
        if segmentWriter != nil,
           let base = activeVODWriterBaseIndex,
           Self.coversTarget(
               target: target,
               base: base,
               head: activeVODWriterHeadIndex,
               coverageWindow: Self.vodProducerCoverageWindow,
               marchAllowance: Self.vodProducerMarchAllowance
           ) {
            return
        }
        var next: Int? = target
        while let current = next {
            guard restartCoalescer.begin(current, authoritative: authoritative) else { return }
            cmpLog("[CMP-AVP] vod producer restart segment=\(current) authoritative=\(authoritative)")
            // Recycle the retiring producer's demuxer: same source URL
            // (reanchored spec only moves the start time), and the open
            // input + warm cue index are the dominant fixed cost of a
            // seek-triggered restart.
            var handoff: LoopbackInputHandoff?
            if let retiring = segmentWriter {
                let h = LoopbackInputHandoff()
                handoff = h
                retiring.stop(recyclingInputInto: h)
            }
            writerSpec = sessionSpec.reanchored(
                at: plan.sourceStartSeconds(ofSegment: current)
            )
            startWriter(vodBaseIndex: current, recycledInput: handoff)
            next = restartCoalescer.next(justRan: current)
        }
    }

    // MARK: - First segment

    private func handleFirstSegmentReady(playlistName: String) {
        guard !isTornDown, let server = segmentServer else { return }
        guard canAttachFirstSegment?() ?? false else { return }
        let decision = Self.playlistURLDecision(
            isExternalPlaybackActive: isExternalPlaybackActive?() ?? false,
            externalURL: { server.resourceURL(for: playlistName, reachableFromExternalDevice: true) },
            loopbackURL: { server.resourceURL(for: playlistName) }
        )
        if decision.abandonsExternalHandoff {
            onExternalPlaybackHandoffAbandoned?()
        }
        guard let url = decision.url else {
            onFailure?(.loopbackPlaylistURLUnavailable)
            return
        }
        server.setAcceptsExternalClients(decision.usesExternalURL)
        onFirstSegmentReady?(
            (url: url, playlistName: playlistName, usesExternalURL: decision.usesExternalURL)
        )
    }

    /// Whether the producer anchored at `base` (having finalized up to `head`,
    /// nil before its first segment lands) both covers `target` and is close
    /// enough that its forward march delivers it before the fetch's miss
    /// deadline — i.e. whether a restart would be pure churn.
    ///
    /// The head-proximity bound matters on long-GOP sources: a seek landing
    /// 3+ heavy segments past the produced head used to ride "covered by
    /// base+8" into an 8 s wait and a 404. This applies to recovery re-bases
    /// too: restarting a covering producer discards its march and re-produces
    /// the same span — the recovery ladder's player-side nudge/reload is the
    /// tool for a consumer wedge, not producer churn. A genuinely wedged
    /// producer surfaces separately (source stall → premature EOF / mux
    /// failures) and escalates through the watchdog budget.
    static func coversTarget(
        target: Int,
        base: Int,
        head: Int?,
        coverageWindow: Int,
        marchAllowance: Int
    ) -> Bool {
        guard target >= base, target <= base + coverageWindow else { return false }
        return target <= max(head ?? (base - 1), base - 1) + marchAllowance
    }

    /// Starting up with AirPlay already engaged: prefer the LAN address, but
    /// a session that cannot reach one still plays here rather than failing.
    static func playlistURLDecision(
        isExternalPlaybackActive: Bool,
        externalURL: () -> URL?,
        loopbackURL: () -> URL?
    ) -> (url: URL?, usesExternalURL: Bool, abandonsExternalHandoff: Bool) {
        var useExternalURL = isExternalPlaybackActive
        var resolvedExternalURL: URL?
        var abandonsExternalHandoff = false
        if useExternalURL {
            resolvedExternalURL = externalURL()
            if resolvedExternalURL == nil {
                useExternalURL = false
                abandonsExternalHandoff = true
            }
        }
        return (
            url: resolvedExternalURL ?? loopbackURL(),
            usesExternalURL: useExternalURL,
            abandonsExternalHandoff: abandonsExternalHandoff
        )
    }

    // MARK: - Operations the backend needs

    /// The store's counters, or nil when no session is running. The stats
    /// panel, the playhead watchdog and the reanchor log all read them.
    func storeStats() -> LoopbackSegmentStoreStats? {
        segmentStore?.stats()
    }

    /// Wall seconds since the store last served a segment, nil before the
    /// first serve or without a store. A consumer still pulling is filling
    /// its buffer, not wedged.
    func secondsSinceLastSegmentServe() -> Double? {
        segmentStore?.secondsSinceLastSegmentServe()
    }

    /// Total HTTP requests the server has parsed, nil without one. The
    /// startup ladder compares snapshots to tell a slow-but-fetching
    /// AVPlayer from one whose loader pipeline died.
    var servedRequestCount: UInt64? {
        segmentServer?.servedRequestCount
    }

    /// Replaces this session's access token wherever it appears, so a
    /// loopback URL cannot carry the secret into a support bundle. Without a
    /// server there is no token and the line passes through.
    func redactLog(_ value: String) -> String {
        segmentServer?.redactingAccessToken(in: value) ?? value
    }

    /// The URL AVPlayer should point at for an already-published resource
    /// when external playback starts or stops. Nil means "no address the
    /// receiver can reach" — the caller keeps playback on this device.
    ///
    /// Nil-without-a-server folds into the same answer on purpose: a bind
    /// failure retires the server before any writer runs, so no resource has
    /// been published and no caller has a name to ask for.
    func resourceURL(
        forPublishedResource resourceName: String,
        reachableFromExternalDevice: Bool
    ) -> URL? {
        segmentServer?.resourceURL(
            for: resourceName,
            reachableFromExternalDevice: reachableFromExternalDevice
        )
    }

    /// Opens or closes the listener to off-device clients for an AirPlay
    /// handoff that started or ended mid-session.
    func setAcceptsExternalClients(_ accepts: Bool) {
        segmentServer?.setAcceptsExternalClients(accepts)
    }

    /// Selects the bitmap subtitle stream the producer decodes, applying it
    /// to the running writer and to every writer a restart builds after it.
    func selectBitmapSubtitleStream(_ streamIndex: Int?) {
        selectedBitmapSubtitleStream = streamIndex
        segmentWriter?.setBitmapSubtitleTapStream(streamIndex)
    }

    // MARK: - Teardown

    /// Releases the producer, the server, the store and the session
    /// directory, and drops every closure so a draining writer's late
    /// callbacks land nowhere. A host is never restarted after this.
    ///
    /// The writer's own callbacks are deliberately left alone: `isTornDown`
    /// latches first and the producer generation is retired with it, so every
    /// closure this host installed on a writer bails — including the two that
    /// never reach main (the anchored store seed and the bitmap cue tap),
    /// which `isTornDown` alone could not gate.
    func teardown() {
        isTornDown = true
        retireProducerGeneration()
        let writer = segmentWriter
        segmentWriter = nil
        segmentServer?.stop()
        segmentServer = nil
        segmentStore = nil
        releaseCallbacks()

        let dir = sessionDirectory
        let preserveDir = keepArtifacts
        // Deferred to `stop`'s completion when a writer exists so the mux
        // thread has finished before the directory goes away; synchronous
        // otherwise, because the optional-chained completion never runs.
        let disposeSessionDirectory: () -> Void = {
            if preserveDir {
                cmpLog("[CMP-AVP] retained local DV artifacts dir=\(dir.path)")
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        if let writer {
            writer.stop(completion: disposeSessionDirectory)
        } else {
            disposeSessionDirectory()
        }
    }

    private func releaseCallbacks() {
        isExternalPlaybackActive = nil
        canAttachFirstSegment = nil
        hasDetectedHDR10Plus = nil
        onFirstSegmentReady = nil
        onSegmentPlanResolved = nil
        onSourceDownloadStats = nil
        onGeneratedMediaStats = nil
        onBridgedAudioAnchored = nil
        onHDR10PlusMetadataDetected = nil
        onBitmapSubtitleTapTracks = nil
        onBitmapSubtitleTapCue = nil
        onFinished = nil
        onExternalPlaybackHandoffAbandoned = nil
        onFailure = nil
    }
}
