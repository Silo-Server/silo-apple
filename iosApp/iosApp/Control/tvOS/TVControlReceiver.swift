#if os(tvOS)
import Foundation
import Network
import OSLog

@MainActor
@Observable
final class TVControlReceiver {
    static let shared = TVControlReceiver()

    private var listener: NWListener?
    private var advertisedServerId: String?
    private var advertisedServerName: String?
    private var advertisedServerIdentity: String?
    /// Bumped whenever we intentionally cancel/replace the listener, so its
    /// state handler can tell a system-initiated failure (restart) from our
    /// own teardown (ignore).
    private var listenerGeneration = 0
    /// Mirrors "is a player registered" into the Bonjour TXT record so phones
    /// can see that this TV is playing *before* connecting. A bare connection
    /// with no player takes over the TV screen (standby view), so the phone's
    /// silent auto-reconnect must only target TVs that are actually playing.
    private var isPlaybackAdvertised = false
    private weak var router: AppRouter?
    private var activeSession: SiloControlSession?
    private var activeConnectionId: UUID?
    /// Connections that haven't said hello yet. One only takes the session
    /// slot once its hello arrives (see `promote`), so a bare socket or a
    /// stalled handshake can't evict the phone in use.
    private struct PendingConnection {
        let session: SiloControlSession
        var readTask: Task<Void, Never>?
        var authWatchdogTask: Task<Void, Never>?
        let acceptedAt = ContinuousClock.now
    }
    private var pendingConnections: [UUID: PendingConnection] = [:]
    /// A burst of connections that never say hello can't pile up past this.
    private static let maxPendingConnections = 4
    private(set) var standbyState: TVControlStandbyState?
    private var readTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var missedHeartbeats = 0
    private var isAuthorized = false
    private var didReceiveHello = false
    private var negotiatedVersion: Int?
    private var pendingHandoffRequestId: String?
    private var remoteLaunchReady = false
    private static let heartbeatInterval: Duration = .seconds(3)
    private static let maxMissedHeartbeats = 3      // ~9–12s of silence ⇒ dead
    private static let authGracePeriod: Duration = .seconds(5)
    private weak var playerViewModel: PlayerViewModel?
    private var playerContentId: String?
    private var playerHandoffGeneration: UUID?
    private var pendingPlayerHandoffGeneration: UUID?
    /// A terminally rejected handoff does not need a best-effort logout, but
    /// player teardown is asynchronous. Carry its exact generation through
    /// `unregisterPlayer` so a replacement handoff is never treated as the
    /// rejected one.
    private var rejectedPlayerHandoffGeneration: UUID?
    private var remoteControllerName: String?
    private var remoteControllerDeviceId: String?
    private var remoteControllerServerId: String?
    private var remoteControllerServerIdentity: String?
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "control.receiver"
    )

    private init() {}

    func start(router: AppRouter) {
        self.router = router
        guard let server = ServerRegistry.shared.activeServer else {
            stop()
            return
        }
        let serverId = RemotePlaybackIdentityManager.shared.effectiveServerId ?? server.id
        let serverName = RemotePlaybackIdentityManager.shared.effectiveServerName ?? server.displayName
        let serverIdentity = RemotePlaybackIdentityManager.shared.effectiveServerIdentity
        if listener != nil,
           advertisedServerId == serverId,
           advertisedServerName == serverName,
           advertisedServerIdentity == serverIdentity {
            return
        }

        stop()
        startListener(serverId: serverId, serverName: serverName, serverIdentity: serverIdentity)
    }

    private func startListener(serverId: String, serverName: String, serverIdentity: String?) {
        listenerGeneration += 1
        let generation = listenerGeneration

        let device = AppleDeviceIdentity.current
        var record: [String: String] = [
            "v": String(SiloControlProtocol.version),
            "name": device.name,
            "id": device.id,
            "server": serverId,
            "serverName": serverName,
            "playing": isPlaybackAdvertised ? "1" : "0"
        ]
        // Lets a phone signed in at another address of the same deployment
        // list this TV. Older phones ignore the key.
        if let serverIdentity {
            record["serverIdentity"] = serverIdentity
        }
        let txt = NWTXTRecord(record)

        do {
            let listener = try NWListener(using: SiloControlSession.tlsParameters())
            listener.service = NWListener.Service(
                name: device.name,
                type: SiloControlProtocol.serviceType,
                txtRecord: txt
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    await self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerGeneration == generation else { return }
                    switch state {
                    case .failed(let error):
                        Self.logger.error("control listener failed: \(String(describing: error), privacy: .public)")
                        self.scheduleListenerRestart()
                    case .cancelled:
                        // We bump the generation before cancelling ourselves, so a
                        // current-generation cancel is the system tearing us down
                        // (e.g. after suspension) — recover the advertisement.
                        self.scheduleListenerRestart()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            advertisedServerId = serverId
            advertisedServerName = serverName
            advertisedServerIdentity = serverIdentity
        } catch {
            Self.logger.error("failed to start control listener: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleListenerRestart() {
        listener = nil
        advertisedServerId = nil
        advertisedServerName = nil
        advertisedServerIdentity = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.listener == nil, let router = self.router else { return }
            self.start(router: router)
        }
    }

    /// Rebuilds the Bonjour advertisement with an updated `playing` TXT flag.
    /// Recreating the listener does not disturb the accepted control session.
    private func setPlaybackAdvertised(_ playing: Bool) {
        guard isPlaybackAdvertised != playing else { return }
        isPlaybackAdvertised = playing
        refreshAdvertisement()
    }

    private func refreshAdvertisement() {
        guard listener != nil,
              let serverId = RemotePlaybackIdentityManager.shared.effectiveServerId else { return }
        let serverName = RemotePlaybackIdentityManager.shared.effectiveServerName ?? "Silo"
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        startListener(
            serverId: serverId,
            serverName: serverName,
            serverIdentity: RemotePlaybackIdentityManager.shared.effectiveServerIdentity
        )
    }

    func stop() {
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        advertisedServerId = nil
        advertisedServerName = nil
        advertisedServerIdentity = nil
        closeActiveSession(sendClose: false)
        for connectionId in Array(pendingConnections.keys) {
            dropPendingConnection(connectionId, sendClose: false)
        }
    }

    func disconnectRemoteControl() {
        closeActiveSession(sendClose: true)
    }

    func temporaryAuthExpired(expected event: SessionExpiryEvent) {
        let expectedGenerationID = event.account.credentialGenerationID
        guard event.disposition == .temporarySessionExpired,
              RemotePlaybackIdentityManager.shared.activeIdentity?.generationID == expectedGenerationID else {
            return
        }
        rejectedPlayerHandoffGeneration = expectedGenerationID
        sendError(code: "temporary_session_expired", message: "The phone profile session expired.")
        let hadPlayer = playerViewModel != nil
        stopRemotePlayback()
        if !hadPlayer {
            Task { @MainActor [weak self] in
                guard await RemotePlaybackIdentityManager.shared.end(
                    expectedGenerationID: expectedGenerationID,
                    notifyServer: false
                ) else { return }
                if self?.rejectedPlayerHandoffGeneration == expectedGenerationID {
                    self?.rejectedPlayerHandoffGeneration = nil
                }
                self?.refreshAdvertisement()
                self?.reconcileAuthorizationAfterRestore()
            }
        }
    }

    func registerPlayer(_ viewModel: PlayerViewModel, contentId: String) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        playerViewModel = viewModel
        playerContentId = contentId
        playerHandoffGeneration = pendingPlayerHandoffGeneration
        pendingPlayerHandoffGeneration = nil
        standbyState = nil
        startStateUpdates()
        sendState()
        setPlaybackAdvertised(true)
    }

    func unregisterPlayer(_ viewModel: PlayerViewModel) {
        guard playerViewModel == nil || playerViewModel === viewModel else { return }
        let endingGeneration = playerHandoffGeneration
        playerViewModel = nil
        playerContentId = nil
        playerHandoffGeneration = nil
        stateTask?.cancel()
        stateTask = nil
        refreshStandbyState()
        sendState()
        setPlaybackAdvertised(false)
        if let endingGeneration,
           RemotePlaybackIdentityManager.shared.activeIdentity?.generationID == endingGeneration {
            Task { @MainActor [weak self, weak viewModel] in
                await viewModel?.waitForCleanupCompletion()
                let notifyServer = self?.rejectedPlayerHandoffGeneration != endingGeneration
                guard await RemotePlaybackIdentityManager.shared.end(
                    expectedGenerationID: endingGeneration,
                    notifyServer: notifyServer
                ) else { return }
                if self?.rejectedPlayerHandoffGeneration == endingGeneration {
                    self?.rejectedPlayerHandoffGeneration = nil
                }
                self?.refreshAdvertisement()
                self?.reconcileAuthorizationAfterRestore()
                self?.refreshStandbyState()
            }
        }
    }

    private func accept(_ connection: NWConnection) async {
        // Newest controller wins (matches AirPlay/Cast), but only once it has
        // said hello: until then the phone in use keeps the session.
        if pendingConnections.count >= Self.maxPendingConnections,
           let oldest = pendingConnections.min(by: { $0.value.acceptedAt < $1.value.acceptedAt })?.key {
            dropPendingConnection(oldest, sendClose: false)
        }
        let session = SiloControlSession(connection: connection)
        let connectionId = UUID()
        pendingConnections[connectionId] = PendingConnection(session: session)
        let stream = await session.open()
        pendingConnections[connectionId]?.readTask = makeReadTask(stream: stream, connectionId: connectionId)
        pendingConnections[connectionId]?.authWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.authGracePeriod)
            guard let self, self.pendingConnections[connectionId] != nil else { return }
            Self.logger.info("control: connection never said hello; closing it")
            self.dropPendingConnection(connectionId, sendClose: true)
        }

        do {
            try await session.send(makeHello())
        } catch {
            dropPendingConnection(connectionId, sendClose: false)
        }
    }

    private func makeReadTask(
        stream: AsyncThrowingStream<SiloControlMessage, Error>,
        connectionId: UUID
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await message in stream {
                    await MainActor.run {
                        self?.route(message, connectionId: connectionId)
                    }
                }
                await MainActor.run {
                    self?.handleConnectionClosed(connectionId: connectionId)
                }
            } catch {
                await MainActor.run {
                    if self?.activeConnectionId == connectionId {
                        self?.sendError(code: "connection_failed", message: error.localizedDescription)
                    }
                    self?.handleConnectionClosed(connectionId: connectionId)
                }
            }
        }
    }

    private func route(_ message: SiloControlMessage, connectionId: UUID) {
        guard pendingConnections[connectionId] != nil else {
            handle(message, connectionId: connectionId)
            return
        }
        switch message {
        case .hello(let hello):
            promote(connectionId, hello: hello)
        case .ping:
            pendingConnections[connectionId]?.session.enqueue(.pong)
        case .close:
            dropPendingConnection(connectionId, sendClose: false)
        default:
            // Nothing else counts before a hello.
            break
        }
    }

    /// Makes a pending connection the active controller now that its hello
    /// names it. A `resume` hello (a phone reconnecting or silently resuming,
    /// not a person picking this TV) is refused while a different phone holds
    /// the session.
    private func promote(_ connectionId: UUID, hello: SiloControlHello) {
        guard let pending = pendingConnections.removeValue(forKey: connectionId) else { return }
        pending.authWatchdogTask?.cancel()
        func refuse(code: String, message: String) {
            pending.session.enqueue(.error(SiloControlErrorMessage(code: code, message: message)))
            Task {
                await pending.session.closeGracefully()
                pending.readTask?.cancel()
            }
        }
        // A phone this TV can't serve must not cost the current one its session.
        guard hello.role == .phone,
              let version = SiloControlProtocol.negotiatedVersion(with: hello.supportedVersions),
              let serverId = hello.serverId, !serverId.isEmpty else {
            refuse(code: "version_unsupported", message: "Update Silo on both devices to continue.")
            return
        }
        if version < 2, !RemotePlaybackIdentityManager.shared.controllerMatchesEffectiveServer(
            serverId: serverId,
            serverIdentity: ServerIdentity.usable(hello.serverIdentity)
        ) {
            refuse(code: "server_mismatch", message: "This Apple TV is connected to a different Silo server.")
            return
        }
        if hello.resume == true,
           activeSession != nil,
           let current = remoteControllerDeviceId,
           current != hello.deviceId {
            Self.logger.info("control: refusing a resume while another controller is active")
            refuse(
                code: SiloControlProtocol.controllerActiveErrorCode,
                message: "\(remoteControllerName ?? "Another phone") is using this Apple TV."
            )
            return
        }
        if activeSession != nil {
            closeActiveSession(sendClose: true)
        }
        activeSession = pending.session
        activeConnectionId = connectionId
        readTask = pending.readTask
        isAuthorized = false
        didReceiveHello = false
        negotiatedVersion = nil
        remoteLaunchReady = false
        remoteControllerName = nil
        remoteControllerDeviceId = nil
        remoteControllerServerId = nil
        remoteControllerServerIdentity = nil
        if playerViewModel != nil {
            startStateUpdates()
        }
        startHeartbeat(connectionId: connectionId)
        handle(.hello(hello), connectionId: connectionId)
    }

    private func dropPendingConnection(_ connectionId: UUID, sendClose: Bool) {
        guard let pending = pendingConnections.removeValue(forKey: connectionId) else { return }
        pending.authWatchdogTask?.cancel()
        Task {
            if sendClose {
                await pending.session.closeGracefully()
            } else {
                await pending.session.close()
            }
            pending.readTask?.cancel()
        }
    }

    private func handle(_ message: SiloControlMessage, connectionId: UUID) {
        guard activeConnectionId == connectionId else { return }
        // NOTE: liveness is reset only on `.pong` (below), not on every inbound
        // message. A `.pong` is the controller's reply to our ping, so it's the
        // only message that proves the controller can still *receive* from us.
        // Resetting on any inbound (e.g. the controller's own pings) would let a
        // half-open connection — controller's receive path dead but its send
        // path alive — keep the session pinned open forever.
        switch message {
        case .hello(let hello):
            guard hello.role == .phone,
                  let version = SiloControlProtocol.negotiatedVersion(with: hello.supportedVersions),
                  let serverId = hello.serverId, !serverId.isEmpty else {
                sendError(code: "version_unsupported", message: "Update Silo on both devices to continue.")
                closeActiveSession(sendClose: true)
                return
            }
            didReceiveHello = true
            negotiatedVersion = version
            remoteControllerName = hello.deviceName
            remoteControllerDeviceId = hello.deviceId
            remoteControllerServerId = serverId
            remoteControllerServerIdentity = ServerIdentity.usable(hello.serverIdentity)
            if RemotePlaybackIdentityManager.shared.controllerMatchesEffectiveServer(
                serverId: serverId,
                serverIdentity: remoteControllerServerIdentity
            ) {
                isAuthorized = true
                refreshStandbyState()
                sendState()
            } else if version >= 2 {
                // A v2 cross-server controller may stay connected only long
                // enough to complete server-mediated identity handoff.
                isAuthorized = false
                standbyState = nil
            } else {
                sendError(code: "server_mismatch",
                          message: "This Apple TV is connected to a different Silo server.")
                closeActiveSession(sendClose: true)
            }
        case .handoffOffer(let offer):
            guard negotiatedVersion == 2, let controllerDeviceId = remoteControllerDeviceId else {
                sendHandoffCancel(offer.requestId, reason: "version_unsupported", message: "Update Silo on both devices to continue.")
                return
            }
            beginHandoff(offer, controllerDeviceId: controllerDeviceId, connectionId: connectionId)
        case .handoffCancel(let cancel):
            guard cancel.requestId == pendingHandoffRequestId else { return }
            cancelPendingHandoff()
        case .launch(let launch):
            guard isAuthorized else {
                sendError(code: "unauthorized", message: "Connect with a matching Silo account first.")
                return
            }
            if negotiatedVersion == 2,
               (!remoteLaunchReady || RemotePlaybackIdentityManager.shared.activeIdentity == nil) {
                sendError(code: "handoff_required", message: "Prepare the phone profile before playing.")
                return
            }
            handleLaunch(launch)
        case .control(let command):
            guard isAuthorized else {
                sendError(code: "unauthorized", message: "Connect with a matching Silo account first.")
                return
            }
            handleControl(command)
        case .unsupportedControl(let name):
            // An older v2 controller sent a command this build retired (e.g.
            // `set_hdr_enabled`). Drop it silently rather than replying with
            // `.error`: the phone renders an error frame as a user-visible
            // banner and abandons a silent auto-resume, so a stale button on
            // an old remote would look like a broken connection. Ignoring it
            // matches what the user sees anyway — nothing happens.
            Self.logger.info("control: ignoring unsupported command \(name, privacy: .public)")
        case .ping:
            activeSession?.enqueue(.pong)
        case .pong:
            missedHeartbeats = 0
        case .state, .error, .handoffChallenge, .handoffReady:
            break
        case .unsupported(let type):
            // A kind added by a newer phone. Ignoring it keeps the session.
            Self.logger.info("control: ignoring unsupported message \(type, privacy: .public)")
        case .close:
            closeActiveSession(sendClose: false)
        }
    }

    private func beginHandoff(
        _ offer: SiloControlHandoffOffer,
        controllerDeviceId: String,
        connectionId: UUID
    ) {
        cancelPendingHandoff()
        pendingHandoffRequestId = offer.requestId
        remoteLaunchReady = false

        handoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manager = RemotePlaybackIdentityManager.shared
                if manager.activeIdentity != nil,
                   !manager.matches(offer, controllerDeviceId: controllerDeviceId) {
                    let previousPlayer = self.playerViewModel
                    self.stopRemotePlayback()
                    await previousPlayer?.waitForCleanupCompletion()
                    await manager.end()
                }

                let ready = try await manager.prepare(
                    offer: offer,
                    controllerDeviceId: controllerDeviceId,
                    controllerDeviceName: self.remoteControllerName
                ) { [weak self] challenge in
                    guard let self,
                          self.activeConnectionId == connectionId,
                          self.pendingHandoffRequestId == offer.requestId,
                          let session = self.activeSession else {
                        throw CancellationError()
                    }
                    try await session.send(.handoffChallenge(challenge))
                }

                guard self.activeConnectionId == connectionId,
                      self.pendingHandoffRequestId == offer.requestId else {
                    await manager.end()
                    return
                }
                self.pendingHandoffRequestId = nil
                self.handoffTask = nil
                self.isAuthorized = true
                self.remoteLaunchReady = true
                self.refreshAdvertisement()
                self.activeSession?.enqueue(.handoffReady(ready))
                self.armReadyTimeout(connectionId: connectionId)
            } catch is CancellationError {
                return
            } catch {
                guard self.activeConnectionId == connectionId else { return }
                self.sendHandoffCancel(
                    offer.requestId,
                    reason: (error as? RemotePlaybackIdentityManager.HandoffError)?.cancelReason
                        ?? "handoff_failed",
                    message: error.localizedDescription
                )
                self.pendingHandoffRequestId = nil
                self.handoffTask = nil
            }
        }
    }

    private func armReadyTimeout(connectionId: UUID) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self,
                  self.activeConnectionId == connectionId,
                  self.remoteLaunchReady,
                  self.playerViewModel == nil else { return }
            await RemotePlaybackIdentityManager.shared.end()
            self.remoteLaunchReady = false
            self.pendingPlayerHandoffGeneration = nil
            self.isAuthorized = false
            self.refreshAdvertisement()
            self.sendError(code: "launch_timeout", message: "No content was launched, so the temporary profile was restored.")
            self.closeActiveSession(sendClose: true)
        }
    }

    private func cancelPendingHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
        pendingHandoffRequestId = nil
    }

    private func sendHandoffCancel(_ requestId: String, reason: String, message: String?) {
        activeSession?.enqueue(.handoffCancel(SiloControlHandoffCancel(
            requestId: requestId,
            reason: reason,
            message: message
        )))
    }

    private func handleLaunch(_ launch: SiloControlLaunchRequest) {
        // The launch names the phone's registry key; the identity learned
        // from its hello lets a same-deployment phone on another address
        // launch without a handoff having renamed the effective server.
        let launchIdentity = launch.serverId == remoteControllerServerId
            ? remoteControllerServerIdentity : nil
        guard RemotePlaybackIdentityManager.shared.controllerMatchesEffectiveServer(
            serverId: launch.serverId,
            serverIdentity: launchIdentity
        ) else {
            sendError(code: "server_mismatch", message: "This Apple TV is connected to a different Silo server.")
            return
        }

        let playback = launch.playback
        standbyState = nil
        let generation = RemotePlaybackIdentityManager.shared.activeIdentity?.generationID
        // Replacing a title: the outgoing player still owns this generation
        // and would end the temporary identity on its way out, just as the
        // incoming player starts loading under it. Hand the generation to
        // the new player instead; the old one tears down without ending it.
        if playerViewModel != nil, playerHandoffGeneration == generation {
            playerHandoffGeneration = nil
        }
        pendingPlayerHandoffGeneration = generation
        router?.presentPlayer(
            contentId: playback.contentId,
            fileId: playback.fileId,
            audioTrackIndex: playback.audioTrackIndex,
            subtitleTrackIndex: playback.subtitleTrackIndex,
            startFromBeginning: playback.startFromBeginning,
            resumePosition: playback.resumePosition
        )
        sendLoadingState(for: playback.contentId)
    }

    private func handleControl(_ command: SiloControlCommand) {
        if command.name == .stop {
            stopRemotePlayback()
            return
        }

        // Volume, mute, and next-episode all flow through applySiloControlCommand
        // below; only .stop needs special handling (it dismisses the player).
        guard let playerViewModel else {
            sendError(code: "player_not_ready", message: "The TV player is not ready yet.")
            return
        }

        do {
            try playerViewModel.applySiloControlCommand(command)
            sendState()
        } catch {
            sendError(code: "command_failed", message: error.localizedDescription)
        }
    }

    private func handleConnectionClosed(connectionId: UUID) {
        if pendingConnections[connectionId] != nil {
            dropPendingConnection(connectionId, sendClose: false)
            return
        }
        guard activeConnectionId == connectionId else { return }
        cancelPendingHandoff()
        activeSession = nil
        activeConnectionId = nil
        remoteControllerName = nil
        readTask = nil
        stateTask?.cancel()
        stateTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        missedHeartbeats = 0
        isAuthorized = false
        didReceiveHello = false
        negotiatedVersion = nil
        remoteLaunchReady = false
        remoteControllerDeviceId = nil
        remoteControllerServerId = nil
        remoteControllerServerIdentity = nil
        standbyState = nil
    }

    private func closeActiveSession(sendClose: Bool) {
        cancelPendingHandoff()
        let session = activeSession
        let read = readTask
        activeSession = nil
        activeConnectionId = nil
        remoteControllerName = nil
        readTask = nil
        stateTask?.cancel()
        stateTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        missedHeartbeats = 0
        isAuthorized = false
        didReceiveHello = false
        negotiatedVersion = nil
        remoteLaunchReady = false
        remoteControllerDeviceId = nil
        remoteControllerServerId = nil
        remoteControllerServerIdentity = nil
        standbyState = nil

        guard let session else {
            read?.cancel()
            return
        }
        // Send the goodbye BEFORE cancelling the read task. Cancelling the
        // consumer fires the message stream's onTermination, which tears the
        // connection down and races ahead of the `.close` — the peer then
        // sees a bare EOF, reads it as a dropped connection, and instantly
        // auto-reconnects (the "Disconnect Remote loops right back" bug).
        // Stray inbound messages during the goodbye are dropped by the
        // activeConnectionId guard (already nil).
        Self.logger.info("control: closing session sendClose=\(sendClose, privacy: .public)")
        Task {
            if sendClose {
                await session.closeGracefully()
            } else {
                await session.close()
            }
            read?.cancel()
        }
    }

    private func stopRemotePlayback() {
        playerViewModel = nil
        playerContentId = nil
        stateTask?.cancel()
        stateTask = nil
        router?.presentedPlayer = nil
        refreshStandbyState()
        sendState()
        setPlaybackAdvertised(false)
    }

    private func refreshStandbyState() {
        guard activeSession != nil, isAuthorized, playerViewModel == nil else {
            standbyState = nil
            return
        }
        standbyState = TVControlStandbyState(
            controllerName: remoteControllerName,
            serverName: RemotePlaybackIdentityManager.shared.effectiveServerName
        )
    }

    private func reconcileAuthorizationAfterRestore() {
        remoteLaunchReady = false
        isAuthorized = RemotePlaybackIdentityManager.shared.controllerMatchesEffectiveServer(
            serverId: remoteControllerServerId,
            serverIdentity: remoteControllerServerIdentity
        )
        if isAuthorized {
            sendState()
        } else {
            standbyState = nil
        }
    }

    private func startHeartbeat(connectionId: UUID) {
        heartbeatTask?.cancel()
        missedHeartbeats = 0
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, self.activeConnectionId == connectionId else { return }
                self.missedHeartbeats += 1
                if self.missedHeartbeats > Self.maxMissedHeartbeats {
                    Self.logger.info("control: controller heartbeat timed out; closing session")
                    self.closeActiveSession(sendClose: false)
                    return
                }
                self.activeSession?.enqueue(.ping)
            }
        }
    }

    private func startStateUpdates() {
        stateTask?.cancel()
        guard activeSession != nil else { return }
        stateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.sendState()
            }
        }
    }

    private func sendState() {
        guard isAuthorized, let session = activeSession else { return }
        let state: SiloControlPlaybackState
        if let playerViewModel {
            state = playerViewModel.makeSiloControlPlaybackState(contentId: playerContentId)
        } else {
            state = idleState()
        }
        session.enqueue(.state(state))
    }

    private func sendLoadingState(for contentId: String) {
        guard let session = activeSession else { return }
        let state = SiloControlPlaybackState(
            contentId: contentId,
            sessionId: nil,
            title: "Loading",
            subtitle: nil,
            isPlaying: false,
            isLoading: true,
            isBuffering: false,
            currentTime: 0,
            duration: 0,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioTrackId: nil,
            selectedSubtitleTrackId: nil,
            qualityOptions: [],
            activeQualityId: ApplePlaybackQuality.autoId,
            isQualitySwitching: false,
            playbackSpeed: PlayerSettings.shared.playbackSpeed,
            videoGravity: PlayerSettings.shared.videoGravity.rawValue,
            hdrEnabled: PlayerSettings.shared.hdrEnabled,
            supportsVideoGravity: false,
            volume: 1.0,
            isMuted: false,
            hasNextEpisode: false,
            nextEpisodeTitle: nil,
            error: nil
        )
        session.enqueue(.state(state))
    }

    private func sendError(code: String, message: String) {
        guard let session = activeSession else { return }
        session.enqueue(.error(SiloControlErrorMessage(code: code, message: message)))
    }

    private func makeHello() -> SiloControlMessage {
        let device = AppleDeviceIdentity.current
        return .hello(SiloControlHello(
            role: .tv,
            deviceName: device.name,
            deviceId: device.id,
            serverId: RemotePlaybackIdentityManager.shared.effectiveServerId,
            serverName: RemotePlaybackIdentityManager.shared.effectiveServerName,
            supportedVersions: SiloControlProtocol.supportedVersions,
            serverIdentity: RemotePlaybackIdentityManager.shared.effectiveServerIdentity
        ))
    }

    private func idleState() -> SiloControlPlaybackState {
        SiloControlPlaybackState(
            contentId: nil,
            sessionId: nil,
            title: "Ready",
            subtitle: nil,
            isPlaying: false,
            isLoading: false,
            isBuffering: false,
            currentTime: 0,
            duration: 0,
            audioTracks: [],
            subtitleTracks: [],
            selectedAudioTrackId: nil,
            selectedSubtitleTrackId: nil,
            qualityOptions: [],
            activeQualityId: ApplePlaybackQuality.autoId,
            isQualitySwitching: false,
            playbackSpeed: PlayerSettings.shared.playbackSpeed,
            videoGravity: PlayerSettings.shared.videoGravity.rawValue,
            hdrEnabled: PlayerSettings.shared.hdrEnabled,
            supportsVideoGravity: false,
            volume: 1.0,
            isMuted: false,
            hasNextEpisode: false,
            nextEpisodeTitle: nil,
            error: nil
        )
    }
}
#endif
