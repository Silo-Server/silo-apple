import XCTest
import Network
@testable import Silo

/// Workstream A1 of the playback-continuity plan: `retargetOrigin` swaps the
/// proxy's origin endpoint in place after a silent session renewal. The
/// critical behavior is that a reader blocked at the cache edge (its byte
/// demand parked because the old origin stopped delivering) resumes against
/// the new origin without the serve connection, cache, or local URL changing.
final class PlaybackSourceProxyRetargetTests: XCTestCase {

    /// Minimal HTTP/1.1 range origin on 127.0.0.1 serving zeros. With
    /// `stallAfterByte` set it delivers bytes up to that absolute offset and
    /// then holds the connection open without data — the shape of an origin
    /// whose session died mid-body without a socket error.
    private final class StubOrigin {
        let listener: NWListener
        let totalBytes: Int64
        let stallAfterByte: Int64?
        private(set) var port: UInt16 = 0
        private let queue = DispatchQueue(label: "retarget-stub-origin")
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private let lock = NSLock()
        private(set) var requestedOffsets: [Int64] = []

        init(totalBytes: Int64, stallAfterByte: Int64? = nil) throws {
            self.totalBytes = totalBytes
            self.stallAfterByte = stallAfterByte
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

        func observedOffsets() -> [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return requestedOffsets
        }

        func start() async throws {
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            port = try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if !resumed, let port = self.listener.port {
                            resumed = true
                            continuation.resume(returning: port.rawValue)
                        }
                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: error)
                        }
                    default:
                        break
                    }
                }
                self.listener.start(queue: self.queue)
            }
        }

        func stop() {
            listener.cancel()
            lock.lock()
            let open = connections.values
            connections.removeAll()
            lock.unlock()
            open.forEach { $0.cancel() }
        }

        private func accept(_ connection: NWConnection) {
            lock.lock()
            connections[ObjectIdentifier(connection)] = connection
            lock.unlock()
            connection.start(queue: queue)
            receiveRequest(connection, buffered: Data())
        }

        private func receiveRequest(_ connection: NWConnection, buffered: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
                guard let self, error == nil else { return }
                var head = buffered
                if let data { head.append(data) }
                guard let headEnd = head.range(of: Data("\r\n\r\n".utf8)) else {
                    if head.count < 64 * 1024 {
                        self.receiveRequest(connection, buffered: head)
                    }
                    return
                }
                let request = String(data: head[..<headEnd.lowerBound], encoding: .utf8) ?? ""
                self.respond(connection, request: request)
            }
        }

        private func respond(_ connection: NWConnection, request: String) {
            var offset: Int64 = 0
            var end: Int64 = totalBytes - 1
            for line in request.split(separator: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("range:"), let eq = line.range(of: "bytes=") {
                    let spec = line[eq.upperBound...]
                    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                    offset = parts.first.flatMap { Int64($0) } ?? 0
                    if parts.count > 1, let bounded = Int64(parts[1]) {
                        end = min(bounded, totalBytes - 1)
                    }
                }
            }
            lock.lock()
            requestedOffsets.append(offset)
            lock.unlock()
            let remaining = end - offset + 1
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(offset)-\(end)/\(totalBytes)\r\nContent-Length: \(remaining)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
                self?.sendBody(connection, cursor: offset, end: end)
            })
        }

        private static let bodyChunk = Data(count: 64 * 1024)

        private func sendBody(_ connection: NWConnection, cursor: Int64, end: Int64) {
            let remaining = end - cursor + 1
            guard remaining > 0 else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            if let stallAfterByte, cursor >= stallAfterByte {
                // Hold the connection open with no further data: a dead
                // session mid-body, not a socket error.
                return
            }
            var chunkLength = min(remaining, Int64(Self.bodyChunk.count))
            if let stallAfterByte, cursor < stallAfterByte {
                chunkLength = min(chunkLength, stallAfterByte - cursor)
            }
            let chunk = Data(count: Int(chunkLength))
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil else { return }
                self?.sendBody(connection, cursor: cursor + chunkLength, end: end)
            })
        }
    }

    /// Reads `bytes=0-` from a URL, signalling once `stallTarget` bytes have
    /// arrived and again when the full body has.
    private final class CountingReader: NSObject, URLSessionDataDelegate {
        let reachedStallTarget = XCTestExpectation(description: "reader reached the stall point")
        let completed = XCTestExpectation(description: "reader received the full body")
        private let stallTarget: Int64
        private let total: Int64
        private(set) var received: Int64 = 0
        private var session: URLSession?

        init(stallTarget: Int64, total: Int64) {
            self.stallTarget = stallTarget
            self.total = total
        }

        func start(url: URL) {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            session.dataTask(with: request).resume()
        }

        func cancel() {
            session?.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            received += Int64(data.count)
            if received >= stallTarget {
                reachedStallTarget.fulfill()
            }
            if received >= total {
                completed.fulfill()
            }
        }
    }

    private static let fileSize: Int64 = 2 * 1024 * 1024
    private static let stallPoint: Int64 = 256 * 1024

    func testRetargetResumesParkedReaderAgainstNewOrigin() async throws {
        let deadOrigin = try StubOrigin(totalBytes: Self.fileSize, stallAfterByte: Self.stallPoint)
        try await deadOrigin.start()
        defer { deadOrigin.stop() }
        let liveOrigin = try StubOrigin(totalBytes: Self.fileSize)
        try await liveOrigin.start()
        defer { liveOrigin.stop() }

        let proxy = PlaybackSourceProxy(originURL: deadOrigin.url, originHeaders: [:])
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)
        let localURL = try XCTUnwrap(proxy.localURL)

        let reader = CountingReader(stallTarget: Self.stallPoint, total: Self.fileSize)
        reader.start(url: localURL)
        defer { reader.cancel() }

        // The reader must actually hit the dead origin's edge and park.
        await fulfillment(of: [reader.reachedStallTarget], timeout: 10)

        proxy.retargetOrigin(url: liveOrigin.url, headers: [:])

        // The parked byte demand re-routes against the new origin and the
        // read completes without the serve connection ever being touched.
        await fulfillment(of: [reader.completed], timeout: 10)
        XCTAssertEqual(reader.received, Self.fileSize)
        XCTAssertFalse(
            liveOrigin.observedOffsets().isEmpty,
            "the renewed origin never saw a range request after retarget"
        )
    }

    func testRetargetAfterStopIsANoOp() async throws {
        let origin = try StubOrigin(totalBytes: Self.fileSize)
        try await origin.start()
        defer { origin.stop() }

        let proxy = PlaybackSourceProxy(originURL: origin.url, originHeaders: [:])
        try await proxy.start()
        proxy.stop()
        // Must not crash, spawn connections, or resurrect the resource.
        proxy.retargetOrigin(url: origin.url, headers: [:])
        XCTAssertTrue(origin.observedOffsets().isEmpty)
    }
}
