import XCTest
@testable import Silo

/// The conformance suite for lowering quality when playback keeps buffering.
///
/// The oracle is the server repo's `docs/design/2026-10-17-buffering-quality.md`,
/// encoded as `Fixtures/BufferingQuality/vectors.json` (vendored unchanged; see
/// its `SOURCE`). Web and Android replay the same file, so a divergence fails
/// here rather than arriving as a bug report. The focused tests below cover the
/// Apple-only presentation rules the vectors do not reach.
@MainActor
final class BufferingQualityControllerTests: XCTestCase {
    private typealias Controller = BufferingQualityController

    // MARK: - Vectors

    func testEveryVectorCase() throws {
        let vectors = try Self.loadVectors()
        XCTAssertFalse(vectors.cases.isEmpty)
        for vectorCase in vectors.cases {
            XCTContext.runActivity(named: vectorCase.name) { _ in
                assertReplay(vectorCase, sendsBufferingQualityFields: true)
            }
        }
    }

    /// Against a server without `buffering_quality_v1` the controller behaves
    /// the same; its replans only drop the two fields that server would reject.
    func testEveryVectorCaseWithoutBufferingQualityFeature() throws {
        let vectors = try Self.loadVectors()
        for vectorCase in vectors.cases {
            XCTContext.runActivity(named: vectorCase.name) { _ in
                assertReplay(vectorCase, sendsBufferingQualityFields: false)
            }
        }
    }

    func testConstantsCopyAndVocabularyMatchTheVectors() throws {
        let vectors = try Self.loadVectors()
        let constants = vectors.constants
        XCTAssertEqual(Set(constants.keys), [
            "STARTUP_GRACE_MS", "STALL_MIN_MS", "STALLS_BEFORE_TRIGGER", "STALL_WINDOW_MS",
            "LONG_STALL_MS", "PROMPT_SECONDS", "REOFFER_MIN_MS", "NO_LOWER_COOLDOWN_MS",
            "REARM_AFTER_UNADOPTED_MS", "STEP_DOWN_RATIO", "MIN_ESTIMATE_KBPS", "RENDERER_WAIT_BUFFER_MS",
        ], "a new constant needs a controller counterpart")
        XCTAssertEqual(constants["STARTUP_GRACE_MS"] as? Int, Controller.startupGraceMs)
        XCTAssertEqual(constants["STALL_MIN_MS"] as? Int, Controller.stallMinMs)
        XCTAssertEqual(constants["STALLS_BEFORE_TRIGGER"] as? Int, Controller.stallsBeforeTrigger)
        XCTAssertEqual(constants["STALL_WINDOW_MS"] as? Int, Controller.stallWindowMs)
        XCTAssertEqual(constants["LONG_STALL_MS"] as? Int, Controller.longStallMs)
        XCTAssertEqual(constants["PROMPT_SECONDS"] as? Double, Controller.promptSeconds)
        XCTAssertEqual(constants["REOFFER_MIN_MS"] as? Int, Controller.reofferMinMs)
        XCTAssertEqual(constants["NO_LOWER_COOLDOWN_MS"] as? Int, Controller.noLowerCooldownMs)
        XCTAssertEqual(constants["REARM_AFTER_UNADOPTED_MS"] as? Int, Controller.rearmAfterUnadoptedMs)
        XCTAssertEqual(constants["STEP_DOWN_RATIO"] as? Double, Controller.stepDownRatio)
        XCTAssertEqual(constants["MIN_ESTIMATE_KBPS"] as? Int, Controller.minEstimateKbps)
        XCTAssertEqual(constants["RENDERER_WAIT_BUFFER_MS"] as? Int, Controller.rendererWaitBufferMs)

        XCTAssertEqual(vectors.copy, [
            "prompt_title": Controller.promptTitle,
            "prompt_lower": Controller.lowerAction,
            "prompt_keep": Controller.keepAction,
            "undo_caption": Controller.undoCaption,
            "undo_action": Controller.undoAction,
            "lowered": Controller.loweredNotice,
            "cant_lower": Controller.cantLowerNotice,
        ])
        XCTAssertEqual(Controller.Notice.lowered.text, vectors.copy["lowered"])
        XCTAssertEqual(Controller.Notice.cantLower.text, vectors.copy["cant_lower"])

        // The replay below understands exactly these; anything new must fail
        // loudly rather than be skipped.
        XCTAssertEqual(Set(vectors.eventTypes), Set(VectorEvent.knownTypes))
        XCTAssertEqual(Set(vectors.outputTypes), ["replan", "prompt_shown", "undo_shown", "notice"])
        XCTAssertEqual(
            Set(vectors.cases.flatMap { $0.bufferingAction.values }).subtracting(Self.knownActions),
            []
        )
    }

    // MARK: - Pause and the pill timer

    func testPauseFreezesThePillTimerAndPlayResumesIt() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        XCTAssertEqual(h.controller.pill?.kind, .prompt)
        XCTAssertEqual(h.controller.pill?.deadline, h.date(146_000))

        h.at(136_000) { $0.paused() }
        XCTAssertNil(h.controller.pill?.deadline, "a pause freezes the timer")
        XCTAssertEqual(h.controller.pill?.remaining, 10)

        h.clock.advance(to: 600_000)
        XCTAssertEqual(h.controller.pill?.kind, .prompt, "frozen time never runs out")

        h.at(600_000) { $0.playing() }
        XCTAssertEqual(h.controller.pill?.deadline, h.date(610_000), "play resumes from what was left")
        h.clock.advance(to: 609_999)
        XCTAssertNotNil(h.controller.pill)
        h.clock.advance(to: 610_000)
        XCTAssertNil(h.controller.pill)
        XCTAssertEqual(h.shown, [.init(131_000, .pillShown(.prompt))])
    }

    // MARK: - Competing pills

    func testCompetingPillDefersThePromptUntilItHides() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.controller.setCompetingPillVisible(true)
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        XCTAssertNil(h.controller.pill)
        XCTAssertEqual(h.shown, [], "nothing shows behind the intro-skip or Next Up pill")
        XCTAssertFalse(h.controller.back(), "a deferred pill does not consume Back")

        h.at(140_000) { $0.setCompetingPillVisible(false) }
        XCTAssertEqual(h.controller.pill?.kind, .prompt)
        XCTAssertEqual(h.controller.pill?.deadline, h.date(155_000), "it shows with a full timer")
        XCTAssertEqual(h.shown, [.init(140_000, .pillShown(.prompt))])
    }

    func testDeferredPromptIsDroppedWhenThePlanChanges() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.controller.setCompetingPillVisible(true)
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        h.at(135_000) { $0.planAdopted(Self.plan("p2")) }
        h.at(140_000) { $0.setCompetingPillVisible(false) }
        XCTAssertNil(h.controller.pill)
        XCTAssertEqual(h.shown, [])
    }

    func testCompetingPillHidesAVisiblePillAndBringsItBack() {
        let h = Harness(mode: .always)
        h.lowerAutomatically()
        XCTAssertEqual(h.controller.pill?.kind, .undo)

        h.at(139_000) { $0.setCompetingPillVisible(true) }
        XCTAssertNil(h.controller.pill)
        h.at(200_000) { $0.setCompetingPillVisible(false) }
        XCTAssertEqual(h.controller.pill?.kind, .undo)
        XCTAssertEqual(h.controller.pill?.remaining, 10, "its timer was frozen while hidden")
        XCTAssertEqual(h.controller.pill?.deadline, h.date(210_000))
        h.clock.advance(to: 209_999)
        XCTAssertNotNil(h.controller.pill)
        h.clock.advance(to: 210_000)
        XCTAssertNil(h.controller.pill)
        XCTAssertEqual(h.shown, [
            .init(131_000, .replan(Self.autoLowering(44_100))),
            .init(134_000, .pillShown(.undo)),
            .init(200_000, .pillShown(.undo)),
        ], "coming back is shown again")
    }

    // MARK: - Host inputs

    func testQualityChangeClearsTheAnswerAndThePill() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        h.at(132_000) { $0.selectKeep() }
        h.at(133_000) { $0.playing() }
        h.at(200_000) { $0.waiting() }
        h.at(207_000) { $0.playing() }
        XCTAssertEqual(h.shown.count, 1, "an answered title is not prompted again")

        h.at(210_000) { $0.qualityChanged() }
        h.at(300_000) { $0.waiting() }
        h.clock.advance(to: 306_000)
        XCTAssertEqual(h.controller.pill?.kind, .prompt, "the answer was for the old quality")

        h.at(307_000) { $0.qualityChanged() }
        XCTAssertNil(h.controller.pill)
        h.at(308_000) { $0.playing() }
        XCTAssertEqual(h.shown, [
            .init(131_000, .pillShown(.prompt)),
            .init(306_000, .pillShown(.prompt)),
        ], "history cleared: the stall that was in progress counts only from the change")
    }

    func testAdoptingAPlanTheControllerDidNotRequestHidesTheUndoPill() {
        let h = Harness(mode: .always)
        h.lowerAutomatically()
        h.at(140_000) { $0.planAdopted(Self.plan("p3", delivered: 63_000)) }
        XCTAssertNil(h.controller.pill)

        // Not the lowering's result: no notice, no cooldown, fresh history.
        h.at(200_000) { $0.waiting() }
        h.clock.advance(to: 210_000)
        XCTAssertEqual(h.shown, [
            .init(131_000, .replan(Self.autoLowering(44_100))),
            .init(134_000, .pillShown(.undo)),
            .init(206_000, .replan(Self.autoLowering(44_100))),
        ])
    }

    func testAutoWithoutAUsableEstimateShowsCantLowerOncePerTitle() {
        let h = Harness(mode: .always)
        let rungs = [
            Controller.QualityRung(label: "original", bitrateKbps: 140, preservesSource: true),
            Controller.QualityRung(label: "low", bitrateKbps: 120, preservesSource: false),
        ]
        // 0.7 × 140 = 98, under MIN_ESTIMATE_KBPS, although a lower rung exists.
        h.startPlaying(Self.plan("p1", delivered: 140, rungs: rungs))
        h.at(125_000) { $0.waiting() }
        h.at(132_000) { $0.playing() }
        h.at(200_000) { $0.waiting() }
        h.at(210_000) { $0.reset() }
        XCTAssertEqual(h.summaries.map(\.action), [.cantLower])

        // A new title, and Auto reporting no delivered bitrate at all.
        h.startPlaying(Self.plan("q1", delivered: nil), at: 210_000)
        h.at(400_000) { $0.waiting() }
        h.clock.advance(to: 410_000)
        XCTAssertEqual(h.shown, [
            .init(131_000, .notice(.cantLower)),
            .init(406_000, .notice(.cantLower)),
        ])
    }

    func testBackIsConsumedOnlyByAVisiblePill() {
        let h = Harness(mode: .ask)
        XCTAssertFalse(h.controller.back())
        h.startPlaying(Self.plan("p1"))
        XCTAssertFalse(h.controller.back())
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        XCTAssertTrue(h.controller.back())
        XCTAssertNil(h.controller.pill)
        XCTAssertFalse(h.controller.back(), "a second Back behaves normally")
    }

    func testSuspendedControllerOnlyRecordsStats() {
        let h = Harness(mode: .always)
        h.controller.isSuspended = true
        h.startPlaying(Self.plan("p1"))
        h.at(30_000) { $0.waiting() }
        h.at(31_500) { $0.playing() }
        h.at(90_000) { $0.waiting() }
        h.at(91_200) { $0.playing() }
        h.at(125_000) { $0.waiting() }
        h.at(140_000) { $0.playing() }
        h.at(150_000) { $0.planEnded() }
        XCTAssertEqual(h.shown, [])
        XCTAssertEqual(h.summaries, [Controller.PlanSummary(
            planId: "p1",
            playedMs: 30_000 + 58_500 + 33_800 + 10_000,
            stallCount: 3,
            stallTotalMs: 1_500 + 1_200 + 15_000,
            stallLongestMs: 15_000,
            deliveredKbps: 63_000,
            mode: .always,
            action: .none,
            bandwidthEstimateKbps: nil
        )])
    }

    func testSuspendingTakesDownAVisiblePrompt() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        XCTAssertNotNil(h.controller.pill)
        h.controller.isSuspended = true
        XCTAssertNil(h.controller.pill)
        XCTAssertFalse(h.controller.back())
    }

    // MARK: - Cross-platform rulings the vectors do not pin

    /// A stall still running when a replan's plan replaces its plan ends with
    /// that plan and counts there.
    func testAStallInProgressWhenItsPlanIsReplacedCounts() {
        let h = Harness(mode: .always)
        h.lowerAutomatically()
        XCTAssertEqual(h.summaries.first, Controller.PlanSummary(
            planId: "p1", playedMs: 125_000, stallCount: 1, stallTotalMs: 9_000, stallLongestMs: 9_000,
            deliveredKbps: 63_000, mode: .always, action: .lowered, bandwidthEstimateKbps: nil
        ))
    }

    /// A stall that runs into an outage drops its time so far; only the part
    /// after the outage counts.
    func testAnOutageDropsTheStallTimeBeforeIt() {
        let h = Harness(mode: .never)
        h.startPlaying(Self.plan("p1"))
        h.at(30_000) { $0.waiting() }
        h.at(33_000) { $0.transportTroubleChanged(true) }
        h.at(40_000) { $0.transportTroubleChanged(false) }
        h.at(42_000) { $0.playing() }
        h.at(50_000) { $0.planEnded() }
        XCTAssertEqual(h.summaries.map(\.stallCount), [1])
        XCTAssertEqual(h.summaries.map(\.stallTotalMs), [2_000])
    }

    /// Leaving a Watch Party room starts trigger history fresh, with the grace
    /// over.
    func testLeavingARoomStartsTriggerHistoryFresh() {
        let h = Harness(mode: .always)
        h.controller.isSuspended = true
        h.startPlaying(Self.plan("p1"))
        h.at(30_000) { $0.waiting() }
        h.at(31_500) { $0.playing() }
        h.at(90_000) { $0.waiting() }
        h.at(91_200) { $0.playing() }
        h.at(100_000) { $0.isSuspended = false }
        h.at(110_000) { $0.waiting() }
        h.at(111_500) { $0.playing() }
        XCTAssertEqual(h.shown, [], "the room's stalls are not this history's")
        h.at(150_000) { $0.waiting() }
        h.at(151_200) { $0.playing() }
        XCTAssertEqual(h.shown, [.init(151_200, .replan(Self.autoLowering(44_100)))])
    }

    /// Back on the undo pill hides it as its timer ending does, so a long
    /// stall in progress is evaluated at once.
    func testBackOnTheUndoPillEvaluatesALongStallInProgress() {
        let h = Harness(mode: .always)
        h.lowerAutomatically()
        h.at(136_000) { $0.setCompetingPillVisible(true) }
        h.at(145_000) { $0.waiting() }
        h.clock.advance(to: 152_000)
        h.at(160_000) { $0.setCompetingPillVisible(false) }
        XCTAssertEqual(h.controller.pill?.kind, .undo)
        h.at(161_000) { _ = $0.back() }
        XCTAssertEqual(h.shown.last, .init(161_000, .replan(Self.autoLowering(22_120))))
    }

    /// A plan opened with a wait keeps its grace anchored there when its first
    /// frame follows.
    func testStartupGraceStaysAnchoredAtTheFirstWait() {
        let h = Harness(mode: .always)
        h.at(0) { $0.planAdopted(Self.plan("p1")) }
        h.at(0) { $0.waiting() }
        h.at(4_000) { $0.playing() }
        h.at(12_000) { $0.waiting() }
        h.at(14_000) { $0.playing() }
        h.at(60_000) { $0.waiting() }
        h.at(61_500) { $0.playing() }
        XCTAssertEqual(h.shown, [.init(61_500, .replan(Self.autoLowering(44_100)))])
    }

    /// A wait the host noticed late (a frozen software playhead) is timed from
    /// when it began.
    func testABackdatedWaitIsTimedFromWhenItBegan() {
        let h = Harness(mode: .never)
        h.startPlaying(Self.plan("p1"))
        h.at(30_000) { $0.waiting(cause: .network, startedAgoMs: 1_000) }
        h.at(30_500) { $0.playing() }
        h.at(40_000) { $0.planEnded() }
        XCTAssertEqual(h.summaries.map(\.stallCount), [1])
        XCTAssertEqual(h.summaries.map(\.stallTotalMs), [1_500])
        XCTAssertEqual(h.summaries.map(\.playedMs), [29_000 + 9_500])
    }

    /// Only a prompt that timed out starts the re-offer wait; one answered with
    /// Lower quality does not.
    func testAnAcceptedLoweringStartsNoReofferWait() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        h.at(132_000) { $0.selectLower() }
        h.at(134_000) {
            $0.planAdopted(Self.plan("p2", delivered: 31_600))
            $0.playing()
        }
        h.at(200_000) { $0.waiting() }
        h.clock.advance(to: 206_000)
        XCTAssertEqual(h.shown.last, .init(206_000, .pillShown(.prompt)))
    }

    /// A lowering whose plan reports no delivered bitrate came back lower.
    func testALoweringResultWithoutADeliveredBitrateIsLower() {
        let h = Harness(mode: .always)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.at(134_000) {
            $0.planAdopted(Self.plan("p2", delivered: nil))
            $0.playing()
        }
        XCTAssertEqual(h.shown.last, .init(134_000, .pillShown(.undo)))
    }

    /// The failure notice after a no-lower result uses up the title's
    /// once-per-title "Can't lower quality" notice.
    func testAFailureNoticeSpendsTheOncePerTitleNotice() {
        let h = Harness(mode: .always)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.at(134_000) {
            $0.planAdopted(Self.plan("p2", delivered: 63_000))
            $0.playing()
        }
        h.at(140_000) { $0.planAdopted(Self.plan("p3", rungs: []), controllerInitiated: false) }
        h.at(200_000) { $0.waiting() }
        h.clock.advance(to: 210_000)
        XCTAssertEqual(h.shown.filter { if case .notice = $0.output { return true } else { return false } },
                       [.init(134_000, .notice(.cantLower))])
    }

    // MARK: - Replay

    private func assertReplay(_ vectorCase: VectorCase, sendsBufferingQualityFields: Bool) {
        let label = "\(vectorCase.name) (buffering_quality_v1 \(sendsBufferingQualityFields ? "on" : "off"))"
        let h = Harness(mode: vectorCase.mode)
        h.controller.sendsBufferingQualityFields = sendsBufferingQualityFields
        var adopted: [String] = []
        for event in vectorCase.events {
            h.clock.advance(to: event.t)
            if case .planAdopted(let plan, _) = event.kind { adopted.append(plan.id) }
            if let sent = event.apply(to: h.controller) { h.record(sent) }
        }
        h.clock.advance(to: vectorCase.until)
        h.controller.planEnded()

        let expected = vectorCase.expect.map { output in
            sendsBufferingQualityFields ? output : output.droppingBufferingQualityFields()
        }
        XCTAssertEqual(h.shown.map { VectorOutput($0) }, expected, label)

        XCTAssertEqual(h.summaries.map(\.planId), adopted, "\(label): one plan_summary per adopted plan")
        for (planId, action) in vectorCase.bufferingAction {
            XCTAssertEqual(
                h.summaries.first { $0.planId == planId }?.action.rawValue, action,
                "\(label): buffering_action for \(planId)"
            )
        }
    }

    // MARK: - Fixtures

    private static let ladder: [Controller.QualityRung] = [
        .init(label: "original", bitrateKbps: 63_000, preservesSource: true),
        .init(label: "1080p-high", bitrateKbps: 10_000, preservesSource: false),
        .init(label: "1080p-medium", bitrateKbps: 6_000, preservesSource: false),
        .init(label: "720p-high", bitrateKbps: 4_000, preservesSource: false),
    ]

    private static func plan(
        _ id: String,
        delivered: Int? = 63_000,
        quality: String = "auto",
        rungs: [Controller.QualityRung] = ladder
    ) -> Controller.Plan {
        .init(id: id, deliveredKbps: delivered, quality: quality, availableQualities: rungs, qualityReductionUnavailable: false)
    }

    private static func autoLowering(_ estimate: Int) -> Controller.ReplanRequest {
        .init(qualityPreference: "auto", bandwidthEstimateKbps: estimate, bandwidthEstimateSource: "observed_rebuffer")
    }

    private static let knownActions: Set<String> = [
        "none", "ignored", "lowered", "restored", "accepted", "kept", "timed_out", "cant_lower",
    ]

    private static func loadVectors() throws -> Vectors {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "vectors", bundleClass: BufferingQualityControllerTests.self
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        return try Vectors(object)
    }
}

// MARK: - Harness

/// A controller on a manual clock, recording every output with its time.
@MainActor
private final class Harness {
    struct Recorded: Equatable, CustomStringConvertible {
        let t: Int
        let output: BufferingQualityController.Output

        init(_ t: Int, _ output: BufferingQualityController.Output) {
            self.t = t
            self.output = output
        }

        var description: String { "\(t) \(output)" }
    }

    let clock = ManualBufferingQualityClock()
    let controller: BufferingQualityController
    private(set) var outputs: [Recorded] = []

    init(mode: BufferingQualityMode) {
        controller = BufferingQualityController(clock: clock)
        controller.mode = mode
        controller.sendsBufferingQualityFields = true
        controller.onOutput = { [unowned self] output in
            self.outputs.append(Recorded(self.clock.nowMs, output))
        }
    }

    /// Everything but `plan_summary`: what the vectors' `expect` lists.
    var shown: [Recorded] {
        outputs.filter {
            if case .planSummary = $0.output { return false }
            return true
        }
    }

    var summaries: [BufferingQualityController.PlanSummary] {
        outputs.compactMap {
            if case .planSummary(let summary) = $0.output { return summary }
            return nil
        }
    }

    /// An output the player sends itself with the controller's fields, such
    /// as a client replan.
    func record(_ output: BufferingQualityController.Output) {
        outputs.append(Recorded(clock.nowMs, output))
    }

    func at(_ ms: Int, _ action: (BufferingQualityController) -> Void) {
        clock.advance(to: ms)
        action(controller)
    }

    func date(_ ms: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(ms) / 1000)
    }

    func startPlaying(_ plan: BufferingQualityController.Plan, at ms: Int = 0) {
        at(ms) {
            $0.planAdopted(plan)
            $0.playing()
        }
    }

    /// The vectors' `undo` case: a long stall lowers Auto at 131000 and the
    /// lower plan's undo pill shows at 134000.
    func lowerAutomatically() {
        startPlaying(.init(
            id: "p1", deliveredKbps: 63_000, quality: "auto",
            availableQualities: [.init(label: "1080p-high", bitrateKbps: 10_000, preservesSource: false)],
            qualityReductionUnavailable: false
        ))
        at(125_000) { $0.waiting() }
        at(134_000) {
            $0.planAdopted(.init(
                id: "p2", deliveredKbps: 31_600, quality: "auto",
                availableQualities: [.init(label: "1080p-high", bitrateKbps: 10_000, preservesSource: false)],
                qualityReductionUnavailable: false
            ))
            $0.playing()
        }
    }
}

/// A clock the test advances by hand, in whole milliseconds. Due timers fire in
/// deadline order, first-scheduled first on a tie, including timers that firing
/// ones schedule.
@MainActor
final class ManualBufferingQualityClock: PlayerPromptClock {
    private final class Timer: PlayerPromptTimer {
        let fireAtMs: Int
        let order: Int
        let action: @MainActor () -> Void
        var cancelled = false

        init(fireAtMs: Int, order: Int, action: @escaping @MainActor () -> Void) {
            self.fireAtMs = fireAtMs
            self.order = order
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    private(set) var nowMs = 0
    private var timers: [Timer] = []
    private var scheduled = 0

    var now: Date { Date(timeIntervalSinceReferenceDate: TimeInterval(nowMs) / 1000) }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> PlayerPromptTimer {
        let timer = Timer(
            fireAtMs: nowMs + Int((max(0, delay) * 1000).rounded()),
            order: scheduled,
            action: action
        )
        scheduled += 1
        timers.append(timer)
        return timer
    }

    func advance(to ms: Int) {
        precondition(ms >= nowMs, "the clock only moves forward")
        while let next = timers
            .filter({ !$0.cancelled && $0.fireAtMs <= ms })
            .min(by: { ($0.fireAtMs, $0.order) < ($1.fireAtMs, $1.order) }) {
            nowMs = max(nowMs, next.fireAtMs)
            next.cancelled = true
            next.action()
        }
        timers.removeAll { $0.cancelled }
        nowMs = ms
    }
}

// MARK: - Vector model

private enum VectorError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let what): return "vectors.json: \(what)"
        }
    }
}

private struct Vectors {
    let constants: [String: Any]
    let copy: [String: String]
    let eventTypes: [String]
    let outputTypes: [String]
    let cases: [VectorCase]

    /// Every top-level key, so a new section fails loudly instead of being
    /// skipped. `connection_budget_cases` is the server's oracle for the
    /// connection endpoint's budget, which clients display and never compute.
    /// `probe_cases` are replayed by `BandwidthProbeMeterTests`.
    static let knownKeys: Set<String> = [
        "version", "spec", "about", "constants", "copy", "event_types", "output_types", "defaults", "cases",
        "connection_budget_cases", "probe_about", "probe_constants", "probe_cases",
    ]

    init(_ object: [String: Any]) throws {
        let unknown = Set(object.keys).subtracting(Self.knownKeys)
        guard unknown.isEmpty else {
            throw VectorError.malformed("unknown top-level keys \(unknown.sorted())")
        }
        guard let constants = object["constants"] as? [String: Any],
              let copy = object["copy"] as? [String: String],
              let eventTypes = object["event_types"] as? [String],
              let outputTypes = object["output_types"] as? [String],
              let defaults = object["defaults"] as? [String: Any],
              let defaultMode = defaults["mode"] as? String,
              let cases = object["cases"] as? [[String: Any]] else {
            throw VectorError.malformed("top-level keys")
        }
        self.constants = constants
        self.copy = copy
        self.eventTypes = eventTypes
        self.outputTypes = outputTypes
        self.cases = try cases.map { try VectorCase($0, defaultMode: defaultMode) }
    }
}

private struct VectorCase {
    let name: String
    let mode: BufferingQualityMode
    let events: [VectorEvent]
    let until: Int
    let expect: [VectorOutput]
    let bufferingAction: [String: String]

    init(_ object: [String: Any], defaultMode: String) throws {
        guard let name = object["name"] as? String,
              let events = object["events"] as? [[String: Any]],
              let until = object["until"] as? Int,
              let expect = object["expect"] as? [[String: Any]] else {
            throw VectorError.malformed("case keys")
        }
        let modeValue = object["mode"] as? String ?? defaultMode
        guard let mode = BufferingQualityMode(wireValue: modeValue) else {
            throw VectorError.malformed("\(name): mode \(modeValue)")
        }
        self.name = name
        self.mode = mode
        self.events = try events.map { try VectorEvent($0, in: name) }
        self.until = until
        self.expect = try expect.map { try VectorOutput($0, in: name) }
        self.bufferingAction = object["buffering_action"] as? [String: String] ?? [:]
    }
}

private struct VectorEvent {
    enum Kind {
        case planAdopted(BufferingQualityController.Plan, controllerInitiated: Bool)
        case playing
        case waiting(BufferingQualityController.WaitCause)
        case pause, seek
        case transportErrorStart, transportErrorEnd
        case replanFailed
        case selectLower, selectKeep, selectRestore, back
        /// A higher-priority actionable pill appeared, or the last one hid.
        case pillObscured, pillUnobscured
        /// The player sends a replan for its own reasons.
        case clientReplan(operation: String)
        case qualityChanged
        case newAttempt
    }

    static let knownTypes = [
        "plan_adopted", "playing", "waiting", "pause", "seek", "transport_error_start",
        "transport_error_end", "replan_failed", "select_lower", "select_keep", "select_restore", "back",
        "pill_obscured", "pill_unobscured", "client_replan", "quality_changed", "new_attempt",
    ]

    /// The operations a `client_replan` may carry.
    static let clientReplanOperations: Set<String> = [
        "track_change", "seek_reanchor", "seek_failure_recovery", "failure_recovery", "output_change",
    ]

    let t: Int
    let kind: Kind

    init(_ object: [String: Any], in caseName: String) throws {
        guard let t = object["t"] as? Int, let type = object["type"] as? String else {
            throw VectorError.malformed("\(caseName): event keys")
        }
        self.t = t
        switch type {
        case "plan_adopted":
            guard let plan = object["plan"] as? [String: Any] else {
                throw VectorError.malformed("\(caseName): plan_adopted without plan")
            }
            // Absent means the adoption answers the controller's own replan,
            // or a start.
            kind = .planAdopted(
                try Self.plan(plan, in: caseName),
                controllerInitiated: object["controllerInitiated"] as? Bool ?? true
            )
        case "playing": kind = .playing
        case "waiting":
            switch object["cause"] as? String {
            case nil: kind = .waiting(.network)
            case "seek": kind = .waiting(.seek)
            case "pause": kind = .waiting(.pause)
            case "reload": kind = .waiting(.reload)
            case "renderer": kind = .waiting(.renderer)
            case let cause?: throw VectorError.malformed("\(caseName): unknown wait cause \(cause)")
            }
        case "pause": kind = .pause
        case "seek": kind = .seek
        case "transport_error_start": kind = .transportErrorStart
        case "transport_error_end": kind = .transportErrorEnd
        case "replan_failed": kind = .replanFailed
        case "select_lower": kind = .selectLower
        case "select_keep": kind = .selectKeep
        case "select_restore": kind = .selectRestore
        case "back": kind = .back
        case "pill_obscured": kind = .pillObscured
        case "pill_unobscured": kind = .pillUnobscured
        case "client_replan":
            guard let operation = object["operation"] as? String,
                  Self.clientReplanOperations.contains(operation) else {
                throw VectorError.malformed("\(caseName): client_replan operation")
            }
            kind = .clientReplan(operation: operation)
        case "quality_changed": kind = .qualityChanged
        case "new_attempt": kind = .newAttempt
        default: throw VectorError.malformed("\(caseName): unknown event type \(type)")
        }
    }

    /// Feeds the event to the controller. Returns what the player sends itself
    /// with the controller's fields: a client replan.
    @MainActor
    func apply(to controller: BufferingQualityController) -> BufferingQualityController.Output? {
        switch kind {
        case .planAdopted(let plan, let controllerInitiated):
            controller.planAdopted(plan, controllerInitiated: controllerInitiated)
        case .playing: controller.playing()
        case .waiting(let cause): controller.waiting(cause: cause)
        case .pause: controller.paused()
        case .seek: controller.seeked()
        case .transportErrorStart: controller.transportTroubleChanged(true)
        case .transportErrorEnd: controller.transportTroubleChanged(false)
        case .replanFailed: controller.replanFailed()
        case .selectLower: controller.selectLower()
        case .selectKeep: controller.selectKeep()
        case .selectRestore: controller.selectRestore()
        case .back: controller.back()
        case .pillObscured: controller.setCompetingPillVisible(true)
        case .pillUnobscured: controller.setCompetingPillVisible(false)
        case .clientReplan(let operation):
            return controller.clientReplan(operation: operation).map(BufferingQualityController.Output.replan)
        case .qualityChanged: controller.qualityChanged()
        case .newAttempt: controller.newAttempt()
        }
        return nil
    }

    private static func plan(_ object: [String: Any], in caseName: String) throws -> BufferingQualityController.Plan {
        guard let id = object["plan_id"] as? String,
              let quality = object["quality"] as? String,
              let rungs = object["available_qualities"] as? [[String: Any]] else {
            throw VectorError.malformed("\(caseName): plan keys")
        }
        let warnings = object["degradation_warnings"] as? [String] ?? []
        // The vectors write a missing delivered bitrate as 0.
        let delivered = object["delivered_kbps"] as? Int
        return .init(
            id: id,
            deliveredKbps: delivered == 0 ? nil : delivered,
            quality: quality,
            availableQualities: try rungs.map { rung in
                guard let label = rung["label"] as? String,
                      let bitrate = rung["bitrate_kbps"] as? Int else {
                    throw VectorError.malformed("\(caseName): quality keys")
                }
                return .init(
                    label: label,
                    bitrateKbps: bitrate,
                    preservesSource: rung["preserves_source"] as? Bool ?? false
                )
            },
            qualityReductionUnavailable: warnings.contains("quality_reduction_unavailable")
        )
    }
}

/// An output in the vectors' shape, so expected and actual compare directly.
private struct VectorOutput: Equatable, CustomStringConvertible {
    let t: Int
    let type: String
    let body: NSDictionary?
    let key: String?

    init(_ object: [String: Any], in caseName: String) throws {
        guard let t = object["t"] as? Int, let type = object["type"] as? String else {
            throw VectorError.malformed("\(caseName): output keys")
        }
        self.t = t
        self.type = type
        switch type {
        case "replan":
            guard let body = object["body"] as? [String: Any] else {
                throw VectorError.malformed("\(caseName): replan without body")
            }
            self.body = body as NSDictionary
            key = nil
        case "notice":
            guard let key = object["key"] as? String, ["lowered", "cant_lower"].contains(key) else {
                throw VectorError.malformed("\(caseName): notice key")
            }
            body = nil
            self.key = key
        case "prompt_shown", "undo_shown":
            body = nil
            key = nil
        default:
            throw VectorError.malformed("\(caseName): unknown output type \(type)")
        }
    }

    init(_ recorded: Harness.Recorded) {
        t = recorded.t
        switch recorded.output {
        case .replan(let request):
            type = "replan"
            body = request.wireBody as NSDictionary
            key = nil
        case .pillShown(let kind):
            type = kind == .prompt ? "prompt_shown" : "undo_shown"
            body = nil
            key = nil
        case .notice(let notice):
            type = "notice"
            body = nil
            key = notice == .lowered ? "lowered" : "cant_lower"
        case .planSummary:
            preconditionFailure("summaries are checked separately")
        }
    }

    private init(t: Int, type: String, body: NSDictionary?, key: String?) {
        self.t = t
        self.type = type
        self.body = body
        self.key = key
    }

    /// The same output as a server without `buffering_quality_v1` receives it.
    func droppingBufferingQualityFields() -> VectorOutput {
        guard let body = body?.mutableCopy() as? NSMutableDictionary else { return self }
        body.removeObjects(forKeys: ["bandwidth_estimate_source", "learned_limit"])
        return VectorOutput(t: t, type: type, body: body, key: key)
    }

    var description: String {
        var parts = ["\(t) \(type)"]
        if let key { parts.append(key) }
        if let body,
           let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            parts.append(json)
        }
        return parts.joined(separator: " ")
    }
}
