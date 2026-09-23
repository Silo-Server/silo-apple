import Foundation
import OSLog

actor PlaybackRealtimeClient {
    typealias CommandHandler = @MainActor (PlaybackRealtimeCommandEnvelope) async throws -> Void
    typealias EventHandler = @MainActor (PlaybackRealtimeEventEnvelope) async -> Void
    /// Mints a fresh single-use ticket for one connect of `sessionId`.
    typealias Handshake = @Sendable (_ sessionId: String, _ authority: PlaybackV2SessionAuthority) async throws
        -> APIv2PlaybackControlHandshake
    typealias OwnerCheck = @Sendable (CapturedOrdinaryRequestAuth) async -> Bool

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlaybackRealtime"
    )

    private let commandHandler: CommandHandler
    private let eventHandler: EventHandler?
    private let session: URLSession
    private let handshake: Handshake
    private let ownerIsCurrent: OwnerCheck
    private let encoder = JSONEncoder()
    private let reconnectDelaysNanos: [UInt64]
    /// After this many consecutive connection failures, stop reconnecting and
    /// flip `isRealtimeUnavailable` so consumers can surface a non-fatal
    /// "realtime control unavailable" notice. Local playback continues; only
    /// remote command/event delivery is degraded.
    private static let consecutiveFailureCircuitBreakerThreshold = 8

    private var boundSessionId: String?
    private var generation: Int = 0
    private var socket: URLSessionWebSocketTask?
    /// Closes the open socket when its ticket's connection lifetime runs out,
    /// so the loop reconnects with a new ticket.
    private var lifetimeTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var seenCommandIds = Set<String>()
    private(set) var isRealtimeConnected = false
    private(set) var isRealtimeUnavailable = false
    private struct ConnectivityObserver {
        let id: UUID
        let handler: (@MainActor (Bool) -> Void)
    }
    private struct UnavailabilityObserver {
        let id: UUID
        let handler: (@MainActor (Bool) -> Void)
    }
    private var connectivityListeners: [ConnectivityObserver] = []
    private var unavailabilityListeners: [UnavailabilityObserver] = []
    /// Serializes notification delivery to listeners. Without this, rapid
    /// state flips can be observed out of order on the MainActor because
    /// independent `Task { @MainActor in }` hops have no FIFO guarantee.
    /// Tracking the in-flight task also lets `unbind` cancel pending
    /// deliveries that no consumer is going to act on.
    private var connectivityNotificationTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    init(
        session: URLSession = .shared,
        handshake: @escaping Handshake = { sessionId, authority in
            // Wait out an identity transition instead of spending reconnect
            // attempts on requests the closed dispatch gate would refuse.
            guard await HTTPClient.shared.waitForRequestDispatchOpen() else { throw CancellationError() }
            return try await SiloAPI.shared.apiV2Client.playbackControlHandshake(
                sessionID: sessionId, installationID: authority.installationID, auth: authority.owner)
        },
        ownerIsCurrent: @escaping OwnerCheck = PlaybackRealtimeClient.isCurrentOwner,
        reconnectDelaysNanos: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000],
        commandHandler: @escaping CommandHandler,
        eventHandler: EventHandler? = nil
    ) {
        self.session = session
        self.handshake = handshake
        self.ownerIsCurrent = ownerIsCurrent
        self.reconnectDelaysNanos = reconnectDelaysNanos
        self.commandHandler = commandHandler
        self.eventHandler = eventHandler
    }

    @Sendable private static func isCurrentOwner(_ owner: CapturedOrdinaryRequestAuth) async -> Bool {
        await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: owner) != nil
    }

    /// Connects the control socket of `sessionId` for the owner and
    /// installation that started it. Every connect mints its own ticket
    /// under that owner; nothing reuses a ticket or the current bearer token.
    func bind(sessionId: String, authority: PlaybackV2SessionAuthority) {
        let normalized = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard boundSessionId != normalized else { return }

        generation += 1
        boundSessionId = normalized
        seenCommandIds.removeAll()
        // Reset the circuit breaker — a new session deserves fresh
        // reconnect budget independent of the previous session's history.
        setRealtimeUnavailable(false)
        closeSocket()
        runTask?.cancel()

        let currentGeneration = generation
        runTask = Task { [weak self] in
            await self?.runConnectionLoop(sessionId: normalized, authority: authority, generation: currentGeneration)
        }
    }

    func unbind() {
        generation += 1
        boundSessionId = nil
        seenCommandIds.removeAll()
        runTask?.cancel()
        runTask = nil
        connectivityNotificationTask?.cancel()
        connectivityNotificationTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        closeSocket()
    }

    private func runConnectionLoop(
        sessionId: String,
        authority: PlaybackV2SessionAuthority,
        generation: Int
    ) async {
        var attempt = 0
        var consecutiveFailures = 0

        while isCurrentBinding(sessionId: sessionId, generation: generation) {
            do {
                // The session belongs to the owner that started it; after an
                // account or profile switch no ticket is minted for it again.
                guard await ownerIsCurrent(authority.owner) else {
                    throw PlaybackSequencedError.authorityChanged
                }
                let ticketed = try await handshake(sessionId, authority)
                try Task.checkCancellation()
                guard isCurrentBinding(sessionId: sessionId, generation: generation) else { break }

                let socket = session.webSocketTask(with: ticketed.request)
                self.socket = socket
                seenCommandIds.removeAll()
                socket.resume()
                closeWhenLifetimeEnds(socket, afterSeconds: ticketed.maxConnectionSeconds)

                try await send(makePlaybackRealtimeHello(sessionId: sessionId), on: socket)
                attempt = 0
                consecutiveFailures = 0
                setRealtimeConnected(true)
                setRealtimeUnavailable(false)
                try await receiveLoop(on: socket, sessionId: sessionId, authority: authority, generation: generation)
            } catch is CancellationError {
                break
            } catch where Self.endsControl(error) {
                // Retrying cannot help: the owner moved on, or the server does
                // not serve the control handshake for it.
                Self.logger.warning(
                    "Realtime control stopped for session \(sessionId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                if isCurrentBinding(sessionId: sessionId, generation: generation) {
                    closeSocket()
                    setRealtimeUnavailable(true)
                }
                break
            } catch {
                consecutiveFailures += 1
                Self.logger.warning(
                    "Realtime websocket loop failed for session \(sessionId, privacy: .public) (consecutive=\(consecutiveFailures)): \(String(describing: error), privacy: .public)"
                )
            }

            // A newer bind or unbind already closed this loop's socket, and
            // `socket` may now hold the next session's connection.
            guard isCurrentBinding(sessionId: sessionId, generation: generation) else {
                break
            }
            closeSocket()

            if consecutiveFailures >= Self.consecutiveFailureCircuitBreakerThreshold {
                Self.logger.error(
                    "Realtime websocket circuit breaker tripped after \(consecutiveFailures) consecutive failures for session \(sessionId, privacy: .public); pausing reconnect attempts"
                )
                setRealtimeUnavailable(true)
                break
            }

            let delay = reconnectDelaysNanos[min(attempt, reconnectDelaysNanos.count - 1)]
            attempt += 1
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    /// Failures that no reconnect can fix: the session's owner is no longer
    /// the current one, the server does not serve the control handshake, or
    /// the server needs an update for v2.
    ///
    /// `HTTPError.requestIdentityChanged` is not one of them. The HTTP client
    /// also throws it while any identity transition holds the dispatch gate,
    /// including ones that leave this owner in place (removing another server,
    /// a refused sign-out). It takes the ordinary backoff, and the owner check
    /// at the top of the next attempt stops the loop if the owner did change.
    private static func endsControl(_ error: Error) -> Bool {
        switch error {
        case PlaybackSequencedError.authorityChanged, PlaybackSequencedError.controlUnavailable,
             HTTPError.authorityChanged, APIv2Error.serverUpdateRequired:
            return true
        default:
            return false
        }
    }

    /// Subscribe to changes in `isRealtimeUnavailable`. The handler runs on
    /// the main actor — consumers (PlayerViewModel) can mutate
    /// `@Observable` state directly. Returns the current value once at
    /// subscription time so observers don't need a separate read. The
    /// returned token must be passed to `removeUnavailabilityObserver`
    /// to avoid leaking observers across binds.
    @discardableResult
    func observeUnavailability(_ handler: @escaping @MainActor (Bool) -> Void) async -> UUID {
        let id = UUID()
        unavailabilityListeners.append(UnavailabilityObserver(id: id, handler: handler))
        let snapshot = isRealtimeUnavailable
        await MainActor.run { handler(snapshot) }
        return id
    }

    /// Subscribe to changes in websocket readiness. This is stricter than
    /// `isRealtimeUnavailable`: it is false before the session websocket has
    /// connected and sent hello, during reconnect gaps, and after unbind.
    @discardableResult
    func observeConnectivity(_ handler: @escaping @MainActor (Bool) -> Void) async -> UUID {
        let id = UUID()
        let observer = ConnectivityObserver(id: id, handler: handler)
        connectivityListeners.append(observer)
        let snapshot = isRealtimeConnected
        notifyConnectivity(snapshot, listeners: [observer])
        return id
    }

    func removeUnavailabilityObserver(_ id: UUID) {
        unavailabilityListeners.removeAll { $0.id == id }
    }

    func removeConnectivityObserver(_ id: UUID) {
        connectivityListeners.removeAll { $0.id == id }
    }

    private func setRealtimeConnected(_ value: Bool) {
        guard isRealtimeConnected != value else { return }
        isRealtimeConnected = value
        notifyConnectivity(value, listeners: connectivityListeners)
    }

    private func notifyConnectivity(_ value: Bool, listeners: [ConnectivityObserver]) {
        connectivityNotificationTask?.cancel()
        connectivityNotificationTask = Task { @MainActor in
            for observer in listeners {
                if Task.isCancelled { return }
                observer.handler(value)
            }
        }
    }

    private func setRealtimeUnavailable(_ value: Bool) {
        guard isRealtimeUnavailable != value else { return }
        isRealtimeUnavailable = value
        let listeners = unavailabilityListeners
        // Replace any in-flight notification task — the new state
        // supersedes whatever the previous task was about to deliver, so
        // listeners always see the latest value last regardless of how
        // fast the state churns.
        notificationTask?.cancel()
        notificationTask = Task { @MainActor in
            for observer in listeners {
                if Task.isCancelled { return }
                observer.handler(value)
            }
        }
    }

    private func receiveLoop(
        on socket: URLSessionWebSocketTask,
        sessionId: String,
        authority: PlaybackV2SessionAuthority,
        generation: Int
    ) async throws {
        while isCurrentBinding(sessionId: sessionId, generation: generation) {
            let message = try await socket.receive()
            // Frames act on this player only while its session owner is the
            // current one.
            guard await ownerIsCurrent(authority.owner) else {
                throw PlaybackSequencedError.authorityChanged
            }
            guard isCurrentBinding(sessionId: sessionId, generation: generation) else { return }
            guard let data = decodeInboundMessageData(message) else { continue }
            guard let inbound = parsePlaybackRealtimeInboundMessage(data) else { continue }

            switch inbound {
            case .event(let event):
                guard event.sessionId == sessionId else { continue }
                await eventHandler?(event)
            case .command(let command):
                guard command.sessionId == sessionId else { continue }
                if seenCommandIds.contains(command.commandId) {
                    continue
                }
                seenCommandIds.insert(command.commandId)

                try await send(
                    makePlaybackRealtimeAck(
                        sessionId: sessionId,
                        commandId: command.commandId
                    ),
                    on: socket
                )

                do {
                    try await commandHandler(command)
                    try await send(
                        makePlaybackRealtimeResult(
                            sessionId: sessionId,
                            commandId: command.commandId,
                            status: .completed
                        ),
                        on: socket
                    )
                } catch let error as PlaybackRealtimeCommandExecutionError {
                    try await send(
                        makePlaybackRealtimeResult(
                            sessionId: sessionId,
                            commandId: command.commandId,
                            status: .rejected,
                            error: error.rejectionReason
                        ),
                        on: socket
                    )
                } catch {
                    try await send(
                        makePlaybackRealtimeResult(
                            sessionId: sessionId,
                            commandId: command.commandId,
                            status: .rejected,
                            error: PlaybackRealtimeCommandExecutionError.commandFailed.rejectionReason
                        ),
                        on: socket
                    )
                }
            }
        }
    }

    private func send<T: Encodable>(
        _ envelope: T,
        on socket: URLSessionWebSocketTask
    ) async throws {
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PlaybackRealtimeTransportError.encodingFailure
        }
        try await socket.send(.string(text))
    }

    private func decodeInboundMessageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private func closeWhenLifetimeEnds(_ socket: URLSessionWebSocketTask, afterSeconds seconds: Int) {
        lifetimeTask?.cancel()
        lifetimeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func closeSocket() {
        setRealtimeConnected(false)
        lifetimeTask?.cancel()
        lifetimeTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func isCurrentBinding(sessionId: String, generation: Int) -> Bool {
        boundSessionId == sessionId && self.generation == generation
    }
}

enum PlaybackRealtimeTransportError: Error {
    case encodingFailure
}
