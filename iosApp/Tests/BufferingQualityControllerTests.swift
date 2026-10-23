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
    fileprivate typealias Controller = BufferingQualityController

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

    /// The vectors' pending pick sees no evaluation until it is refused;
    /// here playback resumes from the long stall while the pick is pending.
    func testNothingPromptsWhileAPickIsPending() {
        let h = Harness(mode: .ask)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.clock.advance(to: 131_000)
        h.at(133_000) { $0.pickSent() }
        h.at(134_000) { $0.playing() }
        XCTAssertNil(h.controller.pill)

        // Refused: the long stall still counts, and the next evaluation asks.
        h.at(135_000) { $0.pickRefused() }
        h.at(140_000) { $0.waiting() }
        h.at(142_000) { $0.playing() }
        XCTAssertEqual(h.shown, [
            .init(131_000, .pillShown(.prompt)),
            .init(142_000, .pillShown(.prompt)),
        ])
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

    /// New content: the once-per-title "Can't lower quality" notice can show
    /// again. (The vectors pin the notice itself, once per title.)
    func testResetLetsTheNextTitleShowCantLowerAgain() {
        let h = Harness(mode: .always)
        h.startPlaying(Self.plan("p1", delivered: nil))
        h.at(125_000) { $0.waiting() }
        h.at(210_000) { $0.reset() }
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

    /// The stall that triggers a lowering ends when the player swaps in the
    /// lower plan's source; it still counts in the plan it stalled, as one in
    /// progress at that plan's end would. A stall a reload cuts short in a
    /// plan that then plays on stays uncounted.
    func testAStallTheSourceSwapEndsCountsInItsPlan() {
        let h = Harness(mode: .always)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.at(133_000) { $0.waiting(cause: .reload) }
        h.at(134_000) {
            $0.planAdopted(Self.plan("p2", delivered: 31_600))
            $0.playing()
        }
        XCTAssertEqual(h.summaries.map(\.stallCount), [1])
        XCTAssertEqual(h.summaries.map(\.stallTotalMs), [8_000])

        h.at(200_000) { $0.waiting() }
        h.at(202_000) { $0.waiting(cause: .reload) }
        h.at(203_000) { $0.playing() }
        h.at(210_000) { $0.planEnded() }
        XCTAssertEqual(h.summaries.map(\.stallCount), [1, 0])
    }

    /// A replacement of a plan that played: its loading, from the source
    /// swap through its adoption to its first frame, is a source reload.
    /// Gauntlet T2: an audio-track switch on a fast link took 6 s to adoption
    /// and 11.4 s more to play. Timed from the swap, it would have lowered at
    /// 76 s.
    func testASlowTrackChangeDoesNotLower() {
        let h = Harness(mode: .always)
        h.startPlaying(Self.plan("p1"))
        h.at(60_000) { $0.waiting(cause: .reload) }
        h.at(66_000) {
            $0.planAdopted(Self.plan("p2"), controllerInitiated: false)
            $0.waiting()
        }
        h.at(77_400) { $0.playing() }
        h.clock.advance(to: 120_000)
        XCTAssertEqual(h.shown, [])
    }

    /// The lower plan of a lowering after the attempt played never starts,
    /// its media measured arriving below its bitrate: its wait is a source
    /// reload, so it lowers again only at its start deadline. Apple TV S2: a
    /// lowered version's subtitle rendition answered 503 for 20-27 s, and its
    /// wait, timed under its own grace, lowered Auto again at 16 s, rung by
    /// rung.
    func testALoweredPlanThatNeverStartsLowersOnlyAtItsDeadline() {
        let h = Harness(mode: .always)
        h.startPlaying(Self.plan("p1"))
        h.at(125_000) { $0.waiting() }
        h.at(133_000) { $0.waiting(cause: .reload) }
        h.at(134_000) {
            $0.planAdopted(Self.plan("p2", delivered: 31_600))
            $0.waiting()
        }
        h.measuredKbps = 10_000
        h.clock.advance(to: 179_000)
        XCTAssertEqual(h.shown, [
            .init(131_000, .replan(Self.autoLowering(44_100))),
            .init(134_000, .pillShown(.undo)),
        ])
        XCTAssertTrue(h.controller.startDeadlinePassed())
        XCTAssertEqual(h.shown.last, .init(179_000, .replan(Self.autoLowering(22_120, observed: 10_000))))
    }

    /// A plan adopted before any plan of the attempt played, here a failure
    /// recovery 5 s into the start, continues the start under the grace it
    /// began: its wait triggers at 16 s, not 10 s after its adoption.
    func testAReplacementBeforeAnythingPlayedKeepsTheStartsGrace() {
        let h = Harness(mode: .always)
        h.measuredKbps = 20_000
        h.at(0) {
            $0.planAdopted(Self.plan("p1"))
            $0.waiting()
        }
        h.at(5_000) { $0.planAdopted(Self.plan("p2"), controllerInitiated: false) }
        h.clock.advance(to: 15_999)
        XCTAssertEqual(h.shown, [])
        h.clock.advance(to: 16_000)
        XCTAssertEqual(h.shown, [.init(16_000, .replan(Self.autoLowering(44_100, observed: 20_000)))])
    }

    /// Before any plan of the attempt has played, a trigger lowers only on
    /// evidence that the plan's media arrived below its delivered bitrate,
    /// and the lowering carries it; without it the start runs on to the
    /// player's deadline, and a start wait the first frame ends is no counted
    /// stall. Gauntlet Apple TV V5: each lower plan's subtitle rendition was
    /// refused for 20-27 s, nothing measured the link, and Auto lowered eight
    /// times, to 125 kbps. Once the attempt has played, the stall rules need
    /// no evidence.
    func testBeforeAnythingPlayedOnlyASlowLinkLowers() {
        // The start's own plan, waiting from 0: nothing measured (a subtitle
        // reader shares the link), or media at its bitrate. Nothing triggers
        // in any mode: no lowering, no prompt, no `ignored`.
        for mode in [BufferingQualityMode.always, .ask, .never] {
            for measured in [nil, 63_000] {
                let h = Harness(mode: mode)
                h.measuredKbps = measured
                h.at(0) {
                    $0.planAdopted(Self.plan("p1"))
                    $0.waiting()
                }
                h.at(45_000) { $0.planEnded() }
                XCTAssertEqual(h.shown, [], "\(mode) \(measured as Any)")
                XCTAssertEqual(h.summaries.map(\.action), [.none], "\(mode) \(measured as Any)")
            }
        }

        // An embedded subtitle's prefetch shares the link, so nothing is
        // measured, but the counted reader got 4.5 Mbps of the plan's
        // bitrate (bedroom Apple TV, 5 Mbps link): that is evidence. A picked
        // quality asks at the long stall, and Auto lowers without sending the
        // reader's share; it sends what the link delivered to both readers
        // when the device counted it. A bound at the bitrate is no evidence.
        let sharedLink: [(String, Int, Int?, [Harness.Recorded])] = [
            ("original", 4_500, nil, [.init(16_000, .pillShown(.prompt))]),
            ("auto", 4_500, nil, [.init(16_000, .replan(Self.autoLowering(44_100)))]),
            ("auto", 2_500, 4_900, [.init(16_000, .replan(Self.autoLowering(44_100, observed: 4_900)))]),
            ("original", 63_000, nil, []),
        ]
        for (quality, bound, link, expected) in sharedLink {
            let h = Harness(mode: .always)
            h.arrivalLowerBoundKbps = bound
            h.linkKbps = link
            h.at(0) {
                $0.planAdopted(Self.plan("p1", quality: quality))
                $0.waiting()
            }
            h.clock.advance(to: 20_000)
            XCTAssertEqual(h.shown, expected, "\(quality) \(bound) \(link as Any)")
        }

        // The start's plan, lowered on evidence; its lower plan comes back
        // 7 s later and never starts either. It lowers again only on its
        // own evidence, once its undo pill is gone.
        let cascade: [(measured: Int?, expected: [Harness.Recorded])] = [
            (nil, []),
            (10_000, []),
            (3_000, [.init(38_000, .replan(Self.autoLowering(7_000, observed: 3_000)))]),
        ]
        for (measured, expected) in cascade {
            let h = Harness(mode: .always)
            h.measuredKbps = 20_000
            h.at(0) {
                $0.planAdopted(Self.plan("p1"))
                $0.waiting()
            }
            h.at(23_000) { $0.planAdopted(Self.plan("p2", delivered: 10_000)) }
            h.measuredKbps = measured
            h.clock.advance(to: 68_000)
            XCTAssertEqual(h.shown, [
                .init(16_000, .replan(Self.autoLowering(44_100, observed: 20_000))),
                .init(23_000, .pillShown(.undo)),
            ] + expected, "\(measured as Any)")
        }

        // A slow start with no evidence: its first frame lowers nothing, and
        // the stall after it is the plan's first counted one.
        let slowStart = Harness(mode: .always)
        slowStart.at(0) {
            $0.planAdopted(Self.plan("p1"))
            $0.waiting()
        }
        slowStart.at(25_000) { $0.playing() }
        slowStart.at(60_000) { $0.waiting() }
        slowStart.at(62_000) { $0.playing() }
        slowStart.at(70_000) { $0.planEnded() }
        XCTAssertEqual(slowStart.shown, [])
        XCTAssertEqual(slowStart.summaries.map(\.stallCount), [1])

        let played = Harness(mode: .always)
        played.startPlaying(Self.plan("p1"))
        played.at(125_000) { $0.waiting() }
        played.clock.advance(to: 131_000)
        XCTAssertEqual(played.shown, [.init(131_000, .replan(Self.autoLowering(44_100)))])
    }

    /// On Auto in `always`, a plan that never became playable within the
    /// player's own deadline, its media measured arriving below its
    /// delivered bitrate, lowers as a long stall would, the lowering's own
    /// plan included, whose loading is a reload (gauntlet T5/A2). Otherwise
    /// the player's failure recovery keeps it; each case would lower without
    /// its own rule.
    func testAStartDeadlineLowersAutoInAlways() {
        // An outage during the lower plan's load ended `LONG_STALL_MS` before
        // the deadline: time enough for a fair run.
        func lowerPlanAtItsDeadline() -> Harness {
            let h = Harness(mode: .always)
            h.startPlaying(Self.plan("p1"))
            h.at(125_000) { $0.waiting() }
            h.at(133_000) { $0.waiting(cause: .reload) }
            h.at(134_000) { $0.planAdopted(Self.plan("p2", delivered: 31_600)) }
            h.at(150_000) { $0.transportTroubleChanged(true) }
            h.at(173_000) { $0.transportTroubleChanged(false) }
            h.clock.advance(to: 179_000)
            return h
        }
        let h = lowerPlanAtItsDeadline()
        h.measuredKbps = 18_000
        XCTAssertTrue(h.controller.startDeadlinePassed())
        XCTAssertEqual(h.shown.last, .init(179_000, .replan(Self.autoLowering(22_120, observed: 18_000))))
        // No evidence the link is slow: nothing measured, or media that
        // arrived at the delivered bitrate.
        for measured in [nil, 31_600] {
            let h = lowerPlanAtItsDeadline()
            h.measuredKbps = measured
            let shown = h.shown.count
            XCTAssertFalse(h.controller.startDeadlinePassed(), "\(measured as Any)")
            XCTAssertEqual(h.shown.count, shown, "\(measured as Any)")
        }

        let auto = Self.plan("p1", delivered: 6_000)
        let leftToRecovery: [(String, BufferingQualityMode, Controller.Plan, (Harness) -> Void)] = [
            ("ask first", .ask, auto, { _ in }),
            ("never", .never, auto, { _ in }),
            ("kept, then Automatically", .ask, auto, { h in
                h.at(17_000) { c in
                    c.selectKeep()
                    c.mode = .always
                }
            }),
            ("a picked quality", .always, Self.plan("p1", delivered: 6_000, quality: "1080p-medium"), { _ in }),
            ("no lower rung", .always, Self.plan("p1", delivered: 3_000), { _ in }),
            ("a Watch Party", .always, auto, { h in h.at(1_000) { $0.isSuspended = true } }),
            ("an outage", .always, auto, { h in h.at(1_000) { $0.transportTroubleChanged(true) } }),
            ("an outage that ended 3 s before", .always, auto, { h in
                h.at(1_000) { $0.transportTroubleChanged(true) }
                h.at(42_000) { $0.transportTroubleChanged(false) }
            }),
            ("a renderer wait", .always, auto, { h in h.at(1_000) { $0.waiting(cause: .renderer) } }),
            ("a lowering no plan answered", .always, auto, { h in h.at(17_000) { $0.replanFailed() } }),
            ("the no-lower cooldown", .always, auto, { h in
                h.at(18_000) {
                    $0.planAdopted(Self.plan("p2", delivered: 6_000))
                    $0.waiting()
                }
            }),
        ]
        for (name, mode, plan, meanwhile) in leftToRecovery {
            let h = Harness(mode: mode)
            h.measuredKbps = 2_000
            h.at(0) {
                $0.planAdopted(plan)
                $0.waiting()
            }
            meanwhile(h)
            h.clock.advance(to: 45_000)
            let shown = h.shown.count
            XCTAssertFalse(h.controller.startDeadlinePassed(), name)
            XCTAssertEqual(h.shown.count, shown, name)
        }

        // Restore answers the title as Keep does (gauntlet T8: the restored
        // source never started on a slow link).
        let restored = Harness(mode: .always)
        restored.measuredKbps = 2_000
        restored.lowerAutomatically()
        restored.at(140_000) { $0.selectRestore() }
        restored.at(141_000) { $0.waiting(cause: .reload) }
        restored.at(142_000) {
            $0.planAdopted(Self.plan("p3"))
            $0.waiting()
        }
        restored.at(187_000) { XCTAssertFalse($0.startDeadlinePassed(), "restored") }
    }

    /// The running summary is the plan's summary as if it ended now, kept on
    /// the device in case the app ends first. The plan plays on.
    func testTheRunningSummaryLeavesThePlanPlaying() {
        let h = Harness(mode: .never)
        h.startPlaying(Self.plan("p1"))
        h.at(30_000) { $0.waiting() }
        h.at(36_000) { $0.playing() }
        h.at(40_000) { $0.waiting() }
        var running: [Controller.PlanSummary?] = []
        h.at(45_000) { running = [$0.runningSummary, $0.runningSummary] }
        XCTAssertTrue(h.summaries.isEmpty, "nothing is sent")
        XCTAssertEqual(running[0], running[1])
        h.at(45_000) { $0.planEnded() }
        XCTAssertEqual(h.summaries, [running[0]].compactMap { $0 }, "including the stall still running")
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

    /// A new attempt between a lowering and the player refusing to send it
    /// discards the kept estimate for good: the refusal restores nothing.
    func testARefusedLoweringAfterANewAttemptRestoresNoEstimate() {
        let h = Harness(mode: .always)
        h.lowerAutomatically()
        XCTAssertEqual(h.controller.keptEstimateKbps, 44_100)
        h.at(200_000) { $0.waiting() }
        h.at(207_000) { _ in }
        XCTAssertEqual(h.controller.keptEstimateKbps, 22_120, "the second lowering's estimate")
        h.at(207_000) {
            $0.newAttempt()
            $0.replanRefused()
        }
        XCTAssertNil(h.controller.keptEstimateKbps)
    }

    /// A wait noticed late after a pause is not backdated into the pause.
    func testABackdatedWaitStaysOutOfAPause() {
        let h = Harness(mode: .never)
        h.startPlaying(Self.plan("p1"))
        h.at(30_000) { $0.paused() }
        h.at(40_000) { $0.waiting(cause: .network, startedAgoMs: 12_000) }
        h.at(41_000) { $0.playing() }
        h.at(50_000) { $0.planEnded() }
        XCTAssertEqual(h.summaries.map(\.stallTotalMs), [1_000], "timed from 40000, not from inside the pause")
        XCTAssertEqual(h.summaries.map(\.playedMs), [30_000 + 9_000])
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
        // The vectors' waits are a link too slow for every plan: each plan's
        // media is measured arriving below its bitrate.
        h.measuredKbps = 1
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

    fileprivate static let ladder: [Controller.QualityRung] = [
        .init(label: "original", bitrateKbps: 63_000),
        .init(label: "1080p-high", bitrateKbps: 10_000),
        .init(label: "1080p-medium", bitrateKbps: 6_000),
        .init(label: "720p-high", bitrateKbps: 4_000),
    ]

    fileprivate static func plan(
        _ id: String,
        delivered: Int? = 63_000,
        quality: String = "auto",
        rungs: [Controller.QualityRung] = ladder
    ) -> Controller.Plan {
        .init(id: id, deliveredKbps: delivered, quality: quality, availableQualities: rungs, qualityReductionUnavailable: false)
    }

    private static func autoLowering(_ estimate: Int, observed: Int? = nil) -> Controller.ReplanRequest {
        .init(
            qualityPreference: "auto", bandwidthEstimateKbps: estimate, bandwidthEstimateSource: "observed_rebuffer",
            observedThroughputKbps: observed
        )
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
    /// What the player measures the playing plan's media arriving at.
    var measuredKbps: Int?
    /// The evidence-only bound of a shared link.
    var arrivalLowerBoundKbps: Int?
    /// What the link delivered, every reader included.
    var linkKbps: Int?

    init(mode: BufferingQualityMode) {
        controller = BufferingQualityController(clock: clock)
        controller.mode = mode
        controller.sendsBufferingQualityFields = true
        controller.onOutput = { [unowned self] output in
            self.outputs.append(Recorded(self.clock.nowMs, output))
        }
        controller.measuredThroughputKbps = { [unowned self] in self.measuredKbps }
        controller.arrivalLowerBoundKbps = { [unowned self] in self.arrivalLowerBoundKbps }
        controller.linkThroughputKbps = { [unowned self] in self.linkKbps }
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
        startPlaying(BufferingQualityControllerTests.plan("p1"))
        at(125_000) { $0.waiting() }
        at(134_000) {
            $0.planAdopted(BufferingQualityControllerTests.plan("p2", delivered: 31_600))
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
    var elapsedMs: Int { nowMs }

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
        /// The viewer's quality pick is sent, or the player refuses it.
        case pickSent, pickRefused
        case newAttempt
    }

    static let knownTypes = [
        "plan_adopted", "playing", "waiting", "pause", "seek", "transport_error_start",
        "transport_error_end", "replan_failed", "select_lower", "select_keep", "select_restore", "back",
        "pill_obscured", "pill_unobscured", "client_replan", "quality_changed", "pick_sent", "pick_refused",
        "new_attempt",
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
        case "pick_sent": kind = .pickSent
        case "pick_refused": kind = .pickRefused
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
        case .pickSent: controller.pickSent()
        case .pickRefused: controller.pickRefused()
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
            activeQuality: object["active_quality"] as? String,
            availableQualities: try rungs.map { rung in
                guard let label = rung["label"] as? String,
                      let bitrate = rung["bitrate_kbps"] as? Int else {
                    throw VectorError.malformed("\(caseName): quality keys")
                }
                return .init(label: label, bitrateKbps: bitrate)
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

private extension BufferingQualityController.ReplanRequest {
    /// The request body as the vectors write it: `operation` and every
    /// present field, snake_case.
    var wireBody: [String: Any] {
        var body: [String: Any] = ["operation": operation, "quality_preference": qualityPreference]
        if let bandwidthEstimateKbps { body["bandwidth_estimate_kbps"] = bandwidthEstimateKbps }
        if let bandwidthEstimateSource { body["bandwidth_estimate_source"] = bandwidthEstimateSource }
        if let learnedLimit { body["learned_limit"] = learnedLimit }
        return body
    }
}
