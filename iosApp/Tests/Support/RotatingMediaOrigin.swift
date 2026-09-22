import Foundation
import Network

/// A loopback-only origin for the bundled synthetic HLS video. Later segments
/// stay pending until the test has observed playback, preventing AVPlayer's
/// eager downloads from hiding a credential change behind a complete buffer.
final class RotatingMediaOrigin: @unchecked Sendable {
    static let initialAccessToken = "synthetic-initial"
    static let rotatedAccessToken = "synthetic-rotated"
    static let initialAuthorization = "Bearer \(initialAccessToken)"
    static let rotatedAuthorization = "Bearer \(rotatedAccessToken)"
    static let sessionID = "test-session"
    static let mediaPath = "/api/v1/playback/transcode/\(sessionID)"
    static let subtitlePath = "/api/v1/stream/\(sessionID)/subtitles/1.ass"
    static let fontPath = "/api/v1/stream/\(sessionID)/subtitles/1/fonts"
    static let firstGatedSegment = 6

    struct Request: Sendable {
        let path: String
        let segment: Int?
        let status: Int
        let usedRotatedAuthorization: Bool
    }

    struct Snapshot: Sendable {
        let requests: [Request]
        let pendingSegments: Int

        var rejectedRequests: Int { requests.filter { $0.status == 401 }.count }
        var acceptedLaterSegments: Int {
            requests.filter { $0.status == 200 && ($0.segment ?? -1) >= firstGatedSegment }.count
        }
        var acceptedRotatedSegments: Int {
            requests.filter { $0.status == 200 && $0.segment != nil && $0.usedRotatedAuthorization }.count
        }
        var description: String {
            requests.map { "\($0.status) \($0.path) auth=\($0.usedRotatedAuthorization ? "rotated" : "initial-or-missing")" }
                .joined(separator: "\n") + "\npendingSegments=\(pendingSegments)"
        }
    }

    private struct PendingRequest {
        let connection: NWConnection
        let method: String
        let path: String
        let authorization: String?
        let segment: Int?
    }

    private let queue = DispatchQueue(label: "SiloTests.RotatingMediaOrigin")
    private let segments: [Data]
    private let subtitle: Data
    private let fonts: Data
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var pending: [PendingRequest] = []
    private var requests: [Request] = []
    private var authorization = initialAuthorization
    private var gateIsOpen = false
    private var startContinuation: CheckedContinuation<URL, Error>?

    init(bundle: Bundle) throws {
        guard let subtitleURL = bundle.url(forResource: "authored", withExtension: "ass"),
              let fontURL = bundle.url(forResource: "SiloASSFixture", withExtension: "ttf") else {
            throw NSError(domain: "RotatingMediaOrigin", code: 3)
        }
        subtitle = try Data(contentsOf: subtitleURL)
        fonts = try JSONSerialization.data(withJSONObject: [[
            "name": "fixture.ttf", "data": try Data(contentsOf: fontURL).base64EncodedString()
        ]])
        segments = try (0...1).map { index in
            guard let url = bundle.url(forResource: "v3_hls_0\(index)", withExtension: "ts") else {
                throw NSError(domain: "RotatingMediaOrigin", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Bundled synthetic HLS segment \(index) is missing"
                ])
            }
            return try Data(contentsOf: url)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(Self.mediaPath)/master.m3u8") else { return }
                        self.startContinuation?.resume(returning: url)
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
                self.queue.asyncAfter(deadline: .now() + 5) {
                    guard let continuation = self.startContinuation else { return }
                    self.startContinuation = nil
                    continuation.resume(throwing: NSError(domain: "RotatingMediaOrigin", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Loopback listener did not start within five seconds"]))
                    self.listener.cancel()
                }
            }
        }
    }

    func releaseLaterSegments(rotatingAuthorization: Bool, acceptingPreviouslyIssuedRequests: Bool = false) {
        queue.sync {
            if rotatingAuthorization { authorization = Self.rotatedAuthorization }
            gateIsOpen = true
            let heldRequests = pending
            pending.removeAll()
            for request in heldRequests {
                // An API-driven refresh can finish while an old media request
                // is already in flight. This mode lets that request finish;
                // every subsequently issued request must use the new token.
                respond(request, acceptingInitialAuthorization: acceptingPreviouslyIssuedRequests)
            }
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { Snapshot(requests: requests, pendingSegments: pending.count) }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
            pending.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
                self.handle(header, connection: connection)
            } else if error != nil || complete || accumulated.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: accumulated)
            }
        }
    }

    private func handle(_ header: String, connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ")
        guard start.count >= 2 else { connection.cancel(); return }
        let path = String(start[1]).components(separatedBy: "?")[0]
        let authorization = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].caseInsensitiveCompare("Authorization") == .orderedSame else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }.first
        let segmentPrefix = "\(Self.mediaPath)/segment/"
        let segment = path.hasPrefix(segmentPrefix) && path.hasSuffix(".ts")
            ? Int(path.dropFirst(segmentPrefix.count).dropLast(3)) : nil
        let request = PendingRequest(connection: connection, method: String(start[0]), path: path,
                                     authorization: authorization, segment: segment)
        if let segment, segment >= Self.firstGatedSegment, !gateIsOpen {
            pending.append(request)
        } else {
            respond(request)
        }
    }

    private func respond(_ request: PendingRequest, acceptingInitialAuthorization: Bool = false) {
        let status: Int
        let body: Data
        let contentType: String
        let acceptedInitialRequest = acceptingInitialAuthorization && request.authorization == Self.initialAuthorization
        if request.authorization != authorization && !acceptedInitialRequest {
            status = 401
            body = Data("Synthetic bearer expired".utf8)
            contentType = "text/plain"
        } else if request.path == "\(Self.mediaPath)/master.m3u8" {
            status = 200
            body = Self.playlist
            contentType = "application/vnd.apple.mpegurl"
        } else if request.path == Self.subtitlePath || request.path == Self.subtitlePath.replacingOccurrences(of: "1.ass", with: "2.ass") {
            status = 200
            body = subtitle
            contentType = "text/plain"
        } else if request.path == Self.fontPath {
            status = 200
            body = fonts
            contentType = "application/json"
        } else if let segment = request.segment, (0..<24).contains(segment) {
            status = 200
            body = segments[segment % 2]
            contentType = "video/mp2t"
        } else {
            status = 404
            body = Data()
            contentType = "text/plain"
        }
        requests.append(Request(path: request.path, segment: request.segment, status: status,
                                usedRotatedAuthorization: request.authorization == Self.rotatedAuthorization))
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : "Not Found"
        var response = Data(("HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        if request.method != "HEAD" { response.append(body) }
        request.connection.send(content: response, completion: .contentProcessed { _ in request.connection.cancel() })
    }

    private static var playlist: Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:1",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0"]
        for index in 0..<24 {
            // The fixture pair has a two-second timestamp range. Discontinuity
            // restarts its timeline cleanly each time we reuse that same pair.
            if index > 0, index.isMultiple(of: 2) { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append("#EXTINF:1.000000,")
            lines.append("segment/\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
