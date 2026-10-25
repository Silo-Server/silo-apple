#if os(tvOS)
import Foundation
import Network
import OSLog

/// Serves every SiloControl controller connected to this TV: phones,
/// tablets, and integrations such as Home Assistant. Each controller has its
/// own connection, heartbeat and authorization. The player, the temporary
/// phone identity, the one in-flight handoff and the standby screen are
/// shared by all of them.
@MainActor
@Observable
final class TVControlReceiver {
    static let shared = TVControlReceiver()

    /// One connected controller.
    @MainActor
    private final class Controller {
        let id = UUID()
        /// Order of acceptance; lower is older.
        let sequence: Int
        let session: SiloControlSession
        var readTask: Task<Void, Never>?
        var heartbeatTask: Task<Void, Never>?
        var authWatchdogTask: Task<Void, Never>?
        var missedHeartbeats = 0
        var didReceiveHello = false
        var isAuthorized = false
        var negotiatedVersion: Int?
        var deviceName: String?
        var deviceId: String?
        var serverId: String?
        var serverIdentity: String?
        var features: Set<String> = []
        var passive = false
        /// The temporary identity generation this controller's handoff
        /// produced. A v2 launch needs it to equal the active generation.
        var readyGeneration: UUID?
        var commandBudget = SiloControlReceiverPolicy.CommandBudget()
        var rateLimitNoticeAt: Date?

        init(sequence: Int, session: SiloControlSession) {
            self.sequence = sequence
            self.session = session
        }

        func supports(_ feature: String) -> Bool {
            features.contains(feature)
        }

        func summary(isHandingOff: Bool) -> SiloControlReceiverPolicy.ControllerSummary {
            .init(id: id, sequence: sequence, didReceiveHello: didReceiveHello, passive: passive,
                  isAuthorized: isAuthorized, isHandingOff: isHandingOff)
        }
    }

    private struct PendingHandoff: Equatable {
        let controllerId: UUID
        let requestId: String
    }

    /// Who may reuse the active temporary identity without a new approval:
    /// the connection whose handoff installed it, or whoever presents the
    /// resume token issued to that connection.
    private struct IssuedIdentity {
        let generation: UUID
        var connectionId: UUID?
        let resumeToken: String?
    }

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
    private var controllers: [UUID: Controller] = [:]
    private var controllerSequence = 0
    private(set) var standbyState: TVControlStandbyState?
    private var stateTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var pendingHandoff: PendingHandoff?
    private var issuedIdentity: IssuedIdentity?
    /// Session teardown of a player a handoff stopped. Kept apart from the
    /// handoff, so a replacement handoff still waits for it.
    private var playerCleanupTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private static let heartbeatInterval: Duration = .seconds(3)
    private static let maxMissedHeartbeats = 3      // ~9–12s of silence ⇒ dead
    private static let authGracePeriod: Duration = .seconds(5)
    private static let readyTimeout: Duration = .seconds(60)
    private weak var playerViewModel: PlayerViewModel?
    private var playerContentId: String?
    private var playerHandoffGeneration: UUID?
    private var pendingPlayerHandoffGeneration: UUID?
    /// A terminally rejected handoff does not need a best-effort logout, but
    /// player teardown is asynchronous. Carry its exact generation through
    /// `unregisterPlayer` so a replacement handoff is never treated as the
    /// rejected one.
    private var rejectedPlayerHandoffGeneration: UUID?
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "control.receiver"
    )

    /// Poster and synopsis for the playing title, sent with its state.
    private let nowPlayingMetadata = SiloControlNowPlayingMetadataResolver()

    private init() {
        nowPlayingMetadata.onChange = { [weak self] in self?.broadcastState() }
    }

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
        for id in Array(controllers.keys) {
            closeController(id, reason: nil, sendClose: false)
        }
    }

    /// The TV's own Disconnect (standby screen button or Menu). Closes every
    /// controller that put the standby screen up; passive ones (integrations,
    /// silent auto-resume) never did and stay connected.
    func disconnectRemoteControl() {
        for controller in controllers.values where !controller.passive {
            closeController(controller.id, reason: SiloControlCloseReason.tvDisconnected)
        }
    }

    func temporaryAuthExpired(expected event: SessionExpiryEvent) {
        let expectedGenerationID = event.account.credentialGenerationID
        guard event.disposition == .temporarySessionExpired,
              RemotePlaybackIdentityManager.shared.activeIdentity?.generationID == expectedGenerationID else {
            return
        }
        rejectedPlayerHandoffGeneration = expectedGenerationID
        // Everyone watching loses the title, not only the phone that lent it.
        broadcast(.error(SiloControlErrorMessage(
            code: "temporary_session_expired",
            message: "The phone profile session expired."
        )))
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
                self?.reconcileAuthorization()
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
        refreshStandbyState()
        updateStateTicks()
        broadcastState()
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
        nowPlayingMetadata.track(contentId: nil)
        refreshStandbyState()
        broadcastState()
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
                self?.reconcileAuthorization()
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) async {
        let session = SiloControlSession(connection: connection)
        let existing = controllers.values.map { $0.summary(isHandingOff: pendingHandoff?.controllerId == $0.id) }
        switch SiloControlReceiverPolicy.admission(existing: existing) {
        case .admit:
            break
        case .admitEvicting(let id):
            Self.logger.info("control: at controller limit; closing an idle connection")
            closeController(id, reason: SiloControlCloseReason.tooManyControllers)
        case .refuse:
            Self.logger.info("control: at controller limit; refusing a new controller")
            let stream = await session.open()
            try? await session.send(makeHello())
            session.enqueue(.error(SiloControlErrorMessage(
                code: "too_many_controllers",
                message: "Too many devices are controlling this Apple TV. Disconnect one and try again."
            )))
            // The peer's features aren't known yet, but every shipped decoder
            // ignores the `close` payload. Without the reason, a phone that
            // saw `multi_controller` in the hello would forget this TV.
            await session.closeGracefully(reason: SiloControlCloseReason.tooManyControllers)
            withExtendedLifetime(stream) {}
            return
        }

        controllerSequence += 1
        let controller = Controller(sequence: controllerSequence, session: session)
        controllers[controller.id] = controller
        let stream = await session.open()
        // `stop()` may have run while the connection opened.
        guard controllers[controller.id] === controller else {
            await session.close()
            return
        }
        startReadLoop(stream: stream, controller: controller)
        startHeartbeat(controller)
        startAuthWatchdog(controller)

        do {
            try await session.send(makeHello())
        } catch {
            closeController(controller.id, reason: nil, sendClose: false)
        }
    }

    private func startReadLoop(
        stream: AsyncThrowingStream<SiloControlMessage, Error>,
        controller: Controller
    ) {
        let controllerId = controller.id
        // Inherits the main actor, so frames are handled without a hop. A
        // failed stream gets no error frame: the connection is already gone.
        controller.readTask = Task { [weak self] in
            do {
                for try await message in stream {
                    self?.handle(message, from: controllerId)
                }
            } catch {}
            self?.closeController(controllerId, reason: nil, sendClose: false)
        }
    }

    private func handle(_ message: SiloControlMessage, from controllerId: UUID) {
        guard let controller = controllers[controllerId] else { return }
        // NOTE: liveness is reset only on `.pong` (below), not on every inbound
        // message. A `.pong` is the controller's reply to our ping, so it's the
        // only message that proves the controller can still *receive* from us.
        // Resetting on any inbound (e.g. the controller's own pings) would let a
        // half-open connection — controller's receive path dead but its send
        // path alive — keep the session pinned open forever.
        switch message {
        case .hello(let hello):
            handleHello(hello, from: controller)
        case .handoffOffer(let offer):
            guard (controller.negotiatedVersion ?? 0) >= 2, let controllerDeviceId = controller.deviceId else {
                sendHandoffCancel(offer.requestId, reason: "version_unsupported",
                                  message: "Update Silo on both devices to continue.", to: controller)
                return
            }
            beginHandoff(offer, from: controller, controllerDeviceId: controllerDeviceId)
        case .handoffCancel(let cancel):
            guard pendingHandoff == PendingHandoff(controllerId: controller.id, requestId: cancel.requestId) else {
                return
            }
            cancelPendingHandoff()
        case .launch(let launch):
            guard controller.isAuthorized else {
                sendError(code: "unauthorized", message: "Connect with a matching Silo account first.", to: controller)
                return
            }
            if (controller.negotiatedVersion ?? 0) >= 2,
               !SiloControlReceiverPolicy.canLaunch(
                   readyGeneration: controller.readyGeneration,
                   activeGeneration: RemotePlaybackIdentityManager.shared.activeIdentity?.generationID
               ) {
                sendError(code: "handoff_required", message: "Prepare the phone profile before playing.", to: controller)
                return
            }
            handleLaunch(launch, from: controller)
        case .control(let command):
            guard controller.isAuthorized else {
                sendError(code: "unauthorized", message: "Connect with a matching Silo account first.", to: controller)
                return
            }
            guard controller.commandBudget.allow() else {
                noteRateLimited(controller)
                return
            }
            handleControl(command, from: controller)
        case .unsupportedControl(let name):
            // An older v2 controller sent a command this build retired (e.g.
            // `set_hdr_enabled`). Drop it silently rather than replying with
            // `.error`: the phone renders an error frame as a user-visible
            // banner and abandons a silent auto-resume, so a stale button on
            // an old remote would look like a broken connection. Ignoring it
            // matches what the user sees anyway — nothing happens.
            Self.logger.info("control: ignoring unsupported command \(name, privacy: .public)")
        case .presence(let presence):
            guard controller.didReceiveHello else { return }
            controller.passive = presence.passive
            refreshStandbyState()
        case .unsupported(let type):
            // A newer controller sent a message type this build predates.
            // Drop it silently, for the same reason as `.unsupportedControl`.
            Self.logger.info("control: ignoring unsupported message type \(type, privacy: .public)")
        case .ping:
            controller.session.enqueue(.pong)
        case .pong:
            controller.missedHeartbeats = 0
        case .state, .error, .handoffChallenge, .handoffReady:
            break
        case .close:
            closeController(controller.id, reason: nil, sendClose: false)
        }
    }

    private func handleHello(_ hello: SiloControlHello, from controller: Controller) {
        guard !controller.didReceiveHello else { return }
        // Read first, so even a refusal below can carry a close reason.
        controller.features = Set(hello.features ?? [])
        guard hello.role == .phone,
              let version = SiloControlProtocol.negotiatedVersion(with: hello.supportedVersions),
              let serverId = hello.serverId, !serverId.isEmpty else {
            sendError(code: "version_unsupported", message: "Update Silo on both devices to continue.", to: controller)
            closeController(controller.id, reason: SiloControlCloseReason.unauthorized)
            return
        }
        controller.didReceiveHello = true
        controller.negotiatedVersion = version
        controller.authWatchdogTask?.cancel(); controller.authWatchdogTask = nil
        controller.deviceName = hello.deviceName
        controller.deviceId = hello.deviceId
        controller.serverId = serverId
        controller.serverIdentity = ServerIdentity.usable(hello.serverIdentity)
        controller.passive = hello.passive == true

        let matchesServer = RemotePlaybackIdentityManager.shared.controllerMatchesEffectiveServer(
            serverId: serverId,
            serverIdentity: controller.serverIdentity
        )
        // A v2 cross-server controller may stay connected, unauthorized,
        // to complete server-mediated identity handoff.
        guard matchesServer || version >= 2 else {
            sendError(code: "server_mismatch",
                      message: "This Apple TV is connected to a different Silo server.", to: controller)
            closeController(controller.id, reason: SiloControlCloseReason.unauthorized)
            return
        }

        // The device's older sockets are ones it has abandoned. Only a
        // connection the TV keeps replaces them, so a refused hello can't
        // knock out a working one.
        let replaced = SiloControlReceiverPolicy.connectionsReplaced(
            byHelloFrom: hello.deviceId,
            on: controller.id,
            existing: controllers.values.map { (id: $0.id, deviceId: $0.deviceId) }
        )
        for id in replaced {
            closeController(id, reason: SiloControlCloseReason.replaced)
        }

        controller.isAuthorized = matchesServer
        guard matchesServer else { return }
        refreshStandbyState()
        updateStateTicks()
        sendState(to: controller)
    }

    // MARK: - Handoff

    private func beginHandoff(
        _ offer: SiloControlHandoffOffer,
        from controller: Controller,
        controllerDeviceId: String
    ) {
        let manager = RemotePlaybackIdentityManager.shared
        // A handoff stops what is on screen before the swap, so consent is
        // asked here, not at launch, and checked again before the stop.
        let canConfirm = controller.supports(SiloControlFeature.replaceConfirmation)
        if let nowPlaying = titleNeedingConsent(for: offer, canConfirm: canConfirm) {
            sendReplaceConfirmationRequired(offer.requestId, nowPlaying: nowPlaying, to: controller)
            return
        }

        if let pending = pendingHandoff, pending.controllerId != controller.id,
           let other = controllers[pending.controllerId] {
            sendHandoffCancel(
                pending.requestId,
                reason: SiloControlHandoffCancelReason.superseded,
                message: "\(controller.deviceName ?? "Another device") started playing on this TV.",
                to: other
            )
        }
        cancelPendingHandoff()
        let pending = PendingHandoff(controllerId: controller.id, requestId: offer.requestId)
        pendingHandoff = pending

        let activeGeneration = manager.activeIdentity?.generationID
        let issued = issuedIdentity.flatMap { $0.generation == activeGeneration ? $0 : nil }
        let allowReuse = SiloControlReceiverPolicy.mayReuseIdentity(
            offerMatchesIdentity: manager.matches(offer, controllerDeviceId: controllerDeviceId),
            identityConnection: issued?.connectionId,
            connection: controller.id,
            issuedResumeToken: issued?.resumeToken,
            offeredResumeToken: offer.resumeToken
        )
        let controllerId = controller.id
        let controllerName = controller.deviceName

        handoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let ready = try await manager.prepare(
                    offer: offer,
                    controllerDeviceId: controllerDeviceId,
                    controllerDeviceName: controllerName,
                    allowReuse: allowReuse,
                    beforeActivation: { [weak self] in
                        guard let self else { return }
                        // Another controller may have started a title while
                        // the server approved this one.
                        if let nowPlaying = self.titleNeedingConsent(for: offer, canConfirm: canConfirm) {
                            throw ReplaceConfirmationRequired(nowPlaying: nowPlaying)
                        }
                        try await self.stopPlaybackBeforeIdentitySwap()
                    }
                ) { [weak self] challenge in
                    guard let self,
                          self.pendingHandoff == pending,
                          let session = self.controllers[controllerId]?.session else {
                        throw CancellationError()
                    }
                    try await session.send(.handoffChallenge(challenge))
                }

                let generation = manager.activeIdentity?.generationID
                guard self.pendingHandoff == pending,
                      let controller = self.controllers[controllerId],
                      let generation else {
                    // The controller left or was superseded after approval.
                    // A fresh identity nobody can launch under is handed back;
                    // a reused one may still be playing.
                    if !ready.reused, let generation {
                        await manager.end(expectedGenerationID: generation)
                        self.refreshAdvertisement()
                        self.reconcileAuthorization()
                    }
                    return
                }
                self.pendingHandoff = nil
                self.handoffTask = nil
                self.completeHandoff(ready, generation: generation, for: controller)
            } catch is CancellationError {
                return
            } catch {
                guard let controller = self.controllers[controllerId] else { return }
                if let refusal = error as? ReplaceConfirmationRequired {
                    self.sendReplaceConfirmationRequired(offer.requestId, nowPlaying: refusal.nowPlaying, to: controller)
                } else {
                    self.sendHandoffCancel(
                        offer.requestId,
                        reason: (error as? RemotePlaybackIdentityManager.HandoffError)?.cancelReason
                            ?? "handoff_failed",
                        message: error.localizedDescription,
                        to: controller
                    )
                }
                if self.pendingHandoff == pending {
                    self.pendingHandoff = nil
                    self.handoffTask = nil
                }
            }
        }
    }

    private func completeHandoff(_ ready: SiloControlHandoffReady, generation: UUID, for controller: Controller) {
        // Readiness is this controller's alone: an earlier controller's
        // launch must never play under this profile.
        for other in controllers.values where other.id != controller.id {
            other.readyGeneration = nil
        }
        controller.readyGeneration = generation
        controller.isAuthorized = true

        var resumeToken: String?
        if controller.supports(SiloControlFeature.resumeToken) {
            resumeToken = issuedIdentity.flatMap { $0.generation == generation ? $0.resumeToken : nil }
                ?? SiloControlReceiverPolicy.makeResumeToken()
        }
        issuedIdentity = IssuedIdentity(generation: generation, connectionId: controller.id, resumeToken: resumeToken)

        refreshAdvertisement()
        // A cross-server identity changes the effective server under the
        // other controllers.
        reconcileAuthorization()
        var reply = ready
        reply.resumeToken = resumeToken
        controller.session.enqueue(.handoffReady(reply))
        armReadyTimeout(generation: generation, controllerId: controller.id)
    }

    /// Stops what is playing, waits for its server session to close, then ends
    /// an earlier phone's identity. An approved handoff runs this just before
    /// it installs the phone's identity, including for a title the TV started
    /// under its own account: the player's stop rides on the identity it
    /// started under, so after the swap it is refused and the session lingers
    /// beside the phone's.
    private func stopPlaybackBeforeIdentitySwap() async throws {
        let manager = RemotePlaybackIdentityManager.shared
        if let player = playerViewModel {
            stopRemotePlayback()
            // Chained, so a stop a cancelled handoff left running is still awaited.
            let earlierCleanup = playerCleanupTask
            playerCleanupTask = Task {
                await earlierCleanup?.value
                await player.waitForCleanupCompletion()
            }
        } else if manager.activeIdentity != nil {
            stopRemotePlayback()
        }
        // Also covers a stop an earlier, replaced handoff started.
        if let cleanup = playerCleanupTask {
            await cleanup.value
            if playerCleanupTask == cleanup { playerCleanupTask = nil }
        }
        try Task.checkCancellation()
        // Something started playing on the TV meanwhile; swapping the identity
        // now would strand that player's session instead.
        guard playerViewModel == nil else { throw PlaybackStartedDuringHandoff() }
        if manager.activeIdentity != nil {
            await manager.end()
        }
    }

    private struct PlaybackStartedDuringHandoff: LocalizedError {
        var errorDescription: String? { "The TV started playing something else. Try again." }
    }

    private struct ReplaceConfirmationRequired: Error {
        let nowPlaying: SiloControlNowPlayingSummary
    }

    /// What `offer` would replace without its user's consent, or nil when
    /// the handoff may go ahead.
    private func titleNeedingConsent(
        for offer: SiloControlHandoffOffer,
        canConfirm: Bool
    ) -> SiloControlNowPlayingSummary? {
        let nowPlaying = nowPlayingSummary()
        let needsConsent = SiloControlReceiverPolicy.needsReplaceConfirmation(
            titleOnScreen: isTitleOnScreen,
            playingUnderOfferedProfile: isPlaying(underProfileOf: offer),
            replaceConfirmed: SiloControlReceiverPolicy.confirmationCovers(
                onScreenContentId: nowPlaying.contentId,
                replaceConfirmed: offer.replaceConfirmed == true,
                replacingContentId: offer.replacingContentId
            ),
            controllerCanConfirm: canConfirm
        )
        return needsConsent ? nowPlaying : nil
    }

    private func sendReplaceConfirmationRequired(
        _ requestId: String,
        nowPlaying: SiloControlNowPlayingSummary,
        to controller: Controller
    ) {
        sendHandoffCancel(
            requestId,
            reason: SiloControlHandoffCancelReason.replaceConfirmationRequired,
            message: "\(nowPlaying.profileName ?? "Someone") is watching \(nowPlaying.title) on this TV.",
            nowPlaying: nowPlaying,
            to: controller
        )
    }

    /// Hands back an identity nobody launched under. Runs whether or not the
    /// controller that asked for it is still connected: a phone that leaves
    /// after `handoff_ready` must not leave its profile on the TV.
    private func armReadyTimeout(generation: UUID, controllerId: UUID) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readyTimeout)
            guard let self, !Task.isCancelled,
                  RemotePlaybackIdentityManager.shared.activeIdentity?.generationID == generation,
                  self.playerViewModel == nil,
                  self.router?.presentedPlayer == nil else { return }
            guard await RemotePlaybackIdentityManager.shared.end(expectedGenerationID: generation) else { return }
            self.pendingPlayerHandoffGeneration = nil
            self.refreshAdvertisement()
            self.reconcileAuthorization()
            guard let controller = self.controllers[controllerId] else { return }
            self.sendError(code: "launch_timeout",
                           message: "No content was launched, so the temporary profile was restored.",
                           to: controller)
            // A cross-server controller can't do anything else here.
            if !controller.isAuthorized {
                self.closeController(controllerId, reason: SiloControlCloseReason.launchTimeout)
            }
        }
    }

    private func cancelPendingHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
        pendingHandoff = nil
    }

    /// A title is on screen or on its way there.
    private var isTitleOnScreen: Bool {
        playerViewModel != nil || router?.presentedPlayer != nil
    }

    /// Whether what is on screen plays under the profile `offer` names. The
    /// TV plays under the temporary identity when one is active, else under
    /// its own saved profile.
    private func isPlaying(underProfileOf offer: SiloControlHandoffOffer) -> Bool {
        if let identity = RemotePlaybackIdentityManager.shared.activeIdentity {
            return identity.profileId == offer.profileId && ServerRegistry.serversMatch(
                serverId: identity.serverId, verifiedServerId: identity.serverIdentity,
                serverId: offer.serverId, verifiedServerId: offer.serverIdentity
            )
        }
        guard let server = ServerRegistry.shared.activeServer,
              let profileId = ServerRegistry.shared.activeProfileId else { return false }
        return profileId == offer.profileId && ServerRegistry.serversMatch(
            serverId: server.id, verifiedServerId: server.verifiedServerId,
            serverId: offer.serverId, verifiedServerId: offer.serverIdentity
        )
    }

    private func nowPlayingSummary() -> SiloControlNowPlayingSummary {
        let state = playerViewModel?.makeSiloControlPlaybackState(contentId: playerContentId)
        let identity = RemotePlaybackIdentityManager.shared.activeIdentity
        let startedByPhone = identity != nil && playerHandoffGeneration == identity?.generationID
        // Under a borrowed identity only its own name is right. Phones that
        // don't send one (Android today) leave it nil, and the prompt then
        // says "Someone" rather than naming the TV's own profile.
        let profileName = identity.map(\.profileName) ?? CurrentProfileStore.shared.profile?.name
        return SiloControlNowPlayingSummary(
            contentId: state?.contentId ?? playerContentId,
            title: state?.title ?? "a title",
            subtitle: state?.subtitle,
            profileName: profileName,
            controllerName: startedByPhone ? identity?.controllerDeviceName : nil
        )
    }

    // MARK: - Launch and control

    private func handleLaunch(_ launch: SiloControlLaunchRequest, from controller: Controller) {
        // The launch names the phone's registry key; the identity learned
        // from its hello lets a same-deployment phone on another address
        // launch without a handoff having renamed the effective server.
        let launchIdentity = launch.serverId == controller.serverId
            ? controller.serverIdentity : nil
        guard RemotePlaybackIdentityManager.shared.controllerMatchesEffectiveServer(
            serverId: launch.serverId,
            serverIdentity: launchIdentity
        ) else {
            sendError(code: "server_mismatch",
                      message: "This Apple TV is connected to a different Silo server.", to: controller)
            return
        }

        let playback = launch.playback
        standbyState = nil
        let generation = RemotePlaybackIdentityManager.shared.activeIdentity?.generationID
        if let player = playerViewModel,
           SiloControlReceiverPolicy.canReplaceInPlayer(
               playerGeneration: playerHandoffGeneration, activeGeneration: generation,
               playerIsDisposed: player.needsReplacementForPresentation,
               playerIsWatchParty: player.isWatchPartyPlayback
           ) {
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            playerContentId = playback.contentId
            player.replaceSiloControlPlayback(playback)
            DiagnosticsCoordinator.recordBreadcrumb(
                category: .playback, tag: "SiloControl",
                message: "remote playback replaced in existing player"
            )
            broadcastState()
            return
        }
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
            pinsVersion: playback.pinsVersion == true,
            audioTrackIndex: playback.audioTrackIndex,
            subtitleTrackIndex: playback.subtitleTrackIndex,
            startFromBeginning: playback.startFromBeginning,
            resumePosition: playback.resumePosition
        )
        broadcast(.state(placeholderState(contentId: playback.contentId, title: "Loading", isLoading: true)))
    }

    private func handleControl(_ command: SiloControlCommand, from controller: Controller) {
        // .stop goes through the receiver, so it also clears a title still loading (no player registered yet).
        if command.name == .stop {
            stopRemotePlayback()
            return
        }

        guard let playerViewModel else {
            sendError(code: "player_not_ready", message: "The TV player is not ready yet.", to: controller)
            return
        }

        do {
            try playerViewModel.applySiloControlCommand(command)
            broadcastState()
        } catch {
            sendError(code: "command_failed", message: error.localizedDescription, to: controller)
        }
    }

    /// Tells a controller over its command budget once a second at most;
    /// replying to every dropped command would only add to the flood.
    private func noteRateLimited(_ controller: Controller) {
        let now = Date()
        if let last = controller.rateLimitNoticeAt, now.timeIntervalSince(last) < 1 { return }
        controller.rateLimitNoticeAt = now
        Self.logger.info("control: rate-limiting a controller")
        sendError(code: "rate_limited", message: "Too many commands. Slow down and try again.", to: controller)
    }

    // MARK: - Teardown and authorization

    /// The one exit for a controller. Closing one never touches playback,
    /// the temporary identity, or the other controllers.
    private func closeController(_ id: UUID, reason: String?, sendClose: Bool = true) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.heartbeatTask?.cancel(); controller.heartbeatTask = nil
        controller.authWatchdogTask?.cancel(); controller.authWatchdogTask = nil
        if pendingHandoff?.controllerId == id {
            cancelPendingHandoff()
        }
        // Reuse from here on needs the resume token.
        if issuedIdentity?.connectionId == id {
            issuedIdentity?.connectionId = nil
        }
        refreshStandbyState()
        updateStateTicks()

        let session = controller.session
        let read = controller.readTask
        let wireReason = controller.supports(SiloControlFeature.closeReason) ? reason : nil
        // Send the goodbye BEFORE cancelling the read task. Cancelling the
        // consumer fires the message stream's onTermination, which tears the
        // connection down and races ahead of the `.close` — the peer then
        // sees a bare EOF, reads it as a dropped connection, and instantly
        // auto-reconnects. Stray inbound messages during the goodbye are
        // dropped: the controller is no longer in `controllers`.
        Self.logger.info("control: closing controller sendClose=\(sendClose, privacy: .public) reason=\(reason ?? "none", privacy: .public)")
        Task {
            if sendClose {
                await session.closeGracefully(reason: wireReason)
            } else {
                await session.close()
            }
            read?.cancel()
        }
    }

    /// Stops what is on screen. The player is torn down here rather than from
    /// its view's disappearance: a title started from a TV detail page is a
    /// pushed route, which clearing `presentedPlayer` never dismisses.
    private func stopRemotePlayback() {
        playerViewModel?.stopAndClose()
        playerViewModel = nil
        playerContentId = nil
        stateTask?.cancel()
        stateTask = nil
        router?.presentedPlayer = nil
        refreshStandbyState()
        broadcastState()
        setPlaybackAdvertised(false)
    }

    /// The standby screen shows while an authorized, non-passive controller
    /// waits and nothing is on screen. It names the newest such controller.
    private func refreshStandbyState() {
        let waiting = controllers.values.filter { $0.isAuthorized && !$0.passive }
        guard !isTitleOnScreen, let newest = waiting.max(by: { $0.sequence < $1.sequence }) else {
            standbyState = nil
            return
        }
        standbyState = TVControlStandbyState(
            controllerName: newest.deviceName,
            serverName: RemotePlaybackIdentityManager.shared.effectiveServerName,
            otherControllerCount: waiting.count - 1
        )
    }

    /// Re-checks every controller against the effective server after the
    /// temporary identity changed (handoff, restore, timeout). Readiness
    /// survives only for the identity still active.
    private func reconcileAuthorization() {
        let manager = RemotePlaybackIdentityManager.shared
        let activeGeneration = manager.activeIdentity?.generationID
        for controller in controllers.values {
            // Its own identity ended (title over, ready timeout, expiry);
            // another controller's handoff clears readiness before this runs.
            let ownIdentityEnded = controller.readyGeneration != nil
                && controller.readyGeneration != activeGeneration
            if controller.readyGeneration != activeGeneration {
                controller.readyGeneration = nil
            }
            guard controller.didReceiveHello else { continue }
            let wasAuthorized = controller.isAuthorized
            controller.isAuthorized = manager.controllerMatchesEffectiveServer(
                serverId: controller.serverId,
                serverIdentity: controller.serverIdentity
            ) || (activeGeneration != nil && controller.readyGeneration == activeGeneration)
            if controller.isAuthorized, !wasAuthorized {
                sendState(to: controller)
            } else if !controller.isAuthorized, wasAuthorized, !ownIdentityEnded {
                sendError(code: "server_mismatch",
                          message: "This Apple TV is now playing from a different Silo server.",
                          to: controller)
            }
        }
        refreshStandbyState()
        updateStateTicks()
    }

    private func startHeartbeat(_ controller: Controller) {
        let controllerId = controller.id
        controller.heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, let controller = self.controllers[controllerId] else { return }
                controller.missedHeartbeats += 1
                if controller.missedHeartbeats > Self.maxMissedHeartbeats {
                    Self.logger.info("control: controller heartbeat timed out; closing it")
                    self.closeController(controllerId, reason: nil, sendClose: false)
                    return
                }
                controller.session.enqueue(.ping)
            }
        }
    }

    private func startAuthWatchdog(_ controller: Controller) {
        let controllerId = controller.id
        controller.authWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.authGracePeriod)
            guard let self, let controller = self.controllers[controllerId], !controller.didReceiveHello else {
                return
            }
            Self.logger.info("control: controller never said hello; closing it")
            self.closeController(controllerId, reason: SiloControlCloseReason.timeout)
        }
    }

    // MARK: - Outbound

    /// Ticks state out only while a title plays and an authorized controller
    /// is listening, so ordinary TV playback runs no timer.
    private func updateStateTicks() {
        guard playerViewModel != nil, controllers.values.contains(where: \.isAuthorized) else {
            stateTask?.cancel()
            stateTask = nil
            // Nobody to send artwork to, so stop keeping its URL signed.
            nowPlayingMetadata.track(contentId: nil)
            return
        }
        guard stateTask == nil else { return }
        stateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.broadcastState()
            }
        }
    }

    private func currentState() -> SiloControlPlaybackState {
        guard let playerViewModel else {
            nowPlayingMetadata.track(contentId: nil)
            return idleState()
        }
        var state = playerViewModel.makeSiloControlPlaybackState(contentId: playerContentId)
        // Follows the live content ID, so an autoplayed next episode drops
        // the previous title's poster on its first tick.
        nowPlayingMetadata.track(contentId: state.contentId)
        let metadata = nowPlayingMetadata.metadata(for: state.contentId)
        state.posterUrl = metadata?.posterUrl
        state.overview = metadata?.overview
        return state
    }

    /// Built once per tick and shared by every authorized controller.
    private func broadcastState() {
        guard controllers.values.contains(where: \.isAuthorized) else { return }
        broadcast(.state(currentState()))
    }

    private func sendState(to controller: Controller) {
        guard controller.isAuthorized else { return }
        controller.session.enqueue(.state(currentState()))
    }

    /// Sends `message` to every authorized controller.
    private func broadcast(_ message: SiloControlMessage) {
        for controller in controllers.values where controller.isAuthorized {
            controller.session.enqueue(message)
        }
    }

    /// Replies go to the controller that caused them, never to the others.
    private func sendError(code: String, message: String, to controller: Controller) {
        controller.session.enqueue(.error(SiloControlErrorMessage(code: code, message: message)))
    }

    private func sendHandoffCancel(
        _ requestId: String,
        reason: String,
        message: String?,
        nowPlaying: SiloControlNowPlayingSummary? = nil,
        to controller: Controller
    ) {
        controller.session.enqueue(.handoffCancel(SiloControlHandoffCancel(
            requestId: requestId,
            reason: reason,
            message: message,
            nowPlaying: nowPlaying
        )))
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
            serverIdentity: RemotePlaybackIdentityManager.shared.effectiveServerIdentity,
            features: SiloControlFeature.receiverFeatures
        ))
    }

    private func idleState() -> SiloControlPlaybackState {
        placeholderState(contentId: nil, title: "Ready", isLoading: false)
    }

    /// State for a TV with no playing title: idle, or loading `contentId`.
    private func placeholderState(contentId: String?, title: String, isLoading: Bool) -> SiloControlPlaybackState {
        SiloControlPlaybackState(
            contentId: contentId,
            sessionId: nil,
            title: title,
            subtitle: nil,
            isPlaying: false,
            isLoading: isLoading,
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
