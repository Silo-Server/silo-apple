import Foundation
import OSLog

actor PlaybackRealtimeClient {
    typealias CommandHandler = @MainActor (PlaybackRealtimeCommandEnvelope) async throws -> Void
    typealias EventHandler = @MainActor (PlaybackRealtimeEventEnvelope) async -> Void

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackRealtime"
    )

    private let commandHandler: CommandHandler
    private let eventHandler: EventHandler?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let reconnectDelaysNanos: [UInt64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
    ]
    /// After this many consecutive connection failures, stop reconnecting and
    /// flip `isRealtimeUnavailable` so consumers can surface a non-fatal
    /// "realtime control unavailable" notice. Local playback continues; only
    /// remote command/event delivery is degraded.
    private static let consecutiveFailureCircuitBreakerThreshold = 8

    private var boundSessionId: String?
    private var generation: Int = 0
    private var socket: URLSessionWebSocketTask?
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
        commandHandler: @escaping CommandHandler,
        eventHandler: EventHandler? = nil
    ) {
        self.session = session
        self.commandHandler = commandHandler
        self.eventHandler = eventHandler
    }

    func bind(sessionId: String) {
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
            await self?.runConnectionLoop(sessionId: normalized, generation: currentGeneration)
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

    private func runConnectionLoop(sessionId: String, generation: Int) async {
        var attempt = 0
        var consecutiveFailures = 0

        while isCurrentBinding(sessionId: sessionId, generation: generation) {
            do {
                let request = try await makeRequest(sessionId: sessionId)
                try Task.checkCancellation()

                let socket = session.webSocketTask(with: request)
                self.socket = socket
                seenCommandIds.removeAll()
                socket.resume()

                try await send(makePlaybackRealtimeHello(sessionId: sessionId), on: socket)
                attempt = 0
                consecutiveFailures = 0
                setRealtimeConnected(true)
                setRealtimeUnavailable(false)
                try await receiveLoop(on: socket, sessionId: sessionId, generation: generation)
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                Self.logger.warning(
                    "Realtime websocket loop failed for session \(sessionId, privacy: .public) (consecutive=\(consecutiveFailures)): \(String(describing: error), privacy: .public)"
                )
            }

            closeSocket()

            guard isCurrentBinding(sessionId: sessionId, generation: generation) else {
                break
            }

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
        connectivityListeners.append(ConnectivityObserver(id: id, handler: handler))
        let snapshot = isRealtimeConnected
        await MainActor.run { handler(snapshot) }
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
        let listeners = connectivityListeners
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
        generation: Int
    ) async throws {
        while isCurrentBinding(sessionId: sessionId, generation: generation) {
            let message = try await socket.receive()
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

    private func makeRequest(sessionId: String) async throws -> URLRequest {
        let serverUrl = await ContinuumAPI.shared.currentServerUrl()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverUrl.isEmpty else {
            throw PlaybackRealtimeTransportError.serverUrlNotConfigured
        }

        guard var components = URLComponents(string: serverUrl) else {
            throw PlaybackRealtimeTransportError.invalidServerURL(serverUrl)
        }

        let normalizedPath = "/api/v1/playback/sessions/\(sessionId)/control/ws"
        let basePath = components.percentEncodedPath
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.percentEncodedPath = trimmedBase + normalizedPath

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }

        guard let url = components.url else {
            throw PlaybackRealtimeTransportError.invalidServerURL(serverUrl)
        }

        var request = URLRequest(url: url)
        if let token = await ContinuumAPI.shared.currentAccessToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            throw PlaybackRealtimeTransportError.missingAccessToken
        }
        return request
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

    private func closeSocket() {
        setRealtimeConnected(false)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func isCurrentBinding(sessionId: String, generation: Int) -> Bool {
        boundSessionId == sessionId && self.generation == generation
    }
}

enum PlaybackRealtimeTransportError: Error {
    case serverUrlNotConfigured
    case invalidServerURL(String)
    case missingAccessToken
    case encodingFailure
}
