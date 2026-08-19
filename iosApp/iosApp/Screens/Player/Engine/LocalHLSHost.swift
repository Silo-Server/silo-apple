import Foundation

/// The local HLS pipeline behind one `.siloLoopback` session: the segment
/// store, the loopback HTTP server, the producing writer (plus its
/// demand-driven restarts) and the session directory they share.
///
/// Stage 2 wave 2a moved this lifecycle glue out of `AVPlayerBackend`
/// (inventory-3 §4.1–4.5, §4.7) with the bodies intact. What stayed in the
/// adapter: items and observers, the display-criteria write → settle → attach
/// ordering, the initial-video-display gate, audio session, PiP/AirPlay
/// policy, seek deadlines, every recovery ladder, and the subtitle plane —
/// the tap this host hands the writer belongs to the backend because its cue
/// store is keyed to the SOURCE and deliberately outlives a session.
///
/// Isolation mirrors the adapter it came from: the class is not actor
/// isolated, `requestProducerRestart` is `@MainActor` exactly as
/// `requestVODProducerRestart` was, and every callback the writer, store or
/// server fires keeps the hop it had (the writer's mux thread and the
/// server's resolver queue still hop to main in the same place).
///
/// Identity is the host itself. There is no session-id string to compare:
/// the backend owns exactly one live host, `teardown()` latches
/// `isTornDown` and nils every closure so a draining writer's late callbacks
/// land nowhere, and the backend re-checks `loopbackHost === host` in each
/// closure it installs.
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
    /// creation (Stage 2 design §7.2) — nothing mutates the environment.
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

    private let playbackPositionProvider: () -> Double?
    private let isSourceOutageActive: () -> Bool
    /// The backend's source-keyed subtitle cue tap. Handed to every producer,
    /// including restarts, so a restarted writer keeps filling the same store.
    private let subtitleTap: (URL) -> LoopbackSubtitleTap?
    /// AVPlayer's external-playback state, for the first-segment URL choice.
    var isExternalPlaybackActive: (() -> Bool)?
    /// The backend's first-segment gate: not disposed and no item attached yet.
    var canAttachFirstSegment: (() -> Bool)?
    /// The bitmap subtitle stream the backend has selected; every new writer
    /// inherits it so a selection survives producer restarts.
    var selectedBitmapSubtitleTapStream: (() -> Int?)?
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

    private(set) var segmentWriter: LoopbackSegmentWriter?
    private(set) var segmentServer: LoopbackSegmentServer?
    private(set) var segmentStore: LoopbackSegmentStore?
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
    private(set) var isTornDown = false

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
        let store = LoopbackSegmentStore(
            generation: generation,
            memoryBudgetBytes: storeMemoryBudgetBytes,
            spillPolicy: storeSpillPolicy,
            debugDirectory: debugDirectory
        )
        let retentionBudget = vodRetentionBudgetBytes
        cmpLog("[CMP-HLS-STORE] vod retention budgetBytes=\(retentionBudget)")
        store.configureVODRetention(budgetBytes: retentionBudget)
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
                named: String(format: "seg_%06d.m4s", index),
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
        let sessionSpec = writerSpec
        let sessionDir = sessionDirectory
        let writer = LoopbackSegmentWriter(
            sessionSpec: sessionSpec,
            outputDirectory: sessionDir,
            segmentStore: segmentStore,
            vodPlan: vodPlanForCurrentSource(spec: sessionSpec),
            vodBaseIndex: vodBaseIndex,
            recycledInputHandoff: recycledInput
        )
        let tap = subtitleTap(sessionSpec.sourceURL)
        writer.isSourceOutageActive = isSourceOutageActive
        writer.onSubtitleTapTracks = { [weak tap] infos in
            tap?.registerTracks(infos)
        }
        writer.onSubtitleTapCue = { [weak tap] cue in
            tap?.ingest(cue)
        }
        writer.onBitmapSubtitleTapTracks = { [weak self] indices in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.onBitmapSubtitleTapTracks?(indices)
            }
        }
        // Mux thread; the writer only decodes (and therefore only emits)
        // while a stream is selected, and SubtitleSession serialises feeds
        // on its own queue — same pattern as the extractor's decode thread.
        writer.onBitmapSubtitleTapCue = { [weak self] streamIndex, cues, trimActiveAt in
            self?.onBitmapSubtitleTapCue?(streamIndex, cues, trimActiveAt)
        }
        // Selection survives producer restarts: every new writer inherits it.
        writer.setBitmapSubtitleTapStream(selectedBitmapSubtitleTapStream?() ?? nil)
        activeVODWriterBaseIndex = vodBaseIndex
        activeVODWriterHeadIndex = vodBaseIndex - 1
        // Seed the consumer window at the producer's base so a resumed
        // or restarted session isn't parked by backpressure before the
        // player's first fetch declares a real target.
        segmentStore.declareVODTarget(vodBaseIndex)
        // A resume-first session anchors itself once the plan resolves;
        // re-seed from the writer's TRUE base or the producer parks
        // against a window still sitting at 0 while AVPlayer's resume
        // fetches strand (the living-room resume startup timeout).
        writer.onVODProducerAnchored = { [weak self, weak segmentStore] base in
            segmentStore?.declareVODTarget(base)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.activeVODWriterBaseIndex = base
                self.activeVODWriterHeadIndex = base - 1
            }
        }
        // Produced-head tracking for the restart coverage decision:
        // a fetch may only ride the running march when it's within
        // vodProducerMarchAllowance of what has actually been written.
        writer.onSegmentAppended = { [weak self] segmentIndex, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.activeVODWriterHeadIndex = max(
                    self.activeVODWriterHeadIndex ?? segmentIndex,
                    segmentIndex
                )
            }
        }
        writer.onSegmentPlanResolved = { [weak self] plan in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.resolvedVODPlan = ResolvedVODPlan(
                    plan: plan,
                    sourceURL: sessionSpec.sourceURL
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
                self?.handleFirstSegmentReady(playlistName: playlistName)
            }
        }
        writer.onFinished = { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.onFinished?(error)
            }
        }
        writer.playbackPositionProvider = playbackPositionProvider
        writer.onSourceDownloadStats = { [weak self] bitsPerSecond, totalBytesRead in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown else { return }
                self.onSourceDownloadStats?(bitsPerSecond, totalBytesRead)
            }
        }
        writer.onGeneratedMediaStats = { [weak self] generatedStats in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown else { return }
                self.onGeneratedMediaStats?(generatedStats)
            }
        }
        writer.onBridgedAudioAnchored = { [weak self] seconds in
            DispatchQueue.main.async {
                guard let self, !self.isTornDown else { return }
                self.onBridgedAudioAnchored?(seconds)
            }
        }
        // HDR10+ badge: install the one-shot SEI scan only for plain HEVC PQ
        // sessions whose label currently reads "HDR10" and has not flipped.
        // DV Profile 8 sources keep their validated labels (scan not installed).
        if sessionSpec.videoMode == .passthroughHEVC,
           sessionSpec.manifestMetadata.videoRange != "HLG",
           sessionSpec.manifestMetadata.videoRange != "SDR",
           !(hasDetectedHDR10Plus?() ?? false) {
            writer.onHDR10PlusMetadataDetected = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isTornDown else { return }
                    self.onHDR10PlusMetadataDetected?()
                }
            }
        }
        segmentWriter = writer
        writer.start()
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
        if let base = activeVODWriterBaseIndex,
           segmentWriter != nil,
           target >= base,
           target <= base + Self.vodProducerCoverageWindow,
           target <= max(activeVODWriterHeadIndex ?? (base - 1), base - 1)
                        + Self.vodProducerMarchAllowance {
            // The running producer covers it AND is close enough that its
            // forward march delivers before the fetch's miss deadline. The
            // head-proximity bound matters on long-GOP sources: a seek
            // landing 3+ heavy segments past the produced head used to ride
            // "covered by base+8" into an 8 s wait and a 404. This applies
            // to recovery re-bases too: restarting a covering producer
            // discards its march and re-produces the same span — the
            // recovery ladder's player-side nudge/reload is the tool for a
            // consumer wedge, not producer churn. A genuinely wedged
            // producer surfaces separately (source stall → premature EOF /
            // mux failures) and escalates through the watchdog budget.
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
        guard canAttachFirstSegment?() ?? true else { return }
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

    // MARK: - Teardown

    /// Releases the producer, the server, the store and the session
    /// directory, and drops every closure so a draining writer's late
    /// callbacks land nowhere. A host is never restarted after this.
    func teardown() {
        isTornDown = true
        let writer = segmentWriter
        segmentWriter = nil
        writer?.onFirstSegmentReady = nil
        writer?.onSegmentAppended = nil
        writer?.onSourceDownloadStats = nil
        writer?.onGeneratedMediaStats = nil
        writer?.onHDR10PlusMetadataDetected = nil
        writer?.onBridgedAudioAnchored = nil
        writer?.onFinished = nil
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
        selectedBitmapSubtitleTapStream = nil
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
