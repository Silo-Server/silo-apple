import XCTest
@testable import Silo

/// Workstream A1 of the playback-continuity plan: `retargetOrigin` swaps the
/// proxy's origin endpoint in place after a silent session renewal. The
/// critical behavior is that a reader blocked at the cache edge (its byte
/// demand parked because the old origin stopped delivering) resumes against
/// the new origin without the serve connection, cache, or local URL changing.
final class PlaybackSourceProxyRetargetTests: XCTestCase {

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
        let deadOrigin = RangeOriginStub(totalBytes: Self.fileSize, stallAfterByte: Self.stallPoint)
        try await deadOrigin.start()
        defer { deadOrigin.stop() }
        let liveOrigin = RangeOriginStub(totalBytes: Self.fileSize)
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
        let origin = RangeOriginStub(totalBytes: Self.fileSize)
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
