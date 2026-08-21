import XCTest
@testable import Silo

/// Pins the loopback lifecycle glue Stage 2 wave 2a moved out of
/// `AVPlayerBackend` into `LocalHLSHost` (inventory-3 §4.1–4.5, §4.7): the
/// first-segment playlist URL choice (including the AirPlay branch), the
/// producer-restart guards and their coalescing, the source-keyed VOD plan
/// that has to outlive a session, and a teardown that releases everything.
///
/// No producer is ever started here: `LoopbackSegmentWriter` needs a real
/// FFmpeg input. The producer-generation cases do construct writers — the
/// host installs its callbacks on them and the test fires those callbacks
/// exactly as a live mux thread would — but none of them is ever `start()`ed.
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

    /// A writer the host can adopt. Never started: its callbacks are what
    /// these tests drive, and starting it would need a real FFmpeg input.
    private func makeWriter(
        spec: LoopbackSessionSpec,
        vodBaseIndex: Int
    ) -> LoopbackSegmentWriter {
        LoopbackSegmentWriter(
            sessionSpec: spec,
            outputDirectory: makeSessionDirectory(),
            segmentStore: LoopbackSegmentStore(
                generation: 1,
                spillPolicy: .disabled(reason: "test")
            ),
            vodBaseIndex: vodBaseIndex
        )
    }

    /// The host's writer callbacks hop to main before they touch its state.
    /// `wait` spins the run loop, and the main queue is FIFO, so everything
    /// enqueued before this block has run by the time it returns.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private struct RetiredProducerError: Error {}

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

    // MARK: - Producer coverage (requestProducerRestart's ride-the-march guard)

    /// The one piece of arithmetic in this class that has regressed on device
    /// twice. `requestProducerRestart` can't be driven into it from a test
    /// (it needs a running producer), so the predicate itself is pinned.
    func testCoverageRequiresTheTargetAtOrAheadOfTheProducerBase() {
        // Behind the base: the running producer will never reach it.
        XCTAssertFalse(
            LocalHLSHost.coversTarget(
                target: 4, base: 5, head: 9, coverageWindow: 8, marchAllowance: 2
            )
        )
        // The base itself is covered even before the first segment lands
        // (head nil ⇒ base - 1, and base <= base - 1 + 2).
        XCTAssertTrue(
            LocalHLSHost.coversTarget(
                target: 5, base: 5, head: nil, coverageWindow: 8, marchAllowance: 2
            )
        )
    }

    func testCoverageStopsAtTheWindowEdge() {
        XCTAssertTrue(
            LocalHLSHost.coversTarget(
                target: 13, base: 5, head: 12, coverageWindow: 8, marchAllowance: 2
            ),
            "base + window is still covered"
        )
        XCTAssertFalse(
            LocalHLSHost.coversTarget(
                target: 14, base: 5, head: 13, coverageWindow: 8, marchAllowance: 2
            ),
            "one past the window needs a restart however close the head is"
        )
    }

    func testCoverageRequiresTheTargetNearTheProducedHead() {
        // Inside the coverage window but three heavy segments past the
        // produced head: waiting for the march would burn the miss deadline
        // and 404 (living-room frozen-video seeks), so this must restart.
        XCTAssertFalse(
            LocalHLSHost.coversTarget(
                target: 10, base: 2, head: 7, coverageWindow: 8, marchAllowance: 2
            )
        )
        XCTAssertTrue(
            LocalHLSHost.coversTarget(
                target: 9, base: 2, head: 7, coverageWindow: 8, marchAllowance: 2
            ),
            "head + marchAllowance is the last index the march delivers in time"
        )
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

        // Parked, not run: no producer was swapped in behind the running one
        // (a started writer always publishes its base index).
        XCTAssertNil(host.activeVODWriterBaseIndex)
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

        XCTAssertNil(host.activeVODWriterBaseIndex)
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

        XCTAssertNil(host.activeVODWriterBaseIndex)
        XCTAssertFalse(host.restartCoalescer.isInFlight)
    }

    // MARK: - Producer generation

    /// `requestProducerRestart` stops the retiring writer by flag and never
    /// joins its mux thread, so that thread keeps firing at the host after
    /// its successor is already producing. None of those events may be
    /// observed: they would drag the store's consumer window back to the
    /// retired base, overwrite the successor's coverage bookkeeping or its
    /// plan, or fail the successor's session with the error the retiring
    /// writer's own cancellation produced.
    @MainActor
    func testRetiredProducerCallbacksAreIgnoredAndTheLiveOnesApply() throws {
        let spec = makeSpec()
        let host = makeHost(spec: spec)
        defer { host.teardown() }

        let retiring = makeWriter(spec: spec, vodBaseIndex: 0)
        host.adoptProducer(retiring, spec: spec, vodBaseIndex: 0)
        let live = makeWriter(spec: spec, vodBaseIndex: 6)
        host.adoptProducer(live, spec: spec, vodBaseIndex: 6)

        // Adopting the successor is what publishes its base; the head sits
        // one behind until it finalizes a segment.
        XCTAssertEqual(host.activeVODWriterBaseIndex, 6)
        XCTAssertEqual(host.activeVODWriterHeadIndex, 5)

        var publishedPlans: [Int] = []
        host.onSegmentPlanResolved = { publishedPlans.append($0.segmentCount) }
        var finishes: [String] = []
        host.onFinished = { finishes.append($0.map { String(describing: $0) } ?? "eof") }
        var bitmapTracks: [[Int]] = []
        host.onBitmapSubtitleTapTracks = { bitmapTracks.append($0) }

        // The live producer's events are the ones that count...
        live.onVODProducerAnchored?(7)
        live.onSegmentAppended?(9, 36)
        live.onSegmentPlanResolved?(makePlan(segmentCount: 12))
        live.onBitmapSubtitleTapTracks?([2])
        live.onFinished?(nil)
        // ...and then the retired producer's mux thread catches up.
        retiring.onVODProducerAnchored?(0)
        retiring.onSegmentAppended?(99, 400)
        retiring.onSegmentPlanResolved?(makePlan(segmentCount: 3))
        retiring.onBitmapSubtitleTapTracks?([5])
        retiring.onFinished?(RetiredProducerError())
        drainMainQueue()

        XCTAssertEqual(host.activeVODWriterBaseIndex, 7)
        XCTAssertEqual(host.activeVODWriterHeadIndex, 9)
        XCTAssertEqual(host.resolvedVODPlan?.plan.segmentCount, 12)
        XCTAssertEqual(host.resolvedVODPlan?.sourceURL, spec.sourceURL)
        XCTAssertEqual(publishedPlans, [12])
        XCTAssertEqual(finishes, ["eof"], "a retired producer must not fail the live session")
        XCTAssertEqual(bitmapTracks, [[2]])
    }

    /// The bitmap cue tap fires on the mux thread and never hops, so its tag
    /// is checked there — the same check that keeps a retired producer's
    /// anchor from re-seeding the store's consumer window.
    @MainActor
    func testRetiredProducerBitmapCuesAreIgnoredOnTheMuxThread() throws {
        let spec = makeSpec()
        let host = makeHost(spec: spec)
        defer { host.teardown() }

        let retiring = makeWriter(spec: spec, vodBaseIndex: 0)
        host.adoptProducer(retiring, spec: spec, vodBaseIndex: 0)
        let live = makeWriter(spec: spec, vodBaseIndex: 6)
        host.adoptProducer(live, spec: spec, vodBaseIndex: 6)

        var fedStreams: [Int] = []
        host.onBitmapSubtitleTapCue = { streamIndex, _, _ in fedStreams.append(streamIndex) }

        live.onBitmapSubtitleTapCue?(2, [], nil)
        retiring.onBitmapSubtitleTapCue?(5, [], 12)

        XCTAssertEqual(fedStreams, [2])
    }

    // MARK: - The narrow operations the adapter reaches for

    /// The selection the adapter used to push straight at the writer is the
    /// host's now, so the running producer and every producer a restart
    /// builds after it decode the same stream.
    func testBitmapSubtitleStreamSelectionIsHeldForEveryWriter() throws {
        let host = makeHost()
        XCTAssertNil(host.selectedBitmapSubtitleStream)

        host.selectBitmapSubtitleStream(3)
        XCTAssertEqual(host.selectedBitmapSubtitleStream, 3)

        host.selectBitmapSubtitleStream(nil)
        XCTAssertNil(host.selectedBitmapSubtitleStream)
    }

    /// Each reader in the adapter falls back to a neutral value (0 requests,
    /// infinite time since a serve, the unredacted line). The host has to
    /// answer "nothing" without a session rather than invent one.
    func testNarrowOperationsReportNothingWithoutARunningSession() throws {
        let host = makeHost()

        XCTAssertNil(host.storeStats())
        XCTAssertNil(host.secondsSinceLastSegmentServe())
        XCTAssertNil(host.servedRequestCount)
        XCTAssertNil(
            host.resourceURL(
                forPublishedResource: "master.m3u8",
                reachableFromExternalDevice: false
            )
        )
        XCTAssertEqual(host.redactLog("token/master.m3u8"), "token/master.m3u8")
        // No listener to open; the AirPlay swap must not trap on a session
        // that never bound one.
        host.setAcceptsExternalClients(true)
    }

    // MARK: - Teardown

    func testTeardownReleasesTheStoreServerAndEveryCallback() throws {
        let host = makeHost()
        host.start()
        // The store and the server are reachable only through the narrow
        // operations the backend uses; both answer while the session runs.
        XCTAssertNotNil(host.storeStats())
        XCTAssertNotNil(host.servedRequestCount)

        host.onFirstSegmentReady = { _ in XCTFail("late first segment must land nowhere") }
        host.onSegmentPlanResolved = { _ in XCTFail("late plan must land nowhere") }
        host.onGeneratedMediaStats = { _ in XCTFail("late stats must land nowhere") }
        host.onFinished = { _ in XCTFail("late writer finish must land nowhere") }
        host.onFailure = { _ in XCTFail("late failure must land nowhere") }
        host.canAttachFirstSegment = { XCTFail("gate must not be asked"); return true }

        host.teardown()

        XCTAssertTrue(host.isTornDown)
        XCTAssertNil(host.storeStats())
        XCTAssertNil(host.servedRequestCount)
        XCTAssertNil(host.secondsSinceLastSegmentServe())
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
