import AetherEngine
import Foundation
import OSLog

@Observable
@MainActor
final class AudioPlayerViewModel {
    private let api: SiloAPI
    private struct StartedAudioSession {
        let session: PlaybackSessionResponse
        let authority: PlaybackV2SessionAuthority
        let track: AudioPlaybackTrack
        let streamHeaders: [String: String]
        let timeline: PlaybackTimelineMapper
    }

    private let engine = AetherAudioPlaybackController()
    private let nowPlaying = AudioNowPlayingCoordinator()
    private var syncTask: Task<Void, Never>?
    private var activeTrackIndex: Int?
    /// Standard playback session for the file currently loaded in the
    /// engine. Audiobooks get one session per file; crossing a part
    /// boundary retires this session and starts a fresh one.
    private var activeSession: PlaybackSessionResponse?
    /// The owner and installation `activeSession` was started under; its
    /// progress and stop run under them and nothing else.
    private var activeAuthority: PlaybackV2SessionAuthority?
    /// Sequences the session-local progress samples of each server session.
    private var progressSequence = PlaybackProgressSequence()
    /// Converts Aether's player axis to the active file's source axis and
    /// determines whether a seek can stay within the current V3 transport.
    private var activeTimeline: PlaybackTimelineMapper?
    private var loadingEngineEpoch: AetherAudioPlaybackController.LoadEpoch?
    private var activeEngineEpoch: AetherAudioPlaybackController.LoadEpoch?
    /// Invalidates an in-flight track load when the user seeks again or
    /// closes the player while `/playback/start` is still on the wire.
    private var loadGeneration = 0
    /// Serializes `start(contentId:)` requests: bumped before the
    /// item-detail load so a slower, older start cannot overwrite the
    /// context of a newer book that superseded it. Kept separate from
    /// `loadGeneration`, which fences seeks and per-file session loads.
    private var startGeneration = 0
    /// Where the latest requested seek will land while its load is still in
    /// flight. Relative skips build on it so quick repeated presses add up.
    private var pendingSeekTarget: Double?
    /// Identifies the seek that owns `pendingSeekTarget`. A seek that ends
    /// (loaded, failed, or superseded by a non-seek load such as an
    /// automatic part advance) releases the target only if no newer seek
    /// has claimed it.
    private var seekSequence = 0
    /// Profile-wide audiobook skip intervals, read at each press so a change
    /// applies without restarting the book.
    let seekIntervalPreferences = SeekIntervalPreferences.shared
    @ObservationIgnored private var isObservingSeekIntervals = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Playback"
    )

    private(set) var context: AudiobookPlaybackContext?
    /// The book opened from its download without the server: every part
    /// plays from disk and progress waits in the offline queue.
    private(set) var isOfflineSession = false
    /// The download scope active when the book started. When the book is
    /// downloaded, by then or during playback, its local resume point and
    /// offline queue are written there, and only while that scope is still
    /// loaded.
    private var progressScopeOwner: DownloadManager.ProgressOwner?
    /// Downloaded files that failed to open in this session; their parts
    /// stream instead of failing again on every seek.
    private var unopenableLocalFileIds: Set<Int> = []
    /// When each book's latest recorded position was sampled. An upload that
    /// answers late must not record its older position over a newer one;
    /// kept across sessions, since a close's save can race the last tick's.
    private var latestRecordedSample: [String: Date] = [:]
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    /// The playhead, updated on every ~10 Hz clock tick. Read it only in
    /// small views that render the time, such as the scrubber.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Typed Aether state remains the transport source of truth. The UI's
    /// play/pause affordances derive from this value instead of optimistic
    /// booleans written by button handlers.
    private(set) var engineState: PlaybackState = .idle
    /// The chapter the playhead is currently inside, if any. Written only when
    /// the playhead crosses into another chapter, so readers do not re-render
    /// on every engine time tick.
    private(set) var currentChapter: AudioPlaybackChapter?
    /// Cover-derived colors for the player backdrop and control tint.
    /// Stays on `.fallback` until sampling resolves so the UI never
    /// blocks on image work.
    private(set) var palette: AudioCoverPalette = .fallback
    /// The caller's preview of the book being started, shown until the
    /// session's own context arrives. Nil once `start` finishes.
    private(set) var loadingPreview: AudioPlaybackPreview?

    static let availableRates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var playbackRate: Double = 1.0
    let sleepTimer = SleepTimer()

    var hasActiveSession: Bool { context != nil }
    var isPlaying: Bool {
        switch engineState {
        case .playing, .seeking:
            true
        case .idle, .loading, .paused, .ended, .error:
            false
        }
    }
    var title: String { context?.title ?? loadingPreview?.title ?? "" }
    var subtitle: String? { context?.subtitle ?? loadingPreview?.subtitle }
    var posterUrl: String? { context?.posterUrl ?? loadingPreview?.posterUrl }
    /// Sorted by start time; `AudiobookPlaybackContext` sorts them once.
    var chapters: [AudioPlaybackChapter] { context?.chapters ?? [] }

    /// The intervals the audiobook controls use right now.
    var skipIntervals: SeekIntervalPair {
        seekIntervalPreferences.pair(for: .audiobook)
    }

    init(api: SiloAPI = .shared) {
        self.api = api
        engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }
        sleepTimer.configure { [weak self] in
            self?.pause()
        }
    }

    func start(
        contentId: String,
        restart: Bool = false,
        startPosition: Double? = nil,
        libraryId: Int? = nil,
        preview: AudioPlaybackPreview? = nil
    ) async {
        startGeneration += 1
        let generation = startGeneration
        isLoading = true
        loadingPreview = preview?.contentId == contentId ? preview : nil
        error = nil
        pendingSeekTarget = nil
        Task { await seekIntervalPreferences.refresh() }
        do {
            // No AVAudioSession setup here: AetherEngine declares the category
            // (.playback/.moviePlayback, multichannel, off-main) at init and activates it
            // on its audio paths. See the AetherEngine README, "Who owns the audio session".
            if context != nil {
                await closePlayback()
            }
            guard generation == startGeneration else { return }
            if let loadingPreview {
                loadPreviewPalette(posterUrl: loadingPreview.posterUrl, generation: generation)
            }
            let downloads = DownloadManager.shared
            let download = Self.playableDownload(contentId: contentId, in: downloads)
            let progressOwner = downloads.progressOwner()
            let context: AudiobookPlaybackContext
            var opensOffline = false
            if let download, !ConnectionMonitor.shared.isServerReachable {
                // No server to ask: open the download directly instead of
                // waiting for the detail request to time out.
                context = try await offlineContext(for: download)
                opensOffline = true
            } else {
                do {
                    context = try await onlineContext(contentId: contentId, libraryId: libraryId,
                                                      hasDownload: download != nil)
                } catch {
                    guard let download, generation == startGeneration,
                          !Task.isCancelled, !Self.isCancellation(error) else { throw error }
                    context = try await offlineContext(for: download)
                    opensOffline = true
                }
            }
            guard generation == startGeneration else {
                // A newer start() superseded this request while the context
                // loaded; abandon it so the older, slower result cannot
                // overwrite the newer book's context.
                return
            }
            self.context = context
            isOfflineSession = opensOffline
            progressScopeOwner = progressOwner
            duration = context.totalDurationSeconds
            setPlayhead(clampGlobal(startPosition ?? (restart ? 0 : context.resumePositionSeconds)))
            loadPalette(posterUrl: context.posterUrl)
            let artwork = await resolvedURL(context.posterUrl)
            guard generation == startGeneration else { return }
            if let artwork {
                nowPlaying.setArtworkURL(artwork)
            }
            try await loadTrack(at: currentTime, autoplay: true)
            guard generation == startGeneration else { return }
            startSyncLoop()
        } catch is CancellationError {
            // A newer start/seek/close owns the player now.
        } catch {
            if generation == startGeneration {
                handlePlaybackError(error)
                resetSessionState()
            }
        }
        if generation == startGeneration {
            isLoading = false
            loadingPreview = nil
        }
    }

    func play() {
        guard context != nil else { return }
        // Resuming is media starting again: a running speed test stops.
        BandwidthProbeScheduler.shared.playbackStarting()
        engine.setRate(playbackRate, shouldResume: true)
        pushNowPlaying()
    }

    func pause() {
        guard context != nil else { return }
        engine.pause()
        pushNowPlaying()
        Task { await syncNow() }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to globalTime: Double) {
        guard context != nil else { return }
        let target = clampGlobal(globalTime)
        seekSequence += 1
        let sequence = seekSequence
        pendingSeekTarget = target
        Task {
            do {
                try await loadTrack(at: target, autoplay: isPlaying)
                releasePendingSeek(sequence)
                await syncNow()
            } catch is CancellationError {
                // A newer seek keeps its own target. Anything else that
                // superseded this load (close, an automatic part advance)
                // abandoned the target, so later skips must start from the
                // playhead again.
                releasePendingSeek(sequence)
                return
            } catch {
                releasePendingSeek(sequence)
                handlePlaybackError(error)
            }
        }
    }

    private func releasePendingSeek(_ sequence: Int) {
        if seekSequence == sequence { pendingSeekTarget = nil }
    }

    /// Relative skip by signed seconds, measured from the latest requested
    /// target rather than a playhead that has not caught up yet.
    func skip(by seconds: Double) {
        guard context != nil else { return }
        seek(to: RelativeSeek.target(
            current: currentTime,
            pending: pendingSeekTarget,
            delta: seconds,
            duration: duration
        ))
    }

    func skipBackward() {
        skip(by: -Double(skipIntervals.backward))
    }

    func skipForward() {
        skip(by: Double(skipIntervals.forward))
    }

    func jumpToChapter(_ chapter: AudioPlaybackChapter) {
        seek(to: chapter.startSeconds)
    }

    func previousChapter() {
        if let chapter = chapters.last(where: { $0.startSeconds < currentTime - 5 }) {
            jumpToChapter(chapter)
        } else {
            seek(to: 0)
        }
    }

    func nextChapter() {
        if let chapter = chapters.first(where: { $0.startSeconds > currentTime + 1 }) {
            jumpToChapter(chapter)
        }
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.5), 3.0)
        engine.setRate(playbackRate, shouldResume: isPlaying)
        pushNowPlaying()
    }

    func close() async {
        startGeneration += 1
        isLoading = false
        loadingPreview = nil
        await closePlayback()
    }

    private func closePlayback() async {
        let closedContext = context
        let closedSession = activeSession
        let closedAuthority = activeAuthority
        let position = currentTime
        let total = duration
        let scopeOwner = currentProgressScopeOwner()
        let sampledAt = Date()
        resetSessionState()
        if let closedContext {
            let auth = await TokenStore.shared.captureOrdinaryRequestAuth()
            await saveBookPosition(
                contentId: closedContext.contentId,
                position: position,
                duration: total,
                sampledAt: sampledAt,
                scopeOwner: scopeOwner,
                auth: auth,
                label: "final audiobook sync" // i18n-ignore: log label
            )
        }
        if let closedSession, let closedAuthority {
            await stopPlaybackSession(closedSession, authority: closedAuthority, reason: "audio player closed")
        }
    }

    /// Stops the engine and returns every piece of session state to idle.
    /// Uploads no progress and stops no server session; `closePlayback`
    /// does both with the values it captured beforehand.
    private func resetSessionState() {
        syncTask?.cancel()
        syncTask = nil
        loadGeneration += 1
        pendingSeekTarget = nil
        loadingEngineEpoch = nil
        activeEngineEpoch = nil
        engine.stop()
        nowPlaying.detach()
        sleepTimer.cancel()
        context = nil
        isOfflineSession = false
        progressScopeOwner = nil
        unopenableLocalFileIds = []
        activeSession = nil
        activeAuthority = nil
        activeTrackIndex = nil
        activeTimeline = nil
        engineState = .idle
        currentTime = 0
        currentChapter = nil
        duration = 0
        palette = .fallback
    }

    private func loadTrack(at globalTime: Double, autoplay: Bool) async throws {
        guard let context,
              let index = AudioPlaybackTimeline.trackIndex(at: globalTime, tracks: context.tracks),
              let track = context.tracks.first(where: { $0.index == index }) else {
            throw APIError.unsupportedMedia(AppLanguage.string(.audiobookErrorNoPlayableTrack))
        }
        loadGeneration += 1
        let generation = loadGeneration
        let localTime = AudioPlaybackTimeline.localTime(for: globalTime, in: track)
        var resolvedGlobalTime = globalTime
        var didLoadNewTrack = false

        var requiresNewSession = true
        // A downloaded part has no server session; its timeline and engine
        // epoch are enough to seek inside it.
        if activeTrackIndex == index,
           let activeTimeline,
           let activeEngineEpoch {
            switch activeTimeline.seekDisposition(forSourceTime: localTime) {
            case .local(let playerSeconds):
                try await engine.seek(to: playerSeconds, epoch: activeEngineEpoch)
                try requireCurrentLoad(generation)
                requiresNewSession = false
            case .replan:
                break
            }
        }

        if requiresNewSession, let localURL = localFileURL(for: track) {
            do {
                try await loadLocalTrack(track, url: localURL, localTime: localTime, generation: generation)
                resolvedGlobalTime = AudioPlaybackTimeline.globalTime(for: localTime, in: track)
                didLoadNewTrack = true
                requiresNewSession = false
            } catch {
                // Superseded, or nothing else to play: report it. Online, a
                // copy that won't open is streamed instead.
                guard !isOfflineSession, !Self.isCancellation(error), generation == loadGeneration else { throw error }
                unopenableLocalFileIds.insert(track.fileId)
                logger.warning(
                    "downloaded audiobook part failed to open; streaming it: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        } else if requiresNewSession, isOfflineSession {
            // Opened without the server, and the file is gone (deleted or
            // replaced since): there is nothing to stream from.
            throw OfflinePlaybackError.mediaFileMissing
        }

        if requiresNewSession {
            // Keep the committed session/epoch installed while the next part
            // is negotiated. A start failure occurs before Aether is touched,
            // so the current part can remain the active truth instead of being
            // retired speculatively.
            let priorSession = activeSession
            let priorAuthority = activeAuthority
            let started = try await startSession(for: track, localTime: localTime)
            var candidateEngineEpoch: AetherAudioPlaybackController.LoadEpoch?
            do {
                try requireCurrentLoad(generation)
                guard let streamRequest = await makeStreamRequest(
                    session: started.session,
                    additionalHeaders: started.streamHeaders
                ) else {
                    throw APIError.unsupportedMedia(AppLanguage.string(.audiobookErrorNoPlayableTrack))
                }
                try requireCurrentLoad(generation)
                let engineEpoch = engine.beginLoad()
                candidateEngineEpoch = engineEpoch
                loadingEngineEpoch = engineEpoch
                try await engine.finishLoad(
                    engineEpoch,
                    url: streamRequest.url,
                    headers: streamRequest.headers,
                    startSeconds: started.timeline.aetherStartPosition
                )
                try requireCurrentLoad(generation)
                guard loadingEngineEpoch == engineEpoch,
                      engine.activeLoadEpoch == engineEpoch else {
                    throw CancellationError()
                }

                // Promote the candidate only after Aether has accepted the
                // source. A failed or superseded load therefore cannot leave
                // a ghost server session installed as the active track.
                loadingEngineEpoch = nil
                activeEngineEpoch = engineEpoch
                activeSession = started.session
                activeAuthority = started.authority
                activeTrackIndex = started.track.index
                activeTimeline = started.timeline
                resolvedGlobalTime =
                    started.track.startOffsetSeconds
                        + started.timeline.sourcePosition(
                            forPlayerTime: started.session.position
                        )
                didLoadNewTrack = true
                if let priorSession, let priorAuthority,
                   priorSession.sessionId != started.session.sessionId {
                    Task { [weak self] in
                        await self?.stopPlaybackSession(
                            priorSession,
                            authority: priorAuthority,
                            reason: "successor audio track committed"
                        )
                    }
                }
            } catch {
                if let candidateEngineEpoch,
                   engine.activeLoadEpoch == candidateEngineEpoch {
                    engine.stop()
                }
                if loadingEngineEpoch == candidateEngineEpoch {
                    loadingEngineEpoch = nil
                }
                await stopPlaybackSession(
                    started.session,
                    authority: started.authority,
                    reason: "candidate audio load did not become active"
                )
                // `AetherEngine.load` replaces the prior media before it probes
                // the candidate, so once `beginLoad()` has run the old engine
                // epoch can no longer resume and its session must be retired.
                // Before that point the prior Aether load is untouched: if a
                // newer seek superseded this one it is still playing against
                // `priorSession`, so leave that session alive and let the newer
                // load own it. Only when this load is still the current one —
                // and therefore tears the player down below — does the prior
                // session have to be released here.
                let candidateReplacedEngineMedia = candidateEngineEpoch != nil
                let failureTearsDownPlayer = generation == loadGeneration
                if let priorSession, let priorAuthority,
                   priorSession.sessionId != started.session.sessionId,
                   candidateReplacedEngineMedia || failureTearsDownPlayer {
                    await stopPlaybackSession(
                        priorSession,
                        authority: priorAuthority,
                        reason: candidateReplacedEngineMedia
                            ? "audio successor load failed after replacing prior media"
                            : "audio successor load failed before touching prior media"
                    )
                }
                resetEngineAfterLoadFailure(ifCurrent: generation)
                throw error
            }
        }

        try requireCurrentLoad(generation)
        setPlayhead(clampGlobal(resolvedGlobalTime))
        if didLoadNewTrack {
            attachNowPlaying()
        }
        if autoplay {
            engine.setRate(playbackRate, shouldResume: true)
        }
        pushNowPlaying()
    }

    private func resetEngineAfterLoadFailure(ifCurrent generation: Int) {
        guard generation == loadGeneration else { return }
        loadingEngineEpoch = nil
        activeEngineEpoch = nil
        engine.stop()
        activeSession = nil
        activeAuthority = nil
        activeTrackIndex = nil
        activeTimeline = nil
        nowPlaying.detach()
    }

    private func startSession(
        for track: AudioPlaybackTrack,
        localTime: Double
    ) async throws -> StartedAudioSession {
        // Every request of this session runs for the owner captured here.
        guard let owner = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profileId = owner.profileId,
              !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlaybackV3TerminalFailure(
                reason: "profile_required",
                message: "Select a profile before starting playback.", // i18n-ignore: English data (D44)
                retryable: false,
                displayMessage: AppLanguage.string(.playerErrorSelectProfile)
            )
        }

        // A running bandwidth probe stops so it cannot slow the start.
        BandwidthProbeScheduler.shared.playbackStarting()
        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        // A start refused because the server's playback installation changed
        // runs once more with the refreshed capability and a new attempt id.
        let (playbackAttemptId, authority, response) = try await PlaybackV3CapabilityGate.shared.withInstallationRefresh { capability in
            let authority = PlaybackV2SessionAuthority(owner: owner, installationID: capability.installationID)
            let playbackAttemptId = "apple-audio:\(UUID().uuidString.lowercased())"
            // Audiobook resume is a whole-item timeline stitched across files.
            // The server keeps session-local progress for liveness, while the
            // client owns durable resume/history through /sync/progress, so the
            // start sends progress_persistence "client".
            let request = PlaybackV3StartRequest(
                protocolVersion: PlaybackProtocolV3.version,
                clientFeatures: ApplePlaybackV3Capabilities.audiobookFeatures,
                fileId: track.fileId,
                profileId: profileId,
                playbackAttemptId: playbackAttemptId,
                qualityPreference: ApplePlaybackQuality.autoId,
                subtitleFidelityPreference: "preserve",
                progressPersistence: "client",
                startPosition: localTime.isFinite ? max(0, localTime) : 0,
                audioTrackId: nil,
                audioTrackIndex: nil,
                subtitleTrackId: nil,
                subtitleTrackIndex: nil,
                metered: false,
                bandwidthEstimateKbps: nil,
                bandwidthCapKbps: nil,
                clientCapabilities: snapshot.capabilities,
                clientPlaybackContext: snapshot.context
            )
            // One identical resend after a transport failure: the server
            // replays the attempt instead of starting it twice.
            return (playbackAttemptId, authority, try await authority.start(request))
        }

        switch response.validatedForApple() {
        case .terminal(let terminal):
            Task {
                await PlaybackSessionBridge.reportTerminalStart(
                    playbackAttemptId: playbackAttemptId,
                    snapshot: snapshot,
                    terminal: terminal,
                    authority: authority
                )
            }
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            if let allocatedSessionId {
                _ = try? await authority.stop(allocatedSessionId, finalSample: nil)
            }
            throw PlaybackV3TerminalFailure(
                reason: "invalid_playback_plan",
                message: "The server returned an incompatible protocol V3 playback plan.", // i18n-ignore: English data (D44)
                retryable: false,
                displayMessage: AppLanguage.string(.playerErrorIncompatiblePlan)
            )
        case .playable(let plan, let sessionId):
            guard response.serverFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ) else {
                _ = try? await authority.stop(sessionId, finalSample: nil)
                throw PlaybackV3TerminalFailure(
                    reason: "server_upgrade_required",
                    message: "This server did not honor authenticated media transport for the playback plan.", // i18n-ignore: English data (D44)
                    retryable: false,
                    displayMessage: AppLanguage.string(.playerErrorUnauthenticatedTransport)
                )
            }
            let timeline: PlaybackTimelineMapper
            do {
                try ApplePlaybackV3PlanAdapter.validate(plan)
                timeline = try PlaybackTimelineMapper(validating: plan.timeline)
            } catch {
                _ = try? await authority.stop(sessionId, finalSample: nil)
                throw error
            }
            guard let effectiveTrack = context?.tracks.first(where: {
                $0.fileId == plan.effectiveMediaFileId
            }), let effectiveVersion = effectiveTrack.version else {
                _ = try? await authority.stop(sessionId, finalSample: nil)
                throw PlaybackV3TerminalFailure(
                    reason: "effective_file_unavailable",
                    message: "The server selected an unavailable audiobook part.", // i18n-ignore: English data (D44)
                    retryable: false,
                    displayMessage: AppLanguage.string(.audiobookErrorUnavailablePart)
                )
            }
            let session = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: plan,
                sessionId: sessionId,
                selectedVersion: effectiveVersion,
                serverFeatures: response.serverFeatures
            )
            return StartedAudioSession(
                session: session,
                authority: authority,
                track: effectiveTrack,
                streamHeaders: plan.stream.headers,
                timeline: timeline
            )
        }
    }

    /// Tints the player from the preview cover while the session loads, so
    /// the background does not jump from the fallback once playback starts.
    private func loadPreviewPalette(posterUrl: String?, generation: Int) {
        Task { [weak self] in
            guard let sampled = await AudioCoverPaletteSampler.palette(for: posterUrl) else { return }
            guard let self, generation == self.startGeneration, self.context == nil else { return }
            self.palette = sampled
        }
    }

    private func loadPalette(posterUrl: String?) {
        let contentId = context?.contentId
        Task { [weak self] in
            guard let sampled = await AudioCoverPaletteSampler.palette(for: posterUrl) else { return }
            guard let self, self.context?.contentId == contentId else { return }
            self.palette = sampled
        }
    }

    private func requireCurrentLoad(_ generation: Int) throws {
        guard !Task.isCancelled, generation == loadGeneration, context != nil else {
            throw CancellationError()
        }
    }

    private func stopPlaybackSession(
        _ session: PlaybackSessionResponse,
        authority: PlaybackV2SessionAuthority,
        reason: String
    ) async {
        progressSequence.forget(session.sessionId)
        do {
            try await authority.stop(session.sessionId, finalSample: nil)
        } catch {
            logger.warning(
                "stopPlayback failed for \(session.sessionId, privacy: .public) (\(reason, privacy: .public)): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }

    private func handleEngineEvent(_ scopedEvent: AetherAudioPlaybackController.ScopedEvent) {
        let isLoadingEpoch = scopedEvent.epoch == loadingEngineEpoch
        let isActiveEpoch = scopedEvent.epoch == activeEngineEpoch
        guard isLoadingEpoch || isActiveEpoch else { return }
        switch scopedEvent.event {
        case .state(let state):
            let reachedEnd = isActiveEpoch && state == .ended && engineState != .ended
            engineState = state
            if reachedEnd {
                let generation = loadGeneration
                Task { [weak self] in
                    await self?.advanceAfterTrackEnd(expectedGeneration: generation)
                }
            }
            pushNowPlaying()
        case .time(let localTime):
            if isActiveEpoch {
                handleEngineTime(localTime)
            }
        case .failure(let failure):
            if isActiveEpoch, let failure {
                handlePlaybackFailure(failure)
            }
        }
    }

    private func handlePlaybackFailure(_ failure: PlaybackErrorInfo) {
        let domain = failure.underlyingDomain ?? "AetherEngine.\(failure.kind.rawValue)"
        let error = NSError(
            domain: domain,
            code: failure.underlyingCode ?? 1,
            userInfo: [NSLocalizedDescriptionKey: failure.message]
        )
        handlePlaybackError(error)
    }

    private func handlePlaybackError(_ error: Error) {
        self.error = ErrorState(error)
        pushNowPlaying()
    }

    private func handleEngineTime(_ localTime: Double) {
        guard let context,
              let activeTrackIndex,
              let activeTimeline,
              let track = context.tracks.first(where: { $0.index == activeTrackIndex }) else { return }
        setPlayhead(clampGlobal(
            AudioPlaybackTimeline.globalTime(
                for: activeTimeline.sourcePosition(forPlayerTime: localTime),
                in: track
            )
        ))
        // A tick only advances the playhead, which the system extrapolates
        // from the published rate, so the coordinator republishes it at most
        // every couple of seconds. Transport changes still publish at once.
        nowPlaying.updatePlayhead(position: currentTime)
    }

    /// Moves the playhead, replacing `currentChapter` only when the playhead
    /// lands in a different chapter.
    private func setPlayhead(_ globalTime: Double) {
        currentTime = globalTime
        let chapter = AudioPlaybackTimeline.chapter(at: globalTime, in: chapters)
        if chapter != currentChapter {
            currentChapter = chapter
        }
    }

    private func advanceAfterTrackEnd(expectedGeneration: Int) async {
        guard expectedGeneration == loadGeneration else { return }
        guard let context,
              let activeTrackIndex,
              let current = context.tracks.first(where: { $0.index == activeTrackIndex }) else { return }
        let nextStart = current.startOffsetSeconds + current.durationSeconds + 0.01
        if AudioPlaybackTimeline.trackIndex(at: nextStart, tracks: context.tracks) != activeTrackIndex,
           nextStart < duration {
            // The advance replaces any in-flight seek load, so that seek's
            // target no longer describes where playback is heading.
            pendingSeekTarget = nil
            do {
                try await loadTrack(at: nextStart, autoplay: true)
            } catch is CancellationError {
                return
            } catch {
                handlePlaybackError(error)
            }
        } else {
            setPlayhead(duration)
            pushNowPlaying()
            await syncNow()
        }
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                await self?.syncNow()
            }
        }
    }

    /// Two progress sinks, mirroring the web player: the playback session
    /// gets the file-local position (admin activity + session keepalive;
    /// never persisted because the session started with
    /// `disable_progress_persistence`), and `/sync/progress` gets the
    /// whole-book position that powers resume and Continue Listening.
    private func syncNow() async {
        guard let context else { return }
        // The whole-book sample and the identity it uploads under are taken
        // before any await, so a newer start or a profile switch while the
        // session sample is on the wire can't mix into it.
        let contentId = context.contentId
        let position = currentTime
        let total = duration
        let sampledAt = Date()
        let scopeOwner = currentProgressScopeOwner()
        let auth = await TokenStore.shared.captureOrdinaryRequestAuth()
        if let session = activeSession,
           let authority = activeAuthority,
           let activeTrackIndex,
           let track = context.tracks.first(where: { $0.index == activeTrackIndex }) {
            do {
                let sample = try PlaybackSequencedSample(
                    sequence: progressSequence.next(for: session.sessionId),
                    position: AudioPlaybackTimeline.localTime(for: currentTime, in: track),
                    isPaused: !isPlaying
                )
                _ = try await SiloAPI.shared.apiV2Client.updatePlaybackProgress(
                    sessionID: session.sessionId,
                    sample: sample,
                    installationID: authority.installationID,
                    auth: authority.owner
                )
            } catch {
                logger.warning(
                    "playback progress failed for session \(session.sessionId, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }
        await saveBookPosition(
            contentId: contentId,
            position: position,
            duration: total,
            sampledAt: sampledAt,
            scopeOwner: scopeOwner,
            auth: auth,
            label: "audiobook progress sync" // i18n-ignore: log label
        )
    }

    /// Uploads the whole-book position through `POST /api/v2/sync/progress`,
    /// the only durable resume point for an audiobook. Each call is a new
    /// write of the current position: a failed or unanswered upload is never
    /// re-sent, and the next periodic sync or close carries a fresh value.
    @discardableResult
    private func uploadBookPosition(contentId: String, position: Double, duration: Double,
                                    auth: CapturedOrdinaryRequestAuth?, label: String) async -> Bool {
        guard let auth, let item = SyncProgressItem(
            mediaItemId: contentId,
            position: position,
            duration: duration,
            forceOverwrite: true
        ) else { return false }
        let outcome = await SiloAPI.shared.apiV2Client.syncProgress([item], auth: auth)
        if let failure = outcome.failureSummary {
            logger.warning(
                "\(label, privacy: .public) failed for \(contentId, privacy: .public) at \(position, privacy: .public): \(failure, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func attachNowPlaying() {
        let handlers = AudioNowPlayingCoordinator.Handlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            isPaused: { [weak self] in !(self?.isPlaying ?? false) },
            seek: { [weak self] target in self?.seek(to: target) },
            skip: { [weak self] delta in self?.skip(by: delta) }
        )
        if !isObservingSeekIntervals {
            isObservingSeekIntervals = true
            seekIntervalPreferences.observe(self) { [weak self] in
                self?.syncNowPlayingSkipIntervals()
            }
        }
        syncNowPlayingSkipIntervals()
        #if os(iOS) || os(tvOS)
        nowPlaying.attach(session: engine.audioNowPlayingSession, handlers: handlers)
        #else
        nowPlaying.attach(handlers: handlers)
        #endif
        pushNowPlaying()
    }

    private func syncNowPlayingSkipIntervals() {
        let pair = skipIntervals
        nowPlaying.setPreferredSkipIntervals(
            backward: Double(pair.backward),
            forward: Double(pair.forward)
        )
    }

    private func pushNowPlaying() {
        guard let context else { return }
        nowPlaying.update(
            title: context.title,
            artist: context.subtitle,
            albumTitle: AppLanguage.string(.audiobookPlayerLabel),
            duration: duration,
            position: currentTime,
            isPlaying: isPlaying,
            playbackRate: playbackRate
        )
    }

    private func makeStreamRequest(
        session: PlaybackSessionResponse,
        additionalHeaders: [String: String]
    ) async -> StreamRequest? {
        let serverURL = await SiloAPI.shared.currentServerUrl()
        let accessToken = await SiloAPI.shared.currentAccessToken()
        return StreamRequest.resolve(
            rawURL: session.streamUrl,
            serverURL: serverURL,
            additionalHeaders: additionalHeaders,
            accessToken: accessToken,
            requiresHeaderAuthenticatedMedia: true
        )
    }

    private func resolvedURL(_ raw: String?) async -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        // A downloaded book's cover is a file on this device.
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        let serverUrl = await SiloAPI.shared.currentServerUrl()
        guard !serverUrl.isEmpty else { return nil }
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: base + path)
    }

    // MARK: - Downloaded books

    /// The session's download scope. A book started while the download store
    /// was still loading had none at start; it takes the scope once the store
    /// has loaded. A profile or server switch closes the player, so that is
    /// still the scope playback started in.
    private func currentProgressScopeOwner() -> DownloadManager.ProgressOwner? {
        if progressScopeOwner == nil {
            progressScopeOwner = DownloadManager.shared.progressOwner()
        }
        return progressScopeOwner
    }

    /// Saves the whole-book position sampled at `sampledAt`. A book that is
    /// downloaded now, in the still-loaded `scopeOwner` scope its playback
    /// started in, queues it while the server can't be reached (sent with
    /// that time, so the newest position wins), and when an upload gets no
    /// answer, so it isn't lost when the connection drops mid-book. Once the
    /// server is back, even a book opened offline uploads directly. A
    /// position older than the one already recorded is dropped.
    private func saveBookPosition(contentId: String, position: Double, duration: Double, sampledAt: Date,
                                  scopeOwner: DownloadManager.ProgressOwner?,
                                  auth: CapturedOrdinaryRequestAuth?, label: String) async {
        let completed = AudiobookProgress.isFinished(played: false, position: position, totalDuration: duration)
        let downloads = DownloadManager.shared
        // Decided at each save, so a download that finishes mid-book counts
        // from then on.
        var downloadOwner: DownloadManager.ProgressOwner?
        if let scopeOwner, downloads.isCurrent(scopeOwner),
           Self.playableDownload(contentId: contentId, in: downloads) != nil {
            downloadOwner = scopeOwner
        }
        // Compared only with this device's own sample times, never with the
        // server's clock.
        func isLatest() -> Bool {
            if let latest = latestRecordedSample[contentId], latest > sampledAt { return false }
            latestRecordedSample[contentId] = sampledAt
            return true
        }
        func queue(_ owner: DownloadManager.ProgressOwner) {
            guard isLatest() else { return }
            downloads.recordOfflineProgress(mediaItemId: contentId, position: position, duration: duration,
                                            completed: completed, owner: owner, sampledAt: sampledAt,
                                            latchesCompleted: false)
        }
        if let owner = downloadOwner, !ConnectionMonitor.shared.isServerReachable {
            queue(owner)
            return
        }
        let uploaded = await uploadBookPosition(contentId: contentId, position: position, duration: duration,
                                                auth: auth, label: label)
        guard let owner = downloadOwner else { return }
        if uploaded {
            guard isLatest() else { return }
            downloads.recordLocalProgress(mediaItemId: contentId, position: position, duration: duration,
                                          completed: completed, owner: owner, sampledAt: sampledAt,
                                          latchesCompleted: false)
        } else {
            queue(owner)
        }
    }

    /// The book's completed download, when its file can play: a single
    /// file, saved whole.
    private static func playableDownload(contentId: String, in downloads: DownloadManager) -> DownloadRecord? {
        guard let record = downloads.record(forContentId: contentId),
              record.isAudiobook, record.isPlayableOffline else { return nil }
        return record
    }

    /// The downloaded file for `track`, when the book's download holds that
    /// exact file and it is on disk.
    private func localFileURL(for track: AudioPlaybackTrack) -> URL? {
        guard let context, !unopenableLocalFileIds.contains(track.fileId),
              let record = Self.playableDownload(contentId: context.contentId, in: DownloadManager.shared),
              record.mediaFileId == String(track.fileId),
              let url = DownloadManager.shared.absoluteMediaURL(for: record),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// How long a start waits for listening done offline to reach the
    /// server before reading the server's resume point.
    private static let offlineProgressSyncWait: Duration = .seconds(3)

    /// The book from the server. Listening this device did offline is sent
    /// first, briefly, so the server can keep the newer of it and progress
    /// made elsewhere since; its resume point is then the reconciled one.
    /// When the server didn't apply it (refused, deferred, or not answered in
    /// time), the local resume point wins over the server's, which is older
    /// than this device's unsent listening.
    private func onlineContext(contentId: String, libraryId: Int?, hasDownload: Bool) async throws -> AudiobookPlaybackContext {
        let downloads = DownloadManager.shared
        var localIsNewer = false
        if hasDownload, downloads.hasUnsentProgress(forMediaItemId: contentId) {
            let applied = await downloads.syncUnsentProgress(forMediaItemId: contentId,
                                                             waitingAtMost: Self.offlineProgressSyncWait)
            try Task.checkCancellation()
            localIsNewer = !applied
        }
        var detail = try await api.itemDetail(contentId: contentId, libraryId: libraryId)
        if localIsNewer, downloads.appliedProgressItemIds.contains(contentId) {
            // The send landed while the detail was on its way, which may have
            // read the server before it; read it again rather than let the
            // local position win over progress made elsewhere.
            detail = try await api.itemDetail(contentId: contentId, libraryId: libraryId)
            localIsNewer = false
        }
        guard let context = AudiobookPlaybackContext(detail: detail) else {
            throw APIError.unsupportedMedia(AppLanguage.string(.audiobookErrorNoPlayableTrack))
        }
        if hasDownload { downloads.noteAudiobookAuthor(contentId: contentId, author: context.subtitle) }
        if localIsNewer, let local = downloads.localProgress(forMediaItemId: contentId) {
            return context.resuming(at: AudiobookProgress.playerStartPosition(local.position,
                                                                               totalDuration: context.totalDurationSeconds))
        }
        return context
    }

    /// The book from its download alone: the stored manifest describes the
    /// file, and the local resume point (kept newest-first with the
    /// server's) says where to pick up.
    private func offlineContext(for record: DownloadRecord) async throws -> AudiobookPlaybackContext {
        let downloads = DownloadManager.shared
        guard let manifest = await downloads.loadManifest(for: record) else {
            throw OfflinePlaybackError.manifestUnavailable
        }
        let stored = downloads.localProgress(forMediaItemId: record.contentId)?.position ?? 0
        guard let context = AudiobookPlaybackContext(
            download: record,
            manifest: manifest,
            posterUrl: downloads.posterImageURL(for: record)?.absoluteString,
            resumePositionSeconds: 0
        ) else {
            throw APIError.unsupportedMedia(AppLanguage.string(.audiobookErrorNoPlayableTrack))
        }
        return context.resuming(at: AudiobookProgress.playerStartPosition(stored, totalDuration: context.totalDurationSeconds))
    }

    /// Loads a downloaded part from disk. There is no server session: the
    /// file's own timeline is the part's. Promotes it only once Aether has
    /// accepted the file, and retires the part's previous server session.
    private func loadLocalTrack(_ track: AudioPlaybackTrack, url: URL, localTime: Double, generation: Int) async throws {
        let priorSession = activeSession
        let priorAuthority = activeAuthority
        let timeline = PlaybackTimelineMapper(directStartSeconds: localTime)
        try requireCurrentLoad(generation)
        let engineEpoch = engine.beginLoad()
        loadingEngineEpoch = engineEpoch
        do {
            try await engine.finishLoad(engineEpoch, url: url, headers: [:], startSeconds: timeline.aetherStartPosition)
            try requireCurrentLoad(generation)
            guard loadingEngineEpoch == engineEpoch, engine.activeLoadEpoch == engineEpoch else {
                throw CancellationError()
            }
        } catch {
            if engine.activeLoadEpoch == engineEpoch { engine.stop() }
            if loadingEngineEpoch == engineEpoch { loadingEngineEpoch = nil }
            // `beginLoad()` replaced the prior media, so its session can no
            // longer resume.
            if let priorSession, let priorAuthority {
                await stopPlaybackSession(priorSession, authority: priorAuthority,
                                          reason: "local audio load failed after replacing prior media")
            }
            resetEngineAfterLoadFailure(ifCurrent: generation)
            throw error
        }
        loadingEngineEpoch = nil
        activeEngineEpoch = engineEpoch
        activeSession = nil
        activeAuthority = nil
        activeTrackIndex = track.index
        activeTimeline = timeline
        if let priorSession, let priorAuthority {
            Task { [weak self] in
                await self?.stopPlaybackSession(priorSession, authority: priorAuthority,
                                                reason: "downloaded audio track committed")
            }
        }
    }

    /// A request cancelled because a newer start, seek or close took over.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if case HTTPError.network(let underlying as URLError) = error, underlying.code == .cancelled { return true }
        return false
    }

    private func clampGlobal(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), max(0, duration))
    }
}
