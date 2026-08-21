import Network
import XCTest
@testable import Silo

final class LoopbackSegmentServerRangeTests: XCTestCase {
    func testLANAccessTokenAuthorizesOnlyItsResourcePrefix() {
        XCTAssertEqual(
            LoopbackSegmentServer.authorizedResourcePath(
                "/session-secret/master.m3u8",
                accessToken: "session-secret"
            ),
            "master.m3u8"
        )
        XCTAssertNil(
            LoopbackSegmentServer.authorizedResourcePath(
                "/other-session/master.m3u8",
                accessToken: "session-secret"
            )
        )
        XCTAssertNil(
            LoopbackSegmentServer.authorizedResourcePath(
                "/master.m3u8",
                accessToken: "session-secret"
            )
        )
    }

    func testPrivateIPv4AddressSelectionExcludesPublicAndLinkLocalAddresses() {
        XCTAssertTrue(LoopbackSegmentServer.isPrivateIPv4Address("10.0.0.4"))
        XCTAssertTrue(LoopbackSegmentServer.isPrivateIPv4Address("172.20.1.2"))
        XCTAssertTrue(LoopbackSegmentServer.isPrivateIPv4Address("192.168.1.10"))
        // Link-local means DHCP never completed; a receiver on the real subnet
        // cannot route to it.
        XCTAssertFalse(LoopbackSegmentServer.isPrivateIPv4Address("169.254.2.3"))
        XCTAssertFalse(LoopbackSegmentServer.isPrivateIPv4Address("8.8.8.8"))
        XCTAssertFalse(LoopbackSegmentServer.isPrivateIPv4Address("10.0.0.999"))
        XCTAssertFalse(LoopbackSegmentServer.isPrivateIPv4Address("10.-1.0.1"))
        XCTAssertFalse(LoopbackSegmentServer.isPrivateIPv4Address("not-an-address"))
    }

    func testAdvertisedInterfaceExcludesCellularAndTunnels() {
        XCTAssertTrue(LoopbackSegmentServer.isReceiverReachableInterface("en0"))
        XCTAssertTrue(LoopbackSegmentServer.isReceiverReachableInterface("en1"))
        XCTAssertTrue(LoopbackSegmentServer.isReceiverReachableInterface("bridge100"))
        XCTAssertFalse(LoopbackSegmentServer.isReceiverReachableInterface("pdp_ip0"))
        XCTAssertFalse(LoopbackSegmentServer.isReceiverReachableInterface("utun3"))
        XCTAssertFalse(LoopbackSegmentServer.isReceiverReachableInterface("ipsec0"))
        XCTAssertFalse(LoopbackSegmentServer.isReceiverReachableInterface("awdl0"))
        XCTAssertFalse(LoopbackSegmentServer.isReceiverReachableInterface("llw0"))
    }

    func testLANExposureUsesLoopbackURLBeforeExternalHandoff() throws {
        let server = LoopbackSegmentServer(
            segmentStore: LoopbackSegmentStore(generation: 1),
            exposure: .localNetwork
        )

        let url = try XCTUnwrap(server.resourceURL(for: "master.m3u8"))
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertTrue(url.path.hasSuffix("/master.m3u8"))
        XCTAssertNotEqual(url.path, "/master.m3u8")
    }

    func testResourceURLLogRedactionHidesTheSessionToken() throws {
        let server = LoopbackSegmentServer(
            segmentStore: LoopbackSegmentStore(generation: 2),
            exposure: .localNetwork
        )

        let url = try XCTUnwrap(server.resourceURL(for: "master.m3u8"))
        let token = try XCTUnwrap(url.pathComponents.dropFirst().first)
        let redacted = server.redactingAccessToken(in: url.absoluteString)

        XCTAssertFalse(redacted.contains(token))
        XCTAssertTrue(redacted.contains("master.m3u8"))
    }

    func testOffDevicePeerClassificationTreatsUnknownEndpointsAsLocal() {
        XCTAssertFalse(LoopbackSegmentServer.isOffDevicePeer(.hostPort(host: .ipv4(.loopback), port: 8080)))
        XCTAssertFalse(LoopbackSegmentServer.isOffDevicePeer(.hostPort(host: .ipv6(.loopback), port: 8080)))
        XCTAssertFalse(LoopbackSegmentServer.isOffDevicePeer(.hostPort(host: .name("localhost", nil), port: 8080)))
        XCTAssertTrue(
            LoopbackSegmentServer.isOffDevicePeer(
                .hostPort(host: .ipv4(IPv4Address("192.168.1.42")!), port: 8080)
            )
        )
    }

    func testAdvertisedVODSegmentMissRetriesInsteadOf404() {
        XCTAssertEqual(
            LoopbackSegmentServer.vodMissingResponseKind(index: 5, segmentCount: 10),
            .retryLater
        )
        XCTAssertEqual(
            LoopbackSegmentServer.vodMissingResponseKind(index: 10, segmentCount: 10),
            .notFound
        )
        XCTAssertEqual(
            LoopbackSegmentServer.vodMissingResponseKind(index: 5, segmentCount: nil),
            .notFound
        )
    }

    func testVODMissSendsHeadersBeforeSlowSegmentFinishes() async throws {
        let store = LoopbackSegmentStore(generation: 909)
        let server = LoopbackSegmentServer(segmentStore: store)
        let segmentName = "seg_000002.m4s"
        let payload = Data(repeating: 0xA5, count: 32 * 1024)

        server.vodSegmentMissResolver = { _ in
            Thread.sleep(forTimeInterval: LoopbackSegmentServer.vodEarlyResponseDelaySeconds + 0.75)
            store.beginProgressiveSegment(named: segmentName)
            store.appendProgressiveSegment(named: segmentName, bytes: payload.prefix(4_096))
            store.putSegment(name: segmentName, data: payload, duration: 4)
            return store.resource(path: segmentName, waitForNearFuture: false)
        }

        try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(segmentName)")!
        let started = CFAbsoluteTimeGetCurrent()
        let earlyHeaderElapsed = LockedElapsed()
        server.onEarlyVODResponseHeaders = { path in
            XCTAssertEqual(path, segmentName)
            earlyHeaderElapsed.set(CFAbsoluteTimeGetCurrent() - started)
        }
        let delegate = SegmentResponseTimingDelegate(startedAt: started)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let result = try await delegate.fetch(url: url, using: session)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNotNil(result.firstBodyElapsed)
        XCTAssertNotNil(earlyHeaderElapsed.value)
        XCTAssertLessThan(
            (earlyHeaderElapsed.value ?? .infinity) + 0.4,
            result.firstBodyElapsed ?? .infinity,
            "headers must beat the delayed segment's first bytes"
        )
        XCTAssertEqual(result.data, payload)
    }

    // MARK: - Progressive stream termination

    // The progressive response streams a segment whose final length is
    // unknown when the headers go out, so it is chunk-framed: the terminating
    // 0-length chunk is the only statement that the segment is complete. Only
    // a genuinely complete stored segment may send it — otherwise a
    // superseded or timed-out prefix is indistinguishable from a whole
    // segment and AVPlayer caches a truncated fMP4 instead of refetching.

    func testCompleteProgressiveStreamTerminatesTheChunkedBody() async throws {
        let store = LoopbackSegmentStore(generation: 912)
        let server = LoopbackSegmentServer(segmentStore: store)
        let segmentName = "seg_000003.m4s"
        store.beginProgressiveSegment(named: segmentName)
        store.appendProgressiveSegment(named: segmentName, bytes: Data(repeating: 0x5A, count: 16))
        try await server.start()
        defer { server.stop() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            store.putSegment(name: segmentName, data: Data(repeating: 0x5A, count: 32), duration: 4)
        }

        let wire = await Self.rawResponse(port: server.port, path: segmentName, timeout: 6)
        XCTAssertTrue(wire.closed, "the response must end")
        XCTAssertTrue(
            Self.headers(of: wire.bytes).contains("Transfer-Encoding: chunked"),
            "an open-ended segment body needs framing to be completable"
        )
        XCTAssertTrue(
            Self.endsWithChunkedTerminator(wire.bytes),
            "a complete segment terminates its body"
        )
    }

    func testSupersededProgressiveStreamEndsWithoutTerminatingTheBody() async throws {
        let store = LoopbackSegmentStore(generation: 913)
        let server = LoopbackSegmentServer(segmentStore: store)
        let segmentName = "seg_000003.m4s"
        store.beginProgressiveSegment(named: segmentName)
        store.appendProgressiveSegment(named: segmentName, bytes: Data(repeating: 0x5A, count: 16))
        try await server.start()
        defer { server.stop() }

        // A restarted producer republishes the same name from zero while the
        // response is mid-flight: the prefix already on the wire can never be
        // completed.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            store.beginProgressiveSegment(named: segmentName)
        }

        let wire = await Self.rawResponse(port: server.port, path: segmentName, timeout: 6)
        XCTAssertTrue(wire.closed, "a superseded stream must be dropped, not left open")
        XCTAssertFalse(
            Self.endsWithChunkedTerminator(wire.bytes),
            "a superseded prefix must not be declared a complete segment"
        )
    }

    func testProgressiveStreamDeadlineEndsWithoutTerminatingTheBody() async throws {
        let store = LoopbackSegmentStore(generation: 914)
        let server = LoopbackSegmentServer(segmentStore: store)
        server.progressiveStreamMaxSeconds = 0.7
        let segmentName = "seg_000004.m4s"
        store.beginProgressiveSegment(named: segmentName)
        store.appendProgressiveSegment(named: segmentName, bytes: Data(repeating: 0x6B, count: 16))
        try await server.start()
        defer { server.stop() }

        // The producer stalls forever: the response gives up with the segment
        // still incomplete.
        let wire = await Self.rawResponse(port: server.port, path: segmentName, timeout: 6)
        XCTAssertTrue(wire.closed, "the deadline must drop the stream")
        XCTAssertFalse(
            Self.endsWithChunkedTerminator(wire.bytes),
            "a timed-out prefix must not be declared a complete segment"
        )
    }

    // MARK: Raw HTTP client
    //
    // URLSession is not usable to pin this: it accepts a body truncated by a
    // close as complete (measured, both for an unframed body and for a
    // chunked body cut short). What the server puts on the wire is the
    // contract, so these tests read the bytes.

    private static func headers(of response: Data) -> String {
        guard let range = response.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            return String(decoding: response, as: UTF8.self)
        }
        return String(decoding: response[..<range.lowerBound], as: UTF8.self)
    }

    private static func endsWithChunkedTerminator(_ response: Data) -> Bool {
        response.suffix(5) == Data("0\r\n\r\n".utf8)
    }

    private static func rawResponse(
        port: UInt16,
        path: String,
        timeout: TimeInterval
    ) async -> (bytes: Data, closed: Bool) {
        let collector = RawResponseCollector()
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /\(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                receiveAll(connection, into: collector)
            case .failed, .cancelled:
                collector.close()
            default:
                break
            }
        }
        connection.start(queue: .global())
        let deadline = Date().addingTimeInterval(timeout)
        while !collector.isClosed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let closed = collector.isClosed
        connection.cancel()
        return (collector.bytes, closed)
    }

    private static func receiveAll(_ connection: NWConnection, into collector: RawResponseCollector) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data { collector.append(data) }
            guard !isComplete, error == nil else {
                collector.close()
                return
            }
            receiveAll(connection, into: collector)
        }
    }

    func testParsesClosedByteRangeForPartialContent() {
        XCTAssertEqual(
            LoopbackSegmentServer.parseByteRange("bytes=4-9", totalLength: 20),
            .satisfiable(lower: 4, upper: 9)
        )
    }

    func testRejectsUnsatisfiableRange() {
        XCTAssertEqual(
            LoopbackSegmentServer.parseByteRange("bytes=20-30", totalLength: 20),
            .notSatisfiable
        )
    }
}

private final class LockedElapsed: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: CFTimeInterval?

    var value: CFTimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: CFTimeInterval) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class SegmentResponseTimingDelegate: NSObject, URLSessionDataDelegate {
    struct Result {
        let statusCode: Int
        let headerElapsed: CFTimeInterval
        let firstBodyElapsed: CFTimeInterval?
        let data: Data
    }

    private let startedAt: CFTimeInterval
    private var statusCode = 0
    private var headerElapsed: CFTimeInterval = 0
    private var firstBodyElapsed: CFTimeInterval?
    private var data = Data()
    private var continuation: CheckedContinuation<Result, Error>?

    init(startedAt: CFTimeInterval) {
        self.startedAt = startedAt
    }

    func fetch(url: URL, using session: URLSession) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        headerElapsed = CFAbsoluteTimeGetCurrent() - startedAt
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        if firstBodyElapsed == nil {
            firstBodyElapsed = CFAbsoluteTimeGetCurrent() - startedAt
        }
        self.data.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let continuation = continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(
                returning: Result(
                    statusCode: statusCode,
                    headerElapsed: headerElapsed,
                    firstBodyElapsed: firstBodyElapsed,
                    data: data
                )
            )
        }
    }
}

private final class RawResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBytes = Data()
    private var closed = false

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedBytes
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func append(_ data: Data) {
        lock.lock()
        storedBytes.append(data)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}
