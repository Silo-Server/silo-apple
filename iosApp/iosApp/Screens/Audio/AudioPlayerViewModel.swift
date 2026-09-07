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

    private let mutationCoordinator = PlaybackMutationCoordinator.shared
    private var sequencedSessionIDs: Set<String> = []
    private var manifest: APIv2PlaybackManifest?
    private var manifestAuth: CapturedDurableAccountAuth?
    private var manifestCapability: APIv2PlaybackCapabilities?
    private var transitioning = false
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
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
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
            let captured = try await mutationCoordinator.captureStartAuth()
            guard let owner = captured.durable else { throw PlaybackSequencedError.authorityChanged }
            let detail = try await SiloAPI.shared.itemDetail(contentId: contentId, auth: captured.request)
            guard generation == startGeneration else {
                // A newer start() superseded this request while the
                // item-detail load was in flight; abandon it so the older,
                // slower response cannot overwrite the newer book's context.
                return
            }
            guard let anchor = AudiobookPlaybackContext.audioParts(of: detail).first else {
                throw APIError.unsupportedMedia("No playable audio track is available.")
            }
            let manifest = try await mutationCoordinator.discoverTimeline(fileID: anchor.fileId,
                itemID: contentId, auth: owner, capability: captured.capability)
            guard generation == startGeneration else { return }
            let context = try AudiobookPlaybackContext(detail: detail, manifest: manifest)
            self.manifest = manifest
            manifestAuth = owner
            manifestCapability = captured.capability
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
        guard context != nil, activeSession != nil, !transitioning else { return }
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
        engine.setRate(playbackRate, shouldResume: isPlaying && activeSession != nil && !transitioning)
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
        let localPosition = closedContext?.tracks.first(where: { $0.index == activeTrackIndex }).map {
            AudioPlaybackTimeline.localTime(for: position, in: $0)
        }
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
        manifest = nil
        manifestAuth = nil
        manifestCapability = nil
        if let closedSession {
            do {
                try await stopAllocatedSession(id: closedSession.sessionId, position: localPosition)
            } catch { handlePlaybackError(error) }
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
        guard !transitioning else { throw PlaybackSequencedError.invalidSession }
        transitioning = true
        defer { transitioning = false }
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
            // A successor may allocate only after the old part's exact terminal
            // receipt. Unknown stop leaves the durable barrier in place.
            if let priorSession = activeSession {
                engine.pause()
                let priorTrack = context.tracks.first { $0.index == activeTrackIndex }
                let finalPosition = priorTrack.map { AudioPlaybackTimeline.localTime(for: currentTime, in: $0) }
                activeSession = nil
                activeTrackIndex = nil
                activeTimeline = nil
                activeEngineEpoch = nil
                engine.stop()
                try await stopAllocatedSession(id: priorSession.sessionId, position: finalPosition)
                try requireCurrentLoad(generation)
            }
            let started = try await startSession(for: track, localTime: localTime)
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
        guard let manifest, let capturedPlaybackAuth = manifestAuth,
              let initialCapability = manifestCapability,
              let profileId = capturedPlaybackAuth.request.profileId else {
            throw PlaybackSequencedError.authorityChanged
        }
        let binding = try manifest.binding(fileID: track.fileId)
        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        let playbackAttemptId = "apple-audio:\(UUID().uuidString.lowercased())"
        let request = PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.audiobookFeatures + [APIv2PlaybackManifest.feature],
            fileId: track.fileId,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: ApplePlaybackQuality.autoId,
            subtitleFidelityPreference: "preserve",
            progressPersistence: "client_bound",
            startPosition: localTime.isFinite ? max(0, localTime) : 0,
            audioTrackId: nil,
            audioTrackIndex: nil,
            subtitleTrackId: nil,
            subtitleTrackIndex: nil,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context,
            timelineId: manifest.timelineId
        )
        let response = try await mutationCoordinator.startV2(request: request,
            auth: capturedPlaybackAuth, capability: initialCapability, progressTimeline: binding)

        if let id = PlaybackSessionBridge.allocatedSessionId(in: response) {
            sequencedSessionIDs.insert(id)
        }
        switch response.validatedForApple() {
        case .terminal(let terminal):
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            if let allocatedSessionId {
                try? await stopAllocatedSession(id: allocatedSessionId)
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
                try? await stopAllocatedSession(id: sessionId)
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
                try? await stopAllocatedSession(id: sessionId)
                throw error
            }
            guard let effectiveTrack = context?.tracks.first(where: {
                $0.fileId == plan.effectiveMediaFileId
            }) else {
                try? await stopAllocatedSession(id: sessionId)
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

    private func requireCurrentLoad(_ generation: Int) throws {
        guard !Task.isCancelled, generation == loadGeneration, context != nil else {
            throw CancellationError()
        }
    }

    private func stopAllocatedSession(id: String, position: Double? = nil) async throws {
        guard sequencedSessionIDs.contains(id),
              try await mutationCoordinator.stop(sessionID: id, position: position, isPaused: true) else {
            throw PlaybackV3TerminalFailure(reason: "audiobook_stop_unresolved",
                message: "The previous audiobook part has not confirmed its stop. Resolve pending playback before starting another part.",
                retryable: false)
        }
    }

    private func stopPlaybackSession(
        _ session: PlaybackSessionResponse,
        reason: String
    ) async {
        do {
            try await stopAllocatedSession(id: session.sessionId)
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
        if let next = context.tracks.first(where: { $0.index == current.index + 1 }) {
            let nextStart = next.startOffsetSeconds
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
            if let session = activeSession {
                activeSession = nil
                do { try await stopAllocatedSession(id: session.sessionId, position: current.durationSeconds) }
                catch { handlePlaybackError(error) }
            }
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

    /// The server maps this bound part-local sample to durable item progress.
    private func syncNow() async {
        guard !transitioning, let context, let session = activeSession,
              let track = context.tracks.first(where: { $0.index == activeTrackIndex }) else { return }
        do {
            try await mutationCoordinator.report(sessionID: session.sessionId,
                position: AudioPlaybackTimeline.localTime(for: currentTime, in: track), isPaused: !isPlaying)
        } catch {
            logger.warning("Audiobook progress remains unresolved: \(MediaLogRedactor.sanitize(error), privacy: .public)")
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
        return try? await mutationCoordinator.streamRequest(sessionID: session.sessionId,
            rawURL: session.streamUrl, additionalHeaders: additionalHeaders,
            requiresHeaderAuthenticatedMedia: true)
    }

    private func resolvedURL(_ raw: String?) async -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let serverUrl = await SiloAPI.shared.currentServerUrl()
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
