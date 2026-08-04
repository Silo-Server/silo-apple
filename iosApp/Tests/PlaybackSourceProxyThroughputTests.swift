import XCTest
import Network
@testable import Silo

/// Investigation harness for the ~12 Mbps producer ingest ceiling observed on
/// device (2026-07-05, HDR10 MKV, silo.arkyncdn.net): a loopback origin that
/// serves at line rate, a control read hitting it directly, and the same
/// sequential read through PlaybackSourceProxy. If the proxy path collapses
/// here too, the ceiling is in the fill/serve path, not the network.
final class PlaybackSourceProxyThroughputTests: XCTestCase {

    // MARK: - Line-rate loopback origin

    /// Minimal HTTP/1.1 origin on 127.0.0.1 serving `totalBytes` of zeros,
    /// honoring `Range: bytes=N-` with 206 + Content-Range, one request per
    /// connection (Connection: close semantics are fine for the origin
    /// stream, which opens a fresh task per (re)target anyway).
    private final class StubOrigin {
        let listener: NWListener
        let totalBytes: Int64
        let responseDelay: TimeInterval
        private(set) var port: UInt16 = 0
        private let queue = DispatchQueue(label: "stub-origin")
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private let lock = NSLock()
        /// Range request offsets observed, in arrival order.
        private(set) var requestedOffsets: [Int64] = []
        /// Raw byte-range specs (for example `0-4194303` or `8388608-`).
        private var requestedRanges: [String] = []

        init(totalBytes: Int64, responseDelay: TimeInterval = 0) throws {
            self.totalBytes = totalBytes
            self.responseDelay = responseDelay
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

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

        func observedRanges() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return requestedRanges
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
            var requestedRange = "0-"
            for line in request.split(separator: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("range:"), let eq = line.range(of: "bytes=") {
                    let spec = line[eq.upperBound...]
                    requestedRange = String(spec)
                    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                    offset = parts.first.flatMap { Int64($0) } ?? 0
                    if parts.count > 1, let bounded = Int64(parts[1]) {
                        end = min(bounded, totalBytes - 1)
                    }
                }
            }
            lock.lock()
            requestedOffsets.append(offset)
            requestedRanges.append(requestedRange)
            lock.unlock()
            let remaining = end - offset + 1
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(offset)-\(end)/\(totalBytes)\r\nContent-Length: \(remaining)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
            let sendResponse = { [weak self] in
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                    guard error == nil else { return }
                    self?.sendBody(connection, remaining: remaining)
                })
            }
            if responseDelay > 0 {
                queue.asyncAfter(deadline: .now() + responseDelay, execute: sendResponse)
            } else {
                sendResponse()
            }
        }

        private static let bodyChunk = Data(count: 256 * 1024)

        private func sendBody(_ connection: NWConnection, remaining: Int64) {
            guard remaining > 0 else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            let chunk = remaining >= Int64(Self.bodyChunk.count)
                ? Self.bodyChunk
                : Data(count: Int(remaining))
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil else { return }
                self?.sendBody(connection, remaining: remaining - Int64(chunk.count))
            })
        }
    }

    // MARK: - Measured sequential reader

    /// Reads `bytes=0-` from `url` and reports achieved throughput. Stops
    /// after `maxSeconds` or once `totalBytes` arrived, whichever is first.
    private final class ThroughputReader: NSObject, URLSessionDataDelegate {
        private let done = XCTestExpectation(description: "read finished")
        private var received: Int64 = 0
        private let target: Int64
        private let deadline: TimeInterval
        private var started: Date?
        private var finished: Date?
        private var session: URLSession?

        init(target: Int64, deadline: TimeInterval) {
            self.target = target
            self.deadline = deadline
        }

        func measure(url: URL, testCase: XCTestCase) -> (bytes: Int64, seconds: Double) {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            started = Date()
            session.dataTask(with: request).resume()
            let waiter = XCTWaiter()
            _ = waiter.wait(for: [done], timeout: deadline + 5)
            let end = finished ?? Date()
            session.invalidateAndCancel()
            return (received, end.timeIntervalSince(started ?? end))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            received += Int64(data.count)
            let elapsed = Date().timeIntervalSince(started ?? Date())
            if received >= target || elapsed >= deadline {
                if finished == nil {
                    finished = Date()
                    dataTask.cancel()
                    done.fulfill()
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if finished == nil {
                finished = Date()
                done.fulfill()
            }
        }
    }

    // MARK: - Tests

    private static let fileSize: Int64 = 512 * 1024 * 1024
    private static let readTarget: Int64 = 96 * 1024 * 1024
    private static let readDeadline: TimeInterval = 12

    private func mbps(_ bytes: Int64, _ seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    func testOriginStubServesAtLineRate() async throws {
        let origin = try StubOrigin(totalBytes: Self.fileSize)
        try await origin.start()
        defer { origin.stop() }

        let reader = ThroughputReader(target: Self.readTarget, deadline: Self.readDeadline)
        let (bytes, seconds) = reader.measure(url: origin.url, testCase: self)
        let rate = mbps(bytes, seconds)
        print("[THROUGHPUT] control direct-origin read bytes=\(bytes) seconds=\(String(format: "%.2f", seconds)) rate=\(String(format: "%.1f", rate))Mbps")
        // The stub must comfortably outrun any plausible ceiling under test.
        XCTAssertGreaterThan(rate, 200, "stub origin itself is too slow to measure the proxy")
    }

    func testProxySequentialReadThroughput() async throws {
        let origin = try StubOrigin(totalBytes: Self.fileSize)
        try await origin.start()
        defer { origin.stop() }

        let proxy = PlaybackSourceProxy(originURL: origin.url, originHeaders: [:])
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)
        let localURL = try XCTUnwrap(proxy.localURL)

        let reader = ThroughputReader(target: Self.readTarget, deadline: Self.readDeadline)
        let (bytes, seconds) = reader.measure(url: localURL, testCase: self)
        let rate = mbps(bytes, seconds)
        print("[THROUGHPUT] proxy sequential read bytes=\(bytes) seconds=\(String(format: "%.2f", seconds)) rate=\(String(format: "%.1f", rate))Mbps originRequests=\(origin.requestedOffsets)")
        // 4K HDR peaks in the field hit ~20-30 Mbps; the proxy on a Mac over
        // loopback should clear that by an order of magnitude. This is a
        // diagnostic floor, not a performance target.
        XCTAssertGreaterThan(rate, 100, "proxy sequential serve path is the ingest bottleneck")
    }

    func testProxyKeepsStreamingAfter150MillisecondOriginDelay() async throws {
        let origin = try StubOrigin(
            totalBytes: Self.fileSize,
            responseDelay: 0.150
        )
        try await origin.start()
        defer { origin.stop() }

        let proxy = PlaybackSourceProxy(originURL: origin.url, originHeaders: [:])
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)
        let localURL = try XCTUnwrap(proxy.localURL)

        let target: Int64 = 64 * 1024 * 1024
        let reader = ThroughputReader(target: target, deadline: Self.readDeadline)
        let (bytes, seconds) = reader.measure(url: localURL, testCase: self)
        let rate = mbps(bytes, seconds)
        let ranges = origin.observedRanges()
        let openEndedWindows = ranges.filter { $0.hasSuffix("-") }
        print(
            "[THROUGHPUT] delayed-origin latency=150ms bytes=\(bytes) "
                + "seconds=\(String(format: "%.2f", seconds)) "
                + "rate=\(String(format: "%.1f", rate))Mbps ranges=\(ranges)"
        )

        XCTAssertGreaterThanOrEqual(bytes, target, "delayed origin starved the sequential reader")
        XCTAssertEqual(
            openEndedWindows.count,
            1,
            "sequential delivery reopened its streaming window under latency: \(ranges)"
        )
        XCTAssertLessThanOrEqual(
            ranges.count,
            4,
            "sequential delivery fell back to RTT-bound discrete reads: \(ranges)"
        )
        XCTAssertGreaterThan(rate, 80, "150 ms request latency collapsed steady-state throughput")
    }

    /// AE-parity churn regression: random-access probe reads (mkv head,
    /// cues at the tail, subtitle extractor mid-file) arriving during a
    /// sequential playback read must be served as discrete chunks — the
    /// origin must NOT see the streaming window connection torn down and
    /// re-pointed per probe (the pre-window pool did exactly that: a
    /// reconnect storm that pinned device ingest at ~12 Mbps).
    func testProbeReadsDoNotChurnTheSequentialWindow() async throws {
        let origin = try StubOrigin(totalBytes: Self.fileSize)
        try await origin.start()
        defer { origin.stop() }

        let proxy = PlaybackSourceProxy(originURL: origin.url, originHeaders: [:])
        try await proxy.start()
        defer { proxy.stop() }
        proxy.startPrefetch(at: 0)
        let localURL = try XCTUnwrap(proxy.localURL)

        // Probes: far-scattered small reads, like a matroska open pattern.
        let probeOffsets: [Int64] = [
            Self.fileSize - 2_048,          // cues at tail
            Self.fileSize / 2,              // mid-file attachment probe
            300 * 1024 * 1024,              // far metadata probe
        ]
        let probeSession = URLSession(configuration: .ephemeral)
        for offset in probeOffsets {
            var request = URLRequest(url: localURL)
            request.setValue("bytes=\(offset)-\(offset + 1_023)", forHTTPHeaderField: "Range")
            let (body, response) = try await probeSession.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(body.count, 1_024, "probe at \(offset)")
        }

        // Sequential playback read proceeds at full rate despite the probes.
        let reader = ThroughputReader(target: Self.readTarget, deadline: Self.readDeadline)
        let (bytes, seconds) = reader.measure(url: localURL, testCase: self)
        let rate = mbps(bytes, seconds)

        // Origin request budget: the window's connect(s) plus roughly one
        // 4 MB chunk per probe. The old pool produced dozens of retargets.
        let originRequests = origin.requestedOffsets
        print("[THROUGHPUT] window+probes rate=\(String(format: "%.1f", rate))Mbps originRequests=\(originRequests)")
        XCTAssertLessThanOrEqual(
            originRequests.count, 3 + probeOffsets.count * 2,
            "probe reads churned the origin connection pool: \(originRequests)"
        )
        XCTAssertGreaterThan(rate, 100, "sequential read starved while probes were served")
        // The reader can overshoot the target slightly: deliveries keep
        // arriving between fulfillment and the task cancel taking effect.
        XCTAssertGreaterThanOrEqual(bytes, Self.readTarget, "sequential read did not complete")
    }
}
