//
//  PlaybackEngineSession.swift
//
//  One engine session per `LoadID`.
//
//  The backend, the source proxy and the callbacks that bind them belong to one
//  load and are owned together: the callbacks are bound to *this* session, the
//  stream ends when it is disposed, and a late event from a superseded load is
//  dropped structurally rather than by comparing a generation number captured
//  when the closure was created.
//
//  It also owns the load's `RecoveryDriver`, which makes every recovery latch,
//  budget and rolling window load-scoped for free. Backend-originated
//  observations go straight into the driver and the resulting engine-level
//  action is performed on the backend synchronously — exactly where and when
//  the ladder ran. Session- and transport-level actions ride the event stream
//  as `EngineEvent.recoveryAction`, because the shell owns their execution.
//
//  Isolation: a plain `final class`, for the reason `LocalHLSHost` is one —
//  `AVPlayerBackend` and `PlayerViewModel` are both nonisolated, and every
//  producer already runs on the main queue (the backend's notification
//  observers, its `RunLoop.main` timers, the proxy's `Task { @MainActor }`
//  callbacks). Annotating the class would force a hop into every one of them
//  and defer each in-route recovery by a run-loop turn.
//

import Foundation
import OSLog

final class PlaybackEngineSession {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlaybackEngineSession"
    )

    /// Identity of this load. Every event this session publishes belongs to it.
    let loadID: LoadID
    /// What this session was asked to execute.
    let plan: ExecutablePlan
    /// The AVFoundation adapter. Survives an in-place replan: the successor
    /// session adopts this instance rather than building one.
    private(set) var backend: any PlaybackBackend
    /// The concrete backend for the view surface (`AVPlayerSurface` binds to
    /// `AVPlayer`, which is not on the protocol) and for the track coordinator's
    /// port.
    var surfaceBackend: AVPlayerBackend? { backend as? AVPlayerBackend }
    /// The source proxy, when this load has one.
    private(set) var transport: PlaybackSourceProxy?
    /// The load's recovery state and the only runtime caller of
    /// `RecoveryPolicy.decide`.
    let driver: RecoveryDriver
    /// Everything the engine and the transport report, in order.
    let events: AsyncStream<EngineEvent>

    private let continuation: AsyncStream<EngineEvent>.Continuation
    private(set) var isDisposed = false

    /// The backend's `mediaTimelineOffsetSeconds`, mirrored here so this
    /// session can put the playhead it publishes on the **movie** axis.
    ///
    /// `PlaybackBackend.onTimeChange` reports AVPlayer's own clock
    /// (`AVPlayerBackend:2353` yields `time.seconds` raw), which is the player
    /// axis; every other producer of a position in the control plane is movie
    /// time (`PlaybackReducer.movieTime(for:)` = `session.position +
    /// session.timelineOffsetSeconds`, `SeekRequest.targetSeconds`,
    /// `Effect.reportProgress`'s wire position). The view model used to convert
    /// at its own callback — `let movieTime = seconds + playbackTimelineOffset`,
    /// against a mirror of exactly this value fed by
    /// `EngineEvent.timelineOffset` — so on a server-remux resume
    /// (`playMethod == "remux"` → `avPlayerHLS` + `startOfManifest`, where the
    /// offset is the resume point) the two axes differed by minutes.
    ///
    /// The conversion happens **once**, here, at the boundary where the axis is
    /// known: `AVPlayerBackend.setMediaTimelineOffset` is the only writer and it
    /// calls `onTimelineOffsetChange` synchronously, before the item that
    /// reports on the new axis exists (`PlayerViewModel.installEngine` sets it
    /// before `session.start`). A reused backend keeps its offset across an
    /// in-place replan, so the successor session seeds from it.
    private var mediaTimelineOffsetSeconds: Double

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - reusing: the outgoing session when the implementation route did not
    ///     change. Its `AVPlayerBackend` is adopted rather than rebuilt so tvOS
    ///     keeps identical display criteria and the live audio session; its
    ///     callbacks are re-bound to this session's stream and this load's id.
    init(
        loadID: LoadID,
        plan: ExecutablePlan,
        backendFactory: () -> any PlaybackBackend,
        reusing existing: PlaybackEngineSession?,
        transport: PlaybackSourceProxy?
    ) {
        self.loadID = loadID
        self.plan = plan
        self.transport = transport
        self.driver = RecoveryDriver(route: plan.engine)
        // Seeded before `relinquishBackend()`, which is what makes the outgoing
        // session's mirror unreachable.
        self.mediaTimelineOffsetSeconds = existing?.mediaTimelineOffsetSeconds ?? 0
        let adopted = existing?.relinquishBackend()
        self.backend = adopted ?? backendFactory()
        let stream = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream.stream
        self.continuation = stream.continuation
        bindBackend()
        if adopted != nil, let outgoing = existing {
            // The suspension latch was a backend field before this wave, so a
            // reused backend carried its holders across the replan; the load
            // that took the hold releases it once, on whichever session owns
            // the backend when its round trip ends.
            //
            // Every hold travels with its releaser, or it can never be
            // released. `server_replan`'s releaser is the replan's own `defer`,
            // which runs after this session exists. `origin_outage`'s releasers
            // (`.endOutageRideThrough`, the ride-through poll's escalation, and
            // `performServerOutageRecovery`) all read `context.outage`, which
            // was view-model state before this wave and so survived a replan
            // untouched — carry it, or the replacement session is muzzled for
            // the rest of the load.
            driver.adoptSuspensions(outgoing.driver.context.suspendedReasons)
            driver.adoptOutageRideThrough(outgoing.driver.context.outage)
        }
    }

    /// Hands this session's backend to its successor and closes this session
    /// down without disposing the engine. Used by the in-place replan, which
    /// must keep the live `AVPlayer`.
    private func relinquishBackend() -> (any PlaybackBackend)? {
        guard !isDisposed else { return nil }
        unbindBackend()
        isDisposed = true
        continuation.finish()
        return backend
    }

    /// Takes the backend out for an off-main `dispose()` (the fresh-load path,
    /// which must not stall the replacement load behind a slow teardown).
    func detachBackendForDisposal() -> AVPlayerBackend? {
        let concrete = surfaceBackend
        unbindBackend()
        isDisposed = true
        continuation.finish()
        return concrete
    }

    /// Stops and drops the source proxy without touching the engine. The
    /// fresh-load path stashes the proxy's cache and stops it well before the
    /// backend goes away.
    func stopTransport() {
        transport?.stop()
        transport = nil
        backend.sourceOutageStateProvider = nil
    }

    /// Tears the engine down but keeps this session alive as the load's
    /// recovery owner.
    ///
    /// The visible server-outage recovery disposes the player and the proxy and
    /// then *waits* for the server: its `RecoveryContext.serverOutageRecovery`
    /// slot, its backoff and its 90 s budget all have to outlive the engine,
    /// exactly as they did when they were view-model fields. The replacement
    /// load installs a new session, which is what finally retires this one.
    func disposeEngineOnly(reason: String) {
        guard !isDisposed else { return }
        Self.logger.info(
            "[CMP-ENGINE] engine disposed reason=\(reason, privacy: .public)"
        )
        unbindBackend()
        backend.dispose()
    }

    /// Full teardown.
    ///
    /// - Parameter retainingTransport: the tvOS background suspend disposes the
    ///   engine and deliberately leaves the source proxy — and its cache —
    ///   running for the resume (`SourceCacheDisposition.retainProxy`).
    func dispose(reason: String, retainingTransport: Bool = false) {
        guard !isDisposed else {
            // A `retainingTransport` dispose latches `isDisposed` while
            // deliberately leaving the proxy running, so the teardown that
            // follows the suspend (`cleanup()`, `deinit`,
            // `finalizeTerminalPlaybackError`) still has to stop it — that is
            // what legacy's unconditional `sourceProxy?.stop()` covered.
            if !retainingTransport {
                transport?.stop()
                transport = nil
            }
            return
        }
        isDisposed = true
        Self.logger.info(
            "[CMP-ENGINE] session disposed reason=\(reason, privacy: .public)"
        )
        unbindBackend()
        backend.dispose()
        if !retainingTransport {
            transport?.stop()
            transport = nil
        }
        continuation.finish()
    }

    // MARK: - Driving the engine

    /// Hands the plan to the backend. The plan's shape picks the load verb;
    /// everything else already travels as data on it.
    func start(startSeconds: Double) {
        guard !isDisposed else { return }
        switch plan {
        case let .nativeDirect(direct):
            backend.loadDirectFile(
                url: direct.url,
                headers: direct.headers,
                startTime: startSeconds
            )
        case let .serverHLS(hls):
            backend.loadRemoteHLS(
                url: hls.manifestURL,
                headers: hls.headers,
                startTime: startSeconds
            )
        case let .localHLS(local):
            backend.load(sessionSpec: local.sessionSpec, startTime: startSeconds)
        }
    }

    func seek(to seconds: Double) {
        guard !isDisposed else { return }
        backend.seek(to: seconds)
    }

    /// Points the live proxy at a renewed origin without touching the player,
    /// the remuxer or the cache (`attemptBackgroundSessionRenewal`).
    func retargetSource(url: URL, headers: [String: String]) {
        transport?.retargetOrigin(url: url, headers: headers)
    }

    /// Suspends (or resumes) every in-route recovery rung for one owner. The
    /// latch is the driver's; the backend keeps a diagnostic mirror so its
    /// periodic telemetry line still names the holders.
    func suspendRecovery(_ suspended: Bool, reason: String) {
        driver.setSuspended(suspended, reason: reason)
    }

    /// Routes one decided action. Engine-level arms run here and now; the arms
    /// the shell owns ride the event stream.
    func perform(_ action: RecoveryAction) {
        guard !isDisposed else { return }
        switch action {
        case .treatAsNaturalEnd, .requestServerReplan, .switchRoute,
             .renewSourceInBackground, .renewSessionFresh, .rideThroughOutage,
             .recoverFromServerOutage, .waitForServerReady, .autoRecoverInterruption:
            emit(.recoveryAction(action))

        case .endOutageRideThrough:
            // `clearSourceOutageRideThroughState()` released the latch *before*
            // the post-outage kick ran, and the kick's own rung
            // reads it.
            driver.setSuspended(false, reason: RecoveryDriver.originOutageSuspensionReason)
            backend.perform(action)
            emit(.recoveryAction(action))

        case .reassertPlay, .nudgeStartup, .reloadStartupItem, .reanchor,
             .reloadItem, .rebuildLocalSession,
             .deferUntilPlay, .resumePlayback, .fail:
            backend.perform(action)
        }
    }

    // MARK: - Observations

    /// The single entry point for a recovery signal, wherever it came from:
    /// the backend's ladders, the source proxy's three reports, or the shell.
    func observe(_ observation: RecoveryObservation) {
        guard !isDisposed else { return }
        // The notification-driven rungs read the live player where they used to
        // sit; the 1 Hz tick carries its own sample.
        if case .playheadTick = observation {} else if let sample = backend.recoveryPlayheadSample {
            driver.note(playheadSample: sample)
        }
        guard let action = driver.observe(observation) else { return }
        if case .rideThroughOutage = action {
            // `handleOriginOutageChanged(true)`'s in-route suppression: held
            // synchronously at entry so no rung can act in the window before
            // the shell picks the action up off the stream.
            driver.setSuspended(true, reason: RecoveryDriver.originOutageSuspensionReason)
        }
        if case .recoverFromServerOutage = action {
            driver.setSuspended(false, reason: RecoveryDriver.originOutageSuspensionReason)
        }
        if case .fail = action, !Self.isEngineOriginated(observation) {
            // `.fail` is the one action whose executor depends on where the
            // observation came from: an in-route rung *reports* it into the
            // failure ladder (`reportFailure` → `onError`), while a shell-owned
            // observation's `.fail` is already terminal
            // (`finalizeTerminalPlaybackError`).
            emit(.recoveryAction(action))
            return
        }
        perform(action)
    }

    /// Whether this observation is one the engine raised. Backend-raised
    /// signals are answered on the backend; the shell's own observations are
    /// answered by the shell.
    private static func isEngineOriginated(_ observation: RecoveryObservation) -> Bool {
        switch observation {
        case .startupTick, .playheadTick, .itemDeathEvidence, .edgeSample,
             .playbackStalled, .itemFailedToEnd, .playlistUnchanged,
             .likelyToKeepUp, .interactiveSeekDeadlineExpired:
            return true
        case .engineFailed, .originOutage, .sourceInterrupted, .sessionMissing,
             .serverHealthProbe, .runwayExhaustedDuringOutage:
            return false
        }
    }

    /// `PlaybackSourceProxy.onOriginOutageChanged`.
    ///
    /// `handleOriginOutageChanged(true)` also called
    /// `noteBufferingDuringSourceOutage()` when the player was *already* out of
    /// runway, because the buffering edge will not fire again — so the
    /// once-per-outage gate is re-fed here at entry.
    ///
    /// - Parameter isBuffering: the *shell's* buffering flag, which is what
    ///   legacy tested. `setBuffering(_:cause:)` also writes it for causes the
    ///   engine never raises ("replan", "quality_switch", "background_suspend"),
    ///   so the backend's own latch is not a substitute.
    func reportOriginOutage(_ active: Bool, isBuffering: Bool) {
        observe(.originOutage(active: active))
        if active, isBuffering {
            observe(.runwayExhaustedDuringOutage)
        }
    }

    // MARK: - Callback binding

    private func emit(_ event: EngineEvent) {
        guard !isDisposed else { return }
        continuation.yield(event)
    }

    /// `AVPlayerBackend.mediaTime(for:)` (AVPlayerBackend:1351), verbatim —
    /// the same conversion `RecoveryContext.mediaSeconds(forPlayerSeconds:)`
    /// (RecoveryContext:351) applies to the observation channel's playhead.
    private func mediaTime(for playerTime: Double) -> Double {
        guard playerTime.isFinite else { return 0 }
        return max(0, playerTime + mediaTimelineOffsetSeconds)
    }

    private func bindBackend() {
        backend.onTimeChange = { [weak self] seconds in
            guard let self else { return }
            // The one axis conversion — see `mediaTimelineOffsetSeconds`.
            self.emit(.time(seconds: self.mediaTime(for: seconds)))
        }
        backend.onDurationChange = { [weak self] seconds in self?.emit(.duration(seconds: seconds)) }
        backend.onPauseChange = { [weak self] paused in
            guard let self else { return }
            self.driver.note(userPaused: paused)
            self.emit(.pauseChanged(paused))
        }
        backend.onFileLoaded = { [weak self] reason in
            guard let self else { return }
            self.driver.note(playbackEstablished: true)
            self.emit(.fileLoaded(reason: reason))
        }
        backend.onFirstFrame = { [weak self] ms in self?.emit(.firstFrame(ms: ms)) }
        backend.onError = { [weak self] failure in self?.emit(.failed(failure)) }
        backend.onEndOfFile = { [weak self] in self?.emit(.endOfFile) }
        backend.onBufferingChange = { [weak self] buffering in
            self?.emit(.buffering(buffering))
        }
        backend.onBufferedAheadChange = { [weak self] ahead in self?.emit(.bufferedAhead(ahead)) }
        backend.onPlaybackStatsChange = { [weak self] stats in self?.emit(.stats(stats)) }
        backend.onTracksChange = { [weak self] tracks in self?.emit(.tracks(tracks)) }
        backend.onChaptersChange = { [weak self] chapters in self?.emit(.chapters(chapters)) }
        backend.onTimelineOffsetChange = { [weak self] offset in
            guard let self else { return }
            self.mediaTimelineOffsetSeconds = offset.isFinite ? max(0, offset) : 0
            self.driver.note(mediaTimelineOffset: offset)
            self.emit(.timelineOffset(offset))
        }
        backend.onExternalPlaybackActiveChange = { [weak self] active in
            self?.emit(.externalPlayback(active: active))
        }
        backend.onExternalPlaybackAllowedChange = { [weak self] allowed in
            self?.emit(.externalPlaybackAllowed(allowed))
        }
        backend.onExternalPlaybackUnavailable = { [weak self] in
            self?.emit(.externalPlaybackUnavailable)
        }
        backend.onSidecarTracksRegistered = { [weak self] descriptors in
            self?.emit(.sidecarTracksRegistered(descriptors))
        }
        backend.onRecoveryObservation = { [weak self] observation in
            self?.observe(observation)
        }
        backend.sourceOutageStateProvider = { [weak self] in
            self?.transport?.isOriginOutageActive ?? false
        }
        backend.onEngineReloaded = { [weak self] in
            self?.driver.noteEngineLoadStarted()
        }
        backend.onStartupLadderArmed = { [weak self] served in
            self?.driver.armStartupLadder(startedAt: Date(), servedRequests: served)
        }
        backend.recoveryStationarySecondsProvider = { [weak self] in
            guard let since = self?.driver.context.playhead.stationarySince else { return 0 }
            return Date().timeIntervalSince(since)
        }
        driver.onSuspensionChanged = { [weak self] reasons in
            self?.backend.suspendedRecoveryReasons = reasons
        }
    }

    private func unbindBackend() {
        backend.onTimeChange = nil
        backend.onDurationChange = nil
        backend.onPauseChange = nil
        backend.onFileLoaded = nil
        backend.onFirstFrame = nil
        backend.onError = nil
        backend.onEndOfFile = nil
        backend.onBufferingChange = nil
        backend.onBufferedAheadChange = nil
        backend.onPlaybackStatsChange = nil
        backend.onTracksChange = nil
        backend.onChaptersChange = nil
        backend.onTimelineOffsetChange = nil
        backend.onExternalPlaybackActiveChange = nil
        backend.onExternalPlaybackAllowedChange = nil
        backend.onExternalPlaybackUnavailable = nil
        backend.onSidecarTracksRegistered = nil
        backend.onRecoveryObservation = nil
        backend.sourceOutageStateProvider = nil
        backend.onEngineReloaded = nil
        backend.onStartupLadderArmed = nil
        backend.recoveryStationarySecondsProvider = nil
        driver.onSuspensionChanged = nil
    }
}

// MARK: - Source preparation and cache handoff

extension PlaybackEngineSession {

    /// A torn-down proxy's cache, retained across the teardown so a same-file
    /// replacement proxy can adopt it (spans stay in memory, spill stays on
    /// disk) instead of re-downloading. One slot, held by the shell because it
    /// deliberately outlives a session: stashed at every proxy stop that might
    /// be followed by a same-file reload, resolved (adopted or released) by the
    /// next `prepareSource`, and released on terminal teardown. Releasing the
    /// last reference cleans the disk directory via the cache's deinit.
    struct SourceCacheHandoff {
        let fileId: Int
        let cache: PlaybackSourceCache
    }

    /// What the incoming load needs from the shell to size its cache and
    /// resolve the handoff slot.
    struct SourceInputs {
        let fileId: Int?
        let expectedFileSize: Int64?
        let diskSpillRequested: Bool
        /// `currentSelectedVersion.bitrate` in bits per second, the fallback
        /// when the plan carries no loopback session of its own.
        let nominalBitrateBps: Double?
    }

    struct SourcePreparation {
        let plan: PlaybackExecutionPlan
        let proxy: PlaybackSourceProxy?
    }

    enum SourcePreparationError: LocalizedError {
        case missingLocalURL
        case missingLoopbackSession

        var errorDescription: String? {
            switch self {
            case .missingLocalURL:
                return "local proxy URL was unavailable"
            case .missingLoopbackSession:
                return "loopback session was unavailable"
            }
        }
    }

    /// Retain the outgoing proxy's cache for possible adoption by the next
    /// same-file proxy. Called immediately before the proxy is stopped on
    /// non-terminal teardown paths.
    static func stashSourceCache(
        from proxy: PlaybackSourceProxy?,
        fileId: Int?
    ) -> SourceCacheHandoff? {
        guard let proxy, let fileId else { return nil }
        let cache = proxy.handoffCache
        Self.logger.info(
            "[CMP-SOURCE-CACHE] handoff stashed fileId=\(fileId, privacy: .public) cachedBytes=\(cache.stats().cachedBytes, privacy: .public) diskBytes=\(cache.stats().diskSpillBytes, privacy: .public)"
        )
        return SourceCacheHandoff(fileId: fileId, cache: cache)
    }

    /// Resolve the handoff slot against the incoming plan: adopt the cache when
    /// the adoption policy allows, release it otherwise. Either way the caller
    /// empties the slot — a handoff lives for exactly one load attempt.
    private static func adoptableCache(
        _ handoff: SourceCacheHandoff?,
        budgetBytes: Int,
        inputs: SourceInputs
    ) -> PlaybackSourceCache? {
        guard let handoff else { return nil }
        let adopt = SourceCacheAdoptionPolicy.shouldAdopt(
            handoffFileId: handoff.fileId,
            planFileId: inputs.fileId,
            handoffBudgetBytes: handoff.cache.maxBytes,
            planBudgetBytes: budgetBytes,
            handoffDiskSpill: handoff.cache.diskSpillActive,
            planDiskSpill: PlaybackSourceCache.resolveDiskSpillEnabled(inputs.diskSpillRequested),
            cachedTotalLength: handoff.cache.knownTotalLength,
            expectedFileSize: inputs.expectedFileSize
        )
        guard adopt else {
            Self.logger.info(
                "[CMP-SOURCE-CACHE] handoff rejected fileId=\(handoff.fileId, privacy: .public) planFileId=\(inputs.fileId ?? -1, privacy: .public)"
            )
            return nil
        }
        Self.logger.info(
            "[CMP-SOURCE-CACHE] handoff adopted fileId=\(handoff.fileId, privacy: .public) cachedBytes=\(handoff.cache.stats().cachedBytes, privacy: .public)"
        )
        return handoff.cache
    }

    /// Whether this plan runs behind the source proxy at all.
    ///
    /// Loopback included: the proxy exists to give the segment writer a cached,
    /// resumable HTTP origin, and a local `file://` source (offline downloads)
    /// needs neither — it is already seekable on disk and
    /// `LoopbackSegmentWriter` opens the path directly.
    static func usesSourceProxy(for plan: PlaybackExecutionPlan) -> Bool {
        plan.delivery == .direct
            && plan.engine != .avPlayerHLS
            && ["http", "https"].contains(plan.sourceStreamRequest.url.scheme?.lowercased())
    }

    /// `PlayerViewModel.prepareSourceProxy`, moved. Builds (or declines to
    /// build) the source proxy for a plan and rewrites the plan to point at it.
    static func prepareSource(
        for plan: PlaybackExecutionPlan,
        handoff: SourceCacheHandoff?,
        inputs: SourceInputs,
        onPlaybackSessionMissing: @escaping () -> Void,
        onPlaybackSourceInterrupted: @escaping (PlaybackSourceInterruptionReason) -> Void,
        onOriginOutageChanged: @escaping (Bool) -> Void
    ) async throws -> SourcePreparation {
        guard usesSourceProxy(for: plan) else {
            // This load runs without a proxy, so any stashed cache has no
            // adopter — the caller releases it rather than hold its disk spans
            // for the rest of playback. The plan travels through unproxied,
            // still pointing at the file.
            return SourcePreparation(plan: plan, proxy: nil)
        }
        let cacheBudget = sourceCacheBudget(for: plan, nominalBitrateBps: inputs.nominalBitrateBps)
        let cache = adoptableCache(handoff, budgetBytes: cacheBudget, inputs: inputs)
            ?? PlaybackSourceCache(
                maxBytes: cacheBudget,
                diskSpillEnabled: inputs.diskSpillRequested
            )
        let serverAdvertisesDirectStreamResume = plan.serverFeatures.contains(
            PlaybackProtocolV3.directStreamResumeFeature
        )
        let resumeCapable = plan.supportsDirectStreamResume
        let proxy = PlaybackSourceProxy(
            originURL: plan.sourceStreamRequest.url,
            originHeaders: plan.sourceStreamRequest.headers,
            cache: cache,
            onPlaybackSessionMissing: onPlaybackSessionMissing,
            onPlaybackSourceInterrupted: onPlaybackSourceInterrupted,
            onOriginOutageChanged: onOriginOutageChanged,
            resumeCapable: resumeCapable,
            serverAdvertisesDirectStreamResume: serverAdvertisesDirectStreamResume
        )
        do {
            try await proxy.start()
            guard let localURL = proxy.localURL else {
                proxy.stop()
                if plan.engine == .siloPlayerLoopback {
                    throw SourcePreparationError.missingLocalURL
                }
                return SourcePreparation(plan: plan, proxy: nil)
            }
            proxy.setSourceBitrate(
                sourceBitrateBps(for: plan, nominalBitrateBps: inputs.nominalBitrateBps)
            )
            // Loopback included: opening the origin stream here overlaps the
            // TCP/TLS connect and slow-start ramp with demuxer spawn, which
            // is a full round trip saved on high-latency links.
            proxy.startPrefetch(
                at: PlaybackSourcePrefetchPolicy.initialOffset(
                    sourceStartTimeSeconds: plan.loopbackSession?.sourceStartTimeSeconds ?? 0,
                    sourceBitrateBps: sourceBitrateBps(
                        for: plan,
                        nominalBitrateBps: inputs.nominalBitrateBps
                    )
                )
            )
            Self.logger.info(
                "[CMP-SOURCE-CACHE] enabled route=\(plan.engine.label, privacy: .public) budgetBytes=\(cacheBudget, privacy: .public) resumeCapable=\(resumeCapable, privacy: .public) serverAdvertisesResume=\(serverAdvertisesDirectStreamResume, privacy: .public)"
            )
            let streamRequest = StreamRequest(
                url: localURL,
                headers: [:],
                serverUrl: plan.streamRequest.serverUrl
            )
            let loopbackSession = plan.loopbackSession.map { session in
                session.withSource(url: localURL, headers: [:])
            }
            let proxiedPlan = PlaybackExecutionPlan(
                delivery: plan.delivery,
                engine: plan.engine,
                startMode: plan.startMode,
                streamRequest: streamRequest,
                sourceStreamRequest: plan.sourceStreamRequest,
                loopbackSession: loopbackSession,
                requirements: plan.requirements,
                parityBlockers: plan.parityBlockers,
                decisionTrace: plan.decisionTrace + ["source_proxy_enabled"],
                degradationWarnings: plan.degradationWarnings,
                reason: plan.reason,
                playbackSessionId: plan.playbackSessionId,
                wireDelivery: plan.wireDelivery,
                serverFeatures: plan.serverFeatures,
                sourceMetadata: plan.sourceMetadata,
                normalizationSummary: plan.normalizationSummary,
                validationClaims: plan.validationClaims
            )
            if plan.engine == .siloPlayerLoopback, loopbackSession == nil {
                proxy.stop()
                throw SourcePreparationError.missingLoopbackSession
            }
            return SourcePreparation(plan: proxiedPlan, proxy: proxy)
        } catch {
            proxy.stop()
            if plan.engine == .siloPlayerLoopback {
                Self.logger.info("[CMP-SOURCE-CACHE] required proxy failed route=\(plan.engine.label, privacy: .public) error=\(String(describing: error), privacy: .public)")
                throw error
            }
            Self.logger.info("[CMP-SOURCE-CACHE] proxy unavailable; continuing without source cache error=\(String(describing: error), privacy: .public)")
            return SourcePreparation(plan: plan, proxy: nil)
        }
    }

    static func sourceCacheBudget(
        for plan: PlaybackExecutionPlan,
        nominalBitrateBps: Double?
    ) -> Int {
        switch plan.engine {
        case .siloPlayerLoopback:
            return PlaybackSourceCache.siloLoopbackMemoryBudgetBytes
        case .avPlayerNativeDirect, .avPlayerHLS:
            let bitrate = sourceBitrateBps(for: plan, nominalBitrateBps: nominalBitrateBps)
            if let bps = bitrate, bps >= 200_000_000 {
                if PlaybackSourceCache.isConstrainedMemoryDevice {
                    return PlaybackSourceCache.siloLoopbackMemoryBudgetBytes
                }
                return 512 * 1024 * 1024
            }
            if let bps = bitrate, bps >= 80_000_000 {
                if PlaybackSourceCache.isConstrainedMemoryDevice {
                    return 192 * 1024 * 1024
                }
                return PlaybackSourceCache.siloLoopbackMemoryBudgetBytes
            }
            return PlaybackSourceCache.defaultMemoryBudgetBytes
        }
    }

    static func sourceBitrateBps(
        for plan: PlaybackExecutionPlan,
        nominalBitrateBps: Double?
    ) -> Double? {
        if let bps = plan.loopbackSession?.sourceBitrateBps {
            return bps
        }
        return nominalBitrateBps
    }
}
