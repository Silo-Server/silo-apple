import XCTest
@testable import Silo

/// Pins the loopback lifecycle glue Stage 2 wave 2a moved out of
/// `AVPlayerBackend` into `LocalHLSHost` (inventory-3 §4.1–4.5, §4.7): the
/// first-segment playlist URL choice (including the AirPlay branch), the
/// producer-restart guards and their coalescing, the source-keyed VOD plan
/// that has to outlive a session, and a teardown that releases everything.
///
/// No producer is ever started here: `LoopbackSegmentWriter` needs a real
/// FFmpeg input, and every behaviour these tests pin is reachable before the
/// first writer exists.
final class LocalHLSHostTests: XCTestCase {
    // MARK: - Harness

    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for url in scratchDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        scratchDirectories = []
        super.tearDown()
    }

    private func makeSessionDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-dv-hls-debug", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        scratchDirectories.append(url)
        return url
    }

    private func makeSpec(
        sourceURL: URL = URL(string: "https://silo.example/library/item.mkv")!,
        startSeconds: Double = 0
    ) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: [:],
            sourceStartTimeSeconds: startSeconds,
            sourceBitrateBps: nil,
            videoMode: .passthroughH264,
            sourceVideoFrameRate: 24,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 0,
                ffIndex: 1,
                sourceCodec: "eac3",
                sourceChannelCount: 2,
                sourceChannelLayout: "stereo",
                outputMode: .copy,
                preservesAtmos: false
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            )
        )
    }

    private func makePlan(segmentCount: Int = 12) -> LoopbackSegmentPlan {
        LoopbackSegmentPlan(
            boundaries: (0...segmentCount).map { Int64($0) * 4_000 },
            startSeconds: (0...segmentCount).map { Double($0) * 4 },
            anchorSourceSeconds: 0,
            usedKeyframeIndex: true
        )
    }

    private func makeHost(
        spec: LoopbackSessionSpec? = nil,
        sessionDirectory: URL? = nil,
        keepArtifacts: Bool = false,
        carriedVODPlan: LocalHLSHost.ResolvedVODPlan? = nil,
        restartCoalescer: LoopbackRestartCoalescer = LoopbackRestartCoalescer(),
        tap: LoopbackSubtitleTap? = nil
    ) -> LocalHLSHost {
        LocalHLSHost(
            sessionSpec: spec ?? makeSpec(),
            sessionDirectory: sessionDirectory ?? makeSessionDirectory(),
            keepArtifacts: keepArtifacts,
            storeMemoryBudgetBytes: 8 * 1024 * 1024,
            storeSpillPolicy: .disabled(reason: "test"),
            vodRetentionBudgetBytes: 512 * 1024 * 1024,
            serverExposure: .loopbackOnly,
            carriedVODPlan: carriedVODPlan,
            restartCoalescer: restartCoalescer,
            playbackPositionProvider: { nil },
            isSourceOutageActive: { false },
            subtitleTap: { _ in tap }
        )
    }

    // MARK: - Playlist URL choice (handleFirstSegmentReady's first half)

    func testPlaylistURLPrefersTheExternalAddressWhileAirPlayIsActive() throws {
        let external = URL(string: "http://192.168.1.42:8080/token/master.m3u8")!
        let loopback = URL(string: "http://127.0.0.1:8080/token/master.m3u8")!
        var loopbackAsked = false

        let decision = LocalHLSHost.playlistURLDecision(
            isExternalPlaybackActive: true,
            externalURL: { external },
            loopbackURL: {
                loopbackAsked = true
                return loopback
            }
        )

        XCTAssertEqual(decision.url, external)
        XCTAssertTrue(decision.usesExternalURL)
        XCTAssertFalse(decision.abandonsExternalHandoff)
        // The loopback URL is only built when the external one is unusable.
        XCTAssertFalse(loopbackAsked)
    }

    func testPlaylistURLFallsBackToLoopbackAndAbandonsTheHandoffWithNoLANAddress() throws {
        let loopback = URL(string: "http://127.0.0.1:8080/token/master.m3u8")!

        let decision = LocalHLSHost.playlistURLDecision(
            isExternalPlaybackActive: true,
            externalURL: { nil },
            loopbackURL: { loopback }
        )

        // Playback stays on this device rather than failing, and the receiver
        // handoff is abandoned so AVPlayer renders locally again.
        XCTAssertEqual(decision.url, loopback)
        XCTAssertFalse(decision.usesExternalURL)
        XCTAssertTrue(decision.abandonsExternalHandoff)
    }

    func testPlaylistURLUsesLoopbackWithoutAirPlayAndReportsAnUnavailableURL() throws {
        let loopback = URL(string: "http://127.0.0.1:8080/token/master.m3u8")!

        let inactive = LocalHLSHost.playlistURLDecision(
            isExternalPlaybackActive: false,
            externalURL: { XCTFail("must not probe the LAN address without AirPlay"); return nil },
            loopbackURL: { loopback }
        )
        XCTAssertEqual(inactive.url, loopback)
        XCTAssertFalse(inactive.usesExternalURL)
        XCTAssertFalse(inactive.abandonsExternalHandoff)

        let unavailable = LocalHLSHost.playlistURLDecision(
            isExternalPlaybackActive: false,
            externalURL: { nil },
            loopbackURL: { nil }
        )
        XCTAssertNil(unavailable.url)
        XCTAssertFalse(unavailable.abandonsExternalHandoff)
    }

    // MARK: - VOD plan continuity

    func testCarriedVODPlanSeedsTheHostAndIsHandedBackAtTeardown() throws {
        let spec = makeSpec()
        let plan = makePlan()
        let host = makeHost(
            spec: spec,
            carriedVODPlan: LocalHLSHost.ResolvedVODPlan(plan: plan, sourceURL: spec.sourceURL)
        )

        // A reanchored session must reach its first producer already holding
        // the grid the retired one resolved.
        XCTAssertEqual(host.vodPlan?.segmentCount, plan.segmentCount)
        XCTAssertEqual(host.resolvedVODPlan?.sourceURL, spec.sourceURL)

        host.teardown()
        XCTAssertEqual(host.resolvedVODPlan?.plan.segmentCount, plan.segmentCount)
    }

    func testResolvedVODPlanOnlyMatchesItsOwnSource() throws {
        let plan = makePlan()
        let resolved = LocalHLSHost.ResolvedVODPlan(
            plan: plan,
            sourceURL: URL(string: "https://silo.example/library/item.mkv")!
        )

        XCTAssertEqual(
            resolved.matching(URL(string: "https://silo.example/library/item.mkv")!)?.segmentCount,
            plan.segmentCount
        )
        XCTAssertNil(resolved.matching(URL(string: "https://silo.example/library/other.mkv")!))
    }

    // MARK: - Producer restarts

    @MainActor
    func testProducerRestartParksBehindAnInFlightRestart() throws {
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(0), "precondition: a restart is already running")
        let spec = makeSpec()
        let host = makeHost(
            spec: spec,
            carriedVODPlan: LocalHLSHost.ResolvedVODPlan(plan: makePlan(), sourceURL: spec.sourceURL),
            restartCoalescer: coalescer
        )
        host.start()
        defer { host.teardown() }

        host.requestProducerRestart(atSegmentIndex: 5)

        // Parked, not run: no producer was swapped in behind the running one.
        XCTAssertNil(host.segmentWriter)
        XCTAssertTrue(host.restartCoalescer.isInFlight)
    }

    @MainActor
    func testProducerRestartWithoutAPlanForThisSourceIsANoOp() throws {
        let host = makeHost(
            spec: makeSpec(),
            carriedVODPlan: LocalHLSHost.ResolvedVODPlan(
                plan: makePlan(),
                sourceURL: URL(string: "https://silo.example/library/other.mkv")!
            )
        )
        host.start()
        defer { host.teardown() }

        host.requestProducerRestart(atSegmentIndex: 3, authoritative: true)

        XCTAssertNil(host.segmentWriter)
        XCTAssertFalse(host.restartCoalescer.isInFlight)
    }

    @MainActor
    func testProducerRestartAfterTeardownIsANoOp() throws {
        let spec = makeSpec()
        let host = makeHost(
            spec: spec,
            carriedVODPlan: LocalHLSHost.ResolvedVODPlan(plan: makePlan(), sourceURL: spec.sourceURL)
        )
        host.start()
        host.teardown()

        host.requestProducerRestart(atSegmentIndex: 2, authoritative: true)

        XCTAssertNil(host.segmentWriter)
        XCTAssertFalse(host.restartCoalescer.isInFlight)
    }

    // MARK: - Teardown

    func testTeardownReleasesTheStoreServerAndEveryCallback() throws {
        let host = makeHost()
        host.start()
        XCTAssertNotNil(host.segmentStore)
        XCTAssertNotNil(host.segmentServer)

        host.onFirstSegmentReady = { _ in XCTFail("late first segment must land nowhere") }
        host.onSegmentPlanResolved = { _ in XCTFail("late plan must land nowhere") }
        host.onGeneratedMediaStats = { _ in XCTFail("late stats must land nowhere") }
        host.onFinished = { _ in XCTFail("late writer finish must land nowhere") }
        host.onFailure = { _ in XCTFail("late failure must land nowhere") }
        host.canAttachFirstSegment = { XCTFail("gate must not be asked"); return true }

        host.teardown()

        XCTAssertTrue(host.isTornDown)
        XCTAssertNil(host.segmentStore)
        XCTAssertNil(host.segmentServer)
        XCTAssertNil(host.segmentWriter)
        XCTAssertNil(host.onFirstSegmentReady)
        XCTAssertNil(host.onSegmentPlanResolved)
        XCTAssertNil(host.onGeneratedMediaStats)
        XCTAssertNil(host.onFinished)
        XCTAssertNil(host.onFailure)
        XCTAssertNil(host.canAttachFirstSegment)
        XCTAssertNil(host.onBitmapSubtitleTapCue)
    }

    func testTeardownRemovesTheSessionDirectory() throws {
        let directory = makeSessionDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("seg_000000.m4s")
        try Data([0x00, 0x01]).write(to: artifact)

        let host = makeHost(sessionDirectory: directory)
        host.teardown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTeardownKeepsTheSessionDirectoryWhenArtifactsAreRetained() throws {
        let directory = makeSessionDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("seg_000000.m4s")
        try Data([0x00, 0x01]).write(to: artifact)

        // SILO_KEEP_DV_HLS is read once, at construction (design §7.2).
        let host = makeHost(sessionDirectory: directory, keepArtifacts: true)
        host.teardown()

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
    }
}
