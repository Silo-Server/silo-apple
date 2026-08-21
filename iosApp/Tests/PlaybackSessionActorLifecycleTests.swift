import Foundation
import XCTest
@testable import Silo

/// The control plane's re-entrancy rules, driven through a shell whose calls
/// the test can hold open.
///
/// `PlaybackSessionActorTests` drives the actor with `shell: nil`, so every
/// main-actor arm is a no-op and no effect batch can be *parked* mid-flight.
/// That is exactly the shape of the defect these tests pin: `send` commits the
/// reduced state and then awaits its effects, an actor is re-entrant at every
/// `await`, and `beginLoad` orders three suspending effects (the outage
/// ride-through cancel, the loading publish, the outgoing engine dispose)
/// *before* `.startSession`. A second load accepted while the first batch is
/// parked used to be overwritten by it: the parked batch published its stale
/// surface, then cancelled the newer load's fresh-load task and installed its
/// own — whose answer the reducer then refused, leaving the player in
/// `.preparing` behind the loading overlay with nothing left to finish it.
///
/// The fake shell is deliberately local to this file: it is a controllable
/// stand-in, not shared fixture, and every other suite that needs the control
/// plane wants the `shell: nil` one.
@MainActor
final class PlaybackSessionActorLifecycleTests: XCTestCase {

    // MARK: - Effect-batch epoch

    /// The interleave the review found: load A parks in the loading publish,
    /// load B commits and starts, then A resumes.
    func testASupersededLoadBatchStopsInsteadOfClobberingTheNewerLoad() async throws {
        let (actor, shell, _) = try makeActor()
        // Nothing may still be parked when the test ends: a checked
        // continuation that is never resumed is a runtime error.
        defer { shell.releaseAll() }

        shell.hold(.applyPresentation)
        // B's session prepare parks so the test can prove B's task is still
        // alive *after* A resumes — cancelling a task does not resume a
        // continuation, so a clobbered B would simply never come back.
        shell.hold(.prepareFreshSession)

        async let loadA: Void = actor.send(
            .load(
                ControlPlaneFixtures.makeRequest(contentId: "A"),
                origin: .userInitiated,
                options: LoadOptions()
            )
        )
        await expectEntry(shell, to: .applyPresentation)
        let loadAID = try unwrap(await actor.currentState().loadID)

        // The second load runs to completion while A is parked.
        await actor.send(
            .load(
                ControlPlaneFixtures.makeRequest(contentId: "B"),
                origin: .userInitiated,
                options: LoadOptions()
            )
        )
        let loadBID = try unwrap(await actor.currentState().loadID)
        XCTAssertNotEqual(loadAID, loadBID)
        await expectEntry(shell, to: .prepareFreshSession)

        shell.release(.applyPresentation)
        await loadA

        // `recordedEffects` is written the moment an effect is executed, so it
        // answers this synchronously — `.startSession` spawns a task, and the
        // shell would only learn about it a hop later.
        let ran = await actor.recordedEffects
        XCTAssertFalse(
            ran.contains { effect in
                if case .startSession(_, _, let id) = effect { return id == loadAID }
                return false
            },
            "the superseded batch must not reach `.startSession` — that is the call that cancelled B's task"
        )
        XCTAssertEqual(
            shell.torndownLoadIDs,
            [loadAID],
            "and it must not run its own engine dispose either; only B's teardown of A ran"
        )
        XCTAssertEqual(
            shell.presentations.count,
            2,
            "A published once (that is where it parked) and nothing after it resumed"
        )
        let settled = await actor.currentState().loadID
        XCTAssertEqual(settled, loadBID)

        // B was never cancelled: releasing its prepare drives the reducer on.
        shell.release(.prepareFreshSession)
        await expectEntry(
            shell,
            to: .installEngine,
            "B's fresh-load task was cancelled by the batch that had already been superseded"
        )
        XCTAssertEqual(shell.installedLoadIDs, [loadBID])
    }

    /// The same interleave, carried to the end: the state the superseded batch
    /// used to strand in `.preparing` reaches `.playing` under the newer load.
    func testTheSupersededInterleaveStillReachesPlaying() async throws {
        let (actor, shell, _) = try makeActor()
        // Nothing may still be parked when the test ends: a checked
        // continuation that is never resumed is a runtime error.
        defer { shell.releaseAll() }

        shell.hold(.applyPresentation)
        // B's prepare parks across A's resume, so a stale `.startSession` would
        // cancel the very task the rest of this test depends on.
        shell.hold(.prepareFreshSession)
        async let loadA: Void = actor.send(
            .load(
                ControlPlaneFixtures.makeRequest(contentId: "A"),
                origin: .userInitiated,
                options: LoadOptions()
            )
        )
        await expectEntry(shell, to: .applyPresentation)

        await actor.send(
            .load(
                ControlPlaneFixtures.makeRequest(contentId: "B"),
                origin: .userInitiated,
                options: LoadOptions()
            )
        )
        let loadBID = try unwrap(await actor.currentState().loadID)
        await expectEntry(shell, to: .prepareFreshSession)
        shell.release(.applyPresentation)
        await loadA

        shell.release(.prepareFreshSession)
        await expectEntry(
            shell,
            to: .installEngine,
            "the superseded batch stranded the newer load: its session never resolved"
        )
        await actor.ingestEngineEvent(.fileLoaded(reason: "test"), loadID: loadBID)
        guard case .playing(let playing) = await actor.currentState() else {
            return XCTFail("expected the newer load to reach .playing")
        }
        XCTAssertEqual(playing.loadID, loadBID)
    }

    /// Dismiss is a transition like any other: a load parked behind it stops
    /// where it is rather than starting a session the player no longer has.
    func testDismissWhileALoadIsParkedNeverStartsThatLoadsSession() async throws {
        let (actor, shell, _) = try makeActor()
        // Nothing may still be parked when the test ends: a checked
        // continuation that is never resumed is a runtime error.
        defer { shell.releaseAll() }

        shell.hold(.applyPresentation)
        async let loadA: Void = actor.send(
            .load(
                ControlPlaneFixtures.makeRequest(contentId: "A"),
                origin: .userInitiated,
                options: LoadOptions()
            )
        )
        await expectEntry(shell, to: .applyPresentation)
        let loadAID = try unwrap(await actor.currentState().loadID)

        await actor.send(.dismiss)
        shell.release(.applyPresentation)
        await loadA

        let disposed = await actor.currentState()
        XCTAssertEqual(disposed, .disposed)
        let ran = await actor.recordedEffects
        XCTAssertFalse(
            ran.contains { effect in
                if case .startSession = effect { return true }
                return false
            },
            "a dismissed player must not mint a session for the load it was preparing"
        )
        XCTAssertTrue(shell.startedContentIds.isEmpty)
        XCTAssertEqual(shell.torndownLoadIDs, [loadAID], "dismiss disposed the load it found")
    }

    // MARK: - Outgoing progress

    /// The load prologue's report is about the session it is *leaving*, so it
    /// has to run even though the transition that emitted it has already bound
    /// the state to the replacement load. Before this it was compared with
    /// `state.identity` — `nil` on a fresh `.preparing` — and dropped, which
    /// cost every next-episode, retry and tvOS resume the last heartbeat's
    /// worth of resume position.
    func testTheOutgoingSessionsProgressReportIsExecuted() async throws {
        let (actor, shell, _) = try makeActor()
        // Nothing may still be parked when the test ends: a checked
        // continuation that is never resumed is a runtime error.
        defer { shell.releaseAll() }
        _ = try await startPlaying(actor, shell)
        shell.resetCounters()

        await actor.send(
            .load(
                ControlPlaneFixtures.makeRequest(contentId: "next-episode"),
                origin: .autoplay,
                options: LoadOptions(progressPosition: 612)
            )
        )

        XCTAssertEqual(
            shell.offlineProgressChecks,
            1,
            "`.reportProgress` reached the shell instead of being filtered out against the new state"
        )
    }

    /// The visible renewal's force-overwrite write is content-scoped and about
    /// the load being left behind, so comparing its `LoadID` with the state the
    /// same transition had already moved on could only ever refuse it.
    func testTheVisibleRenewalsForcedProgressWriteReachesTheServer() async throws {
        let (actor, shell, transport) = try makeActor()
        defer { shell.releaseAll() }
        let loadID = try await startPlaying(actor, shell)
        await actor.ingest(.engine(.time(seconds: 640), loadID))

        await actor.ingest(.recovery(.renewSessionFresh(reason: "progress"), loadID))

        let writes = await transport.recordedCalls().compactMap { call -> (String, Double, Bool)? in
            if case let .syncProgress(mediaItemId, position, _, forceOverwrite) = call {
                return (mediaItemId, position, forceOverwrite)
            }
            return nil
        }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "content-1")
        XCTAssertEqual(writes.first?.1 ?? 0, 640, accuracy: 0.001)
        XCTAssertEqual(writes.first?.2, true)
    }

    // MARK: - Harness

    private func makeActor() throws
        -> (PlaybackSessionActor, GatedControlPlaneShell, FakePlaybackTransport) {
        let transport = FakePlaybackTransport(
            capability: try PlaybackV3FixtureTestSupport.decode(
                PlaybackV3CapabilityResponse.self,
                named: "capability_response",
                bundleClass: Self.self
            ),
            watchDetail: try ControlPlaneFixtures.makeWatchDetail()
        )
        let shell = GatedControlPlaneShell(
            prepared: try ControlPlaneFixtures.makeProtocolV3PreparedRef().value,
            plan: ControlPlaneFixtures.makePlan(),
            identity: ControlPlaneFixtures.makeIdentity()
        )
        let actor = PlaybackSessionActor(
            bridge: PlaybackSessionBridge(
                transport: transport,
                capabilityGate: PlaybackV3CapabilityGate(transport: transport)
            ),
            shell: shell
        )
        return (actor, shell, transport)
    }

    /// Drive a load to `.playing` through the fake shell: the fresh-load task
    /// really runs, so the `.prepared` answer and the engine install arrive the
    /// way they do in the app. Only `fileLoaded` is fed by hand — there is no
    /// engine behind the fake to emit it.
    @discardableResult
    private func startPlaying(
        _ actor: PlaybackSessionActor,
        _ shell: GatedControlPlaneShell
    ) async throws -> LoadID {
        await actor.send(
            .load(ControlPlaneFixtures.makeRequest(), origin: .userInitiated, options: LoadOptions())
        )
        let loadID = try unwrap(await actor.currentState().loadID)
        await expectEntry(shell, to: .installEngine)
        await actor.ingestEngineEvent(.fileLoaded(reason: "test"), loadID: loadID)
        return loadID
    }

    /// `XCTAssertTrue` takes an autoclosure, which cannot carry an `await`.
    private func expectEntry(
        _ shell: GatedControlPlaneShell,
        to call: GatedControlPlaneShell.Call,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reached = await shell.waitForEntry(to: call)
        XCTAssertTrue(
            reached,
            message.isEmpty ? "the shell was never reached at \(call)" : message,
            file: file,
            line: line
        )
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot carry an `await`.
    private func unwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

/// A `PlaybackControlPlaneShell` whose calls can be parked and released by
/// hand.
///
/// `hold(_:)` arms the next entry into a call to suspend on a continuation the
/// test resumes with `release(_:)`; `waitForEntry(to:)` is how the test knows
/// the actor has got there. Everything else is a recorder.
@MainActor
private final class GatedControlPlaneShell: PlaybackControlPlaneShell {

    /// The calls this fake can gate on. Only the ones a test needs to park in
    /// or count are named; the rest are plain no-ops.
    enum Call: Hashable {
        case applyPresentation
        case prepareFreshSession
        case installEngine
        case teardownEngine
        case recordOfflineProgress
    }

    private(set) var presentations: [Presentation] = []
    private(set) var startedContentIds: [String] = []
    private(set) var installedLoadIDs: [LoadID] = []
    private(set) var torndownLoadIDs: [LoadID] = []
    private(set) var offlineProgressChecks = 0

    private let prepared: PreparedPlayback
    private let plan: PlaybackExecutionPlan
    private let identity: SessionIdentity

    /// How many further entries into a call must park.
    private var holds: [Call: Int] = [:]
    /// Continuations parked in a call, in arrival order.
    private var parked: [Call: [CheckedContinuation<Void, Never>]] = [:]
    /// How many times each call has been entered, and who is waiting on that.
    private var entries: [Call: Int] = [:]
    private struct Waiter {
        let token: Int
        let call: Call
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []
    private var nextWaiterToken = 0

    init(prepared: PreparedPlayback, plan: PlaybackExecutionPlan, identity: SessionIdentity) {
        self.prepared = prepared
        self.plan = plan
        self.identity = identity
    }

    // MARK: Test control

    func hold(_ call: Call, times: Int = 1) {
        holds[call, default: 0] += times
    }

    func release(_ call: Call) {
        guard var queue = parked[call], !queue.isEmpty else { return }
        let continuation = queue.removeFirst()
        parked[call] = queue
        continuation.resume()
    }

    func releaseAll() {
        holds.removeAll()
        let all = parked
        parked.removeAll()
        for queue in all.values {
            for continuation in queue { continuation.resume() }
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(returning: false) }
    }

    /// Wait until `call` has been entered `count` times. Answers `false` on
    /// timeout rather than hanging: a regression that stops the shell being
    /// reached at all has to fail the suite, not wedge it.
    @discardableResult
    func waitForEntry(to call: Call, count: Int = 1, timeout: Duration = .seconds(2)) async -> Bool {
        if entries[call, default: 0] >= count { return true }
        let token = nextWaiterToken
        nextWaiterToken += 1
        let expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire(token)
        }
        let reached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters.append(Waiter(token: token, call: call, count: count, continuation: continuation))
        }
        expiry.cancel()
        return reached
    }

    private func expire(_ token: Int) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    func resetCounters() {
        offlineProgressChecks = 0
        presentations.removeAll()
        startedContentIds.removeAll()
        installedLoadIDs.removeAll()
        torndownLoadIDs.removeAll()
    }

    /// Record the entry, wake anyone waiting for it, then park if held.
    private func enter(_ call: Call) async {
        entries[call, default: 0] += 1
        let reached = entries[call, default: 0]
        let woken = waiters.filter { $0.call == call && reached >= $0.count }
        waiters.removeAll { $0.call == call && reached >= $0.count }
        for waiter in woken { waiter.continuation.resume(returning: true) }

        guard let remaining = holds[call], remaining > 0 else { return }
        holds[call] = remaining - 1
        await withCheckedContinuation { continuation in
            parked[call, default: []].append(continuation)
        }
    }

    // MARK: PlaybackControlPlaneShell

    func applyPresentation(_ presentation: Presentation, transportOnly: Bool) async {
        presentations.append(presentation)
        await enter(.applyPresentation)
    }

    func applyEngineEventToPresentation(_ event: EngineEvent, reduction: EngineEventReduction) async {}

    func prepareFreshSession(
        request: LoadRequest,
        options: LoadOptions,
        origin: LoadOrigin
    ) async throws -> (prepared: PreparedPlayback, plan: PlaybackExecutionPlan, identity: SessionIdentity) {
        startedContentIds.append(request.contentId)
        await enter(.prepareFreshSession)
        return (prepared, plan, identity)
    }

    func presentLoadFailure(_ error: Error, origin: LoadOrigin) async -> String? { nil }

    func recordOfflineProgressIfOffline() async -> Bool {
        offlineProgressChecks += 1
        await enter(.recordOfflineProgress)
        return false
    }

    func installEngine(
        plan: PlaybackExecutionPlan,
        loadID: LoadID,
        reuseEngine: Bool,
        adoptingOutage outage: RecoveryContext.OutageState?
    ) async -> (events: AsyncStream<EngineEvent>?, failure: String?) {
        installedLoadIDs.append(loadID)
        await enter(.installEngine)
        // No stream and no message: "the load was already superseded, so there
        // is nothing to fail" — the arm that leaves the state alone.
        return (nil, nil)
    }

    func teardownEngine(loadID: LoadID, sourceCache: SourceCacheDisposition, engineOnly: Bool) async {
        torndownLoadIDs.append(loadID)
        await enter(.teardownEngine)
    }

    func engineSeek(to seconds: Double) async {}
    func engineTransport(_ command: TransportCommand) async {}
    func performEngineRecovery(_ action: RecoveryAction) async {}
    func observeRecovery(_ observation: RecoveryObservation) async {}
    func liveOutageState() async -> RecoveryContext.OutageState? { nil }
    func clearOutageNoticeLatch() async {}
    func clearServerOutageRecoverySlot() async {}
    func probeServerHealthOnce(reporting timerID: TimerID) async -> Bool { false }
    func reprobeOrigin() async {}

    func prepareReplan(
        _ intent: ReplanIntent
    ) async throws -> (prepared: PreparedPlayback, plan: PlaybackExecutionPlan, identity: SessionIdentity)? {
        nil
    }

    func releaseReplanSuspension(completingQualitySwitch: Bool) async {}

    func prepareRenewal(
        _ renewal: SourceRenewal
    ) async throws -> (prepared: PreparedPlayback, identity: SessionIdentity)? {
        nil
    }

    func noteRenewalSucceeded() async {}
    func noteRenewalFailure(_ error: Error, reason: String) async -> Bool { false }
}
