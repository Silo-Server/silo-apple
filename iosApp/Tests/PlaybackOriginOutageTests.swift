import XCTest
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
        let origin = RangeOriginStub(totalBytes: Self.fileSize)
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
