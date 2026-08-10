import AVFoundation
import Foundation
import OSLog

@Observable
@MainActor
final class AudioPlayerViewModel {
    private struct StartedAudioSession {
        let session: PlaybackSessionResponse
        let track: AudioPlaybackTrack
        let streamHeaders: [String: String]
    }

    private let engine = AudioPlayerEngine()
    private let nowPlaying = NowPlayingController()
    private var syncTask: Task<Void, Never>?
    private var activeTrackIndex: Int?
    /// Standard playback session for the file currently loaded in the
    /// engine. Audiobooks get one session per file; crossing a part
    /// boundary retires this session and starts a fresh one.
    private var activeSession: PlaybackSessionResponse?
    private var protocolV3Available: Bool?
    private var protocolV3AvailabilityServerId: String?
    /// Converts engine-local time back to the effective file's source time.
    private var activeTimelineOffsetSeconds: Double = 0
    /// Invalidates an in-flight track load when the user seeks again or
    /// closes the player while `/playback/start` is still on the wire.
    private var loadGeneration = 0
    /// Serializes `start(contentId:)` requests: bumped before the
    /// item-detail load so a slower, older start cannot overwrite the
    /// context of a newer book that superseded it. Kept separate from
    /// `loadGeneration` because `loadTrack()` bumps that on success.
    private var startGeneration = 0
    private var isClosing = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Playback"
    )

    private(set) var context: AudiobookPlaybackContext?
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Cover-derived colors for the player backdrop and control tint.
    /// Stays on `.fallback` until sampling resolves so the UI never
    /// blocks on image work.
    private(set) var palette: AudioCoverPalette = .fallback

    static let availableRates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var playbackRate: Double = 1.0
    let sleepTimer = SleepTimer()

    var hasActiveSession: Bool { context != nil }
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
        engine.onTime = { [weak self] localTime in
            self?.handleEngineTime(localTime)
        }
        engine.onEnded = { [weak self] in
            Task { await self?.advanceAfterTrackEnd() }
        }
        sleepTimer.configure { [weak self] in
            self?.pause()
        }
    }

    func start(contentId: String, restart: Bool = false, startPosition: Double? = nil) async {
        isLoading = true
        error = nil
        var generation = startGeneration
        do {
            try configureAudioSession()
            if context != nil {
                await close()
            }
            startGeneration += 1
            generation = startGeneration
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
            attachNowPlaying()
            loadPalette(posterUrl: context.posterUrl)
            if let artwork = await resolvedURL(context.posterUrl) {
                nowPlaying.setArtworkURL(artwork)
            }
            try await loadTrack(at: currentTime, autoplay: true)
            startSyncLoop()
        } catch {
            self.error = ErrorState(error)
        }
        if generation == startGeneration { isLoading = false }
    }

    func play() {
        guard context != nil else { return }
        isPlaying = true
        engine.setRate(playbackRate, shouldResume: true)
        pushNowPlaying()
    }

    func pause() {
        guard context != nil else { return }
        isPlaying = false
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
            try? await loadTrack(at: clampGlobal(globalTime), autoplay: isPlaying)
            await syncNow()
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
        guard !isClosing else { return }
        isClosing = true
        syncTask?.cancel()
        syncTask = nil
        loadGeneration += 1
        startGeneration += 1
        let closedContext = context
        let closedSession = activeSession
        let position = currentTime
        let total = duration
        isPlaying = false
        engine.stop()
        nowPlaying.detach()
        sleepTimer.cancel()
        context = nil
        activeSession = nil
        activeTrackIndex = nil
        activeTimelineOffsetSeconds = 0
        currentTime = 0
        duration = 0
        palette = .fallback
        if let closedContext {
            try? await ContinuumAPI.shared.syncProgress(
                mediaItemId: closedContext.contentId,
                position: position,
                duration: total,
                forceOverwrite: true
            )
        }
        if let closedSession {
            try? await ContinuumAPI.shared.stopPlayback(sessionId: closedSession.sessionId)
        }
        isClosing = false
    }

    private func loadTrack(at globalTime: Double, autoplay: Bool) async throws {
        guard let context,
              let index = AudioPlaybackTimeline.trackIndex(at: globalTime, tracks: context.tracks),
              let track = context.tracks.first(where: { $0.index == index }) else {
            throw APIError.unsupportedMedia("No playable audio track is available.")
        }
        let localTime = AudioPlaybackTimeline.localTime(for: globalTime, in: track)
        var resolvedGlobalTime = globalTime
        if activeTrackIndex == index, activeSession != nil {
            engine.seek(to: max(0, localTime - activeTimelineOffsetSeconds))
        } else {
            loadGeneration += 1
            let generation = loadGeneration
            retireActiveSession()
            let started = try await startSession(for: track, localTime: localTime)
            guard generation == loadGeneration, self.context != nil else {
                // Superseded by a newer seek or a close while the request
                // was in flight — release the session we no longer need.
                Task { try? await ContinuumAPI.shared.stopPlayback(sessionId: started.session.sessionId) }
                return
            }
            guard let url = await resolvedStreamURL(started.session.streamUrl) else {
                Task { try? await ContinuumAPI.shared.stopPlayback(sessionId: started.session.sessionId) }
                throw APIError.unsupportedMedia("No playable audio track is available.")
            }
            activeSession = started.session
            activeTrackIndex = started.track.index
            activeTimelineOffsetSeconds = max(0, started.session.timelineOffsetSeconds)
            let headers = started.streamHeaders.merging(await authHeaders()) { _, auth in auth }
            engine.load(
                url: url,
                headers: headers,
                startSeconds: max(0, started.session.position)
            )
            resolvedGlobalTime =
                started.track.startOffsetSeconds
                    + max(0, started.session.position)
                    + activeTimelineOffsetSeconds
        }
        currentTime = clampGlobal(resolvedGlobalTime)
        if autoplay {
            isPlaying = true
            engine.setRate(playbackRate, shouldResume: true)
        }
        pushNowPlaying()
    }

    private func startSession(
        for track: AudioPlaybackTrack,
        localTime: Double
    ) async throws -> StartedAudioSession {
        let activeServerId = await TokenStore.shared.getActiveServerId()
        if protocolV3AvailabilityServerId != activeServerId {
            protocolV3AvailabilityServerId = activeServerId
            protocolV3Available = nil
        }
        if protocolV3Available == nil {
            do {
                let capability = try await ContinuumAPI.shared.playbackV3Capability()
                protocolV3Available = PlaybackSessionBridge.supportsNeutralProtocolV3(capability)
            } catch {
                if PlaybackSessionBridge.isMissingProtocolV3Capability(error) {
                    protocolV3Available = false
                } else {
                    throw error
                }
            }
        }
        guard protocolV3Available == true else {
            throw PlaybackV3TerminalFailure(
                reason: "server_upgrade_required",
                message: "This server does not support the playback protocol this app requires. Update the server to continue.",
                retryable: false
            )
        }
        guard let profileId = await TokenStore.shared.getProfileId(),
              !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlaybackV3TerminalFailure(
                reason: "profile_required",
                message: "Select a profile before starting playback.",
                retryable: false
            )
        }

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
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
            try ApplePlaybackV3PlanAdapter.validate(plan)
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
                selectedVersion: effectiveTrack.version
            )
            return StartedAudioSession(
                session: session,
                track: effectiveTrack,
                streamHeaders: plan.stream.headers
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
        guard let session = activeSession else { return }
        activeSession = nil
        activeTrackIndex = nil
        activeTimelineOffsetSeconds = 0
        Task { try? await ContinuumAPI.shared.stopPlayback(sessionId: session.sessionId) }
    }

    private func handleEngineTime(_ localTime: Double) {
        guard let context,
              let activeTrackIndex,
              let track = context.tracks.first(where: { $0.index == activeTrackIndex }) else { return }
        currentTime = clampGlobal(
            AudioPlaybackTimeline.globalTime(
                for: localTime + activeTimelineOffsetSeconds,
                in: track
            )
        )
        pushNowPlaying()
    }

    private func advanceAfterTrackEnd() async {
        guard let context,
              let activeTrackIndex,
              let current = context.tracks.first(where: { $0.index == activeTrackIndex }) else { return }
        let nextStart = current.startOffsetSeconds + current.durationSeconds + 0.01
        if AudioPlaybackTimeline.trackIndex(at: nextStart, tracks: context.tracks) != activeTrackIndex,
           nextStart < duration {
            try? await loadTrack(at: nextStart, autoplay: true)
        } else {
            currentTime = duration
            isPlaying = false
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
                    "reportPlaybackProgress failed for session \(session.sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
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
                "syncProgress failed for \(context.contentId, privacy: .public) at \(self.currentTime, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func attachNowPlaying() {
        nowPlaying.attach(handlers: NowPlayingController.Handlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            isPaused: { [weak self] in !(self?.isPlaying ?? false) },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            seek: { [weak self] target in self?.seek(to: target) }
        ))
        nowPlaying.setPreferredSkipInterval(30)
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        guard let context else { return }
        nowPlaying.update(
            title: context.title,
            duration: duration,
            position: currentTime,
            isPlaying: isPlaying,
            mediaKind: .audio,
            artist: context.subtitle,
            albumTitle: "Audiobook",
            playbackRate: playbackRate
        )
    }

    private func authHeaders() async -> [String: String] {
        var headers: [String: String] = [:]
        if let token = await TokenStore.shared.getAccessToken() {
            headers["Authorization"] = "Bearer \(token)"
        }
        if let profileId = await TokenStore.shared.getProfileId() {
            headers["X-Profile-Id"] = profileId
        }
        if let profileToken = await TokenStore.shared.getProfileToken() {
            headers["X-Profile-Token"] = profileToken
        }
        return headers
    }

    /// The playback session API emits stream paths relative to `/api/v1`
    /// (e.g. `/stream/{session_id}`), unlike poster URLs which are already
    /// fully prefixed. Mirrors `PlayerViewModel.resolveServerUrl`.
    private func resolvedStreamURL(_ raw: String) async -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let serverUrl = await ContinuumAPI.shared.currentServerUrl()
        guard !serverUrl.isEmpty else { return nil }
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: path.hasPrefix("/api/") ? base + path : base + "/api/v1" + path)
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

    private func configureAudioSession() throws {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
    }
}
