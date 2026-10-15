import Foundation
import Network
@testable import Silo

/// A loopback origin whose connections document redirects to another path,
/// where a different document waits: a saved address that sends the local
/// route's pin read somewhere else. A real listener, so the redirect takes
/// URLSession's own path, which a `URLProtocol` stub cannot reproduce.
final class RedirectingOrigin: @unchecked Sendable {
    static let elsewherePath = "/elsewhere" + ServerIdentity.connectionsPath

    private let queue = DispatchQueue(label: "SiloTests.RedirectingOrigin")
    private let listener: NWListener
    private let document: Data
    private var connections: [NWConnection] = []
    private var paths: [String] = []
    private var startContinuation: CheckedContinuation<String, Error>?

    init(document: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.document = Data(document.utf8)
    }

    /// Starts listening and returns the origin, `http://127.0.0.1:<port>`.
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.startContinuation?.resume(returning: "http://127.0.0.1:\(self.listener.port?.rawValue ?? 0)")
                        self.startContinuation = nil
                    case .failed(let error):
                        self.startContinuation?.resume(throwing: error)
                        self.startContinuation = nil
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: self.queue)
                    self.receive(connection, accumulated: Data())
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// The paths requested so far, in order.
    func requestedPaths() -> [String] {
        queue.sync { paths }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self), on: connection)
            } else if error != nil || complete || accumulated.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: accumulated)
            }
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let start = (header.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard start.count >= 2 else { connection.cancel(); return }
        let path = String(start[1]).components(separatedBy: "?")[0]
        paths.append(path)
        let head: String
        var body = Data()
        switch path {
        case ServerIdentity.connectionsPath:
            let port = listener.port?.rawValue ?? 0
            head = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)\(Self.elsewherePath)\r\n"
        case Self.elsewherePath:
            head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            body = document
        default:
            head = "HTTP/1.1 404 Not Found\r\n"
        }
        var response = Data((head + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
