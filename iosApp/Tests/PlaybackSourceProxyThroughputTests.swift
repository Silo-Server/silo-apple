import XCTest
@testable import Silo

/// Investigation harness for the ~12 Mbps producer ingest ceiling observed on
/// device (2026-07-05, HDR10 MKV, silo.arkyncdn.net): a loopback origin that
/// serves at line rate, a control read hitting it directly, and the same
/// sequential read through PlaybackSourceProxy. If the proxy path collapses
/// here too, the ceiling is in the fill/serve path, not the network.
final class PlaybackSourceProxyThroughputTests: XCTestCase {

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
        let origin = RangeOriginStub(totalBytes: Self.fileSize, bodyChunkBytes: 256 * 1024)
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
        let origin = RangeOriginStub(totalBytes: Self.fileSize, bodyChunkBytes: 256 * 1024)
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
        print("[THROUGHPUT] proxy sequential read bytes=\(bytes) seconds=\(String(format: "%.2f", seconds)) rate=\(String(format: "%.1f", rate))Mbps originRequests=\(origin.observedOffsets())")
        // 4K HDR peaks in the field hit ~20-30 Mbps; the proxy on a Mac over
        // loopback should clear that by an order of magnitude. This is a
        // diagnostic floor, not a performance target.
        XCTAssertGreaterThan(rate, 100, "proxy sequential serve path is the ingest bottleneck")
    }

    func testProxyKeepsStreamingAfter150MillisecondOriginDelay() async throws {
        let origin = RangeOriginStub(
            totalBytes: Self.fileSize,
            responseDelay: 0.150,
            bodyChunkBytes: 256 * 1024
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
        let origin = RangeOriginStub(totalBytes: Self.fileSize, bodyChunkBytes: 256 * 1024)
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
        let originRequests = origin.observedOffsets()
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
