import AetherEngine
import Foundation
import OSLog

@Observable
@MainActor
final class AudioPlayerViewModel {
    private struct StartedAudioSession {
        let session: PlaybackSessionResponse
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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Playback"
    )

    private(set) var context: AudiobookPlaybackContext?
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Typed Aether state remains the transport source of truth. The UI's
    /// play/pause affordances derive from this value instead of optimistic
    /// booleans written by button handlers.
    private(set) var engineState: PlaybackState = .idle
    private(set) var playbackPhase: PlaybackPhase = .idle
    private(set) var playbackFailure: PlaybackErrorInfo?
    /// Duration of the currently loaded file. `duration` above deliberately
    /// remains the stitched whole-book duration presented by Silo.
    private(set) var engineDuration: Double = 0
    /// Cover-derived colors for the player backdrop and control tint.
    /// Stays on `.fallback` until sampling resolves so the UI never
    /// blocks on image work.
    private(set) var palette: AudioCoverPalette = .fallback

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
    var title: String { context?.title ?? "" }
    var subtitle: String? { context?.subtitle }
    var posterUrl: String? { context?.posterUrl }
    var chapters: [AudioPlaybackChapter] { context?.chapters ?? [] }
    var tracks: [AudioPlaybackTrack] { context?.tracks ?? [] }

    /// The chapter the playhead is currently inside, if any.
    var currentChapter: AudioPlaybackChapter? {
        chapters
            .filter { $0.startSeconds <= currentTime }
            .max { $0.startSeconds < $1.startSeconds }
    }

    init() {
        engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }
        sleepTimer.configure { [weak self] in
            self?.pause()
        }
    }

    func start(contentId: String, restart: Bool = false, startPosition: Double? = nil) async {
        startGeneration += 1
        let generation = startGeneration
        isLoading = true
        error = nil
        do {
            // No AVAudioSession setup here: AetherEngine declares the category
            // (.playback/.moviePlayback, multichannel, off-main) at init and activates it
            // on its audio paths. See the AetherEngine README, "Who owns the audio session".
            if context != nil {
                await closePlayback()
            }
            guard generation == startGeneration else { return }
            let detail = try await ContinuumAPI.shared.itemDetail(contentId: contentId)
            guard generation == startGeneration else {
                // A newer start() superseded this request while the
                // item-detail load was in flight; abandon it so the older,
                // slower response cannot overwrite the newer book's context.
                return
            }
            guard let context = AudiobookPlaybackContext(detail: detail) else {
                throw APIError.unsupportedMedia("No playable audio track is available.")
            }
            self.context = context
            duration = context.totalDurationSeconds
            currentTime = clampGlobal(startPosition ?? (restart ? 0 : context.resumePositionSeconds))
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
                resetFailedStart()
            }
        }
        if generation == startGeneration { isLoading = false }
    }

    func play() {
        guard context != nil else { return }
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
        Task {
            do {
                try await loadTrack(at: clampGlobal(globalTime), autoplay: isPlaying)
                await syncNow()
            } catch is CancellationError {
                return
            } catch {
                handlePlaybackError(error)
            }
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func jumpToChapter(_ chapter: AudioPlaybackChapter) {
        seek(to: chapter.startSeconds)
    }

    func previousChapter() {
        let candidates = chapters
            .filter { $0.startSeconds < currentTime - 5 }
            .sorted { $0.startSeconds < $1.startSeconds }
        if let chapter = candidates.last {
            jumpToChapter(chapter)
        } else {
            seek(to: 0)
        }
    }

    func nextChapter() {
        if let chapter = chapters.sorted(by: { $0.startSeconds < $1.startSeconds })
            .first(where: { $0.startSeconds > currentTime + 1 }) {
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
        await closePlayback()
    }

    private func closePlayback() async {
        syncTask?.cancel()
        syncTask = nil
        loadGeneration += 1
        let closedContext = context
        let closedSession = activeSession
        let position = currentTime
        let total = duration
        loadingEngineEpoch = nil
        activeEngineEpoch = nil
        engine.stop()
        nowPlaying.detach()
        sleepTimer.cancel()
        context = nil
        activeSession = nil
        activeTrackIndex = nil
        activeTimeline = nil
        engineDuration = 0
        engineState = .idle
        playbackPhase = .idle
        playbackFailure = nil
        currentTime = 0
        duration = 0
        palette = .fallback
        if let closedContext {
            do {
                try await ContinuumAPI.shared.syncProgress(
                    mediaItemId: closedContext.contentId,
                    position: position,
                    duration: total,
                    forceOverwrite: true
                )
            } catch {
                logger.warning(
                    "final audiobook sync failed for \(closedContext.contentId, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }
        if let closedSession {
            await stopPlaybackSession(closedSession, reason: "audio player closed")
        }
    }

    private func resetFailedStart() {
        syncTask?.cancel()
        syncTask = nil
        loadGeneration += 1
        loadingEngineEpoch = nil
        activeEngineEpoch = nil
        engine.stop()
        nowPlaying.detach()
        sleepTimer.cancel()
        context = nil
        activeSession = nil
        activeTrackIndex = nil
        activeTimeline = nil
        engineDuration = 0
        engineState = .idle
        playbackPhase = .idle
        playbackFailure = nil
        currentTime = 0
        duration = 0
        palette = .fallback
    }

    private func loadTrack(at globalTime: Double, autoplay: Bool) async throws {
        guard let context,
              let index = AudioPlaybackTimeline.trackIndex(at: globalTime, tracks: context.tracks),
              let track = context.tracks.first(where: { $0.index == index }) else {
            throw APIError.unsupportedMedia("No playable audio track is available.")
        }
        loadGeneration += 1
        let generation = loadGeneration
        let localTime = AudioPlaybackTimeline.localTime(for: globalTime, in: track)
        var resolvedGlobalTime = globalTime
        var didLoadNewTrack = false

        var requiresNewSession = true
        if activeTrackIndex == index,
           activeSession != nil,
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

        if requiresNewSession {
            // Keep the committed session/epoch installed while the next part
            // is negotiated. A start failure occurs before Aether is touched,
            // so the current part can remain the active truth instead of being
            // retired speculatively.
            let priorSession = activeSession
            let started: StartedAudioSession
            do {
                started = try await startSession(for: track, localTime: localTime)
            } catch {
                throw error
            }
            var candidateEngineEpoch: AetherAudioPlaybackController.LoadEpoch?
            do {
                try requireCurrentLoad(generation)
                guard let streamRequest = await makeStreamRequest(
                    session: started.session,
                    additionalHeaders: started.streamHeaders
                ) else {
                    throw APIError.unsupportedMedia("No playable audio track is available.")
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
                activeTrackIndex = started.track.index
                activeTimeline = started.timeline
                resolvedGlobalTime =
                    started.track.startOffsetSeconds
                        + started.timeline.sourcePosition(
                            forPlayerTime: started.session.position
                        )
                didLoadNewTrack = true
                if let priorSession,
                   priorSession.sessionId != started.session.sessionId {
                    Task { [weak self] in
                        await self?.stopPlaybackSession(
                            priorSession,
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
                if let priorSession,
                   priorSession.sessionId != started.session.sessionId,
                   candidateReplacedEngineMedia || failureTearsDownPlayer {
                    await stopPlaybackSession(
                        priorSession,
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
        currentTime = clampGlobal(resolvedGlobalTime)
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
        activeTrackIndex = nil
        activeTimeline = nil
        engineDuration = 0
        nowPlaying.detach()
    }

    private func startSession(
        for track: AudioPlaybackTrack,
        localTime: Double
    ) async throws -> StartedAudioSession {
        try await PlaybackV3CapabilityGate.shared.requireNeutralProtocolV3()
        guard let profileId = await TokenStore.shared.getProfileId(),
              !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlaybackV3TerminalFailure(
                reason: "profile_required",
                message: "Select a profile before starting playback.",
                retryable: false
            )
        }

        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        let playbackAttemptId = "apple-audio:\(UUID().uuidString.lowercased())"
        // Audiobook resume is a whole-item timeline stitched across files.
        // The server keeps session-local progress for liveness, while the
        // client owns durable resume/history through /sync/progress.
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
        let response: PlaybackV3DecisionResponse
        do {
            response = try await ContinuumAPI.shared.startPlaybackV3(request: request)
        } catch let error as HTTPError {
            guard case .network = error else { throw error }
            // Preserve the logical attempt identity across an ambiguous
            // transport retry so the server replays instead of double-starting.
            response = try await ContinuumAPI.shared.startPlaybackV3(request: request)
        }

        switch response.validatedForApple() {
        case .terminal(let terminal):
            Task {
                await PlaybackSessionBridge.reportTerminalStart(
                    playbackAttemptId: playbackAttemptId,
                    snapshot: snapshot,
                    terminal: terminal
                )
            }
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            if let allocatedSessionId {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: allocatedSessionId)
            }
            throw PlaybackV3TerminalFailure(
                reason: "invalid_playback_plan",
                message: "The server returned an incompatible protocol V3 playback plan.",
                retryable: false
            )
        case .playable(let plan, let sessionId):
            guard response.serverFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ) else {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: sessionId)
                throw PlaybackV3TerminalFailure(
                    reason: "server_upgrade_required",
                    message: "This server did not honor authenticated media transport for the playback plan.",
                    retryable: false
                )
            }
            let timeline: PlaybackTimelineMapper
            do {
                try ApplePlaybackV3PlanAdapter.validate(plan)
                timeline = try PlaybackTimelineMapper(validating: plan.timeline)
            } catch {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: sessionId)
                throw error
            }
            guard let effectiveTrack = context?.tracks.first(where: {
                $0.fileId == plan.effectiveMediaFileId
            }) else {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: sessionId)
                throw PlaybackV3TerminalFailure(
                    reason: "effective_file_unavailable",
                    message: "The server selected an unavailable audiobook part.",
                    retryable: false
                )
            }
            let session = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: plan,
                sessionId: sessionId,
                selectedVersion: effectiveTrack.version,
                serverFeatures: response.serverFeatures
            )
            return StartedAudioSession(
                session: session,
                track: effectiveTrack,
                streamHeaders: plan.stream.headers,
                timeline: timeline
            )
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

    private func retireActiveSession() {
        let session = activeSession
        activeSession = nil
        activeTrackIndex = nil
        activeTimeline = nil
        activeEngineEpoch = nil
        guard let session else { return }
        Task { [weak self] in
            await self?.stopPlaybackSession(session, reason: "audio track retired")
        }
    }

    private func requireCurrentLoad(_ generation: Int) throws {
        guard !Task.isCancelled, generation == loadGeneration, context != nil else {
            throw CancellationError()
        }
    }

    private func stopPlaybackSession(
        _ session: PlaybackSessionResponse,
        reason: String
    ) async {
        do {
            try await ContinuumAPI.shared.stopPlayback(sessionId: session.sessionId)
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
        case .phase(let phase):
            playbackPhase = phase
        case .time(let localTime):
            if isActiveEpoch {
                handleEngineTime(localTime)
            }
        case .duration(let duration):
            engineDuration = duration.isFinite ? max(0, duration) : 0
        case .failure(let failure):
            playbackFailure = failure
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
        currentTime = clampGlobal(
            AudioPlaybackTimeline.globalTime(
                for: activeTimeline.sourcePosition(forPlayerTime: localTime),
                in: track
            )
        )
        pushNowPlaying()
    }

    private func advanceAfterTrackEnd(expectedGeneration: Int) async {
        guard expectedGeneration == loadGeneration else { return }
        guard let context,
              let activeTrackIndex,
              let current = context.tracks.first(where: { $0.index == activeTrackIndex }) else { return }
        let nextStart = current.startOffsetSeconds + current.durationSeconds + 0.01
        if AudioPlaybackTimeline.trackIndex(at: nextStart, tracks: context.tracks) != activeTrackIndex,
           nextStart < duration {
            do {
                try await loadTrack(at: nextStart, autoplay: true)
            } catch is CancellationError {
                return
            } catch {
                handlePlaybackError(error)
            }
        } else {
            currentTime = duration
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
        if let session = activeSession,
           let activeTrackIndex,
           let track = context.tracks.first(where: { $0.index == activeTrackIndex }) {
            do {
                try await ContinuumAPI.shared.reportPlaybackProgress(
                    sessionId: session.sessionId,
                    report: ProgressReport(
                        position: AudioPlaybackTimeline.localTime(for: currentTime, in: track),
                        isPaused: !isPlaying
                    )
                )
            } catch {
                logger.warning(
                    "reportPlaybackProgress failed for session \(session.sessionId, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }
        do {
            try await ContinuumAPI.shared.syncProgress(
                mediaItemId: context.contentId,
                position: currentTime,
                duration: duration,
                forceOverwrite: true
            )
        } catch {
            logger.warning(
                "syncProgress failed for \(context.contentId, privacy: .public) at \(self.currentTime, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }

    private func attachNowPlaying() {
        let handlers = AudioNowPlayingCoordinator.Handlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            isPaused: { [weak self] in !(self?.isPlaying ?? false) },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            seek: { [weak self] target in self?.seek(to: target) }
        )
        #if os(iOS) || os(tvOS)
        nowPlaying.attach(session: engine.audioNowPlayingSession, handlers: handlers)
        #else
        nowPlaying.attach(handlers: handlers)
        #endif
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        guard let context else { return }
        nowPlaying.update(
            title: context.title,
            artist: context.subtitle,
            albumTitle: "Audiobook",
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
        let serverURL = await ContinuumAPI.shared.currentServerUrl()
        let accessToken = await ContinuumAPI.shared.currentAccessToken()
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
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let serverUrl = await ContinuumAPI.shared.currentServerUrl()
        guard !serverUrl.isEmpty else { return nil }
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: base + path)
    }

    private func clampGlobal(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), max(0, duration))
    }
}
