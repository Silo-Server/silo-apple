import XCTest
@testable import Silo

final class LoopbackSegmentServerRangeTests: XCTestCase {
    func testVODMissSendsHeadersBeforeSlowSegmentFinishes() async throws {
        let store = LoopbackSegmentStore(generation: 909)
        let server = LoopbackSegmentServer(segmentStore: store)
        let segmentName = "seg_000002.m4s"
        let payload = Data(repeating: 0xA5, count: 32 * 1024)

        server.vodSegmentMissResolver = { _ in
            Thread.sleep(forTimeInterval: LoopbackSegmentServer.vodEarlyResponseDelaySeconds + 0.75)
            store.beginProgressiveSegment(named: segmentName)
            store.appendProgressiveSegment(named: segmentName, bytes: payload.prefix(4_096))
            _ = store.putSegment(name: segmentName, data: payload, duration: 4)
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
