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
            case let other: return XCTFail("\(name): mode \(String(describing: other))")
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

    func testEachModeAsksForItsOwnSize() throws {
        XCTAssertEqual(BandwidthProbeMeter(mode: .quick(targetKbps: nil)).requestedBytes, 100_000_000)
        XCTAssertEqual(BandwidthProbeMeter(mode: .accurate).requestedBytes, 1_000_000_000)
        let server = try XCTUnwrap(URL(string: "https://silo.example"))
        XCTAssertEqual(
            BandwidthProbe.downloadURL(
                serverURL: server,
                advertised: "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true",
                bytes: 100_000_000
            )?.absoluteString,
            "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true&size=100000000"
        )
        XCTAssertEqual(
            BandwidthProbe.downloadURL(
                serverURL: try XCTUnwrap(URL(string: "https://silo.example:8096")),
                advertised: "/api/v2/playback/bandwidth-probe?size=5",
                bytes: 1_000_000_000
            )?.absoluteString,
            "https://silo.example:8096/api/v2/playback/bandwidth-probe?size=1000000000"
        )
        XCTAssertNil(BandwidthProbe.downloadURL(serverURL: server, advertised: "ftp://silo.example/probe", bytes: 1))
    }
}

/// The timed download over a stubbed transport: its answers to the server's
/// refusals, and the redirect to a proxy.
final class BandwidthProbeDownloadTests: XCTestCase {
    private let probeURL = URL(string: "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true&size=40000000")!

    override func tearDown() {
        StubProbeProtocol.reset()
        super.tearDown()
    }

    private func download() -> BandwidthProbeDownload {
        let configuration = BandwidthProbeDownload.defaultConfiguration()
        configuration.protocolClasses = [StubProbeProtocol.self]
        return BandwidthProbeDownload(mode: .quick(targetKbps: 115_000), configuration: configuration)
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: probeURL)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("p-1", forHTTPHeaderField: "X-Profile-Id")
        request.setValue("device-1", forHTTPHeaderField: "X-Silo-Device-Id")
        return request
    }

    func testARateLimitIsTypedWithItsRetryAfter() async throws {
        StubProbeProtocol.respond { _ in .init(status: 429, headers: ["Retry-After": "42"]) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .rateLimited(retryAfterSeconds: 42))
    }

    func testARefusalIsUnavailableAndNeverAnotherPath() async throws {
        StubProbeProtocol.respond { _ in .init(status: 503) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .unavailable(status: 503))
        XCTAssertEqual(StubProbeProtocol.requests.map(\.url), [probeURL])
    }

    func testAShortBodyIsTooLittleData() async throws {
        StubProbeProtocol.respond { _ in .init(status: 200, body: Data(count: 1_024)) }
        let result = try await download().measure(request())
        XCTAssertEqual(result, .tooLittleData)
    }

    /// The proxy's URL carries its own short-lived token; the account's
    /// credentials stay with the API.
    func testTheRedirectToTheProxyDropsTheCredentials() async throws {
        let proxy = URL(string: "https://proxy.example/stream/bandwidth-probe/token?size=40000000")!
        StubProbeProtocol.respond { request in
            request.url == proxy ? .init(status: 200, body: Data(count: 1_024)) : .init(status: 307, redirect: proxy)
        }
        _ = try await download().measure(request())
        let proxied = try XCTUnwrap(StubProbeProtocol.requests.last)
        XCTAssertEqual(proxied.url, proxy)
        XCTAssertNil(proxied.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(proxied.value(forHTTPHeaderField: "X-Profile-Id"))
        XCTAssertEqual(proxied.value(forHTTPHeaderField: "X-Silo-Device-Id"), "device-1")
    }

    /// Failures are logged publicly, so they never carry the host.
    func testAFailureIsDescribedWithoutItsHost() {
        let error = URLError(.serverCertificateUntrusted, userInfo: [
            NSLocalizedDescriptionKey: "The certificate for this server is invalid. You might be connecting to a server that is pretending to be “silo.example”.",
            NSURLErrorFailingURLErrorKey: probeURL,
        ])
        XCTAssertEqual(BandwidthProbeDownload.describe(error), "NSURLErrorDomain -1202")
    }

    func testCancellingTheCallerCancelsTheProbe() async throws {
        StubProbeProtocol.respond { _ in .init(status: 200, hangs: true) }
        let probe = download()
        let task = Task { try await probe.measure(request()) }
        while StubProbeProtocol.requests.isEmpty { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled probe has no result")
        } catch is CancellationError {}
    }
}

/// Serves canned probe answers to the download's session.
final class StubProbeProtocol: URLProtocol {
    struct Answer {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        var redirect: URL?
        /// Sends the headers, then nothing.
        var hangs = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: ((URLRequest) -> Answer)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { seen } }

    static func respond(_ answer: @escaping (URLRequest) -> Answer) {
        lock.withLock { self.answer = answer }
    }

    static func reset() {
        lock.withLock {
            answer = nil
            seen = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.lock.withLock { () -> Answer? in
            Self.seen.append(request)
            return Self.answer?(request)
        } ?? Answer(status: 500)
        let url = request.url!
        var headers = answer.headers
        if let redirect = answer.redirect { headers["Location"] = redirect.absoluteString }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let redirect = answer.redirect {
            var next = request
            next.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !answer.hangs else { return }
        if !answer.body.isEmpty { client?.urlProtocol(self, didLoad: answer.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    func testAPlaybackSampleIsALowerBound() async {
        server.stored.playbackSample = sample(kbps: 120_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(server.modes, [], "above the target, it proves the link")
        XCTAssertEqual(scheduler.freshEstimateKbps(), 120_000)

        let slow = FakeProbeServer()
        slow.stored.playbackSample = sample(kbps: 51_200, ageDays: 1)
        let other = BandwidthProbeScheduler(server: slow, clock: clock)
        other.networkChanged(Self.wifi)
        other.setActiveServer("server")
        await advance(seconds: 5)
        XCTAssertEqual(slow.modes, [.quick(targetKbps: 115_000)], "below the target, it does not")
    }

    func testAStartSendsTheHighestCurrentReading() async {
        server.result = .measured(kbps: 48_000, bytes: 6_000_000, durationMs: 1_000, lowerBound: false)
        server.stored.playbackSample = sample(kbps: 60_000, ageDays: 1)
        server.stored.probe = probe(kbps: 30_000, ageDays: 1)
        await signIn()
        XCTAssertEqual(server.modes, [], "the settled probe proves the link")
        XCTAssertEqual(scheduler.freshEstimateKbps(), 60_000)
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
        XCTAssertEqual(outcome, .measured(BandwidthMeasurement(
            kbps: 115_000, lowerBound: true, bytes: 7_187_500, durationMs: 500, transport: "wifi", measuredAt: clock.now
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

    func testARateLimitHoldsLooksUntilItsRetryAfter() async {
        server.result = .rateLimited(retryAfterSeconds: 600)
        await signIn()
        server.result = .measured(kbps: 48_000, bytes: 6_000_000, durationMs: 1_000, lowerBound: false)
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
        for _ in 0..<200 where scheduler.isProbing { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(scheduler.isProbing)
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
        for _ in 0..<200 where scheduler.isProbing { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(scheduler.isProbing)
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
        scheduler.setActiveServer("other")
        XCTAssertNil(scheduler.freshEstimateKbps(), "it belonged to the other server")
        await advance(seconds: 0)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 300_000)
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
/// the real one, it keeps the latest result it is sent.
@MainActor
private final class FakeProbeServer: BandwidthProbeServer {
    var result: BandwidthProbeResult = .measured(kbps: 115_000, bytes: 7_187_500, durationMs: 500, lowerBound: true)
    /// The download never ends until cancelled.
    var hangs = false
    var hasTarget = true
    var targetKbps: Int? = 115_000
    var automatic = true
    var maxAge: TimeInterval = 7 * 24 * 60 * 60
    var stored = BandwidthStoredReadings.none
    private(set) var storedCount = 0
    private(set) var targetCount = 0
    private(set) var modes: [BandwidthProbeMeter.Mode] = []
    private(set) var reports: [BandwidthMeasurement] = []

    func target() async throws -> BandwidthProbeTarget? {
        targetCount += 1
        guard hasTarget else { return nil }
        return BandwidthProbeTarget(
            url: URL(string: "https://silo.example/api/v2/playback/bandwidth-probe")!,
            targetKbps: targetKbps,
            automatic: automatic,
            maxAge: maxAge,
            auth: CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: "server", serverURL: "https://silo.example",
                                                credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: "server"),
                accessToken: "token", profileId: "p-1", profileToken: nil
            )
        )
    }

    func storedReadings() async throws -> BandwidthStoredReadings {
        storedCount += 1
        return stored
    }

    func measure(_ target: BandwidthProbeTarget, mode: BandwidthProbeMeter.Mode) async throws -> BandwidthProbeResult {
        modes.append(mode)
        if hangs { try await Task.sleep(for: .seconds(3_600)) }
        return result
    }

    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> Bool {
        reports.append(measurement)
        stored.probe = measurement.reading
        return true
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

    func testRatesReadInWholeMegabits() {
        XCTAssertEqual(VM.connectionRateText(kbps: 35_280), "35 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 35_500), "36 Mbps")
        XCTAssertEqual(VM.connectionRateText(kbps: 499), "499 kbps")
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
