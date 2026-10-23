import XCTest
@testable import Silo

/// The speed test's arithmetic, replayed against the vendored vectors'
/// `probe_cases` (see `Fixtures/BufferingQuality/SOURCE`). Web and Android
/// replay the same cases.
final class BandwidthProbeMeterTests: XCTestCase {
    private func probeVectors() throws -> [String: Any] {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(named: "vectors", bundleClass: Self.self)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testEveryProbeCase() throws {
        let cases = try XCTUnwrap(try probeVectors()["probe_cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for probeCase in cases {
            let name = try XCTUnwrap(probeCase["name"] as? String)
            let known: Set<String> = ["name", "mode", "target_kbps", "chunks", "end", "expect", "note"]
            XCTAssertEqual(Set(probeCase.keys).subtracting(known), [], "\(name): a new key needs the replay's attention")
            let mode: BandwidthProbeMeter.Mode
            switch probeCase["mode"] as? String {
            case "quick": mode = .quick(targetKbps: probeCase["target_kbps"] as? Int)
            case "accurate": mode = .accurate
            case let other:
                // The rest of the cases still run.
                XCTFail("\(name): mode \(String(describing: other))")
                continue
            }
            var meter = BandwidthProbeMeter(mode: mode)
            for chunk in try XCTUnwrap(probeCase["chunks"] as? [[Int]]) {
                meter.receive(chunk[1], at: chunk[0])
            }
            if let end = probeCase["end"] as? Int {
                meter.transferEnded(at: end)
            } else {
                meter.advance(to: meter.maxMs)
            }
            if let expect = probeCase["expect"] as? [String: Any] {
                XCTAssertEqual(meter.stoppedAt, expect["stop"] as? Int, "\(name): stop")
                XCTAssertEqual(meter.result, BandwidthProbeMeter.Measurement(
                    kbps: try XCTUnwrap(expect["kbps"] as? Int),
                    lowerBound: try XCTUnwrap(expect["lower_bound"] as? Bool),
                    bytes: try XCTUnwrap(expect["bytes"] as? Int),
                    durationMs: try XCTUnwrap(expect["duration_ms"] as? Int)
                ), name)
            } else {
                XCTAssertNil(meter.result, "\(name): measured nothing")
            }
        }
    }

    func testTheConstantsMatchTheVectors() throws {
        let constants = try XCTUnwrap(try probeVectors()["probe_constants"] as? [String: Int])
        XCTAssertEqual(constants, [
            "PROBE_WINDOW_MS": BandwidthProbe.windowMs,
            "QUICK_PROBE_BYTES": BandwidthProbe.quickBytes,
            "QUICK_PROBE_MAX_MS": BandwidthProbe.quickMaxMs,
            "QUICK_SETTLE_WINDOWS": BandwidthProbe.quickSettleWindows,
            "ACCURATE_PROBE_BYTES": BandwidthProbe.accurateBytes,
            "ACCURATE_PROBE_MAX_MS": BandwidthProbe.accurateMaxMs,
            "ACCURATE_SETTLE_WINDOWS": BandwidthProbe.accurateSettleWindows,
            "PROBE_FIRST_BYTE_DEADLINE_MS": BandwidthProbe.firstByteDeadlineMs,
            "MIN_PROBE_KBPS": BandwidthProbe.minKbps,
            "MAX_PROBE_KBPS": BandwidthProbe.maxKbps,
        ], "a new constant needs a counterpart")
    }

    /// A target under 100 kbps is reported as 100, a value the server takes.
    func testTheQuickTestNeverReportsATargetUnder100() {
        var meter = BandwidthProbeMeter(mode: .quick(targetKbps: 40))
        meter.receive(10_000, at: 0)
        meter.receive(10_000, at: 600)
        meter.advance(to: 1_000)
        XCTAssertEqual(meter.result?.kbps, 100)
        XCTAssertEqual(meter.result?.lowerBound, true)
    }

    func testEachModeAsksForItsOwnSize() throws {
        let server = try XCTUnwrap(URL(string: "https://silo.example"))
        XCTAssertEqual(BandwidthProbeMeter(mode: .quick(targetKbps: nil)).requestedBytes, 100_000_000)
        XCTAssertEqual(BandwidthProbeMeter(mode: .accurate).requestedBytes, 1_000_000_000)
        XCTAssertEqual(
            BandwidthProbe.downloadURL(
                try XCTUnwrap(URL(string: "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true")),
                serverURL: server, bytes: 100_000_000
            )?.absoluteString,
            "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true&size=100000000"
        )
        XCTAssertEqual(
            BandwidthProbe.downloadURL(
                try XCTUnwrap(URL(string: "https://silo.example:8096/api/v2/playback/bandwidth-probe?size=5")),
                serverURL: server, bytes: 1_000_000_000
            )?.absoluteString,
            "https://silo.example:8096/api/v2/playback/bandwidth-probe?size=1000000000"
        )
        XCTAssertNil(BandwidthProbe.downloadURL(try XCTUnwrap(URL(string: "ftp://silo.example/probe")), serverURL: server, bytes: 1))
        // The download carries credentials: an https server's never go to
        // cleartext, while an http server's already do.
        let cleartext = try XCTUnwrap(URL(string: "http://silo.example/api/v2/playback/bandwidth-probe"))
        XCTAssertNil(BandwidthProbe.downloadURL(cleartext, serverURL: server, bytes: 1))
        XCTAssertNotNil(BandwidthProbe.downloadURL(
            cleartext, serverURL: try XCTUnwrap(URL(string: "http://silo.example")), bytes: 1
        ))
    }
}

/// The timed download over a stubbed transport: its answers to the server's
/// refusals, and the redirect to a proxy.
final class BandwidthProbeDownloadTests: XCTestCase {
    private let probeURL = URL(string: "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true&size=40000000")!
    private let stub = StubURLProtocol.Handler()

    private func download() -> BandwidthProbeDownload {
        let configuration = BandwidthProbeDownload.defaultConfiguration()
        stub.install(into: configuration)
        return BandwidthProbeDownload(mode: .quick(targetKbps: 115_000), configuration: configuration)
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: probeURL)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("p-1", forHTTPHeaderField: "X-Profile-Id")
        request.setValue("device-1", forHTTPHeaderField: "X-Silo-Device-Id")
        return request
    }

    func testARateLimitWithoutRetryAfterWaits30Seconds() async throws {
        stub.route(StubURLProtocol.any) { _ in .status(429) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .rateLimited(retryAfterSeconds: 30))
    }

    func testARateLimitIsTypedWithItsRetryAfter() async throws {
        stub.route(StubURLProtocol.any) { _ in .init(status: 429, headers: ["Retry-After": "42"]) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .rateLimited(retryAfterSeconds: 42))
    }

    func testARefusalIsUnavailableAndNeverAnotherPath() async throws {
        stub.route(StubURLProtocol.any) { _ in .status(503) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .unavailable(status: 503))
        XCTAssertEqual(stub.requests.map(\.url), [probeURL])
    }

    func testAShortBodyIsTooLittleData() async throws {
        stub.route(StubURLProtocol.any) { _ in .init(status: 200, body: Data(count: 1_024)) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .tooLittleData)
    }

    /// The proxy's URL carries its own short-lived token; the account's
    /// credentials stay with the API.
    func testTheRedirectToTheProxyDropsTheCredentials() async throws {
        let proxy = URL(string: "https://proxy.example/stream/bandwidth-probe/token?size=40000000")!
        stub.route({ $0.url == proxy }) { _ in .init(status: 200, body: Data(count: 1_024)) }
        stub.route(StubURLProtocol.any) { _ in .init(status: 307, redirect: proxy) }
        _ = try await download().measure(request())
        XCTAssertEqual(stub.requests.map(\.url), [probeURL, proxy])
        let proxied = try XCTUnwrap(stub.requests.last)
        XCTAssertNil(proxied.header("Authorization"))
        XCTAssertNil(proxied.header("X-Profile-Id"))
        XCTAssertEqual(proxied.header("X-Silo-Device-Id"), "device-1")
    }

    /// Failures are logged publicly, so they never carry the host.
    func testAFailureIsDescribedWithoutItsHost() {
        let error = URLError(.serverCertificateUntrusted, userInfo: [
            NSLocalizedDescriptionKey: "The certificate for this server is invalid. You might be connecting to a server that is pretending to be “silo.example”.",
            NSURLErrorFailingURLErrorKey: probeURL,
        ])
        XCTAssertEqual(BandwidthProbeDownload.describe(error), "NSURLErrorDomain -1202")
    }

    /// Windows close on the download's clock, not only when data arrives: a
    /// transfer that goes silent still stops at the test's limit, and the
    /// silent windows after the ramp-up measure nothing.
    func testWindowsCloseOnTheClockWhileNoDataArrives() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var ms = 0
            private var readCount = 0
            var reads: Int { lock.withLock { readCount } }
            func read() -> Int {
                lock.withLock {
                    readCount += 1
                    return ms
                }
            }
            func set(_ value: Int) { lock.withLock { ms = value } }
        }
        let clock = Clock()
        stub.route(StubURLProtocol.any) { _ in
            .init(status: 200, body: Data(count: 2_000_000), finishes: false)
        }
        let configuration = BandwidthProbeDownload.defaultConfiguration()
        stub.install(into: configuration)
        let probe = BandwidthProbeDownload(
            mode: .quick(targetKbps: nil), configuration: configuration
        ) { clock.read() }
        let task = Task { try await probe.measure(request()) }
        defer { task.cancel() }
        // The first read stamps the first bytes at 0 and the second times
        // them; then the clock passes the limit with nothing more arriving.
        guard await eventually({ clock.reads >= 2 }) else {
            XCTFail("the first bytes did not land at 0")
            return
        }
        clock.set(BandwidthProbe.quickMaxMs + 1_000)
        let result = try await task.value
        // Without the clock it would wait for the session's idle timeout and
        // fail as a network error.
        XCTAssertEqual(result, .tooLittleData)
    }

    func testCancellingTheCallerCancelsTheProbe() async throws {
        stub.route(StubURLProtocol.any) { _ in .init(status: 200, finishes: false) }
        let probe = download()
        let task = Task { try await probe.measure(request()) }
        defer { task.cancel() }
        try await stub.waitForRequest { _ in true }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled probe has no result")
        } catch is CancellationError {}
    }
}

/// When the probe runs, what it keeps, and what stops it.
@MainActor
final class BandwidthProbeSchedulerTests: XCTestCase {
    private static let wifi = BandwidthProbeNetwork(
        isConnected: true, transport: "wifi", usesCellular: false, isMetered: false, key: "wifi|en0|gw1"
    )
    private static let otherWifi = BandwidthProbeNetwork(
        isConnected: true, transport: "wifi", usesCellular: false, isMetered: false, key: "wifi|en0|gw2"
    )
    private static let cellular = BandwidthProbeNetwork(
        isConnected: true, transport: "cellular", usesCellular: true, isMetered: true, key: "cellular|pdp0|"
    )
    private static let day: TimeInterval = 24 * 60 * 60

    private var clock: ManualBufferingQualityClock!
    private var server: FakeProbeServer!
    private var scheduler: BandwidthProbeScheduler!

    override func setUp() async throws {
        clock = ManualBufferingQualityClock()
        server = FakeProbeServer()
        scheduler = BandwidthProbeScheduler(server: server, clock: clock)
        scheduler.setForeground(true)
    }

    private func advance(seconds: TimeInterval) async {
        clock.advance(to: clock.nowMs + Int(seconds * 1000))
        // Let a look the timer started run on the main actor.
        for _ in 0..<50 { await Task.yield() }
    }

    private func probe(kbps: Int, lowerBound: Bool = false, ageDays: Double) -> BandwidthReading {
        BandwidthReading(kbps: kbps, lowerBound: lowerBound,
                         measuredAt: clock.now.addingTimeInterval(-ageDays * Self.day), source: .probe(transport: "wifi"))
    }

    private func sample(kbps: Int, ageDays: Double) -> BandwidthReading {
        BandwidthReading(kbps: kbps, lowerBound: true,
                         measuredAt: clock.now.addingTimeInterval(-ageDays * Self.day), source: .playbackSample)
    }

    /// Signs in on Wi-Fi and lets the first look run.
    private func signIn() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
    }

    func testALookReadsTheServerThenRunsAQuickTestWhenNothingProvesTheLink() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 4.9)
        XCTAssertEqual(server.storedCount, 1, "the server's readings are read at once")
        XCTAssertEqual(server.modes, [], "the test lets the first screen settle")
        await advance(seconds: 0.1)
        XCTAssertEqual(server.storedCount, 2, "the look reads them again first")
        XCTAssertEqual(server.modes, [.quick(targetKbps: 115_000)])
        XCTAssertEqual(scheduler.freshEstimateKbps(), 115_000)
        XCTAssertEqual(server.reports.map(\.lowerBound), [true])
        XCTAssertEqual(server.reports.map(\.manual), [false], "the automatic test never lifts a limit")
        XCTAssertEqual(scheduler.probeReading?.kbps, 115_000)
    }

    func testACurrentSettledProbeProvesTheLink() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: 6)
        await signIn()
        XCTAssertEqual(server.modes, [])
        XCTAssertEqual(scheduler.freshEstimateKbps(), 48_000)
    }

    func testALowerBoundProvesTheLinkOnlyWhileItReachesTheTarget() async {
        server.stored.probe = probe(kbps: 115_000, lowerBound: true, ageDays: 1)
        await signIn()
        XCTAssertEqual(server.modes, [], "it reaches the 115 Mbps target")

        // The library grew: the target rose past the lower bound.
        server.targetKbps = 150_000
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes, [.quick(targetKbps: 150_000)])
    }

    /// The server's clock can run ahead of the device's.
    func testAReadingDatedAheadOfTheDeviceClockIsCurrent() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: -30.0 / Self.day)
        await signIn()
        XCTAssertEqual(scheduler.freshEstimateKbps(), 48_000)
        XCTAssertEqual(server.modes, [], "it proves the link")
    }

    func testAPlaybackSampleIsALowerBound() async {
        server.stored.playbackSample = sample(kbps: 120_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(server.modes, [], "above the target, it proves the link")
        XCTAssertEqual(scheduler.freshEstimateKbps(), 120_000)

        let slow = FakeProbeServer()
        slow.stored.playbackSample = sample(kbps: 51_200, ageDays: 1)
        let other = BandwidthProbeScheduler(server: slow, clock: clock)
        other.setForeground(true)
        other.networkChanged(Self.wifi)
        other.setActiveServer("server")
        await advance(seconds: 5)
        XCTAssertEqual(slow.modes, [.quick(targetKbps: 115_000)], "below the target, it does not")
    }

    func testAStartSendsTheHighestCurrentReading() async {
        server.stored.playbackSample = sample(kbps: 60_000, ageDays: 1)
        server.stored.probe = probe(kbps: 30_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(server.modes, [], "the settled probe proves the link")
        XCTAssertEqual(scheduler.freshEstimateKbps(), 60_000)
    }

    /// A lower Test speed result replaces the playback sample, as on the
    /// server, even when the read after it fails; an automatic test's result
    /// leaves the higher sample.
    func testOnlyATestSpeedResultReplacesThePlaybackSample() async {
        let rows: [(name: String, testSpeed: Bool, readFails: Bool, estimate: Int)] = [
            ("Test speed", true, false, 20_000),
            ("Test speed, the read after it fails", true, true, 20_000),
            ("automatic test", false, false, 60_000),
        ]
        for row in rows {
            let server = FakeProbeServer()
            server.automatic = !row.testSpeed
            server.stored.playbackSample = sample(kbps: 60_000, ageDays: 0)
            server.result = .measured(.init(kbps: 20_000, lowerBound: false, bytes: 7_500_000, durationMs: 3_000))
            let scheduler = BandwidthProbeScheduler(server: server, clock: clock)
            scheduler.setForeground(true)
            scheduler.networkChanged(Self.wifi)
            scheduler.setActiveServer("server")
            await advance(seconds: 5)
            server.readsFail = row.readFails
            if row.testSpeed { _ = await scheduler.runNow() }
            XCTAssertEqual(server.reports.count, 1, "\(row.name): the test ran")
            XCTAssertEqual(scheduler.freshEstimateKbps(), row.estimate, row.name)
        }
    }

    func testReadingsOlderThanTheMaxAgeAreNotCurrent() async {
        server.maxAge = 3 * Self.day
        server.stored.probe = probe(kbps: 48_000, ageDays: 3.1)
        await signIn()
        XCTAssertEqual(server.modes, [.quick(targetKbps: 115_000)])
    }

    /// No timer re-tests a reading: a look after its lifetime does.
    func testThereIsNoPeriodicTest() async {
        await signIn()
        XCTAssertEqual(server.modes.count, 1)
        await advance(seconds: 30 * Self.day)
        XCTAssertEqual(server.modes.count, 1, "nothing re-tests by itself")
        XCTAssertNil(scheduler.freshEstimateKbps(), "past its lifetime")
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 2)
    }

    func testAutomaticTestsOffLeaveTestSpeed() async {
        server.automatic = false
        await signIn()
        XCTAssertEqual(server.modes, [])
        let outcome = await scheduler.runNow()
        XCTAssertEqual(server.modes, [.accurate])
        // Test speed's result is the viewer's: `manual`, which can lift a learned limit.
        XCTAssertEqual(outcome, .measured(BandwidthMeasurement(
            kbps: 115_000, lowerBound: true, bytes: 7_187_500, durationMs: 500, transport: "wifi", measuredAt: clock.now,
            manual: true
        )))
    }

    func testTestSpeedRunsTheAccurateTestWhateverTheReading() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: 1)
        await signIn()
        _ = await scheduler.runNow()
        XCTAssertEqual(server.modes, [.accurate])
    }

    /// A start in the first seconds sends the server's reading.
    func testEachCheckReadsTheServerAtOnce() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: 1)
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 0)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 48_000, "on sign-in")

        server.stored.probe = probe(kbps: 300_000, ageDays: 2)
        scheduler.networkChanged(Self.otherWifi)
        await advance(seconds: 0)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 300_000, "after a network change")

        server.stored.playbackSample = sample(kbps: 400_000, ageDays: 0)
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 0)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 400_000, "on a return to the foreground")
        XCTAssertEqual(server.modes, [])
    }

    /// Another network has its own reading on the server.
    func testANetworkChangeLooksAgainForThatNetwork() async {
        await signIn()
        XCTAssertEqual(server.modes.count, 1)
        server.stored.probe = probe(kbps: 300_000, ageDays: 2)
        scheduler.networkChanged(Self.otherWifi)
        XCTAssertNil(scheduler.freshEstimateKbps(), "the old network's readings go")
        XCTAssertNil(scheduler.probeReading)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 1, "the server had one")
        XCTAssertEqual(scheduler.freshEstimateKbps(), 300_000)
    }

    func testAMeteredNetworkIsNeitherTestedNorSent() async {
        await signIn()
        scheduler.networkChanged(Self.cellular)
        XCTAssertNil(scheduler.freshEstimateKbps())
        await advance(seconds: Self.day)
        XCTAssertEqual(server.modes.count, 1, "no test on cellular")
        let outcome = await scheduler.runNow()
        XCTAssertEqual(outcome, .metered)
    }

    func testAFailureWaitsForTheNextLook() async {
        server.result = .networkError("reset")
        await signIn()
        XCTAssertEqual(server.modes.count, 1)
        await advance(seconds: Self.day)
        XCTAssertEqual(server.modes.count, 1, "no retry timer")
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 2)
    }

    /// The hold belongs to the server that sent the 429, on any network.
    func testARateLimitHoldsAcrossANetworkChange() async {
        server.result = .rateLimited(retryAfterSeconds: 600)
        await signIn()
        server.result = .measured(.init(kbps: 48_000, lowerBound: false, bytes: 6_000_000, durationMs: 1_000))
        scheduler.networkChanged(Self.otherWifi)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 1, "still within Retry-After")
        await advance(seconds: 600)
        scheduler.networkChanged(Self.wifi)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 2)
    }

    /// Test speed measures accurately even while an automatic test runs.
    func testTestSpeedReplacesARunningAutomaticTest() async {
        server.hangs = true
        await signIn()
        XCTAssertTrue(scheduler.isProbing)
        server.hangs = false
        let outcome = await scheduler.runNow()
        if case .measured = outcome {} else { XCTFail("Test speed ran its own test, not \(outcome)") }
        XCTAssertEqual(server.modes, [.quick(targetKbps: 115_000), .accurate])
    }

    /// A network change while a look still waits on the server keeps its own
    /// look, which runs once the earlier one finishes.
    func testANetworkChangeDuringALookStillLooks() async {
        server.holdsReads = true
        await signIn()
        scheduler.networkChanged(Self.otherWifi)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes, [], "the first look still waits")
        server.releaseReads()
        await expectEventually("the second look tests") { !server.modes.isEmpty }
        XCTAssertEqual(server.modes, [.quick(targetKbps: 115_000)])
    }

    func testARateLimitHoldsLooksUntilItsRetryAfter() async {
        server.result = .rateLimited(retryAfterSeconds: 600)
        await signIn()
        server.result = .measured(.init(kbps: 48_000, lowerBound: false, bytes: 6_000_000, durationMs: 1_000))
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 1, "too soon")
        await advance(seconds: 600)
        XCTAssertEqual(server.modes.count, 1, "and still no timer")
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 2)
    }

    func testPlaybackStartingCancelsARunningTestWhichMeasuresNothing() async {
        server.hangs = true
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        XCTAssertTrue(scheduler.isProbing)

        scheduler.playbackStarting()
        // The cancelled download wakes off the main actor before it returns.
        await expectEventually("the cancelled test ends") { !scheduler.isProbing }
        XCTAssertNil(scheduler.freshEstimateKbps())

        server.hangs = false
        if case .measured = await scheduler.runNow() {} else { XCTFail("Test speed runs once nothing plays") }
    }

    /// Media is still loading for a while after a start, which holds
    /// automatic tests but not **Test speed**.
    func testTheQuietPeriodAfterAStartHoldsOnlyAutomaticTests() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        scheduler.playbackStarting()
        await advance(seconds: 30)
        XCTAssertEqual(server.modes, [])
        if case .measured = await scheduler.runNow() {} else { XCTFail("Test speed runs when nothing plays") }
        XCTAssertEqual(server.modes, [.accurate])
    }

    /// However the player is presented, including picture in picture, its
    /// playback holds tests off for as long as it lasts.
    func testAVideoPlayerHoldsLooksOffUntilItEnds() async {
        let player = NSObject()
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        scheduler.playbackStarting(by: player)
        await advance(seconds: 10 * 60)
        XCTAssertEqual(server.modes, [])
        let refused = await scheduler.runNow()
        XCTAssertEqual(refused, .playbackActive)
        scheduler.playbackEnded(by: player)
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.modes.count, 1)
    }

    func testAReleasedPlayerDoesNotHoldTestsOff() async {
        var player: NSObject? = NSObject()
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        scheduler.playbackStarting(by: player!)
        player = nil
        await advance(seconds: 61)
        if case .measured = await scheduler.runNow() {} else { XCTFail("the released player left no hold") }
    }

    func testBackgroundAndHiddenStopLooksAndCancelTests() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        scheduler.setForeground(false)
        await advance(seconds: 60)
        XCTAssertEqual(server.storedCount, 0)
        scheduler.setForeground(true)
        scheduler.setHidden(true)
        await advance(seconds: 60)
        XCTAssertEqual(server.storedCount, 0, "a hidden or minimized Mac counts as background")
        server.hangs = true
        scheduler.setHidden(false)
        await advance(seconds: 5)
        XCTAssertTrue(scheduler.isProbing)
        scheduler.setHidden(true)
        await expectEventually("the cancelled test ends") { !scheduler.isProbing }
        XCTAssertNil(scheduler.freshEstimateKbps(), "a cancelled test measured nothing")
    }

    func testAServerWithoutAProbeIsLeftAlone() async {
        server.hasTarget = false
        await signIn()
        await advance(seconds: Self.day)
        XCTAssertEqual(server.targetCount, 1)
        XCTAssertEqual(server.modes, [])
    }

    /// A switch to another server while signed in: the old server's estimate
    /// goes at once and the new server's reading is read at once.
    func testAServerSwitchReadsTheNewServerAtOnce() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(scheduler.freshEstimateKbps(), 48_000)

        server.stored.probe = probe(kbps: 300_000, ageDays: 1)
        server.serverId = "other"
        scheduler.setActiveServer("other")
        XCTAssertNil(scheduler.freshEstimateKbps(), "it belonged to the other server")
        await advance(seconds: 0)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 300_000)
    }

    /// A failed connection read changes nothing held and runs no test.
    func testAFailedReadChangesNothingAndRunsNoTest() async {
        server.stored.playbackSample = sample(kbps: 120_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(scheduler.freshEstimateKbps(), 120_000)
        server.stored = .none
        server.readsFail = true
        scheduler.setForeground(false)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 120_000, "the sample it held stays")
        XCTAssertEqual(server.modes, [], "and no test runs on a read that failed")
    }

    /// Nothing is current until the server's reading lifetime is known.
    func testNoReadingIsCurrentBeforeTheLifetimeIsKnown() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: 1)
        server.targetFails = true
        await signIn()
        XCTAssertNil(scheduler.freshEstimateKbps())
        XCTAssertEqual(server.modes, [])
    }

    /// Every sign-in is a check, even to the same server; the same session
    /// signing in again is not.
    func testASignInToTheSameServerIsACheck() async {
        let first = BandwidthProbeSession(serverId: "server", credentialGeneration: UUID(), profileId: "p-1")
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveSession(first)
        await advance(seconds: 0)
        XCTAssertEqual(server.storedCount, 1)
        scheduler.setActiveSession(first)
        await advance(seconds: 0)
        XCTAssertEqual(server.storedCount, 1, "the same session is not signed in again")
        scheduler.setActiveSession(BandwidthProbeSession(serverId: "server", credentialGeneration: UUID(), profileId: "p-1"))
        await advance(seconds: 0)
        XCTAssertEqual(server.storedCount, 2, "a new sign-in reads again")
    }

    /// Test speed's 429 holds automatic tests on that server, across a
    /// sign-out and sign-in.
    func testATestSpeedRateLimitHoldsAutomaticTestsAcrossSignIns() async {
        server.result = .rateLimited(retryAfterSeconds: 600)
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        server.automatic = false
        await advance(seconds: 5)
        let outcome = await scheduler.runNow()
        XCTAssertEqual(outcome, .rateLimited(retryAfterSeconds: 600))
        server.automatic = true
        server.result = .measured(.init(kbps: 48_000, lowerBound: false, bytes: 6_000_000, durationMs: 1_000))
        scheduler.setActiveServer(nil)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        XCTAssertEqual(server.modes, [.accurate], "held until its Retry-After")
    }

    /// A result the server refuses is not kept; one whose report never got
    /// an answer is.
    func testOnlyAResultTheServerDidNotRefuseIsKept() async {
        server.automatic = false
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        server.reportResult = .refused
        if case .notSaved = await scheduler.runNow() {} else { XCTFail("a refused result is not saved") }
        XCTAssertNil(scheduler.probeReading)
        server.reportResult = .failed
        if case .notSaved = await scheduler.runNow() {} else { XCTFail("a failed report is not saved") }
        XCTAssertEqual(scheduler.probeReading?.kbps, 115_000, "but it still describes this connection")
    }

    /// A report still waiting when the network changes keeps nothing for the
    /// network it measured: the new network's readings stay as they are.
    func testAReportThatOutlivesItsNetworkKeepsNothing() async {
        server.automatic = false
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        server.reportResult = .failed
        let scheduler = scheduler!
        server.duringReport = { scheduler.networkChanged(Self.otherWifi) }
        _ = await scheduler.runNow()
        XCTAssertNil(scheduler.probeReading)
    }

    /// A report still waiting when a new session signs in to the same server
    /// keeps nothing for the new session.
    func testAReportThatOutlivesItsSessionKeepsNothing() async {
        server.automatic = false
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveSession(BandwidthProbeSession(serverId: "server", credentialGeneration: UUID(), profileId: "p-1"))
        await advance(seconds: 5)
        server.reportResult = .failed
        let scheduler = scheduler!
        server.duringReport = {
            scheduler.setActiveSession(BandwidthProbeSession(serverId: "server", credentialGeneration: UUID(), profileId: "p-1"))
        }
        _ = await scheduler.runNow()
        XCTAssertNil(scheduler.probeReading)
    }

    /// The app hiding while the look reads the server again starts no test.
    func testAnAutomaticTestDoesNotStartAfterTheAppHidDuringItsRead() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        for _ in 0..<50 { await Task.yield() }
        server.holdsReads = true
        await advance(seconds: 5)
        scheduler.setForeground(false)
        server.releaseReads()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(server.modes.isEmpty, "no test in the background")
    }

    /// Settings reads the connection again whenever it changes, including
    /// when the local route to the server comes or goes on the same network.
    func testTheConnectionRevisionMovesWithTheRoute() async {
        var local: String? = nil
        scheduler.localRouteServerId = { local }
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        let before = scheduler.connectionRevision
        local = "server"
        scheduler.localRouteChanged()
        XCTAssertEqual(scheduler.connectionRevision, before + 1)
        scheduler.networkChanged(Self.otherWifi)
        XCTAssertEqual(scheduler.connectionRevision, before + 2)
    }

    /// A report the server answered without storing is refused; one that got
    /// no answer failed.
    func testAReportTheServerAnsweredIsRefused() throws {
        let problem = try HTTPClient.makeJSONDecoder().decode(
            APIv2Problem.self,
            from: Data(#"{"type":"about:blank","title":"Unprocessable","status":422,"detail":"kbps out of range"}"#.utf8))
        let refused: [Error] = [
            APIv2Error.problem(problem), APIv2Error.httpStatus(500), PlaybackSequencedError.invalidResponse,
        ]
        for error in refused {
            XCTAssertEqual(LiveBandwidthProbeServer.reportResult(for: error), .refused, "\(error)")
        }
        let failed: [Error] = [
            HTTPError.network(underlying: URLError(.timedOut)), CancellationError(),
            HTTPError.requestIdentityChanged, APIv2Error.serverUpdateRequired,
        ]
        for error in failed {
            XCTAssertEqual(LiveBandwidthProbeServer.reportResult(for: error), .failed, "\(error)")
        }
    }

    /// Test speed waits for the automatic test it replaced to stop. The
    /// network changing, or the app hiding, while it waits stops it too.
    func testTestSpeedStopsForWhatHappensWhileItWaits() async {
        for interrupt in ["network", "hidden"] {
            clock = ManualBufferingQualityClock()
            server = FakeProbeServer()
            scheduler = BandwidthProbeScheduler(server: server, clock: clock)
            scheduler.setForeground(true)
            scheduler.networkChanged(Self.wifi)
            scheduler.setActiveServer("server")
            server.holdsMeasures = true
            await advance(seconds: 5)
            XCTAssertEqual(server.modes.count, 1, "\(interrupt): the automatic test is running")
            let scheduler = scheduler!
            let testSpeed = Task { await scheduler.runNow() }
            for _ in 0..<50 { await Task.yield() }
            if interrupt == "network" { scheduler.networkChanged(Self.otherWifi) } else { scheduler.setForeground(false) }
            server.releaseMeasures()
            let outcome = await testSpeed.value
            XCTAssertEqual(outcome, .interrupted, interrupt)
            XCTAssertFalse(server.modes.contains(.accurate), "\(interrupt): Test speed never measured")
        }
    }

    /// A paused video player does not hold Test speed off; one that plays or
    /// loads does.
    func testAPausedPlayerDoesNotHoldTestSpeedOff() async {
        let player = NSObject()
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        scheduler.playbackStarting(by: player)
        let playing = await scheduler.runNow()
        XCTAssertEqual(playing, .playbackActive)
        scheduler.videoPlayer(player, isActive: false)
        if case .measured = await scheduler.runNow() {} else { XCTFail("a paused player holds nothing off") }
        withExtendedLifetime(player) {}
    }

    /// A start sends only a reading of its own server, taken over the route
    /// its media takes.
    func testAStartSendsOnlyAReadingOfItsServerAndRoute() async {
        server.stored.probe = probe(kbps: 48_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(scheduler.freshEstimateKbps(forServer: "server", overLocalRoute: false), 48_000)
        XCTAssertNil(scheduler.freshEstimateKbps(forServer: "elsewhere", overLocalRoute: false), "another server's start")
        XCTAssertNil(scheduler.freshEstimateKbps(forServer: "server", overLocalRoute: true), "media on the local route")

        // The local route coming up is a new connection: read again over it.
        scheduler.localRouteServerId = { "server" }
        scheduler.localRouteChanged()
        await advance(seconds: 0)
        XCTAssertEqual(server.storedCount, 2, "one read at sign-in, one over the route")
        XCTAssertEqual(scheduler.freshEstimateKbps(forServer: "server", overLocalRoute: true), 48_000)
        XCTAssertNil(scheduler.freshEstimateKbps(forServer: "server", overLocalRoute: false))
    }

    func testSigningOutForgetsTheReadings() async {
        await signIn()
        XCTAssertNotNil(scheduler.freshEstimateKbps())
        scheduler.setActiveServer(nil)
        XCTAssertNil(scheduler.freshEstimateKbps(), "they belonged to that server")
    }
}

/// A probe server whose answers the test sets. Main-actor isolated, so a
/// test runs entirely on the main actor and a few yields let it finish. Like
/// the real one, it keeps the latest result it is sent, and a Test speed
/// result clears its playback sample.
@MainActor
private final class FakeProbeServer: BandwidthProbeServer {
    var result: BandwidthProbeResult = .measured(.init(kbps: 115_000, lowerBound: true, bytes: 7_187_500, durationMs: 500))
    /// The download never ends until cancelled.
    var hangs = false
    var hasTarget = true
    var targetKbps: Int? = 115_000
    var automatic = true
    var maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// The server the speed test belongs to.
    var serverId = "server"
    var stored = BandwidthStoredReadings.none
    private(set) var storedCount = 0
    private(set) var targetCount = 0
    private(set) var modes: [BandwidthProbeMeter.Mode] = []
    private(set) var reports: [BandwidthMeasurement] = []

    struct ReadFailed: Error {}
    /// The capability read throws.
    var targetFails = false
    /// The connection read throws.
    var readsFail = false

    func target() async throws -> BandwidthProbeTarget? {
        targetCount += 1
        if targetFails { throw ReadFailed() }
        guard hasTarget else { return nil }
        return BandwidthProbeTarget(
            url: URL(string: "https://silo.example/api/v2/playback/bandwidth-probe")!,
            targetKbps: targetKbps,
            automatic: automatic,
            maxAge: maxAge,
            auth: CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: serverId, serverURL: "https://silo.example",
                                                credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: serverId),
                accessToken: "token", profileId: "p-1", profileToken: nil
            )
        )
    }

    /// Reads wait until ``releaseReads()``.
    var holdsReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []

    func releaseReads() {
        holdsReads = false
        heldReads.forEach { $0.resume() }
        heldReads = []
    }

    func storedReadings() async throws -> BandwidthStoredReadings {
        storedCount += 1
        if holdsReads { await withCheckedContinuation { heldReads.append($0) } }
        if readsFail { throw ReadFailed() }
        return stored
    }

    /// Measurements wait, ignoring cancellation, until ``releaseMeasures()``.
    var holdsMeasures = false
    private var heldMeasures: [CheckedContinuation<Void, Never>] = []

    func releaseMeasures() {
        holdsMeasures = false
        heldMeasures.forEach { $0.resume() }
        heldMeasures = []
    }

    func measure(_ target: BandwidthProbeTarget, mode: BandwidthProbeMeter.Mode) async throws -> BandwidthProbeResult {
        modes.append(mode)
        if holdsMeasures { await withCheckedContinuation { heldMeasures.append($0) } }
        if hangs { try await Task.sleep(for: .seconds(3_600)) }
        return result
    }

    var reportResult = BandwidthReportResult.stored
    /// Runs while the report waits for its answer.
    var duringReport: (@MainActor () -> Void)?

    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> BandwidthReportResult {
        reports.append(measurement)
        if let duringReport { await duringReport() }
        if reportResult == .stored {
            stored.probe = measurement.reading
            if measurement.manual { stored.playbackSample = nil }
        }
        return reportResult
    }
}

/// The Connection group's lines, as Android words them.
final class ConnectionSpeedTextTests: XCTestCase {
    private typealias VM = SettingsViewModel
    private let measured = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func text(_ kbps: Int, after seconds: TimeInterval, on transport: String = "wifi") -> String {
        VM.connectionSpeedText(kbps: kbps, measuredAt: measured, transport: transport,
                               now: measured.addingTimeInterval(seconds))
    }

    func testTheSpeedLineSaysWhenAndOnWhatNetwork() {
        XCTAssertEqual(text(48_317, after: 3 * 60 + 59), "48 Mbps · measured 3 minutes ago on Wi-Fi")
        XCTAssertEqual(text(48_000, after: 59), "48 Mbps · measured just now on Wi-Fi")
        XCTAssertEqual(text(48_000, after: -30), "48 Mbps · measured just now on Wi-Fi", "a clock behind the measurement")
        XCTAssertEqual(text(48_000, after: 60, on: "ethernet"), "48 Mbps · measured 1 minute ago on Ethernet")
        XCTAssertEqual(text(48_000, after: 2 * 3_600, on: "cellular"), "48 Mbps · measured 2 hours ago on cellular")
        XCTAssertEqual(text(48_000, after: 3_600, on: "other"), "48 Mbps · measured 1 hour ago on this connection")
        XCTAssertEqual(text(48_000, after: 26 * 3_600), "48 Mbps · measured 1 day ago on Wi-Fi")
        XCTAssertEqual(text(400, after: 0), "400 kbps · measured just now on Wi-Fi")
    }

    func testALowerBoundReadsFasterThan() {
        XCTAssertEqual(
            VM.connectionSpeedText(kbps: 115_000, lowerBound: true, measuredAt: measured, transport: "wifi",
                                   now: measured.addingTimeInterval(180)),
            "Faster than 115 Mbps · measured 3 minutes ago on Wi-Fi"
        )
        XCTAssertEqual(
            VM.playbackSampleText(kbps: 51_200, measuredAt: measured, now: measured.addingTimeInterval(2 * 3_600)),
            "Faster than 51 Mbps · seen during playback 2 hours ago"
        )
    }

    /// Rounded down, so a lower bound or the budget never overstates the
    /// link.
    func testRatesRoundDown() {
        XCTAssertEqual(VM.connectionRateText(kbps: 114_600), "114 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 10_000), "10 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 9_990), "9.9 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 4_000), "4 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 1_050), "1 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 999), "999 kbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 1_000_000), "1000 Mbps", "no digit grouping")
    }

    /// The limit row reads rates the same way as the speed and the budget.
    func testTheLimitRowSaysTheRateAndTheDay() throws {
        let observed = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z"))
        let limit = APIv2PlaybackConnection.LearnedLimit(
            kbps: 44_100, observedAt: observed, expiresAt: observed.addingTimeInterval(7 * 86_400)
        )
        XCTAssertEqual(
            VM.learnedLimitText(limit, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!),
            "Limited to 44 Mbps after buffering on Oct 17"
        )
    }

    func testTryAgainSaysOneSecondAtOne() {
        XCTAssertEqual(VM.tryAgainMessage(seconds: 1), "Try again in 1 second")
        XCTAssertEqual(VM.tryAgainMessage(seconds: 30), "Try again in 30 seconds")
    }

    func testSpeedTestsAreSkippedOnMeteredNetworks() {
        let cellular = BandwidthProbeNetwork(isConnected: true, transport: "cellular", usesCellular: true,
                                             isMetered: true, key: "c")
        let hotspot = BandwidthProbeNetwork(isConnected: true, transport: "wifi", usesCellular: false,
                                            isMetered: true, key: "h")
        let home = BandwidthProbeNetwork(isConnected: true, transport: "wifi", usesCellular: false,
                                         isMetered: false, key: "w")
        XCTAssertEqual(
            VM.connectionSpeedSkippedText(network: cellular, cellularQualityApplies: true),
            "Speed tests are skipped on cellular, and the Cellular Quality settings apply."
        )
        XCTAssertEqual(
            VM.connectionSpeedSkippedText(network: hotspot, cellularQualityApplies: true),
            "Speed tests are skipped on metered networks, and the Cellular Quality settings apply."
        )
        XCTAssertEqual(
            VM.connectionSpeedSkippedText(network: hotspot, cellularQualityApplies: false),
            "Speed tests are skipped on metered networks."
        )
        XCTAssertNil(VM.connectionSpeedSkippedText(network: home, cellularQualityApplies: true))
        XCTAssertNil(VM.connectionSpeedSkippedText(network: .offline, cellularQualityApplies: true))
    }
}
