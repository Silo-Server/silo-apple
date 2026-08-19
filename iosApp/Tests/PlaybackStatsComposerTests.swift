import XCTest
@testable import Silo

/// One composer owns every user-visible telemetry figure, so the route matrix
/// is pinned here: which producer each row comes from, and that the derived
/// figures (stream speed, cache reuse) have exactly one definition.
final class PlaybackStatsComposerTests: XCTestCase {
    private func makeProxyStats(
        originBytesTransferred: Int64 = 512_000_000,
        currentOriginBitrateBps: Double? = 40_000_000,
        bytesServedFromCache: Int64 = 256_000_000,
        originWaitCount: Int = 12
    ) -> PlaybackSourceProxyStats {
        PlaybackSourceProxyStats(
            cachedBytes: 64_000_000,
            cacheBudgetBytes: 128_000_000,
            highWaterBytes: 128_000_000,
            lowWaterBytes: 64_000_000,
            forwardCachedBytes: 32_000_000,
            estimatedForwardCacheAheadSeconds: 8.5,
            originBytesTransferred: originBytesTransferred,
            currentOriginBitrateBps: currentOriginBitrateBps,
            bytesServedFromCache: bytesServedFromCache,
            originWaitCount: originWaitCount,
            activeOriginRequestCount: 1,
            diskSpillBytes: 1_024,
            diskBudgetBytes: 4_096,
            diskBytesWritten: 2_048,
            resumeCapable: true,
            serverAdvertisesDirectStreamResume: true
        )
    }

    private func makeBackendStats() -> PlaybackStats {
        var stats = PlaybackStats()
        stats.source = "127.0.0.1"
        stats.demuxReadRateBps = 18_000_000
        stats.demuxReadBytes = 99_000_000
        return stats
    }

    // MARK: - Route matrix

    func testLoopbackTakesDownloadRateAndBytesFromProxy() {
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(),
                engine: .siloPlayerLoopback,
                nominalFileBitrateBps: 30_000 * 1_000
            )
        )

        XCTAssertEqual(composed.downloadRateBps, 40_000_000)
        XCTAssertEqual(composed.nominalFileBitrateBps, 30_000_000)
        XCTAssertEqual(try XCTUnwrap(composed.streamSpeed), 1.3333, accuracy: 0.001)
        XCTAssertEqual(composed.networkBytesTransferred, 512_000_000)
        XCTAssertEqual(composed.demuxReadRateBps, 18_000_000)
        XCTAssertEqual(composed.demuxReadBytes, 99_000_000)
        XCTAssertEqual(composed.sourceBytesServedFromCache, 256_000_000)
        XCTAssertEqual(composed.sourceOriginWaitCount, 12)
    }

    func testNativeDirectSelectsDownloadRateLikeLoopback() {
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(),
                engine: .avPlayerNativeDirect,
                nominalFileBitrateBps: 30_000_000
            )
        )

        XCTAssertEqual(composed.downloadRateBps, 40_000_000)
        XCTAssertEqual(composed.networkBytesTransferred, 512_000_000)
    }

    func testHLSUsesObservedBitrateAndKeepsAccessLogBytes() {
        var backend = PlaybackStats()
        backend.source = "media.example.com"
        backend.observedBitrateBps = 12_000_000
        backend.indicatedBitrateBps = 10_000_000
        backend.networkBytesTransferred = 77_000_000

        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: backend,
                proxy: nil,
                engine: .avPlayerHLS,
                nominalFileBitrateBps: 24_000_000
            )
        )

        XCTAssertEqual(composed.downloadRateBps, 12_000_000)
        XCTAssertEqual(composed.networkBytesTransferred, 77_000_000)
        XCTAssertNil(composed.demuxReadRateBps)
        // HLS serves a transcoded variant, so speed is measured against the
        // stream's own indicated bitrate, NOT the catalog file's nominal rate
        // (12 over 10, not 12 over 24).
        XCTAssertEqual(try XCTUnwrap(composed.streamSpeed), 1.2, accuracy: 0.0001)
    }

    func testUnproxiedNativeDirectKeepsBackendNetworkFigures() {
        // The proxy can legitimately be absent on native direct (offline
        // file://, or the proxy failed to start and playback continued).
        // AVPlayer then talks to the origin itself and its access-log
        // figures are the honest ones — the composer must not wipe them.
        var backend = PlaybackStats()
        backend.source = "media.example.com"
        backend.observedBitrateBps = 12_000_000
        backend.networkBytesTransferred = 77_000_000

        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: backend,
                proxy: nil,
                engine: .avPlayerNativeDirect,
                nominalFileBitrateBps: 24_000_000
            )
        )

        XCTAssertEqual(composed.downloadRateBps, 12_000_000)
        XCTAssertEqual(composed.networkBytesTransferred, 77_000_000)
        XCTAssertEqual(try XCTUnwrap(composed.streamSpeed), 0.5, accuracy: 0.0001)
    }

    func testProxiedRouteSuppressesZeroByteOriginCounter() {
        // Before the first origin byte arrives the row must stay hidden, not
        // render "Zero KB".
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(originBytesTransferred: 0),
                engine: .siloPlayerLoopback,
                nominalFileBitrateBps: 30_000_000
            )
        )
        XCTAssertNil(composed.networkBytesTransferred)
    }

    // MARK: - Stream speed

    func testStreamSpeedIsNilWithoutNominalBitrate() {
        for nominal in [nil, Double(0)] {
            let composed = PlaybackStatsComposer.compose(
                PlaybackStatsComposer.Inputs(
                    backend: makeBackendStats(),
                    proxy: makeProxyStats(),
                    engine: .siloPlayerLoopback,
                    nominalFileBitrateBps: nominal
                )
            )
            XCTAssertNil(composed.streamSpeed)
        }
    }

    func testStreamSpeedIsNilWithoutDownloadRate() {
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(currentOriginBitrateBps: nil),
                engine: .siloPlayerLoopback,
                nominalFileBitrateBps: 30_000_000
            )
        )
        XCTAssertNil(composed.streamSpeed)
    }

    // MARK: - Cache reuse

    func testCacheReuseIsTheServedOverFetchedQuotient() {
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(
                    originBytesTransferred: 200,
                    bytesServedFromCache: 300
                ),
                engine: .siloPlayerLoopback,
                nominalFileBitrateBps: 30_000_000
            )
        )
        // Reuse above 1 is legitimate: a backward seek re-serves bytes the
        // origin was only asked for once.
        XCTAssertEqual(try XCTUnwrap(composed.sourceCacheReuseRatio), 1.5, accuracy: 0.0001)
    }

    func testCacheReuseIsNilWhenNothingWasFetched() {
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(
                    originBytesTransferred: 0,
                    bytesServedFromCache: 300
                ),
                engine: .siloPlayerLoopback,
                nominalFileBitrateBps: 30_000_000
            )
        )
        XCTAssertNil(composed.sourceCacheReuseRatio)
    }

    // MARK: - Source label

    func testLocalSourceLabelIsReplacedByOriginHost() {
        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: makeBackendStats(),
                proxy: makeProxyStats(),
                engine: .siloPlayerLoopback,
                originHost: "media.example.com"
            )
        )
        XCTAssertEqual(composed.source, "media.example.com")
    }

    func testRealSourceLabelIsLeftAlone() {
        var backend = makeBackendStats()
        backend.source = "media.example.com"

        let composed = PlaybackStatsComposer.compose(
            PlaybackStatsComposer.Inputs(
                backend: backend,
                proxy: nil,
                engine: .avPlayerHLS,
                originHost: "someone-else.example.com"
            )
        )
        XCTAssertEqual(composed.source, "media.example.com")
    }

    // MARK: - Purity

    func testComposingTwiceFromTheSameInputsIsIdentical() {
        let inputs = PlaybackStatsComposer.Inputs(
            backend: makeBackendStats(),
            proxy: makeProxyStats(),
            engine: .siloPlayerLoopback,
            nominalFileBitrateBps: 30_000_000,
            originHost: "media.example.com"
        )
        XCTAssertEqual(
            PlaybackStatsComposer.compose(inputs),
            PlaybackStatsComposer.compose(inputs)
        )
    }
}
