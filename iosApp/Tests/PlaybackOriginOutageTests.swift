import XCTest
import Network
@testable import Silo

final class PlaybackOriginOutagePolicyTests: XCTestCase {
    private func park(
        cause: PlaybackOriginReconnectPolicy.EndCause,
        sessionMissing: Bool = false,
        enabled: Bool = true
    ) -> Bool {
        PlaybackOriginOutagePolicy.shouldPark(
            cause: cause,
            sessionMissingObserved: sessionMissing,
            rideThroughEnabled: enabled
        )
    }

    func testRetryableCausesPark() {
        XCTAssertTrue(park(cause: .network))
        XCTAssertTrue(park(cause: .stalled))
        XCTAssertTrue(park(cause: .httpOutage(503)))
    }

    func testKillSwitchRestoresLegacyBehavior() {
        XCTAssertFalse(park(cause: .network, enabled: false))
        XCTAssertFalse(park(cause: .httpOutage(503), enabled: false))
    }

    func testSessionMissing404ParksOnlyWithSentinel() {
        XCTAssertTrue(park(cause: .httpFatal(404), sessionMissing: true))
        XCTAssertFalse(park(cause: .httpFatal(404), sessionMissing: false))
    }

    func testOtherFatalCausesNeverPark() {
        XCTAssertFalse(park(cause: .httpFatal(403), sessionMissing: true))
        XCTAssertFalse(park(cause: .prematureEOF))
        XCTAssertFalse(park(cause: .rangeIgnored))
        XCTAssertFalse(park(cause: .entityChanged))
    }
}

/// End-to-end outage ride-through at the proxy level: a reader blocked at
/// the edge when the origin dies is parked (never failed), the outage
/// callback fires, and when the origin returns on the same port the cadence
/// probe resumes the read to completion.
final class PlaybackSourceProxyOutageTests: XCTestCase {

    /// Range origin serving zeros that can go down (listener + connections
    /// killed → connection-refused) and come back on the same port.
    private final class RestartableStubOrigin {
        let totalBytes: Int64
        private(set) var port: UInt16 = 0
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "outage-stub-origin")
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private let lock = NSLock()

        init(totalBytes: Int64) {
            self.totalBytes = totalBytes
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

        func start() async throws {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let host = NWEndpoint.Host.ipv4(.loopback)
            let endpointPort: NWEndpoint.Port = port == 0
                ? .any
                : NWEndpoint.Port(rawValue: port)!
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: endpointPort)
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            port = try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if !resumed, let ready = listener.port {
                            resumed = true
                            continuation.resume(returning: ready.rawValue)
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
                listener.start(queue: self.queue)
            }
        }

        /// Kill the listener and every open connection: new requests get
        /// connection-refused, in-flight bodies die mid-transfer.
        func goDown() {
            listener?.cancel()
            listener = nil
            lock.lock()
            let open = connections.values
            connections.removeAll()
            lock.unlock()
            open.forEach { $0.cancel() }
        }

        /// Restart on the same port.
        func goUp() async throws {
            try await start()
        }

        func stop() { goDown() }

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
            let remaining = end - offset + 1
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(offset)-\(end)/\(totalBytes)\r\nContent-Length: \(remaining)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
                self?.sendBody(connection, remaining: remaining)
            })
        }

        private static let bodyChunk = Data(count: 64 * 1024)

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

    private final class CountingReader: NSObject, URLSessionDataDelegate {
        let completed = XCTestExpectation(description: "reader received the full body")
        let failed = XCTestExpectation(description: "reader connection failed")
        private let total: Int64
        private(set) var received: Int64 = 0
        private var session: URLSession?

        init(total: Int64) {
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
            if received >= total {
                completed.fulfill()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil || received < total {
                failed.fulfill()
            }
        }
    }

    // Small enough that the reader reaches the origin's edge quickly; the
    // first connection must deliver under the productive-bytes floor so the
    // reconnect ladder keeps the fail-fast cap (4 attempts, ~7.5 s).
    private static let fileSize: Int64 = 2 * 1024 * 1024

    func testOutageParksReaderAndRecoversWhenOriginReturns() async throws {
        let origin = RestartableStubOrigin(totalBytes: Self.fileSize)
        try await origin.start()
        defer { origin.stop() }

        let originalProbeDelay = PlaybackOriginOutagePolicy.probeDelaySeconds
        PlaybackOriginOutagePolicy.probeDelaySeconds = 0.3
        defer { PlaybackOriginOutagePolicy.probeDelaySeconds = originalProbeDelay }

        let outageEntered = XCTestExpectation(description: "outage entered")
        let outageCleared = XCTestExpectation(description: "outage cleared")
        let proxy = PlaybackSourceProxy(
            originURL: origin.url,
            originHeaders: [:],
            onOriginOutageChanged: { active in
                if active {
                    outageEntered.fulfill()
                } else {
                    outageCleared.fulfill()
                }
            },
            outageRideThroughEnabled: true
        )
        try await proxy.start()
        defer { proxy.stop() }
        let localURL = try XCTUnwrap(proxy.localURL)

        // Kill the origin before any bytes flow: the ladder stays on the
        // fail-fast (never-productive) cap and the blocked reader parks.
        origin.goDown()
        proxy.startPrefetch(at: 0)

        let reader = CountingReader(total: Self.fileSize)
        reader.start(url: localURL)
        defer { reader.cancel() }

        // Ladder: 4 connection-refused attempts with 0.5/1/2/4 s backoff.
        await fulfillment(of: [outageEntered], timeout: 20)
        XCTAssertTrue(proxy.isOriginOutageActive)

        try await origin.goUp()

        // The cadence probe (0.3 s in this test) reconnects and the parked
        // read resumes to completion; the reader connection never failed.
        await fulfillment(of: [outageCleared], timeout: 20)
        await fulfillment(of: [reader.completed], timeout: 10)
        XCTAssertEqual(reader.received, Self.fileSize)
        XCTAssertFalse(proxy.isOriginOutageActive)

        let failedCheck = XCTWaiter().wait(for: [reader.failed], timeout: 0.1)
        XCTAssertEqual(failedCheck, .timedOut, "the parked reader must never see a failed connection")
    }
}

/// The interrupt-token span deadline around outage transitions: the exact
/// failure sim-validated on 2026-07-07 was a read parked through a ~25 s
/// outage being aborted the instant the outage flag cleared (25 s > the
/// 10 s base allowance measured from span start), racing the redriven bytes
/// and forcing a visible reload.
final class LoopbackInterruptTokenDeadlineTests: XCTestCase {
    func testCoreMediaDemuxWatchdogIgnoresIntentionalPause() {
        XCTAssertFalse(
            CoreMediaDemuxInterruptPolicy.shouldAbort(
                cancelled: false,
                userPaused: true,
                secondsSinceProgress: 120,
                timeoutSeconds: 10
            )
        )
        // Startup and seek restarts run with the playback clock at rate 0
        // without a user pause — the watchdog must stay armed there.
        XCTAssertTrue(
            CoreMediaDemuxInterruptPolicy.shouldAbort(
                cancelled: false,
                userPaused: false,
                secondsSinceProgress: 10.1,
                timeoutSeconds: 10
            )
        )
        XCTAssertTrue(
            CoreMediaDemuxInterruptPolicy.shouldAbort(
                cancelled: true,
                userPaused: true,
                secondsSinceProgress: 0,
                timeoutSeconds: 10
            )
        )
    }

    private func makeToken(outage: @escaping () -> Bool) -> LoopbackInterruptToken {
        let token = LoopbackInterruptToken()
        token.setSourceOutageProvider(outage)
        return token
    }

    func testNormalReadAbortsAtBaseAllowance() {
        let token = makeToken(outage: { false })
        token.beginBlockingSpan(allowanceSeconds: 10)
        XCTAssertFalse(token.shouldInterrupt(now: CFAbsoluteTimeGetCurrent() + 9))
        XCTAssertTrue(token.shouldInterrupt(now: CFAbsoluteTimeGetCurrent() + 11))
        XCTAssertTrue(token.didAbortOnDeadline)
    }

    func testOutageParksWellPastBaseAllowance() {
        let token = makeToken(outage: { true })
        token.beginBlockingSpan(allowanceSeconds: 10)
        XCTAssertFalse(token.shouldInterrupt(now: CFAbsoluteTimeGetCurrent() + 120))
        XCTAssertFalse(token.didAbortOnDeadline)
    }

    func testOutageParkHitsAbsoluteBackstop() {
        let token = makeToken(outage: { true })
        token.beginBlockingSpan(allowanceSeconds: 10)
        XCTAssertTrue(token.shouldInterrupt(
            now: CFAbsoluteTimeGetCurrent() + LoopbackInterruptToken.outageParkAllowanceSeconds + 1
        ))
        XCTAssertTrue(token.didAbortOnDeadline)
    }

    func testOutageClearGrantsFreshAllowanceFromClearInstant() {
        var outageActive = true
        let token = makeToken(outage: { outageActive })
        let start = CFAbsoluteTimeGetCurrent()
        token.beginBlockingSpan(allowanceSeconds: 10)
        // Parked 25 s into the outage; the callback observes the outage.
        XCTAssertFalse(token.shouldInterrupt(now: start + 25))
        outageActive = false
        // The moment the outage clears the elapsed span is 25 s > 10 s base,
        // but the fresh allowance runs from the last outage observation —
        // the read must survive to receive its redriven bytes.
        XCTAssertFalse(token.shouldInterrupt(now: start + 26))
        XCTAssertFalse(token.shouldInterrupt(now: start + 34))
        XCTAssertFalse(token.didAbortOnDeadline)
        // ...but a source that stays silent past the fresh allowance is a
        // genuine wedge again.
        XCTAssertTrue(token.shouldInterrupt(now: start + 36))
        XCTAssertTrue(token.didAbortOnDeadline)
    }

    func testCancellationWinsAndIsNotADeadlineAbort() {
        let token = makeToken(outage: { true })
        token.beginBlockingSpan(allowanceSeconds: 10)
        token.cancel()
        XCTAssertTrue(token.shouldInterrupt(now: CFAbsoluteTimeGetCurrent()))
        XCTAssertFalse(token.didAbortOnDeadline)
    }
}
