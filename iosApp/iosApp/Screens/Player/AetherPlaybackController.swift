import AetherEngine
import AVFoundation
import Combine
import Foundation
#if os(iOS) || os(tvOS)
import MediaPlayer
#endif

/// Silo's single production boundary around AetherEngine.
///
/// Product/session state stays outside this type. Media load, transport, and
/// engine observation enter the app through this one generation-fenced owner.
@MainActor
final class AetherPlaybackController {
    struct EmbeddedSubtitleSelectionError: LocalizedError {
        let streamIndex: Int
        var errorDescription: String? { "The selected embedded subtitle is unavailable in the opened media." }
    }

    func validateEmbeddedSubtitleSelection(_ streamIndex: Int) throws {
        guard engine.subtitleTracks.contains(where: { !$0.isExternal && $0.id == streamIndex }) else {
            throw EmbeddedSubtitleSelectionError(streamIndex: streamIndex)
        }
    }

    struct LoadFailure: LocalizedError {
        let failure: PlaybackErrorInfo
        let underlying: Error

        var errorDescription: String? { failure.message }
    }

    struct LoadEpoch: RawRepresentable, Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    enum Event {
        case state(PlaybackState)
        case phase(PlaybackPhase)
        case playerTime(Double)
        case duration(Double)
        case buffering(Bool)
        case subtitleLoading(Bool)
        case firstFrame
        case inventoryChanged
        case telemetryChanged
        case ended
        case failure(PlaybackErrorInfo)
        case transportRestoreFailed(String)
    }

    struct ScopedEvent {
        let epoch: LoadEpoch
        let event: Event
    }

    /// Player/session-independent changes must still reach the product layer
    /// after a load is invalidated so Now Playing and route UI can detach.
    enum ControllerEvent {
        /// Aether changed the player/session/route that owns system media.
        case systemMediaChanged
        /// Truthful external-video capability and active-route state.
        case externalPlaybackChanged(supported: Bool, active: Bool)
    }

    enum SeekResult: Equatable {
        case completed(sourceSeconds: Double)
        case requiresReplan(sourceSeconds: Double)
    }

    let engine: AetherEngine
    /// Registers this engine with the process-wide audio-session ownership
    /// registry for its lifetime. Silo runs two `AetherEngine`s (audiobooks and
    /// video); without this claim the audio controller would read itself as the
    /// sole live engine and deactivate the shared `AVAudioSession` on its own
    /// teardown, cutting video playback off mid-stream. The claim also carries
    /// this engine's live activity, so the audiobook side can tell a video
    /// engine that exists from one that is actually holding audio.
    private let aetherSessionClaim: AetherAudioSessionOwnership.Claim
    var onEvent: ((ScopedEvent) -> Void)?
    var onControllerEvent: ((ControllerEvent) -> Void)?
    /// iOS 26's Automatic Subtitles turn captions on with no read API behind
    /// them, so Aether forwarding the ask is the only observable signal. The
    /// engine has already deselected its own rendition by the time this fires;
    /// answering it means selecting a matching app track. Delivered only while
    /// a load is active, scoped to that load's epoch.
    var onSystemCaptionRequest: ((LoadEpoch, SystemCaptionRequest) -> Void)?

    private(set) var activeSpec: AetherLoadSpec?
    private(set) var activeLoadEpoch: LoadEpoch?

    /// Whether a transport call can reach anything. `play()`, `pause()` and
    /// `seek` all bail without a load, so a system-media surface that reports
    /// success regardless is telling the system a lie it cannot detect.
    var hasActiveLoad: Bool { activeLoadEpoch != nil && activeSpec != nil }

    /// The active spec is installed before `AetherEngine.load` so synchronous
    /// publications can be scoped to the new epoch. It is not safe to use that
    /// spec for receiver policy until the corresponding load has committed:
    /// the engine may still be exposing the outgoing AVPlayer in between.
    private var hasCommittedActiveLoad = false
    private var generation: UInt64 = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var didPublishFirstFrame = false
    private var didPublishEnd = false
    private var transportIntentGeneration: UInt64 = 0
    private var transportRestoreTask: Task<Void, Never>?
    /// The user's latest transport intent, independent of transient engine
    /// states such as loading, buffering, and error. A replacement load reads
    /// this after it commits so Play/Pause commands issued while loading win.
    private(set) var shouldPlayWhenReady = false
    private var desiredVolume: Float = 1
    private var muted = false
    private var aetherSubtitleIDByAppID: [Int64: Int] = [:]
    private var appSubtitleIDByAetherID: [Int: Int64] = [:]
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var observedExternalPlaybackPlayer: AVPlayer?
    private var externalPlaybackPolicyTask: Task<Void, Never>?
    /// The outgoing native player's receiver policy while Aether replaces its
    /// item. Clearing the active spec must not momentarily revoke an active
    /// AirPlay route before the successor load completes its own handoff.
    private var replacementExternalPlaybackPolicy: Bool?
    private var lastExternalPlaybackSupport = false
    private var lastExternalPlaybackActive = false

    init() throws {
        engine = try AetherEngine()
        aetherSessionClaim = AetherAudioSessionOwnership.Claim(engine: engine)
        #if os(iOS) || os(tvOS)
        engine.ownsVideoNowPlayingSession = true
        #endif
        applyBackgroundPlaybackPreference()
        observeEngine()
    }

    /// Adopts the device's background-playback choice onto the engine.
    ///
    /// The engine reads `backgroundPlaybackEnabled` when the app backgrounds,
    /// not at load time, so re-reading it at the start of every load is what
    /// makes a change taken in Settings apply to the next session even when
    /// this controller outlives the edit. Audiobooks deliberately never route
    /// through here: their engine keeps Aether's default and always plays on
    /// in the background.
    private func applyBackgroundPlaybackPreference() {
        engine.backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
    }

    /// Establishes load identity synchronously, before `AetherEngine.load` can
    /// synchronously publish any state for the replacement media.
    @discardableResult
    func beginLoad(
        _ spec: AetherLoadSpec,
        shouldPlayWhenReady: Bool = true
    ) -> LoadEpoch {
        generation &+= 1
        transportIntentGeneration &+= 1
        transportRestoreTask?.cancel()
        transportRestoreTask = nil
        self.shouldPlayWhenReady = shouldPlayWhenReady
        let epoch = LoadEpoch(rawValue: generation)
        applyBackgroundPlaybackPreference()
        activeLoadEpoch = epoch
        hasCommittedActiveLoad = false
        activeSpec = spec
        configureExternalPlaybackPolicy()
        refreshExternalPlaybackState()
        installDeclaredSubtitleAliases(
            spec.externalSubtitleAppTrackIDs,
            declaredTrackCount: spec.options.externalSubtitles.count
        )
        if let alias = spec.embeddedSubtitleAlias {
            aetherSubtitleIDByAppID[alias.appTrackID] = alias.streamIndex
            appSubtitleIDByAetherID[alias.streamIndex] = alias.appTrackID
        }
        didPublishFirstFrame = false
        didPublishEnd = false
        return epoch
    }

    func finishLoad(_ epoch: LoadEpoch) async throws {
        guard epoch == activeLoadEpoch, let spec = activeSpec else {
            throw CancellationError()
        }
        do {
            try await engine.load(
                url: spec.sourceURL,
                startPosition: spec.aetherStartPosition,
                options: spec.options,
                audioSourceStreamIndex: spec.audioSourceStreamIndex
            )
        } catch is CancellationError {
            guard epoch == activeLoadEpoch else { throw CancellationError() }
            activeLoadEpoch = nil
            activeSpec = nil
            replacementExternalPlaybackPolicy = nil
            aetherSubtitleIDByAppID = [:]
            appSubtitleIDByAetherID = [:]
            configureExternalPlaybackPolicy()
            refreshExternalPlaybackState()
            publishSystemMediaChanged()
            throw CancellationError()
        } catch {
            guard epoch == activeLoadEpoch else { throw CancellationError() }
            let typedFailure = engine.errorInfo
            activeLoadEpoch = nil
            activeSpec = nil
            replacementExternalPlaybackPolicy = nil
            aetherSubtitleIDByAppID = [:]
            appSubtitleIDByAetherID = [:]
            configureExternalPlaybackPolicy()
            refreshExternalPlaybackState()
            publishSystemMediaChanged()
            if let typedFailure {
                throw LoadFailure(failure: typedFailure, underlying: error)
            }
            throw error
        }
        guard epoch == activeLoadEpoch else {
            throw CancellationError()
        }
        hasCommittedActiveLoad = true
        replacementExternalPlaybackPolicy = nil
        configureExternalPlaybackPolicy()
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    func play() {
        shouldPlayWhenReady = true
        // `beginLoad` installs spec/epoch before `engine.load` returns, and
        // that window looks identical to a background teardown: route `.none`,
        // session not ready. Reloading here would start a second `engine.load`
        // and cancel the in-flight startup — the Siri Remote Play/Pause path
        // during the loading spinner.
        switch AetherPlayIntent.action(
            hasCommittedActiveLoad: hasCommittedActiveLoad,
            sessionRequiresRestore: sessionRequiresRestore
        ) {
        case .ignore:
            return
        case .play, .restoreThenPlay:
            break
        }

        transportIntentGeneration &+= 1
        let intentGeneration = transportIntentGeneration
        transportRestoreTask?.cancel()
        transportRestoreTask = Task { @MainActor [weak self] in
            guard let self,
                  let loadEpoch = self.activeLoadEpoch,
                  self.activeSpec != nil else { return }
            if self.hasCommittedActiveLoad, self.sessionRequiresRestore {
                do {
                    try await self.engine.reloadAtCurrentPosition()
                } catch is CancellationError {
                    return
                } catch {
                    guard intentGeneration == self.transportIntentGeneration,
                          loadEpoch == self.activeLoadEpoch else { return }
                    self.publish(
                        .transportRestoreFailed(error.localizedDescription),
                        for: loadEpoch
                    )
                    return
                }
            }
            guard !Task.isCancelled,
                  intentGeneration == self.transportIntentGeneration,
                  loadEpoch == self.activeLoadEpoch,
                  self.activeSpec != nil,
                  self.engine.videoRoute != .none else { return }
            self.engine.play()
            self.transportRestoreTask = nil
        }
    }

    /// The session behind an active load is gone and only a reload can bring
    /// it back — the state a backgrounded app returns to once Aether has run
    /// its wedge-safe teardown.
    ///
    /// `videoRoute` is the supported surface for "which pipeline is serving",
    /// and `.none` is documented as teardown; `playbackBackend` answers the
    /// same question but hosts must not branch on it (api.md). Pairing the
    /// route with `isSessionReady`, which the README names as the flag hosts
    /// gate corrective actions on, keeps a transient reroute — where the route
    /// changes but a session still exists — from being mistaken for teardown.
    private var sessionRequiresRestore: Bool {
        engine.videoRoute == .none && !engine.isSessionReady
    }

    func pause() {
        shouldPlayWhenReady = false
        transportIntentGeneration &+= 1
        transportRestoreTask?.cancel()
        transportRestoreTask = nil
        engine.pause()
    }

    func setRate(_ rate: Float) { engine.setRate(rate) }

    func setVolume(_ volume: Float) {
        desiredVolume = min(max(volume, 0), 1)
        engine.volume = muted ? 0 : desiredVolume
    }

    func setMuted(_ value: Bool) {
        muted = value
        engine.volume = value ? 0 : desiredVolume
    }

    var volume: Float { desiredVolume }

    var isMuted: Bool { muted }

    func setSpeed(_ rate: Double) { engine.setRate(Float(rate)) }

    func dispose() { stop() }

    /// Pauses the outgoing item while keeping Aether's native host mounted for
    /// the replacement load. The next `engine.load` then owns the teardown and
    /// can perform its native-to-native handoff without resetting the tvOS
    /// display criteria, replacing the player layer, or releasing the shared
    /// audio session in between consecutive episodes.
    func prepareForReplacement() {
        invalidateActiveLoad(preservingExternalPlaybackPolicy: true)
        engine.deactivatesAudioSessionOnStop = false
        // Aether otherwise unloads the outgoing AVPlayerItem at the start of
        // `load`, leaving the shared player layer itemless during the Next Up
        // mini-player -> full-screen transition. On tvOS that gap can strand
        // the layer black even though the successor's audio and clock advance.
        // Arm Aether's one-shot atomic item swap before pausing the old item.
        engine.prepareForItemReplacement()
        engine.pause()
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    var isPaused: Bool { engine.state != .playing }

    #if os(iOS) || os(tvOS)
    /// Aether's player-scoped native-video session. It appears only after a
    /// native host has been constructed and is nil on the software route.
    var videoNowPlayingSession: MPNowPlayingSession? {
        guard engine.videoRoute == .loopback || engine.videoRoute == .remoteBypass else {
            return nil
        }
        return engine.videoNowPlayingSession
    }
    #endif

    /// The process-wide Now Playing centers are a fallback only for video
    /// routes for which Aether has no `MPNowPlayingSession`.
    var shouldUseSharedVideoNowPlayingFallback: Bool {
        #if os(macOS)
        switch engine.videoRoute {
        case .loopback, .remoteBypass, .software:
            return true
        case .none, .audio:
            return false
        }
        #else
        return engine.videoRoute == .software
        #endif
    }

    private(set) var supportsExternalPlayback = false
    private(set) var isExternalPlaybackActive = false

    func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }

    func selectSubtitleTrack(id: Int64?) {
        if let id, let aetherID = aetherSubtitleID(forAppID: id) {
            engine.selectSubtitleTrack(index: aetherID)
        } else {
            engine.clearSubtitle()
        }
    }

    func selectSecondarySubtitleTrack(id: Int64?) {
        if let id, let aetherID = aetherSubtitleID(forAppID: id) {
            engine.selectSecondarySubtitleTrack(index: aetherID)
        } else {
            engine.clearSecondarySubtitle()
        }
    }

    func appSubtitleID(forAetherID id: Int) -> Int64 {
        appSubtitleIDByAetherID[id] ?? Int64(id)
    }

    func subtitleUsesMovieTimeline(appTrackID: Int64?, slot: SubtitleSlot) -> Bool {
        let engineID: Int?
        if let appTrackID {
            engineID = aetherSubtitleID(forAppID: appTrackID)
        } else {
            // Only the primary slot has an engine-published active identity.
            engineID = slot == .primary ? engine.activeSubtitleTrackIndex : nil
        }
        return engine.subtitleTracks.contains { $0.id == engineID && $0.isExternal }
    }

    func containsSubtitle(appTrackID: Int64) -> Bool {
        aetherSubtitleIDByAppID[appTrackID] != nil
    }

    @discardableResult
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack, appTrackID: Int64) -> Int64 {
        if aetherSubtitleIDByAppID[appTrackID] != nil { return appTrackID }
        let registered = engine.addExternalSubtitleTrack(track)
        aetherSubtitleIDByAppID[appTrackID] = registered.id
        appSubtitleIDByAetherID[registered.id] = appTrackID
        return appTrackID
    }

    func seek(toSourceTime sourceSeconds: Double) async -> SeekResult {
        guard let timeline = activeSpec?.timeline else {
            return .requiresReplan(sourceSeconds: max(0, sourceSeconds))
        }
        switch timeline.seekDisposition(forSourceTime: sourceSeconds) {
        case .local(let playerSeconds):
            let seekGeneration = generation
            await engine.seek(to: playerSeconds)
            guard seekGeneration == generation else {
                return .requiresReplan(sourceSeconds: max(0, sourceSeconds))
            }
            return .completed(sourceSeconds: timeline.sourcePosition(
                forPlayerTime: engine.clock.currentTime
            ))
        case .replan(let sourceSeconds):
            return .requiresReplan(sourceSeconds: sourceSeconds)
        }
    }

    func stop() {
        invalidateActiveLoad()
        shouldPlayWhenReady = false
        // Leaving video is the app's last use of the shared `AVAudioSession` unless an
        // audiobook is live. Aether never releases the session unless the host opts in
        // per teardown (#215, README "Who owns the audio session"), and a session left
        // active keeps whatever Silo interrupted — another app's music, a podcast —
        // paused or ducked for the rest of the process's life. Opting in here releases
        // it with `.notifyOthersOnDeactivation` so that audio resumes, and also closes
        // the E-AC-3/Atmos passthrough render ring the flag exists for. Gated on no
        // *other* Aether engine actually holding audio, not on engine existence: the
        // audiobook engine can outlive its playback.
        engine.deactivatesAudioSessionOnStop = AetherAudioSessionOwnership
            .canReleaseSharedSession(excluding: aetherSessionClaim)
        engine.stop(finalTeardown: true)
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    private func invalidateActiveLoad(preservingExternalPlaybackPolicy: Bool = false) {
        replacementExternalPlaybackPolicy = preservingExternalPlaybackPolicy
            ? observedExternalPlaybackPlayer?.allowsExternalPlayback
            : nil
        generation &+= 1
        transportIntentGeneration &+= 1
        transportRestoreTask?.cancel()
        transportRestoreTask = nil
        activeLoadEpoch = nil
        hasCommittedActiveLoad = false
        activeSpec = nil
        configureExternalPlaybackPolicy()
        aetherSubtitleIDByAppID = [:]
        appSubtitleIDByAetherID = [:]
        didPublishFirstFrame = false
        didPublishEnd = false
    }

    /// Seeds the alias map for the tracks Aether registers itself during
    /// `load`, whose ids are only knowable by position: Aether numbers
    /// `options.externalSubtitles` sequentially from
    /// `externalSubtitleTrackIDBase`.
    ///
    /// The positional read is sound only while the alias array is parallel to
    /// the declared array, so a mismatch installs nothing rather than a shifted
    /// map: an alias bound to the wrong Aether id silently renders a different
    /// language than the one the UI reports as selected, whereas an absent
    /// alias just means the id is re-established at registration time.
    private func installDeclaredSubtitleAliases(
        _ appIDs: [Int64?],
        declaredTrackCount: Int
    ) {
        aetherSubtitleIDByAppID = [:]
        appSubtitleIDByAetherID = [:]
        guard appIDs.count == declaredTrackCount else {
            assertionFailure(
                "declared subtitle aliases (\(appIDs.count)) must be parallel to "
                    + "options.externalSubtitles (\(declaredTrackCount))"
            )
            return
        }
        for (ordinal, appID) in appIDs.enumerated() {
            guard let appID else { continue }
            let aetherID = AetherEngine.externalSubtitleTrackIDBase + ordinal
            aetherSubtitleIDByAppID[appID] = aetherID
            appSubtitleIDByAetherID[aetherID] = appID
        }
    }

    /// The inverse of `appSubtitleID(forAetherID:)`. Internal so the boundary
    /// tests can assert the translation round-trips.
    func aetherSubtitleID(forAppID id: Int64) -> Int? {
        if let translated = aetherSubtitleIDByAppID[id] {
            return translated
        }
        // A Silo sidecar id is not an Aether id. Passing an unaliased value
        // through reaches Aether as an unknown external id and is silently
        // ignored, leaving the previously selected subtitle on screen.
        guard !SubtitleTrackIdSpace.isSidecar(id) else { return nil }
        return Int(exactly: id)
    }

    private func observeEngine() {
        engine.$state
            .sink { [weak self] state in
                guard let self else { return }
                publish(.state(state))
                if state == .ended, !didPublishEnd {
                    didPublishEnd = true
                    publish(.ended)
                }
            }
            .store(in: &subscriptions)

        engine.$playbackPhase
            .sink { [weak self] phase in self?.publish(.phase(phase)) }
            .store(in: &subscriptions)

        engine.clock.$currentTime
            .sink { [weak self] time in self?.publish(.playerTime(time)) }
            .store(in: &subscriptions)

        engine.$duration
            .sink { [weak self] duration in self?.publish(.duration(duration)) }
            .store(in: &subscriptions)

        engine.$isBuffering
            .sink { [weak self] buffering in self?.publish(.buffering(buffering)) }
            .store(in: &subscriptions)

        engine.$isLoadingSubtitles
            .removeDuplicates()
            .sink { [weak self] loading in self?.publish(.subtitleLoading(loading)) }
            .store(in: &subscriptions)

        engine.$hasFirstFrameReadyForDisplay
            .sink { [weak self] ready in
                guard let self, ready, !didPublishFirstFrame else { return }
                didPublishFirstFrame = true
                publish(.firstFrame)
            }
            .store(in: &subscriptions)

        engine.$errorInfo
            .compactMap { $0 }
            .sink { [weak self] error in self?.publish(.failure(error)) }
            .store(in: &subscriptions)

        Publishers.Merge3(
            engine.$audioTracks.map { _ in () },
            engine.$subtitleTracks.map { _ in () },
            engine.$mediaChapters.map { _ in () }
        )
        .sink { [weak self] in self?.publish(.inventoryChanged) }
        .store(in: &subscriptions)

        engine.diagnostics.$liveTelemetry
            .sink { [weak self] _ in self?.publish(.telemetryChanged) }
            .store(in: &subscriptions)

        engine.systemCaptionRequest
            .sink { [weak self] request in
                guard let self, let epoch = activeLoadEpoch else { return }
                onSystemCaptionRequest?(epoch, request)
            }
            .store(in: &subscriptions)

        engine.$currentAVPlayer
            .sink { [weak self] player in
                guard let self else { return }
                bindExternalPlayback(to: player)
                publishSystemMediaChanged()
            }
            .store(in: &subscriptions)

        // An Aether native host can keep the same AVPlayer while replacing
        // its item. Reassert the host policy and session binding at that seam.
        engine.$currentAVPlayerItem
            .sink { [weak self] _ in
                guard let self else { return }
                configureExternalPlaybackPolicy()
                refreshExternalPlaybackState()
                publishSystemMediaChanged()
            }
            .store(in: &subscriptions)

        engine.$videoRoute
            .sink { [weak self] _ in
                guard let self else { return }
                configureExternalPlaybackPolicy()
                refreshExternalPlaybackState()
                publishSystemMediaChanged()
            }
            .store(in: &subscriptions)

        #if os(iOS) || os(tvOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in self?.refreshExternalPlaybackState() }
            .store(in: &subscriptions)
        #endif
    }

    private func bindExternalPlayback(to player: AVPlayer?) {
        externalPlaybackPolicyTask?.cancel()
        externalPlaybackPolicyTask = nil
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        observedExternalPlaybackPlayer = player
        configureExternalPlaybackPolicy()

        guard let player else {
            refreshExternalPlaybackState()
            return
        }
        externalPlaybackObservation = player.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player,
                      self.observedExternalPlaybackPlayer === player,
                      self.engine.currentAVPlayer === player else { return }
                self.refreshExternalPlaybackState()
            }
        }
    }

    private func configureExternalPlaybackPolicy() {
        guard let player = observedExternalPlaybackPlayer,
              engine.currentAVPlayer === player else { return }
        let allowed = Self.externalPlaybackAllowed(
            activePolicy: externalPlaybackIsReceiverFetchable,
            preservedReplacementPolicy: replacementExternalPlaybackPolicy,
            preservedPolicyIsReceiverSafe: preservedReplacementPolicyIsReceiverSafe
        )
        player.allowsExternalPlayback = allowed
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = allowed
        #endif

        // Other custom-UI integrations bind to the same published AVPlayer.
        // Reassert once after that synchronous publication fan-out so a
        // generic PiP host cannot accidentally reopen a credentialed remote
        // HLS URL to an AirPlay receiver that cannot send its headers.
        externalPlaybackPolicyTask?.cancel()
        externalPlaybackPolicyTask = Task { @MainActor [weak self, weak player] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self, let player,
                  self.observedExternalPlaybackPlayer === player,
                  self.engine.currentAVPlayer === player else { return }
            let allowed = Self.externalPlaybackAllowed(
                activePolicy: self.externalPlaybackIsReceiverFetchable,
                preservedReplacementPolicy: self.replacementExternalPlaybackPolicy,
                preservedPolicyIsReceiverSafe: self.preservedReplacementPolicyIsReceiverSafe
            )
            player.allowsExternalPlayback = allowed
            #if os(iOS)
            player.usesExternalPlaybackWhileExternalScreenIsActive = allowed
            #endif
            self.refreshExternalPlaybackState()
            self.externalPlaybackPolicyTask = nil
        }
    }

    /// A loopback route is receiver-reachable through Aether's AirPlay host
    /// rewrite. A remote-HLS bypass is receiver-fetchable only without custom
    /// request headers; AVURLAsset headers stay on the sending device and are
    /// not credentials an AirPlay receiver can reproduce.
    private var externalPlaybackIsReceiverFetchable: Bool {
        guard hasCommittedActiveLoad, activeSpec != nil else { return false }
        switch engine.videoRoute {
        case .loopback:
            return true
        case .remoteBypass:
            return activeSpec?.options.httpHeaders.isEmpty == true
        case .none, .software, .audio:
            return false
        }
    }

    /// The outgoing player policy can survive only when the successor can use
    /// that same receiver route. Header-authenticated remote HLS cannot: its
    /// AVURLAsset headers remain on the sender. Evaluate this as soon as
    /// `beginLoad` installs the successor spec, before Aether swaps the item on
    /// its retained AVPlayer.
    private var preservedReplacementPolicyIsReceiverSafe: Bool {
        guard activeSpec?.options.nativeRemoteHLS == true else { return true }
        return activeSpec?.options.httpHeaders.isEmpty == true
    }

    nonisolated static func externalPlaybackAllowed(
        activePolicy: Bool,
        preservedReplacementPolicy: Bool?,
        preservedPolicyIsReceiverSafe: Bool
    ) -> Bool {
        guard preservedPolicyIsReceiverSafe else { return activePolicy }
        return preservedReplacementPolicy ?? activePolicy
    }

    private func refreshExternalPlaybackState() {
        let player = engine.currentAVPlayer
        let playerIsActive = player?.isExternalPlaybackActive == true
        let isNativeVideoRoute = engine.videoRoute == .loopback
            || engine.videoRoute == .remoteBypass
        let routeIsActive = playerIsActive
            || (isNativeVideoRoute && Self.isExternalOutputRoute)
        let allowed = Self.externalPlaybackAllowed(
            activePolicy: externalPlaybackIsReceiverFetchable,
            preservedReplacementPolicy: replacementExternalPlaybackPolicy,
            preservedPolicyIsReceiverSafe: preservedReplacementPolicyIsReceiverSafe
        )
        let supported = player != nil && (allowed || routeIsActive)

        supportsExternalPlayback = supported
        isExternalPlaybackActive = routeIsActive
        guard supported != lastExternalPlaybackSupport
                || routeIsActive != lastExternalPlaybackActive else { return }
        lastExternalPlaybackSupport = supported
        lastExternalPlaybackActive = routeIsActive
        onControllerEvent?(.externalPlaybackChanged(supported: supported, active: routeIsActive))
    }

    private func publishSystemMediaChanged() {
        onControllerEvent?(.systemMediaChanged)
    }

    private func publish(_ event: Event, for epoch: LoadEpoch? = nil) {
        guard let activeLoadEpoch,
              epoch == nil || epoch == activeLoadEpoch else { return }
        onEvent?(ScopedEvent(epoch: activeLoadEpoch, event: event))
    }

    private static var isExternalOutputRoute: Bool {
        #if os(iOS) || os(tvOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay || $0.portType == .HDMI
        }
        #else
        false
        #endif
    }
}

/// Whether `play()` may restore a torn-down session or must wait for the
/// in-flight load to commit.
///
/// Split out as a pure decision because the hazard is invisible in the happy
/// path: `beginLoad` publishes spec/epoch before `AetherEngine.load` returns,
/// and that window matches the background-teardown restore predicate. A Play
/// in that window calls `reloadAtCurrentPosition()`, which is another `load`
/// and supersedes the startup generation.
enum AetherPlayIntent {
    enum Action: Equatable {
        /// No committed load yet. The in-flight `engine.load` still owns
        /// startup and will play when it commits.
        case ignore
        /// Session is live; start transport.
        case play
        /// Committed load was torn down in the background; rebuild then play.
        case restoreThenPlay
    }

    static func action(
        hasCommittedActiveLoad: Bool,
        sessionRequiresRestore: Bool
    ) -> Action {
        guard hasCommittedActiveLoad else { return .ignore }
        return sessionRequiresRestore ? .restoreThenPlay : .play
    }
}

extension AetherAudioSessionOwnership.Claim {
    /// A claim that reports its engine's live audio activity.
    ///
    /// Lives here rather than in `AetherAudioSessionOwnership.swift` because that
    /// file is shared into extension targets (Top Shelf) that compile against but
    /// do not link AetherEngine; naming the engine type there breaks their link.
    ///
    /// `.idle` is pre-load or torn down and `.ended` reached end-of-media; every
    /// other state has a live session behind it, including `.paused` — a paused
    /// audiobook still owns its route and must not have the session pulled from
    /// under it. The engine is held weakly: a deallocated engine holds nothing.
    convenience init(engine: AetherEngine) {
        self.init(isHoldingAudio: { [weak engine] in
            guard let engine else { return false }
            switch engine.state {
            case .idle, .ended:
                return false
            default:
                return true
            }
        })
    }
}
