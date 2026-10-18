import XCTest
@testable import Silo

/// The web probe's windowing, ported: `web/src/player/bandwidth-probe.ts` in
/// the server repo. Android's `BandwidthProbeTest` checks the same cases.
final class BandwidthProbeWindowTests: XCTestCase {
    func testASteadyTransferIsTimedAfterTheWarmupFromTheFirstByte() {
        var window = BandwidthProbeWindow()
        // The first chunk opens the window at 1000; its bytes arrived before it.
        XCTAssertFalse(window.onChunk(at: 1_000, size: 5_000_000))
        var done = false
        var at = 1_000
        while !done {
            at += 100
            done = window.onChunk(at: at, size: 1_000_000)
        }
        XCTAssertEqual(at, 3_000, "the budget ends the window 2 s after the first byte")
        // Warm at 1300 with 3 MB; 17 MB in the 1700 ms that followed.
        XCTAssertEqual(window.result(), .measured(kbps: 80_000, bytes: 17_000_000, durationMs: 1_700))
    }

    func testTheWholeWindowIsUsedWhenLessTimeFollowedTheWarmup() {
        var window = BandwidthProbeWindow()
        _ = window.onChunk(at: 0, size: 1)
        _ = window.onChunk(at: 300, size: 600_000) // warm at 300
        _ = window.onChunk(at: 500, size: 400_000) // only 200 ms followed the warmup
        XCTAssertEqual(window.result(), .measured(kbps: 16_000, bytes: 1_000_000, durationMs: 500))
    }

    func testAShortWindowNeedsAMegabyte() {
        var short = BandwidthProbeWindow()
        _ = short.onChunk(at: 0, size: 1)
        _ = short.onChunk(at: 150, size: 999_999)
        XCTAssertEqual(short.result(), .tooLittleData)

        var enough = BandwidthProbeWindow()
        _ = enough.onChunk(at: 0, size: 1)
        _ = enough.onChunk(at: 150, size: 1_000_000)
        XCTAssertEqual(enough.result(), .measured(kbps: 53_333, bytes: 1_000_000, durationMs: 150))
    }

    func testOnlyTheFirstChunkIsNoMeasurement() {
        XCTAssertEqual(BandwidthProbeWindow().result(), .tooLittleData)
        var window = BandwidthProbeWindow()
        _ = window.onChunk(at: 0, size: 40_000_000)
        XCTAssertEqual(window.result(), .tooLittleData)
    }

    func testAStalledTransferIsCutOffAndItsSilenceCountsAgainstTheRate() {
        var window = BandwidthProbeWindow()
        // First byte at 100, then 1 MB every 100 ms until 1000, then nothing.
        _ = window.onChunk(at: 100, size: 1)
        for at in stride(from: 200, through: 1_000, by: 100) {
            XCTAssertFalse(window.onChunk(at: at, size: 1_000_000))
        }
        window.cutOff(at: 2_600)
        // Warm at 400 with 3 MB; 6 MB in the 2200 ms after.
        XCTAssertEqual(window.result(), .measured(kbps: 21_818, bytes: 6_000_000, durationMs: 2_200))
    }

    func testRatesAreClampedToTheContractsRange() {
        var slow = BandwidthProbeWindow()
        _ = slow.onChunk(at: 0, size: 1)
        _ = slow.onChunk(at: 2_000, size: 10_000)
        XCTAssertEqual(slow.result(), .tooLittleData, "40 kbps is below the floor")
        XCTAssertEqual(BandwidthProbe.clampKbps(5_000_000), 1_000_000)
        XCTAssertEqual(BandwidthProbe.clampKbps(100), 100)
        XCTAssertNil(BandwidthProbe.clampKbps(99.9))
        XCTAssertNil(BandwidthProbe.clampKbps(.nan))
    }

    func testTheDownloadURLAsksForFortyMegabytes() throws {
        let server = try XCTUnwrap(URL(string: "https://silo.example"))
        XCTAssertEqual(
            BandwidthProbe.downloadURL(
                serverURL: server,
                advertised: "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true"
            )?.absoluteString,
            "https://silo.example/api/v2/playback/bandwidth-probe?media_path=true&size=40000000"
        )
        XCTAssertEqual(
            BandwidthProbe.downloadURL(
                serverURL: try XCTUnwrap(URL(string: "https://silo.example:8096")),
                advertised: "/api/v2/playback/bandwidth-probe"
            )?.absoluteString,
            "https://silo.example:8096/api/v2/playback/bandwidth-probe?size=40000000"
        )
        XCTAssertNil(BandwidthProbe.downloadURL(serverURL: server, advertised: "ftp://silo.example/probe"))
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
        return BandwidthProbeDownload(configuration: configuration)
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
        // Let a probe the timer started run on the main actor.
        for _ in 0..<50 { await Task.yield() }
    }

    func testProbesAfterTheStartDelayAndKeepsTheEstimateForThatNetwork() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 4.9)
        XCTAssertEqual(server.measureCount, 0, "the first screen settles first")
        await advance(seconds: 0.1)
        XCTAssertEqual(server.measureCount, 1)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 48_000)
        XCTAssertEqual(server.reports.map(\.transport), ["wifi"])
        XCTAssertEqual(scheduler.lastMeasurement?.kbps, 48_000)

        scheduler.networkChanged(Self.otherWifi)
        XCTAssertNil(scheduler.freshEstimateKbps(), "another network discards it")
        XCTAssertNil(scheduler.lastMeasurement)
    }

    func testTheEstimateLastsThirtyMinutesThenTheProbeRunsAgain() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        await advance(seconds: 30 * 60)
        XCTAssertEqual(scheduler.freshEstimateKbps(), 48_000, "still fresh at the 30-minute mark")
        XCTAssertEqual(server.measureCount, 1)
        await advance(seconds: 1)
        XCTAssertEqual(server.measureCount, 2, "re-taken a second after it expires")
    }

    func testAMeteredNetworkIsNeitherProbedNorSent() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        scheduler.networkChanged(Self.cellular)
        XCTAssertNil(scheduler.freshEstimateKbps())
        await advance(seconds: 10 * 60)
        XCTAssertEqual(server.measureCount, 1, "no probe on cellular")
        let outcome = await scheduler.runNow()
        XCTAssertEqual(outcome, .metered)
    }

    func testPlaybackStartingStopsARunningProbeAndHoldsOffForAMinute() async {
        server.hangs = true
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        XCTAssertTrue(scheduler.isProbing)

        scheduler.playbackStarting()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(scheduler.isProbing)
        XCTAssertNil(scheduler.freshEstimateKbps())

        server.hangs = false
        await advance(seconds: 30)
        let tooSoon = await scheduler.runNow()
        XCTAssertEqual(tooSoon, .playbackActive, "the media is still loading")
        await advance(seconds: 31)
        let later = await scheduler.runNow()
        XCTAssertEqual(later, .measured(BandwidthMeasurement(
            kbps: 48_000, bytes: 12_000_000, durationMs: 2_000, transport: "wifi", measuredAt: clock.now
        )))
    }

    func testMediaThatIsPlayingKeepsTheProbeOff() async {
        var playing = true
        scheduler.isMediaActive = { playing }
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        XCTAssertEqual(server.measureCount, 0)
        playing = false
        await advance(seconds: 5 * 60)
        XCTAssertEqual(server.measureCount, 1, "looked again after the retry interval")
    }

    func testARateLimitWaitsForItsRetryAfter() async {
        server.result = .rateLimited(retryAfterSeconds: 600)
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 5)
        server.result = .measured(kbps: 48_000, bytes: 12_000_000, durationMs: 2_000)
        await advance(seconds: 5 * 60)
        XCTAssertEqual(server.measureCount, 1, "the retry interval is shorter than Retry-After")
        await advance(seconds: 5 * 60)
        XCTAssertEqual(server.measureCount, 2)
    }

    func testAServerWithoutAProbeIsLeftAlone() async {
        server.hasTarget = false
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        await advance(seconds: 60 * 60)
        XCTAssertEqual(server.targetCount, 1)
        XCTAssertEqual(server.measureCount, 0)
    }

    func testSigningOutAndBackgroundingStopTheSchedule() async {
        scheduler.networkChanged(Self.wifi)
        scheduler.setActiveServer("server")
        scheduler.setForeground(false)
        await advance(seconds: 60)
        XCTAssertEqual(server.measureCount, 0)
        scheduler.setForeground(true)
        await advance(seconds: 5)
        XCTAssertEqual(server.measureCount, 1)
        scheduler.setActiveServer(nil)
        XCTAssertNil(scheduler.freshEstimateKbps(), "the estimate belonged to that server")
    }
}

/// A probe server whose answers the test sets. Main-actor isolated, so a
/// probe runs entirely on the main actor and a few yields let it finish.
@MainActor
private final class FakeProbeServer: BandwidthProbeServer {
    var result: BandwidthProbeResult = .measured(kbps: 48_000, bytes: 12_000_000, durationMs: 2_000)
    /// The download never ends until cancelled.
    var hangs = false
    var hasTarget = true
    private(set) var targetCount = 0
    private(set) var measureCount = 0
    private(set) var reports: [BandwidthMeasurement] = []

    func target() async throws -> BandwidthProbeTarget? {
        targetCount += 1
        guard hasTarget else { return nil }
        return BandwidthProbeTarget(
            url: URL(string: "https://silo.example/api/v2/playback/bandwidth-probe?size=40000000")!,
            auth: CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: "server", serverURL: "https://silo.example",
                                                credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: "server"),
                accessToken: "token", profileId: "p-1", profileToken: nil
            )
        )
    }

    func measure(_ target: BandwidthProbeTarget) async throws -> BandwidthProbeResult {
        measureCount += 1
        if hangs { try await Task.sleep(for: .seconds(3_600)) }
        return result
    }

    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> Bool {
        reports.append(measurement)
        return true
    }
}
