import XCTest
@testable import Silo

/// The per-session playback summary: what counts as a stall versus a
/// rebuffer, plan and bitrate changes, session boundaries, and when a summary
/// leaves the recorder.
final class PlaybackSessionSummaryRecorderTests: XCTestCase {
    private var time: TimeInterval = 100
    private var emitted: [PlaybackSessionSummary] = []
    private static let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
    private static let owner = PlaybackSessionSummaryRecorder.diagnosticsOwner(binding: binding, profileID: "profile-a")
    private var currentOwner: String? = owner

    override func setUp() {
        super.setUp()
        time = 100
        emitted = []
        currentOwner = Self.owner
        PlaybackSessionSummaryRecorder.resetLatestForTesting()
    }

    override func tearDown() {
        PlaybackSessionSummaryRecorder.resetLatestForTesting()
        super.tearDown()
    }

    private func makeRecorder() -> PlaybackSessionSummaryRecorder {
        PlaybackSessionSummaryRecorder(
            now: { [unowned self] in time },
            emit: { [unowned self] summary, _, _ in emitted.append(summary) },
            currentOwner: { [unowned self] in currentOwner }
        )
    }

    func testStartupStallsAndRebuffers() throws {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        // Waits before the first frame are startup, not stalls.
        recorder.bufferingChanged(true)
        time += 1.5
        recorder.bufferingChanged(false)
        recorder.firstFrame(bitrateBps: 18_000_000)
        XCTAssertEqual(emitted.last?.firstFrameMs, 1500)
        XCTAssertEqual(emitted.last?.bitrateKbps, 18_000)

        // An unexplained wait is a stall and a rebuffer.
        time += 30
        recorder.bufferingChanged(true)
        time += 2
        recorder.bufferingChanged(false)

        // A wait right after a seek is a stall only.
        time += 30
        recorder.seekRequested()
        time += 0.5
        recorder.bufferingChanged(true)
        time += 1
        recorder.bufferingChanged(false)

        recorder.stopped()
        let summary = try XCTUnwrap(emitted.last)
        XCTAssertEqual(summary.outcome, .stopped)
        XCTAssertEqual(summary.stallCount, 2)
        XCTAssertEqual(summary.stallTotalMs, 3000)
        XCTAssertEqual(summary.rebufferCount, 1)
        XCTAssertEqual(summary.rebufferTotalMs, 2000)
        XCTAssertEqual(summary.rebufferMaxMs, 2000)
        XCTAssertEqual(summary.sessionMs(at: time + 100), 65_000)
    }

    func testPlanAndBitrateChangesWithinOneSession() throws {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 18_000_000)
        // Same plan reloaded (transport restore): not a plan change.
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 18_000_000)
        recorder.loadBegan(sessionID: "s1", planID: "p2", playMethod: "transcode_hls")
        recorder.firstFrame(bitrateBps: 8_000_000)
        recorder.ended()

        let summary = try XCTUnwrap(emitted.last)
        XCTAssertEqual(summary.outcome, .ended)
        XCTAssertEqual(summary.planChangeCount, 1)
        XCTAssertEqual(summary.bitrateChangeCount, 1)
        XCTAssertEqual(summary.bitrateKbps, 8_000)
        XCTAssertEqual(summary.playMethod, "transcode_hls")
    }

    func testNewServerSessionFinishesThePreviousSummary() {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 0)
        recorder.failed(code: "network_timeout")
        recorder.loadBegan(sessionID: "s2", planID: "p9", playMethod: "original_http")

        // first frame, failure, and the finished s1 summary
        XCTAssertEqual(emitted.count, 3)
        XCTAssertEqual(emitted[1].errorCount, 1)
        XCTAssertEqual(emitted[1].failureCode, "network_timeout")
        XCTAssertEqual(emitted[2].outcome, .stopped)
        XCTAssertEqual(emitted[2].errorCount, 1)

        // The new session starts clean.
        let latest = PlaybackSessionSummaryRecorder.latestSummary(owner: Self.owner, now: time)?.summary
        XCTAssertEqual(latest?.outcome, .inProgress)
        XCTAssertEqual(latest?.errorCount, 0)
    }

    func testStallCheckpointsAreThrottled() {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 0)
        XCTAssertEqual(emitted.count, 1)
        for _ in 0..<5 {
            time += 5
            recorder.bufferingChanged(true)
            time += 1
            recorder.bufferingChanged(false)
        }
        XCTAssertEqual(emitted.count, 1, "stalls within a minute of the last summary do not emit")
        time += 60
        recorder.bufferingChanged(true)
        time += 1
        recorder.bufferingChanged(false)
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted.last?.stallCount, 6)
    }

    func testEventsWithoutASessionAreIgnored() {
        let recorder = makeRecorder()
        recorder.firstFrame(bitrateBps: 1_000)
        recorder.bufferingChanged(true)
        recorder.failed(code: "decode")
        recorder.stopped()
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertNil(PlaybackSessionSummaryRecorder.latestSummary(owner: Self.owner))
    }

    /// Every key the summary emits is registered, so none is dropped (or, in
    /// a debug build, asserted on) when the line is rendered.
    func testSummaryRendersWithRegisteredAttributes() throws {
        var summary = PlaybackSessionSummary(playMethod: "original_http", startedAt: 10)
        summary.firstFrameMs = 900
        summary.bitrateKbps = 18_000
        summary.failureCode = "decode"
        summary.stallCount = 2
        let line = try XCTUnwrap(summary.renderedDiagnosticsLine(at: 12))
        let decoded = try DiagnosticsJSONCoding.makeDecoder().decode(DiagnosticsLogLine.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.attrs?.count, summary.diagnosticsAttributes(at: 12).count)
        XCTAssertTrue(line.contains(#""session_ms":2000"#))
        XCTAssertTrue(line.contains(#""reason":"in_progress""#))
    }

    func testLatestSummaryIsAppendedToReportLogs() throws {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 0)
        let existing = Data("{\"existing\":true}\n".utf8)

        let logs = DiagnosticsCoordinator.appendingLatestPlaybackSummary(
            to: PendingReportArtifact(relativePath: "logs.jsonl", data: existing),
            binding: Self.binding,
            profileID: "profile-a"
        )
        let text = String(decoding: logs.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"existing\":true}\n"))
        XCTAssertTrue(text.contains(PlaybackSessionSummary.diagnosticsMessage))
        XCTAssertTrue(text.hasSuffix("\n"))

        let breadcrumbs = PendingReportArtifact(relativePath: "breadcrumbs.jsonl", data: existing)
        XCTAssertEqual(
            DiagnosticsCoordinator.appendingLatestPlaybackSummary(
                to: breadcrumbs,
                binding: Self.binding,
                profileID: "profile-a"
            ),
            breadcrumbs
        )
    }

    /// A summary from another account or profile in the same process is not
    /// evidence for this report.
    func testLatestSummaryIsOnlyAttachedForTheOwnerThatPlayedIt() {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 0)
        let logs = PendingReportArtifact(relativePath: "logs.jsonl", data: Data())

        for (binding, profileID) in [
            (Self.binding, "profile-b"),
            (DiagnosticsBinding(serverInstanceID: "srv-b", accountUserID: "42"), "profile-a"),
        ] {
            XCTAssertEqual(
                DiagnosticsCoordinator.appendingLatestPlaybackSummary(to: logs, binding: binding, profileID: profileID),
                logs
            )
        }

        // A session that began with no known owner is attributed to no one.
        currentOwner = nil
        recorder.loadBegan(sessionID: "s2", planID: "p1", playMethod: "original_http")
        XCTAssertNil(PlaybackSessionSummaryRecorder.latestSummary(owner: Self.owner))
    }

    /// A wait still in progress counts: a run killed during a long stall must
    /// not report no stalls.
    func testOpenWaitIsCountedInCheckpointsAndTheLatestSummary() throws {
        let recorder = makeRecorder()
        recorder.loadBegan(sessionID: "s1", planID: "p1", playMethod: "original_http")
        recorder.firstFrame(bitrateBps: 0)
        time += 120
        recorder.bufferingChanged(true)

        // The wait's start is checkpointed once the interval has passed.
        let checkpoint = try XCTUnwrap(emitted.last)
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(checkpoint.stallCount, 1)
        XCTAssertEqual(checkpoint.rebufferCount, 1)

        time += 45
        let latest = try XCTUnwrap(PlaybackSessionSummaryRecorder.latestSummary(owner: Self.owner, now: time)).summary
        XCTAssertEqual(latest.stallCount, 1)
        XCTAssertEqual(latest.stallTotalMs, 45_000)
        XCTAssertEqual(latest.rebufferMaxMs, 45_000)

        recorder.failed(code: "network_timeout")
        XCTAssertEqual(emitted.last?.stallTotalMs, 45_000)

        time += 5
        recorder.stopped()
        let finished = try XCTUnwrap(emitted.last)
        XCTAssertEqual(finished.stallCount, 1)
        XCTAssertEqual(finished.stallTotalMs, 50_000)
        XCTAssertEqual(PlaybackSessionSummaryRecorder.latestSummary(owner: Self.owner, now: time + 60)?.summary, finished)
    }

    // MARK: - Queued breadcrumb write

    /// The breadcrumb is written on a background queue. A write queued before
    /// a profile purge, or before the active profile changed, must not land in
    /// the journal afterwards under whoever is active then.
    func testQueuedSummaryWriteIsDroppedAfterAPurgeOrOwnerChange() {
        let summary = PlaybackSessionSummary(playMethod: "original_http", startedAt: 100)
        let other = PlaybackSessionSummaryRecorder.diagnosticsOwner(binding: Self.binding, profileID: "profile-b")
        var epoch = DiagnosticsEvidenceEpoch(owner: Self.owner, erasureGeneration: 7)
        var writes = 0
        func queuedWrite() -> () -> Void {
            PlaybackSessionSummaryRecorder.diagnosticsWrite(
                for: summary,
                at: 160,
                owner: Self.owner,
                currentEpoch: { epoch },
                write: { _, _ in writes += 1 }
            )
        }

        let unchanged = queuedWrite()
        unchanged()
        XCTAssertEqual(writes, 1)

        let beforePurge = queuedWrite()
        epoch = DiagnosticsEvidenceEpoch(owner: Self.owner, erasureGeneration: 8)
        beforePurge()
        XCTAssertEqual(writes, 1, "a purge ran before the queued write")

        let beforeSwitch = queuedWrite()
        epoch = DiagnosticsEvidenceEpoch(owner: other, erasureGeneration: 8)
        beforeSwitch()
        XCTAssertEqual(writes, 1, "another profile became active before the queued write")
    }

    func testPurgingTheJournalMovesTheEvidenceEpoch() {
        let before = DiagnosticsCoordinator.currentEvidenceEpoch()
        DiagnosticsCoordinator.purgeBreadcrumbJournal()
        XCTAssertNotEqual(DiagnosticsCoordinator.currentEvidenceEpoch(), before)
    }
}
