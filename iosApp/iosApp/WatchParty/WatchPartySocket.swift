import Foundation

struct WatchPartyClientMessage: Encodable, Sendable {
    let type: String
    var requestId: String? = nil
    var sessionId: String? = nil
    var commandId: String? = nil
    var action: WatchPartyTransportAction? = nil
    var positionSeconds: Double? = nil
    var isPaused: Bool? = nil
    var isReady: Bool? = nil
    var ready: Bool? = nil
    var clientSentAt: Date? = nil

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }()

    func encoded() throws -> String {
        String(decoding: try Self.encoder.encode(self), as: UTF8.self)
    }
}

enum WatchPartyServerMessage: Decodable {
    case snapshot(WatchPartyRoom)
    case transport(WatchPartyTransportCommand)
    case suggestions([WatchPartySuggestion])
    /// `receivedAt` is this device's clock when the frame was decoded, before
    /// it queues behind other room frames for the session.
    case pong(client: Date, received: Date, sent: Date, receivedAt: Date)
    case closed(String)
    case connectionReplaced(reason: String?)
    case error(WatchPartyWorkError)
    case actionResult(requestId: String?, action: String, status: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, room, command, suggestions, clientSentAt, serverReceivedAt, serverSentAt, reason, code, message
        case requestId, retryAfterMs, workStarted, action, status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot": self = .snapshot(try c.decode(WatchPartyRoom.self, forKey: .room))
        case "transport_command": self = .transport(try c.decode(WatchPartyTransportCommand.self, forKey: .command))
        case "suggestions_update": self = .suggestions(try c.decode([WatchPartySuggestion].self, forKey: .suggestions))
        case "pong": self = .pong(client: try c.decode(Date.self, forKey: .clientSentAt),
                                  received: try c.decode(Date.self, forKey: .serverReceivedAt),
                                  sent: try c.decode(Date.self, forKey: .serverSentAt), receivedAt: Date())
        case "room_closed": self = .closed(try c.decodeIfPresent(String.self, forKey: .reason) ?? "ended")
        case "connection_replaced": self = .connectionReplaced(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "error": self = .error(WatchPartyWorkError(code: try c.decode(String.self, forKey: .code),
            message: try c.decode(String.self, forKey: .message), requestId: try c.decodeIfPresent(String.self, forKey: .requestId),
            retryAfterMilliseconds: try c.decodeIfPresent(Int.self, forKey: .retryAfterMs),
            workStarted: try c.decodeIfPresent(Bool.self, forKey: .workStarted)))
        case "action_result": self = .actionResult(requestId: try c.decodeIfPresent(String.self, forKey: .requestId),
            action: try c.decode(String.self, forKey: .action), status: try c.decode(String.self, forKey: .status))
        default: self = .unknown
        }
    }
}

enum WatchPartySocketError: Error {
    case invalidURL, unsupportedProtocol, closed
    case remoteClose(code: Int, reason: String?)

    var isInputShield: Bool {
        if case .remoteClose(let code, let reason) = self {
            return code == 1008 && reason == "realtime input shield"
        }
        return false
    }
}

/// A room connection is separate from the player's playback-control socket.
/// Each instance uses a fresh, single-use ticket and has exactly one receiver.
@MainActor
protocol WatchPartySocketConnection: AnyObject {
    func connect(serverURL: String, roomId: String, ticket: WatchPartySocketTicket) throws -> AsyncThrowingStream<WatchPartySocket.Event, Error>
    func send(_ message: WatchPartyClientMessage) async throws
    func close()
}

@MainActor
final class WatchPartySocket: NSObject, URLSessionWebSocketDelegate, WatchPartySocketConnection {
    enum Event { case opened, message(WatchPartyServerMessage) }
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var artworkServerURL: URL?

    func connect(serverURL: String, roomId: String, ticket: WatchPartySocketTicket) throws -> AsyncThrowingStream<Event, Error> {
        close()
        guard ticket.protocol == "silo.room.v2" else { throw WatchPartySocketError.unsupportedProtocol }
        guard var url = URLComponents(string: serverURL), ["https", "http"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil,
              let roomPath = roomId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) else {
            throw WatchPartySocketError.invalidURL
        }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.percentEncodedPath = WatchPartyLobbyPolicy.basePath(url.percentEncodedPath)
            + "/api/v2/watch-together/rooms/\(roomPath)/ws"
        url.query = nil
        url.fragment = nil
        guard let endpoint = url.url else { throw WatchPartySocketError.invalidURL }
        let stream = AsyncThrowingStream<Event, Error>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuation = continuation
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let socket = session.webSocketTask(with: endpoint, protocols: ["silo.room.v2", "silo.ticket.\(ticket.ticket)"])
        self.session = session
        artworkServerURL = URL(string: serverURL)
        task = socket
        socket.resume()
        return stream
    }

    /// Negotiation publishes `opened` before any room frames enter the stream.
    private func startReceiving(_ socket: URLSessionWebSocketTask) {
        guard receiver == nil, task === socket else { return }
        let decoder = HTTPClient.makeJSONDecoder(artworkServerURL: artworkServerURL)
        receiver = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    guard let self, self.task === socket else { return }
                    let data: Data
                    switch frame {
                    case .data(let bytes): data = bytes
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    let message = try decoder.decode(WatchPartyServerMessage.self, from: data)
                    if case .dropped = self.continuation?.yield(.message(message)) {
                        throw WatchPartySocketError.closed
                    }
                }
            } catch {
                guard let self, self.task === socket else { return }
                let code = socket.closeCode
                if code != .invalid {
                    self.continuation?.finish(throwing: WatchPartySocketError.remoteClose(
                        code: code.rawValue, reason: socket.closeReason.flatMap { String(data: $0, encoding: .utf8) }))
                } else { self.continuation?.finish(throwing: error) }
            }
        }
    }

    func send(_ message: WatchPartyClientMessage) async throws {
        guard let task, receiver != nil else { throw WatchPartySocketError.closed }
        try await task.send(.string(message.encoded()))
    }

    func close() {
        receiver?.cancel()
        receiver = nil
        continuation?.finish()
        continuation = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        artworkServerURL = nil
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.task === webSocketTask else { return }
            guard `protocol` == "silo.room.v2" else {
                self.continuation?.finish(throwing: WatchPartySocketError.unsupportedProtocol)
                self.task?.cancel(with: .protocolError, reason: nil)
                return
            }
            self.continuation?.yield(.opened)
            self.startReceiving(webSocketTask)
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                               didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, self.task === webSocketTask else { return }
            // Once receiving, drain the final queued frame before finishing.
            // A replacement frame followed immediately by closure must not be
            // lost to this delegate callback racing the receive continuation.
            guard self.receiver == nil else { return }
            self.continuation?.finish(throwing: WatchPartySocketError.remoteClose(
                code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.task === task else { return }
            guard self.receiver == nil else { return }
            // A refused upgrade never calls didOpen, so it has no receive loop
            // to report its failure. Task completion must release that waiter.
            self.continuation?.finish(throwing: error ?? WatchPartySocketError.closed)
        }
    }
}
