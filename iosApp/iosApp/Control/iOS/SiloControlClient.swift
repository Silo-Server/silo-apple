#if os(iOS)
import Foundation
import OSLog
import UIKit

/// Who initiated a connection attempt. Drives how failures surface (user
/// attempts open the remote cover; reconnects and silent auto-resume don't)
/// and whether the session starts in the "silently resumed" state.
enum SiloControlConnectOrigin {
    case user
    case reconnect
    case autoResume
}

/// The last successfully controlled TV, persisted across launches so a
/// relaunched app can silently reattach while that TV is still playing.
private struct PersistedControlTarget: Codable {
    let id: String
    let name: String
    let serverId: String
    let serverName: String?
}

private enum SiloControlHandoffError: LocalizedError {
    case updateRequired
    case timedOut
    case cancelled(String)
    case identityChanged
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .updateRequired:
            return "Update Silo on the TV to play with your profile."
        case .timedOut:
            return "The TV took too long to prepare your profile."
        case .cancelled(let message):
            return message
        case .identityChanged:
            return "Your server or profile changed. Try playing again."
        case .invalidResponse:
            return "The TV could not verify your playback profile."
        }
    }
}

@MainActor
@Observable
final class SiloControlClient {
    private(set) var activeTarget: SiloControlTarget?
    private(set) var state: SiloControlPlaybackState? {
        didSet { if state == nil { volumeReconciler.clear() } }
    }
    private(set) var isConnecting = false
    var errorMessage: String?
    var isShowingRemoteControl = false

    let clock = RemotePlaybackClock()

    private var volumeReconciler = RemoteVolumeReconciler()

    private let nowPlaying = NowPlayingController()
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkContentId: String?
    private var session: SiloControlSession?
    private var readTask: Task<Void, Never>?
    private var connectionId: UUID?

    private(set) var isReconnecting = false
    /// True while a silent foreground auto-resume probe is connected but
    /// playback isn't confirmed yet — the mini-bar stays hidden so an idle
    /// probe never flashes UI the user didn't ask for.
    private(set) var isAutoResuming = false
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var autoResumeTask: Task<Void, Never>?
    private var autoResumeGeneration = 0
    /// Reconnect requested while the app was backgrounded; deferred until the
    /// next foreground so the attempt budget isn't burned against suspended
    /// sockets.
    private var pendingReconnectReason: String?
    /// The current session was attached silently (auto-resume) and the user
    /// hasn't engaged with it yet. Such a session lets go quietly when the TV
    /// goes idle, so it never flips the TV into the standby takeover screen.
    private var sessionIsAutoResumed = false
    /// Guards against a double-tap on the remote button sending two `.launch`
    /// frames (and presenting the player twice) for the same in-flight
    /// connection.
    private var launchInFlight = false
    private var negotiatedVersion: Int?
    private var pendingHandoffRequestId: String?
    private var handoffChallenge: SiloControlHandoffChallenge?
    private var handoffReady: SiloControlHandoffReady?
    private var handoffCancellation: SiloControlHandoffCancel?
    private var missedHeartbeats = 0
    private(set) var lastTarget: SiloControlTarget?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wasBackgroundedWithActiveSession = false
    private static let heartbeatInterval: Duration = .seconds(3)
    private static let maxMissedHeartbeats = 3
    private static let maxReconnectAttempts = 5
    private static let persistedTargetKey = "silocontrol.lastTarget"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "control.client"
    )

    var hasActiveSession: Bool {
        session != nil && activeTarget != nil
    }

    @discardableResult
    func connect(
        to target: SiloControlTarget,
        origin: SiloControlConnectOrigin = .user,
        allowCrossServer: Bool = false
    ) async -> Bool {
        guard let activeServerId = ServerRegistry.shared.activeServerId else {
            errorMessage = "Choose a server before controlling a TV."
            return false
        }
        let targetsActiveServer = ServerRegistry.serverIdsMatch(target.serverId, activeServerId)
        guard targetsActiveServer || (allowCrossServer && target.protocolVersion >= 2) else {
            errorMessage = "That TV is connected to a different server."
            return false
        }

        switch origin {
        case .user:
            reconnectTask?.cancel()
            reconnectTask = nil
            isReconnecting = false
            pendingReconnectReason = nil
            cancelAutoResumeProbe()
            isAutoResuming = false
            sessionIsAutoResumed = false
        case .reconnect:
            break
        case .autoResume:
            sessionIsAutoResumed = true
        }

        if activeTarget?.id == target.id, session != nil {
            errorMessage = nil
            return true
        }

        await closeCurrentSession(sendClose: true)

        Self.logger.info("control: connecting origin=\(String(describing: origin), privacy: .public)")
        isConnecting = true
        errorMessage = nil
        activeTarget = target
        lastTarget = target
        state = nil
        negotiatedVersion = nil
        resetPendingHandoff()
        // Connecting alone doesn't take over the screen — the mini-bar surfaces
        // the session. The full remote only auto-presents once content launches
        // (see `launch()`) or when the user taps the mini-bar.

        let session = SiloControlSession(endpoint: target.endpoint)
        let connectionId = UUID()
        self.session = session
        self.connectionId = connectionId
        let stream = await session.open()
        startReadLoop(stream: stream, connectionId: connectionId)
        startHeartbeat(connectionId: connectionId)

        do {
            try await session.send(makeHello())
        } catch {
            fail(error.localizedDescription, connectionId: connectionId, quiet: origin != .user)
            return false
        }
        isConnecting = false
        let connected = self.connectionId == connectionId && self.session != nil
        if connected, targetsActiveServer {
            persistLastTarget(target)
        }
        return connected
    }

    func play(on target: SiloControlTarget, request: SiloControlPlaybackRequest) async {
        // Sending content to a TV always opens the remote — show it up front so
        // the connect handshake renders inside the cover, not behind a mini-bar.
        isShowingRemoteControl = true
        guard await connect(to: target, allowCrossServer: true) else { return }
        await launch(request)
    }

    func launch(_ request: SiloControlPlaybackRequest) async {
        guard let activeServer = ServerRegistry.shared.activeServer,
              let profileId = ServerRegistry.shared.activeProfileId,
              !profileId.isEmpty else {
            errorMessage = "Choose a server before controlling a TV."
            return
        }
        guard let session, activeTarget != nil else {
            errorMessage = "Choose a TV from Home before playing."
            return
        }
        // De-dup a double-tap: a second launch while one is already in flight
        // would send a duplicate `.launch` and re-present the player.
        guard !launchInFlight else { return }
        launchInFlight = true
        defer { launchInFlight = false }

        isConnecting = true
        errorMessage = nil
        isShowingRemoteControl = true

        let connectionId = self.connectionId
        do {
            let profileName = (try? await AuthService.shared.getProfiles())?
                .first(where: { $0.id == profileId })?
                .name
            let ready = try await prepareRemoteIdentity(
                server: activeServer,
                profileId: profileId,
                profileName: profileName,
                session: session
            )
            guard ServerRegistry.serverIdsMatch(ready.serverId, activeServer.id),
                  ready.profileId == profileId else {
                throw SiloControlHandoffError.invalidResponse
            }
            adoptEffectiveTarget(server: activeServer)
            try await session.send(.launch(SiloControlLaunchRequest(serverId: activeServer.id, playback: request)))
            isConnecting = false
        } catch {
            fail(error.localizedDescription, connectionId: connectionId)
        }
    }

    private func prepareRemoteIdentity(
        server: ServerEntry,
        profileId: String,
        profileName: String?,
        session: SiloControlSession
    ) async throws -> SiloControlHandoffReady {
        guard await waitForVersionNegotiation() == 2 else {
            throw SiloControlHandoffError.updateRequired
        }
        guard await TokenStore.shared.getAccessToken() != nil else {
            throw SiloControlHandoffError.identityChanged
        }

        let requestId = UUID().uuidString
        pendingHandoffRequestId = requestId
        handoffChallenge = nil
        handoffReady = nil
        handoffCancellation = nil

        try await session.send(.handoffOffer(SiloControlHandoffOffer(
            requestId: requestId,
            serverId: server.id,
            serverURL: server.url,
            serverName: server.displayName,
            profileId: profileId,
            profileName: profileName
        )))

        let challenge = try await waitForHandoffChallenge(requestId: requestId)
        do {
            try ensureActiveIdentity(serverId: server.id, profileId: profileId)

            let lookup: DeviceLookupResponse = try await HTTPClient.shared.get(
                "/api/v1/auth/device",
                query: ["code": challenge.userCode]
            )
            guard lookup.matchCode == challenge.matchCode,
                  lookup.clientPurpose == "remote_playback",
                  lookup.temporary == true else {
                throw SiloControlHandoffError.invalidResponse
            }

            try ensureActiveIdentity(serverId: server.id, profileId: profileId)
            try await HTTPClient.shared.postVoid(
                "/api/v1/auth/device/approve-handoff",
                body: DeviceApproveRequest(code: challenge.userCode)
            )

            let ready = try await waitForHandoffReady(requestId: requestId)
            try ensureActiveIdentity(serverId: server.id, profileId: profileId)
            resetPendingHandoff()
            return ready
        } catch {
            try? await HTTPClient.shared.postVoid(
                "/api/v1/auth/device/deny",
                body: DeviceApproveRequest(code: challenge.userCode)
            )
            resetPendingHandoff()
            throw error
        }
    }

    private func waitForVersionNegotiation() async -> Int? {
        for _ in 0..<100 {
            if let negotiatedVersion { return negotiatedVersion }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private func waitForHandoffChallenge(requestId: String) async throws -> SiloControlHandoffChallenge {
        for _ in 0..<200 {
            if let cancellation = handoffCancellation, cancellation.requestId == requestId {
                throw SiloControlHandoffError.cancelled(cancellation.message ?? "The TV cancelled profile setup.")
            }
            if let challenge = handoffChallenge, challenge.requestId == requestId {
                return challenge
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SiloControlHandoffError.timedOut
    }

    private func waitForHandoffReady(requestId: String) async throws -> SiloControlHandoffReady {
        for _ in 0..<600 {
            if let cancellation = handoffCancellation, cancellation.requestId == requestId {
                throw SiloControlHandoffError.cancelled(cancellation.message ?? "The TV cancelled profile setup.")
            }
            if let ready = handoffReady, ready.requestId == requestId {
                return ready
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SiloControlHandoffError.timedOut
    }

    private func ensureActiveIdentity(serverId: String, profileId: String) throws {
        guard ServerRegistry.shared.activeServerId == serverId,
              ServerRegistry.shared.activeProfileId == profileId else {
            throw SiloControlHandoffError.identityChanged
        }
    }

    private func adoptEffectiveTarget(server: ServerEntry) {
        guard let target = activeTarget else { return }
        let effective = SiloControlTarget(
            id: target.id,
            name: target.name,
            endpoint: target.endpoint,
            serverId: server.id,
            serverName: server.displayName,
            protocolVersion: target.protocolVersion,
            isPlaying: true
        )
        activeTarget = effective
        lastTarget = effective
        persistLastTarget(effective)
    }

    func send(_ command: SiloControlCommand) {
        // Any outbound command counts as user engagement — the session is no
        // longer a passive auto-resume attachment after this.
        sessionIsAutoResumed = false
        session?.enqueue(.control(command))
    }

    func togglePlayPauseOptimistic() {
        clock.setOptimisticPlaying(!clock.isPlaying())
        send(.playPause)
    }

    func seekOptimistic(to seconds: Double) {
        clock.setOptimisticTime(seconds)
        send(.seek(seconds: seconds))
    }

    func playNext() { send(.playNext) }

    /// Shows the requested level immediately and holds it until the TV reports
    /// it — see ``RemoteVolumeReconciler`` for why absolute volume commands need
    /// that hold.
    func setVolume(_ v: Double) {
        let clamped = min(max(v, 0), 1)
        volumeReconciler.requested(clamped)
        if var s = state {
            s.volume = clamped
            state = s
        }
        send(.setVolume(clamped))
    }

    func setMuted(_ m: Bool) {
        // A held level describes an unmuted volume; an explicit mute supersedes it.
        volumeReconciler.clear()
        if var s = state {
            s.isMuted = m
            state = s
        }
        send(.setMuted(m))
    }

    /// Applies one hardware-button volume step.
    ///
    /// Steps always start from the retained `volume`, never from the zero the UI
    /// shows while muted: the TV keeps its level independently of mute, so
    /// sending `0` would overwrite it and leave a later unmute silent. A step
    /// down while muted is therefore a no-op — the TV is already silent, and the
    /// only thing a command could do there is destroy the stored level.
    func stepVolumeOptimistic(_ step: Int) {
        guard let s = state, !(s.isMuted && step < 0) else { return }
        if s.isMuted { setMuted(false) }
        setVolume(s.volume + Double(step) / 16)
    }

    private func reconcileOptimisticVolume(
        _ next: SiloControlPlaybackState
    ) -> SiloControlPlaybackState {
        var reconciled = next
        reconciled.volume = volumeReconciler.reconcile(inbound: next.volume)
        return reconciled
    }

    func hideRemoteControl() {
        isShowingRemoteControl = false
    }

    func showRemoteControl() {
        guard hasActiveSession || isReconnecting else { return }
        sessionIsAutoResumed = false
        isShowingRemoteControl = true
    }

    func turnOffControlMode() {
        disconnect()
    }

    /// User-initiated disconnect: also forgets the persisted target so a
    /// future launch doesn't silently reattach to a TV the user let go of.
    func disconnect() {
        forgetPersistedTarget()
        quietDisconnect()
    }

    /// Tears the session down without touching the persisted target — used
    /// when *we* let go (idle auto-resumed session, failed probe), where a
    /// later foreground should still be allowed to resume.
    private func quietDisconnect() {
        let session = self.session
        let read = readTask
        // Goodbye before cancelling the reader: cancelling the stream consumer
        // fires onTermination → connection teardown, which would race ahead of
        // the `.close` and leave the TV seeing a bare EOF. (Same ordering as
        // TVControlReceiver.closeActiveSession.)
        readTask = nil
        Task {
            await session?.closeGracefully()
            read?.cancel()
        }
        clearSession()
    }

    func appDidEnterBackground() {
        // A half-finished auto-resume probe can't complete while suspended;
        // let go quietly and let the next foreground re-probe.
        cancelAutoResumeProbe()
        if isAutoResuming {
            quietDisconnect()
        }
        guard session != nil else { return }
        wasBackgroundedWithActiveSession = true
        beginBackgroundRemoteControlGracePeriod()
    }

    func appDidBecomeActive() {
        endBackgroundRemoteControlGracePeriod()

        if let reason = pendingReconnectReason {
            // The session dropped while backgrounded; run the reconnect now
            // that sockets work again, with a fresh attempt budget.
            pendingReconnectReason = nil
            wasBackgroundedWithActiveSession = false
            beginReconnect(reason: reason)
            return
        }

        guard wasBackgroundedWithActiveSession else {
            attemptAutoResumeIfIdle()
            return
        }
        wasBackgroundedWithActiveSession = false

        if session == nil {
            beginReconnect(reason: "Lost connection to the TV.")
        } else {
            session?.enqueue(.ping)
        }
    }

    /// Silently reattaches to the last-controlled TV when the app comes to
    /// the foreground (or launches) with no session, *if* that TV is
    /// currently playing per its Bonjour `playing` TXT flag. Idle TVs are
    /// never touched — a bare connection would flip them into the standby
    /// takeover screen.
    func attemptAutoResumeIfIdle() {
        guard session == nil,
              reconnectTask == nil,
              pendingReconnectReason == nil,
              !isReconnecting,
              autoResumeTask == nil,
              let persisted = Self.loadPersistedTarget(),
              ServerRegistry.serverIdsMatch(
                  persisted.serverId,
                  ServerRegistry.shared.activeServerId
              )
        else { return }

        autoResumeGeneration += 1
        let generation = autoResumeGeneration
        autoResumeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.autoResumeGeneration == generation {
                    self.autoResumeTask = nil
                }
            }
            let browser = SiloControlBrowser()
            browser.start()
            defer { browser.stop() }

            var match: SiloControlTarget?
            for _ in 0..<8 {    // scan up to ~4s for the persisted TV
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.session == nil else { return }
                if let found = browser.found.first(where: { $0.id == persisted.id && $0.isPlaying }) {
                    match = found
                    break
                }
            }
            guard let self, let match else { return }

            Self.logger.info("control: auto-resume probe found playing TV")
            self.isAutoResuming = true
            guard await self.connect(to: match, origin: .autoResume) else {
                self.isAutoResuming = false
                return
            }
            // Safety net: the TV sends state right after hello; if nothing
            // confirms playback shortly, let go quietly.
            try? await Task.sleep(for: .seconds(6))
            if self.isAutoResuming, self.autoResumeGeneration == generation {
                self.quietDisconnect()
            }
        }
    }

    private func cancelAutoResumeProbe() {
        autoResumeGeneration += 1
        autoResumeTask?.cancel()
        autoResumeTask = nil
    }

    private func startReadLoop(
        stream: AsyncThrowingStream<SiloControlMessage, Error>,
        connectionId: UUID
    ) {
        readTask?.cancel()
        readTask = Task { [weak self] in
            do {
                for try await message in stream {
                    await MainActor.run { self?.handle(message, connectionId: connectionId) }
                }
                await MainActor.run {
                    guard self?.connectionId == connectionId else { return }
                    self?.beginReconnect(reason: "Lost connection to the TV.")
                }
            } catch {
                await MainActor.run {
                    guard self?.connectionId == connectionId else { return }
                    self?.beginReconnect(reason: error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ message: SiloControlMessage, connectionId: UUID) {
        guard self.connectionId == connectionId else { return }
        // Liveness resets only on `.pong` (the TV's reply to our ping), not on
        // every inbound message — otherwise a half-open connection (our receive
        // path dead, send path alive) keeps the session pinned open. See the
        // matching note in TVControlReceiver.handle.
        switch message {
        case .hello(let hello):
            negotiatedVersion = SiloControlProtocol.negotiatedVersion(with: hello.supportedVersions)
        case .handoffChallenge(let challenge):
            guard challenge.requestId == pendingHandoffRequestId else { return }
            handoffChallenge = challenge
        case .handoffReady(let ready):
            guard ready.requestId == pendingHandoffRequestId else { return }
            handoffReady = ready
        case .handoffCancel(let cancel):
            guard cancel.requestId == pendingHandoffRequestId else { return }
            handoffCancellation = cancel
        case .state(let inbound):
            let state = reconcileOptimisticVolume(inbound)
            self.state = state
            clock.ingest(state)
            updateNowPlaying(for: state)
            isConnecting = false
            errorMessage = nil
            let isIdle = (state.contentId ?? "").isEmpty
            if sessionIsAutoResumed, isIdle, !isShowingRemoteControl {
                // The user never engaged with this silently-resumed session.
                // Holding it open while the TV is idle would flip the TV into
                // the standby takeover screen — let go quietly instead.
                quietDisconnect()
                return
            }
            if isAutoResuming, !isIdle {
                isAutoResuming = false  // playback confirmed — reveal the mini-bar
            }
        case .error(let error):
            if isAutoResuming {
                quietDisconnect()
                return
            }
            errorMessage = error.message
            isConnecting = false
        case .close:
            // The TV ended the session deliberately (user pressed Disconnect,
            // or another controller took over). Respect that intent: also
            // forget the persisted target so no later foreground probe or
            // reconnect silently reattaches.
            Self.logger.info("control: received close from TV; clearing session")
            forgetPersistedTarget()
            clearSession()
        case .ping:
            session?.enqueue(.pong)
        case .pong:
            missedHeartbeats = 0
        case .launch, .control, .unsupportedControl, .handoffOffer:
            break
        }
    }

    private func startHeartbeat(connectionId: UUID) {
        heartbeatTask?.cancel()
        missedHeartbeats = 0
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, self.connectionId == connectionId else { return }
                self.missedHeartbeats += 1
                if self.missedHeartbeats > Self.maxMissedHeartbeats {
                    self.beginReconnect(reason: "Lost connection to the TV.")
                    return
                }
                self.session?.enqueue(.ping)
            }
        }
    }

    private func beginReconnect(reason: String) {
        guard let target = lastTarget else { clearSession(); return }
        Self.logger.info("control: beginReconnect reason=\(reason, privacy: .public) appState=\(UIApplication.shared.applicationState.rawValue, privacy: .public)")
        heartbeatTask?.cancel(); heartbeatTask = nil
        readTask?.cancel(); readTask = nil
        let old = session
        session = nil
        connectionId = nil
        if old != nil { Task { await old?.close() } }
        isReconnecting = true
        errorMessage = nil

        // While backgrounded, sockets are suspended and every attempt would
        // fail — defer until the next foreground instead of burning the
        // attempt budget and wiping the session state.
        if UIApplication.shared.applicationState == .background {
            pendingReconnectReason = reason
            return
        }
        pendingReconnectReason = nil

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...Self.maxReconnectAttempts {
                if attempt > 1 {
                    try? await Task.sleep(for: .seconds(Double(attempt - 1)))   // backoff 1,2,3,4s
                }
                if Task.isCancelled { return }
                if await self.connect(to: target, origin: .reconnect) {
                    self.isReconnecting = false
                    return
                }
            }
            self.isReconnecting = false
            Self.logger.info("control: reconnect gave up after \(Self.maxReconnectAttempts, privacy: .public) attempts")
            // Give up — but if the remote cover is open, keep it up showing
            // why (with "Choose a Different TV" as the recovery path) instead
            // of vanishing silently. The persisted target survives so a later
            // foreground can still silently resume if the TV comes back.
            let keepCoverVisible = self.isShowingRemoteControl
            self.clearSession()
            self.errorMessage = reason
            self.isShowingRemoteControl = keepCoverVisible
        }
    }

    private func fail(_ message: String, connectionId: UUID?, quiet: Bool = false) {
        guard connectionId == nil || self.connectionId == connectionId else { return }
        if !quiet {
            errorMessage = message
            // Surface user-initiated connect/play failures in the remote cover;
            // bare connect (which no longer auto-presents) would fail
            // silently. Reconnect attempts and auto-resume probes stay quiet —
            // popping the cover for a failure the user didn't initiate would
            // hijack whatever they're doing.
            isShowingRemoteControl = true
        }
        isConnecting = false
        isAutoResuming = false
        sessionIsAutoResumed = false
        negotiatedVersion = nil
        resetPendingHandoff()
        detachNowPlaying()
        session = nil
        readTask?.cancel()
        readTask = nil
        self.connectionId = nil
        endBackgroundRemoteControlGracePeriod()
        wasBackgroundedWithActiveSession = false
    }

    private func clearSession() {
        readTask?.cancel()
        readTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        cancelAutoResumeProbe()
        missedHeartbeats = 0
        isReconnecting = false
        isAutoResuming = false
        sessionIsAutoResumed = false
        negotiatedVersion = nil
        resetPendingHandoff()
        pendingReconnectReason = nil
        lastTarget = nil
        session = nil
        connectionId = nil
        activeTarget = nil
        state = nil
        detachNowPlaying()
        isConnecting = false
        isShowingRemoteControl = false
        endBackgroundRemoteControlGracePeriod()
        wasBackgroundedWithActiveSession = false
    }

    private func closeCurrentSession(sendClose: Bool) async {
        let read = readTask
        let session = self.session
        // Invalidate the connection id first so any messages the still-running
        // reader delivers during the goodbye are dropped by handle()'s guard,
        // then say goodbye BEFORE cancelling the reader (cancelling it fires
        // onTermination → teardown, which would swallow the `.close`).
        readTask = nil
        self.session = nil
        connectionId = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        missedHeartbeats = 0
        if let session {
            if sendClose {
                await session.closeGracefully()
            } else {
                await session.close()
            }
        }
        read?.cancel()
        state = nil
        activeTarget = nil
        negotiatedVersion = nil
        resetPendingHandoff()
        detachNowPlaying()
        endBackgroundRemoteControlGracePeriod()
        wasBackgroundedWithActiveSession = false
    }

    private func beginBackgroundRemoteControlGracePeriod() {
        endBackgroundRemoteControlGracePeriod()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SiloControlRemote") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundRemoteControlGracePeriod()
            }
        }
    }

    private func endBackgroundRemoteControlGracePeriod() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: - Persisted target

    private func persistLastTarget(_ target: SiloControlTarget) {
        let value = PersistedControlTarget(
            id: target.id,
            name: target.name,
            serverId: target.serverId,
            serverName: target.serverName
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedTargetKey)
    }

    private static func loadPersistedTarget() -> PersistedControlTarget? {
        guard let data = UserDefaults.standard.data(forKey: persistedTargetKey) else { return nil }
        return try? JSONDecoder().decode(PersistedControlTarget.self, from: data)
    }

    private func forgetPersistedTarget() {
        UserDefaults.standard.removeObject(forKey: Self.persistedTargetKey)
    }

    private func makeHello() -> SiloControlMessage {
        let device = AppleDeviceIdentity.current
        let server = ServerRegistry.shared.activeServer
        return .hello(SiloControlHello(
            role: .phone,
            deviceName: device.name,
            deviceId: device.id,
            serverId: server?.id,
            serverName: server?.displayName,
            supportedVersions: SiloControlProtocol.supportedVersions
        ))
    }

    private func resetPendingHandoff() {
        pendingHandoffRequestId = nil
        handoffChallenge = nil
        handoffReady = nil
        handoffCancellation = nil
    }

    private func updateNowPlaying(for state: SiloControlPlaybackState) {
        guard let contentId = state.contentId, !contentId.isEmpty else {
            detachNowPlaying()
            return
        }

        attachNowPlayingIfNeeded()
        nowPlaying.update(
            title: state.title.isEmpty ? "Silo TV" : state.title,
            duration: state.duration,
            position: clock.displayTime(),
            isPlaying: clock.isPlaying(),
            mediaKind: .video,
            artist: state.subtitle,
            albumTitle: activeTarget.map { "Playing on \($0.name)" },
            playbackRate: state.playbackSpeed
        )
        updateNowPlayingArtwork(contentId: contentId)
    }

    private func attachNowPlayingIfNeeded() {
        nowPlaying.attach(handlers: NowPlayingController.Handlers(
            play: { [weak self] in self?.send(.play) },
            pause: { [weak self] in self?.send(.pause) },
            isPaused: { [weak self] in !(self?.clock.isPlaying() ?? false) },
            currentTime: { [weak self] in self?.clock.displayTime() ?? 0 },
            seek: { [weak self] seconds in self?.seekOptimistic(to: seconds) },
            stop: { [weak self] in self?.send(.stop) },
            next: { [weak self] in self?.playNext() },
            isNextEnabled: { [weak self] in self?.state?.hasNextEpisode == true }
        ))
        nowPlaying.setPreferredSkipIntervals(backward: 10, forward: 30)
    }

    private func updateNowPlayingArtwork(contentId: String) {
        guard contentId != nowPlayingArtworkContentId else { return }
        nowPlayingArtworkContentId = contentId
        nowPlayingArtworkTask?.cancel()

        if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(contentId)) {
            applyNowPlayingArtwork(from: cached)
            return
        }

        nowPlayingArtworkTask = Task { [weak self] in
            do {
                let detail = try await ContinuumAPI.shared.itemDetail(contentId: contentId)
                try Task.checkCancellation()
                self?.applyNowPlayingArtwork(from: detail)
            } catch is CancellationError {
                return
            } catch {
                self?.nowPlaying.setArtworkURL(nil)
            }
        }
    }

    private func applyNowPlayingArtwork(from detail: ItemDetail) {
        let poster = detail.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let backdrop = detail.backdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = [poster, backdrop].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
        nowPlaying.setArtworkURL(candidate.flatMap(URL.init(string:)))
    }

    private func detachNowPlaying() {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingArtworkContentId = nil
        nowPlaying.detach()
    }
}
#endif
