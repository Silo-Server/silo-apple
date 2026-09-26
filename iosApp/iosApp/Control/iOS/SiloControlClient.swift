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
    var serverIdentity: String? = nil
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

    /// Skip intervals for the remote's buttons and this phone's system media
    /// controls while it drives another device.
    var skipIntervals: SeekIntervalPair {
        SeekIntervalPreferences.shared.pair(for: .videoRemoteControl)
    }
    @ObservationIgnored private var isObservingSeekIntervals = false

    private var volumeReconciler = RemoteVolumeReconciler()

    private let nowPlaying = NowPlayingController()
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkContentId: String?
    private var session: SiloControlSession?
    private var readTask: Task<Void, Never>?
    private var connectionId: UUID?
    /// Set once the hello frame for `connectionId` is on the wire. A drop
    /// before that is a failed connect (reported by `connect`'s catch), not a
    /// lost session, so the read loop and heartbeat must not start a
    /// reconnect for it — closing a timed-out pre-hello connection would
    /// otherwise race `fail` and flip a user-visible error into silent
    /// reconnecting.
    private var isHandshakeComplete = false
    /// The TV's hello and handoff replies for `connectionId`. Each connection
    /// gets a new one, and teardown closes it, which fails a launch still
    /// waiting on it.
    private var handshake = SiloControlHandshake()

    private(set) var isReconnecting = false {
        didSet { if !isReconnecting { reconnectSettled.notify() } }
    }
    /// Wakes a Play that is waiting out a reconnect (`launchOnEngagedTV`).
    private let reconnectSettled = SiloControlChangeSignal()
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
    private var missedHeartbeats = 0
    private(set) var lastTarget: SiloControlTarget?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wasBackgroundedWithActiveSession = false
    private static let heartbeatInterval: Duration = .seconds(3)
    private static let maxMissedHeartbeats = 3
    private static let maxReconnectAttempts = 5
    /// How long a single connect (TCP + TLS + hello) may take before it counts
    /// as failed. An outbound `NWConnection` to a TV that's been switched off
    /// parks in `.waiting` indefinitely, so without a deadline a reconnect
    /// attempt — and the "Reconnecting…" bar — would never finish.
    private static let connectTimeout: Duration = .seconds(6)
    /// How long a launch waits for the TV's hello before treating the TV as
    /// too old for a profile handoff. The hello normally arrives right after
    /// connect, long before a launch.
    private static let helloWait: Duration = .seconds(5)
    /// How long a launch waits for each of the TV's handoff replies. Identity
    /// probing on the TV can precede its challenge.
    private static let handoffReplyWait: Duration = .seconds(30)
    private static let persistedTargetKey = "silocontrol.lastTarget"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "control.client"
    )

    var hasActiveSession: Bool {
        session != nil && activeTarget != nil
    }

    /// The one predicate for "the user has a TV engaged", read by the mode
    /// button, the mini-bar, and playback routing alike so they never
    /// disagree. True through an in-flight reconnect (the user still
    /// considers the TV theirs; a Play then waits for the link instead of
    /// starting on the phone) and false during a silent, still-unconfirmed
    /// auto-resume probe (no UI is showing, so nothing may silently cast).
    var remotePlaybackEngaged: Bool {
        (hasActiveSession && !isAutoResuming) || isReconnecting
    }

    /// How long a Play tapped during a reconnect waits for the link before
    /// giving up and reporting the failure in the remote cover.
    private static let launchReconnectWait: Duration = .seconds(45)

    /// Launches on the engaged TV, waiting out an in-flight reconnect first.
    /// Returns false when no TV is engaged, so the caller may play locally.
    /// Never falls through to local playback on its own: once the user has a
    /// TV engaged, a failed launch is reported on the remote cover instead.
    @discardableResult
    func launchOnEngagedTV(_ request: SiloControlPlaybackRequest) async -> Bool {
        guard remotePlaybackEngaged else { return false }
        if isReconnecting {
            isShowingRemoteControl = true
            let deadline = ContinuousClock.now + Self.launchReconnectWait
            while isReconnecting, ContinuousClock.now < deadline, !Task.isCancelled {
                await reconnectSettled.nextChange(before: deadline)
            }
            guard hasActiveSession else {
                if errorMessage == nil {
                    errorMessage = "Couldn't reconnect to \(lastTarget?.name ?? "the TV"). Choose a TV to keep playing there, or turn off control mode to play here."
                }
                isShowingRemoteControl = true
                return true
            }
        }
        await launch(request)
        return true
    }

    @discardableResult
    func connect(
        to target: SiloControlTarget,
        origin: SiloControlConnectOrigin = .user,
        allowCrossServer: Bool = false
    ) async -> Bool {
        guard ServerRegistry.shared.activeServer != nil else {
            errorMessage = "Choose a server before controlling a TV."
            return false
        }
        let targetsActiveServer = target.targetsActiveServer
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

        await closeCurrentSession()

        Self.logger.info("control: connecting origin=\(String(describing: origin), privacy: .public)")
        isConnecting = true
        errorMessage = nil
        activeTarget = target
        lastTarget = target
        state = nil
        // Connecting alone doesn't take over the screen — the mini-bar surfaces
        // the session. The full remote only auto-presents once content launches
        // (see `launch()`) or when the user taps the mini-bar.

        let session = SiloControlSession(endpoint: target.endpoint)
        let connectionId = UUID()
        self.session = session
        self.connectionId = connectionId
        handshake = SiloControlHandshake()
        isHandshakeComplete = false
        let stream = await session.open()
        startReadLoop(stream: stream, connectionId: connectionId)
        startHeartbeat(connectionId: connectionId)

        let hello = makeHello()
        do {
            try await Self.withDeadline(
                Self.connectTimeout,
                onTimeout: { await session.close() }
            ) {
                try await session.send(hello)
            }
        } catch {
            let message = error is SiloControlConnectTimeout
                ? "Couldn't reach \(target.name)."
                : error.localizedDescription
            fail(message, connectionId: connectionId, quiet: origin != .user)
            await session.close()
            return false
        }
        if self.connectionId == connectionId { isHandshakeComplete = true }
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
        let handshake = self.handshake
        do {
            let profileName = (try? await AuthService.shared.getProfiles())?
                .first(where: { $0.id == profileId })?
                .name
            let ready = try await prepareRemoteIdentity(
                server: activeServer,
                profileId: profileId,
                profileName: profileName,
                session: session,
                handshake: handshake
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
        session: SiloControlSession,
        handshake: SiloControlHandshake
    ) async throws -> SiloControlHandoffReady {
        guard try await handshake.negotiatedVersion(within: Self.helloWait) == 2 else {
            throw SiloControlHandoffError.updateRequired
        }
        // The server-side approval runs under the owner captured here: the
        // same account, credential and profile the offer names.
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(), auth.accessToken != nil,
              ServerRegistry.serverIdsMatch(auth.account.serverId, server.id),
              auth.profileId == profileId else {
            throw SiloControlHandoffError.identityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profileId, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let api = SiloAPI.shared.apiV2Client

        let requestId = UUID().uuidString
        handshake.beginHandoff(requestId: requestId)

        // The deployment's other addresses let a TV that cannot reach the
        // phone's URL (a network-plugin origin, say) still prepare the
        // profile at the address it can reach. Best effort: without them the
        // TV falls back to `serverURL` exactly, as before.
        let endpoints = await Self.offeredEndpoints(for: server)
        try ensureActiveIdentity(serverId: server.id, profileId: profileId)
        try await session.send(.handoffOffer(SiloControlHandoffOffer(
            requestId: requestId,
            serverId: server.id,
            serverURL: server.url,
            serverName: server.displayName,
            profileId: profileId,
            profileName: profileName,
            serverIdentity: server.verifiedServerId,
            serverEndpoints: endpoints
        )))

        // A TV that still holds this phone's profile answers `handoff_ready`
        // (reused) with no challenge at all. Waiting for a challenge there
        // timed the launch out, so every second title sent to a TV failed.
        let challenge: SiloControlHandoffChallenge
        switch try await handshake.firstReply(to: requestId, within: Self.handoffReplyWait) {
        case .ready(let ready):
            try ensureActiveIdentity(serverId: server.id, profileId: profileId)
            handshake.endHandoff()
            return ready
        case .challenge(let issued):
            challenge = issued
        }
        do {
            try ensureActiveIdentity(serverId: server.id, profileId: profileId)

            let lookup = try await api.deviceLookup(code: challenge.userCode, identity: identity,
                expectedAccount: auth.account, expectedAuth: auth)
            guard Self.isRemotePlaybackHandoff(lookup, answering: challenge) else {
                throw SiloControlHandoffError.invalidResponse
            }

            try ensureActiveIdentity(serverId: server.id, profileId: profileId)
            try await api.decideDeviceLogin(code: challenge.userCode, approveHandoff: true, identity: identity,
                expectedAccount: auth.account, expectedAuth: auth)

            let ready = try await handshake.ready(for: requestId, within: Self.handoffReplyWait)
            guard await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
                throw SiloControlHandoffError.identityChanged
            }
            try ensureActiveIdentity(serverId: server.id, profileId: profileId)
            handshake.endHandoff()
            return ready
        } catch {
            // Best effort: a deny that fails (or is refused because the owner
            // changed) leaves the request to expire on the server.
            try? await api.decideDeviceLogin(code: challenge.userCode, approveHandoff: false, identity: identity,
                expectedAccount: auth.account, expectedAuth: auth)
            handshake.endHandoff()
            throw error
        }
    }

    /// The TV's challenge is only approvable when the server describes the
    /// same request: its match code, opened for remote playback, and ending
    /// in a temporary session rather than a full sign-in.
    static func isRemotePlaybackHandoff(_ lookup: DeviceLookupResponse, answering challenge: SiloControlHandoffChallenge) -> Bool {
        lookup.matchCode == challenge.matchCode
            && lookup.clientPurpose == "remote_playback"
            && lookup.temporary == true
    }

    /// The addresses the server offers besides the phone's own, from its
    /// connections document. Empty (nil) when the server predates the
    /// contract, the phone has no identity for it, or the read fails.
    private static func offeredEndpoints(for server: ServerEntry) async -> [ServerEndpoint]? {
        guard server.verifiedServerId != nil,
              let token = await TokenStore.shared.getAccessToken(for: server.id), !token.isEmpty,
              let document = await ServerIdentityResolver().fetchConnections(
                  serverURL: server.url, bearer: token
              ),
              document.serverId == server.verifiedServerId else {
            return nil
        }
        let endpoints = document.usableEndpoints
        return endpoints.isEmpty ? nil : endpoints
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
            isPlaying: true,
            serverIdentity: server.verifiedServerId
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

    /// User gave up on an in-flight reconnect: stop trying and forget the
    /// target so no later foreground probe silently reattaches to it.
    func cancelReconnect() {
        guard isReconnecting else { return }
        Self.logger.info("control: reconnect cancelled by user")
        forgetPersistedTarget()
        clearSession()
    }

    /// Tears the session down without touching the persisted target — used
    /// when *we* let go (idle auto-resumed session, failed probe), where a
    /// later foreground should still be allowed to resume.
    private func quietDisconnect() {
        clearSession(goodbye: true)
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
              ServerRegistry.serversMatch(
                  serverId: persisted.serverId,
                  verifiedServerId: persisted.serverIdentity,
                  serverId: ServerRegistry.shared.activeServerId,
                  verifiedServerId: ServerRegistry.shared.activeServer?.verifiedServerId
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
                    guard let self, self.isLiveConnection(connectionId) else { return }
                    self.beginReconnect(reason: "Lost connection to the TV.")
                }
            } catch {
                await MainActor.run {
                    guard let self, self.isLiveConnection(connectionId) else { return }
                    self.beginReconnect(reason: error.localizedDescription)
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
        case .hello, .handoffChallenge, .handoffReady, .handoffCancel:
            handshake.receive(message)
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
                guard let self, self.isLiveConnection(connectionId) else { return }
                self.missedHeartbeats += 1
                if self.missedHeartbeats > Self.maxMissedHeartbeats {
                    self.beginReconnect(reason: "Lost connection to the TV.")
                    return
                }
                self.session?.enqueue(.ping)
            }
        }
    }

    /// True while `id` is the current connection and its hello has been sent,
    /// i.e. a drop now is a lost session rather than a failed connect.
    private func isLiveConnection(_ id: UUID) -> Bool {
        connectionId == id && isHandshakeComplete
    }

    private func beginReconnect(reason: String) {
        guard let target = lastTarget else { clearSession(); return }
        // A reconnect attempt's own read loop / heartbeat reports the failed
        // connection through here too. Restarting would cancel the running
        // loop and hand it a fresh attempt budget — an endless
        // "Reconnecting…" while the TV is off. Let the loop see the failure.
        // `reconnectTask` is cleared when the loop finishes, so a stale
        // handle can't block a later drop (e.g. one deferred from the
        // background and resumed by `appDidBecomeActive`).
        if isReconnecting, reconnectTask != nil || pendingReconnectReason != nil {
            Self.logger.debug("control: reconnect already in progress; ignoring \(reason, privacy: .public)")
            return
        }
        Self.logger.info("control: beginReconnect reason=\(reason, privacy: .public) appState=\(UIApplication.shared.applicationState.rawValue, privacy: .public)")
        tearDown(.connection)
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
                if await self.connect(to: target, origin: .reconnect), self.session != nil {
                    self.isReconnecting = false
                    self.reconnectTask = nil
                    return
                }
                if Task.isCancelled { return }
            }
            self.isReconnecting = false
            self.reconnectTask = nil
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

    // MARK: - Teardown

    /// How much a teardown lets go of.
    private enum TeardownScope {
        /// The connection only. `beginReconnect` expects the same TV back,
        /// so the target, its last state, Now Playing and the background
        /// grace period stay for the reconnect UI.
        case connection
        /// The connection and everything tied to the session.
        case session
    }

    /// The one path that lets go of a connection: it stops the reader and
    /// heartbeat, fails any handshake wait on the connection at once, and
    /// closes the socket. `beginReconnect`, `fail`, `clearSession` and
    /// `closeCurrentSession` all start here and differ only in the client
    /// state they reset on top.
    ///
    /// With `goodbye`, the TV gets `.close` before the reader is cancelled:
    /// cancelling the stream consumer fires onTermination → connection
    /// teardown, which would race ahead of the `.close` and leave the TV
    /// seeing a bare EOF. (Same ordering as TVControlReceiver.closeActiveSession.)
    /// Returns the closing work so `connect` can await the goodbye.
    @discardableResult
    private func tearDown(_ scope: TeardownScope, goodbye: Bool = false) -> Task<Void, Never>? {
        let session = self.session
        let read = readTask
        // Invalidate the connection id first so anything the still-running
        // reader delivers during the goodbye is dropped by handle()'s guard.
        self.session = nil
        readTask = nil
        connectionId = nil
        isHandshakeComplete = false
        heartbeatTask?.cancel(); heartbeatTask = nil
        missedHeartbeats = 0
        handshake.close()
        if scope == .session {
            detachNowPlaying()
            endBackgroundRemoteControlGracePeriod()
            wasBackgroundedWithActiveSession = false
        }
        if goodbye {
            guard session != nil || read != nil else { return nil }
            return Task {
                await session?.closeGracefully()
                read?.cancel()
            }
        }
        read?.cancel()
        guard let session else { return nil }
        return Task { await session.close() }
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
        // Keeps the target and its state; `clearSession` is the full reset.
        tearDown(.session)
        isConnecting = false
        isAutoResuming = false
        sessionIsAutoResumed = false
    }

    private func clearSession(goodbye: Bool = false) {
        tearDown(.session, goodbye: goodbye)
        reconnectTask?.cancel(); reconnectTask = nil
        cancelAutoResumeProbe()
        isReconnecting = false
        isAutoResuming = false
        sessionIsAutoResumed = false
        pendingReconnectReason = nil
        lastTarget = nil
        activeTarget = nil
        state = nil
        isConnecting = false
        isShowingRemoteControl = false
    }

    /// Ends the current session before `connect` opens the next one. The
    /// target and its state clear only after the goodbye; reconnect and
    /// auto-resume bookkeeping is `connect`'s to set.
    private func closeCurrentSession() async {
        await tearDown(.session, goodbye: true)?.value
        state = nil
        activeTarget = nil
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
            serverName: target.serverName,
            serverIdentity: target.serverIdentity
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
            supportedVersions: SiloControlProtocol.supportedVersions,
            serverIdentity: server?.verifiedServerId
        ))
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
        if !isObservingSeekIntervals {
            isObservingSeekIntervals = true
            SeekIntervalPreferences.shared.observe(self) { [weak self] in
                self?.syncNowPlayingSkipIntervals()
            }
        }
        syncNowPlayingSkipIntervals()
    }

    private func syncNowPlayingSkipIntervals() {
        let pair = skipIntervals
        nowPlaying.setPreferredSkipIntervals(
            backward: Double(pair.backward),
            forward: Double(pair.forward)
        )
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
                let detail = try await SiloAPI.shared.itemDetail(contentId: contentId)
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

/// Thrown by `SiloControlClient.withDeadline` when the operation outlives it.
struct SiloControlConnectTimeout: Error {}

extension SiloControlClient {
    /// Runs `operation` and throws `SiloControlConnectTimeout` if it hasn't
    /// finished within `deadline`. `onTimeout` runs before the throw and must
    /// unblock `operation` (e.g. close the connection it is waiting on): the
    /// group cannot return until both children finish, and a send parked in
    /// `NWConnection` doesn't observe task cancellation.
    static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        onTimeout: @escaping @Sendable () async -> Void,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                await onTimeout()
                throw SiloControlConnectTimeout()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
#endif
