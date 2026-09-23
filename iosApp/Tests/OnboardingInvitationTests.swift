import XCTest
@testable import Silo

final class OnboardingInvitationTests: XCTestCase {
    private var server = OnboardingServerStub()

    override func setUp() {
        super.setUp()
        server = OnboardingServerStub()
    }

    func testLegacyInviteTourSuppressionRemainsAccountBoundDuringMigration() throws {
        let suiteName = "legacy-tour-suppression-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let record = try JSONSerialization.data(withJSONObject: [
            "serverId": "server-a",
            "userId": "user-a",
        ])
        defaults.set(record, forKey: "onboardingTourSuppressedAccount.v2")

        XCTAssertEqual(
            LegacyInviteTourSuppression.pendingUserId(for: "server-a", defaults: defaults),
            "user-a"
        )
        XCTAssertNil(LegacyInviteTourSuppression.pendingUserId(for: "server-b", defaults: defaults))

        LegacyInviteTourSuppression.clear(
            serverId: "server-a",
            userId: "user-a",
            defaults: defaults
        )
        XCTAssertNil(LegacyInviteTourSuppression.pendingUserId(for: "server-a", defaults: defaults))
    }

    // MARK: Tour

    @MainActor
    func testStepsWithRetiredSettingTargetsAreDroppedAtLoad() async throws {
        server.setFlow(steps: Self.steps([
            Self.settingStep(id: "user", target: "setting", key: "playback.auto_play_next"),
            Self.settingStep(id: "quality", target: "profile_field", key: "quality_preference"),
            Self.settingStep(id: "device", target: "device_setting", key: "playback.quality"),
        ]))
        let model = try await makeModel()

        await model.load()

        XCTAssertEqual(model.steps.map(\.id), ["quality"])
        XCTAssertFalse(model.finished)
    }

    @MainActor
    func testChoosingARetiredSettingTargetWritesNothing() async throws {
        server.setFlow(steps: Self.steps([Self.welcomeStep(id: "welcome")]))
        let model = try await makeModel()
        await model.load()
        let step = Self.step(Self.settingStep(id: "user", target: "setting", key: "playback.auto_play_next"))

        await model.choose(step: step, value: "true")

        XCTAssertEqual(server.events, [])
        XCTAssertNil(model.selectedValues["user"])
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testFailedSettingWriteStaysVisibleAndDoesNotSelectValue() async throws {
        let failed = Self.settingStep(id: "failed", target: "profile_field", key: "auto_skip_intro")
        server.setFlow(steps: Self.steps([failed]))
        let model = try await makeModel(failProfileWrites: true)
        await model.load()

        await model.choose(step: Self.step(failed), value: "true")

        XCTAssertNil(model.selectedValues["failed"])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.finished)
    }

    @MainActor
    func testUnrenderableFlowDismissesWhenCompletionWriteFails() async throws {
        server.failNextWrite()
        let model = try await makeModel()

        await model.load()

        XCTAssertTrue(model.finished)
        XCTAssertTrue(model.steps.isEmpty)
        XCTAssertEqual(server.requestLines.last, "PUT /api/v2/onboarding/progress")
        // The retry marker keeps the empty tour closed until the gate
        // confirms the completion.
        XCTAssertEqual(
            UnrenderableOnboardingTourSuppression.pendingTourId(serverId: "onboarding-server", profileId: "profile-1"),
            server.tourId
        )
        UnrenderableOnboardingTourSuppression.clear(serverId: "onboarding-server", profileId: "profile-1", tourId: server.tourId)
    }

    @MainActor
    func testFinishingFinalSettingStepPersistsDisplayedDefaultFirst() async throws {
        let step = Self.settingStep(
            id: "final-default",
            target: "profile_field",
            key: "auto_skip_intro",
            defaultValue: "true"
        )
        server.setFlow(steps: Self.steps([step]))
        let model = try await makeModel()

        await model.load()
        XCTAssertTrue(model.isToggleEnabled(for: Self.step(step)))
        await model.finish()

        XCTAssertEqual(server.events, [
            "profile:profile-1",
            "progress:final-default:completed",
        ])
        XCTAssertEqual(model.selectedValues["final-default"], "true")
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testContinueWithoutSavingPostsCompletionBeforeDismissal() async throws {
        let step = Self.settingStep(id: "failed-setting", target: "profile_field", key: "auto_skip_intro")
        server.setFlow(steps: Self.steps([step]))
        let model = try await makeModel(failProfileWrites: true)

        await model.load()
        await model.choose(step: Self.step(step), value: "true")
        await model.continueWithoutSaving()

        XCTAssertEqual(server.events, ["progress:failed-setting:completed"])
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testLoadResumesAtTheServerRecordedStep() async throws {
        server.setFlow(steps: Self.steps([Self.welcomeStep(id: "welcome"), Self.welcomeStep(id: "features")]))
        let model = try await makeModel()

        await model.load(resumeStepId: "features")

        XCTAssertEqual(model.currentIndex, 1)
    }

    @MainActor
    func testProfileWriteRefreshesRuntimeStateAndRecapRemainsUnsupported() async throws {
        let intro = Self.settingStep(id: "intro", target: "profile_field", key: "auto_skip_intro")
        server.setFlow(steps: Self.steps([intro]))
        let runtime = OnboardingRuntimeSettingsRefresherStub()
        let model = try await makeModel(runtime: runtime)
        await model.load()

        await model.choose(step: Self.step(intro), value: "true")

        XCTAssertEqual(server.events, ["profile:profile-1"])
        XCTAssertEqual(runtime.refreshes, ["auto_skip_intro=true"])

        let recap = Self.settingStep(id: "recap", target: "profile_field", key: "auto_skip_recap")
        await model.choose(step: Self.step(recap), value: "true")

        XCTAssertNotNil(model.error)
        XCTAssertEqual(server.events, ["profile:profile-1"])
        XCTAssertEqual(runtime.refreshes, ["auto_skip_intro=true"])
    }

    @MainActor
    func testProfileWriteIsRefusedOnceAnotherProfileIsActive() async throws {
        let intro = Self.settingStep(id: "intro", target: "profile_field", key: "auto_skip_intro")
        server.setFlow(steps: Self.steps([intro]))
        let model = try await makeModel(activeProfileId: "profile-2")
        await model.load()

        await model.choose(step: Self.step(intro), value: "true")

        XCTAssertEqual(server.events, [])
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testEachWriteSendsTheTagOfTheReceiptBeforeIt() async throws {
        server.setFlow(steps: Self.steps([
            Self.welcomeStep(id: "welcome"), Self.welcomeStep(id: "features"), Self.welcomeStep(id: "done"),
        ]))
        let model = try await makeModel()
        await model.load()

        await model.advance()
        await model.advance()

        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(server.requestLines, [
            "GET /api/v2/onboarding/state",
            "GET /api/v2/onboarding/flow",
            "PUT /api/v2/onboarding/progress",
            "PUT /api/v2/onboarding/progress",
        ])
        XCTAssertEqual(server.requests.suffix(2).map { $0.header("if-match") }, [#""r1""#, #""r2""#])
    }

    @MainActor
    func testLostWriteReplyIsNotResentAndTheNextStepReadsTheStateFirst() async throws {
        server.setFlow(steps: Self.steps([
            Self.welcomeStep(id: "welcome"), Self.welcomeStep(id: "features"), Self.welcomeStep(id: "done"),
        ]))
        let model = try await makeModel()
        await model.load()
        server.dropNextWriteReply()

        await model.advance()

        XCTAssertNotNil(model.error, "an uncertain write is surfaced, not replayed")
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1)

        await model.advance()

        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(Array(server.requestLines.suffix(3)), [
            "PUT /api/v2/onboarding/progress",
            "GET /api/v2/onboarding/state",
            "PUT /api/v2/onboarding/progress",
        ])
        XCTAssertEqual(server.requests.last?.header("if-match"), #""r2""#, "the fresh read's tag, not the spent one")
    }

    @MainActor
    func testStaleWriteThenReadShowingTheTourDoneClosesWithoutWriting() async throws {
        server.setFlow(steps: Self.steps([Self.welcomeStep(id: "welcome"), Self.welcomeStep(id: "features")]))
        let model = try await makeModel()
        await model.load()
        server.finishElsewhere()

        await model.advance()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.finished)

        await model.skip()

        XCTAssertTrue(model.finished)
        XCTAssertNil(model.completionRoute)
        XCTAssertEqual(server.events, [])
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1, "only the refused write was sent")
    }

    @MainActor
    func testFinishWhoseReplyWasLostOpensTheChosenRouteOnRetry() async throws {
        server.setFlow(steps: Self.steps([Self.welcomeStep(id: "welcome"), Self.featureStep(id: "search", route: "search")]))
        let model = try await makeModel()
        await model.load(resumeStepId: "search")
        server.dropNextWriteReply()

        await model.finish(route: "search")
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.finished)

        await model.finish(route: "search")

        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.completionRoute, "search", "the finish landed; its navigation still applies")
        XCTAssertEqual(server.events, ["progress:search:completed"])
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1)
    }

    @MainActor
    func testLastStepWhoseReplyWasLostOpensItsRouteOnRetry() async throws {
        server.setFlow(steps: Self.steps([Self.featureStep(id: "search", route: "search")]))
        let model = try await makeModel()
        await model.load()
        server.dropNextWriteReply()

        await model.advance()
        XCTAssertFalse(model.finished)
        await model.advance()

        XCTAssertTrue(model.finished)
        XCTAssertEqual(model.completionRoute, "search")
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1)
    }

    @MainActor
    func testWriteForAReplacedTourClosesTheTour() async throws {
        server.setFlow(steps: Self.steps([Self.welcomeStep(id: "welcome"), Self.featureStep(id: "search", route: "search")]))
        let model = try await makeModel()
        await model.load()
        server.replaceTour()

        await model.advance()

        XCTAssertTrue(model.finished, "a 409 means no progress for this tour can be saved")
        XCTAssertNil(model.completionRoute)
        XCTAssertEqual(server.events, [])
        XCTAssertEqual(server.requestLines.filter { $0.hasPrefix("PUT") }.count, 1)
    }

    @MainActor
    func testReadShowingAReplacedTourClosesTheTourWithoutWriting() async throws {
        server.setFlow(steps: Self.steps([Self.welcomeStep(id: "welcome"), Self.welcomeStep(id: "features")]))
        let model = try await makeModel()
        await model.load()
        server.failNextWrite()
        await model.advance()
        XCTAssertFalse(model.finished)
        server.replaceTour()

        await model.skip()

        XCTAssertTrue(model.finished)
        XCTAssertEqual(server.events, [])
        XCTAssertEqual(Array(server.requestLines.suffix(2)), [
            "PUT /api/v2/onboarding/progress",
            "GET /api/v2/onboarding/state",
        ])
    }

    @MainActor
    func testContinueWithoutSavingClosesTheTourWhenProgressCannotBeSaved() async throws {
        server.setFlow(steps: Self.steps([Self.featureStep(id: "search", route: "search")]))
        let model = try await makeModel()
        await model.load()
        server.failNextWrite()

        await model.continueWithoutSaving()

        XCTAssertTrue(model.finished)
        XCTAssertNil(model.completionRoute, "an unsaved finish does not navigate")
        XCTAssertEqual(server.events, [])
    }

    // MARK: Gate

    @MainActor
    func testGateKeepsTheTourClosedWhenTheStateReadFails() async throws {
        server.failStateReads(with: OnboardingServerStub.problem(503, "unavailable"))
        let gate = try await makeGate()

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state"])
    }

    @MainActor
    func testGateKeepsTheTourClosedOnAServerThatNeedsAnUpdate() async throws {
        let gate = try await makeGate(isUpdateRequired: true)

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.requests.count, 0)
    }

    @MainActor
    func testGatePresentsOnlyATourTheServerConfirmsIsUnfinished() async throws {
        server.setState(lastStep: "features", done: false)
        let open = try await makeGate()
        await open.check(profileId: "profile-1")
        XCTAssertTrue(open.showTour)
        XCTAssertEqual(open.resumeStepId, "features")

        server.setState(lastStep: "features", done: true)
        let done = try await makeGate()
        await done.check(profileId: "profile-1")
        XCTAssertFalse(done.showTour)
    }

    @MainActor
    func testGateRetryOfAnUnrenderableTourReadsTheStateBeforeWriting() async throws {
        let serverId = "onboarding-gate-\(UUID().uuidString)"
        UnrenderableOnboardingTourSuppression.set(serverId: serverId, profileId: "profile-1", tourId: server.tourId)
        addTeardownBlock {
            UnrenderableOnboardingTourSuppression.clear(serverId: serverId, profileId: "profile-1", tourId: "tour")
        }
        // The earlier completion landed even though its reply was lost.
        server.setState(lastStep: nil, done: true)
        let gate = try await makeGate(serverId: serverId)

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state"])
        XCTAssertNil(UnrenderableOnboardingTourSuppression.pendingTourId(serverId: serverId, profileId: "profile-1"))
    }

    @MainActor
    func testGateRetryCompletesAnUnfinishedUnrenderableTourUnderTheReadTag() async throws {
        let serverId = "onboarding-gate-\(UUID().uuidString)"
        UnrenderableOnboardingTourSuppression.set(serverId: serverId, profileId: "profile-1", tourId: server.tourId)
        addTeardownBlock {
            UnrenderableOnboardingTourSuppression.clear(serverId: serverId, profileId: "profile-1", tourId: "tour")
        }
        let gate = try await makeGate(serverId: serverId)

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.events, ["progress:none:completed"])
        XCTAssertEqual(server.requests.last?.header("if-match"), #""r1""#)
        XCTAssertNil(UnrenderableOnboardingTourSuppression.pendingTourId(serverId: serverId, profileId: "profile-1"))
    }

    @MainActor
    func testGateLegacyInviteSkipWritesUnderTheReadTagAndClearsTheMarker() async throws {
        let serverId = seedLegacyInviteMarker(userId: "user-a")
        let gate = try await makeGate(serverId: serverId)

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.events, ["progress:none:skipped"])
        XCTAssertEqual(server.requests.last?.header("if-match"), #""r1""#)
        XCTAssertNil(LegacyInviteTourSuppression.pendingUserId(for: serverId))
    }

    @MainActor
    func testGateLegacyInviteSkipOfAFinishedTourWritesNothing() async throws {
        let serverId = seedLegacyInviteMarker(userId: "user-a")
        server.setState(lastStep: nil, done: true)
        let gate = try await makeGate(serverId: serverId)

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state"])
        XCTAssertNil(LegacyInviteTourSuppression.pendingUserId(for: serverId))
    }

    @MainActor
    func testGateLegacyInviteSkipKeepsTheTourClosedAndTheMarkerWhenTheReadFails() async throws {
        let serverId = seedLegacyInviteMarker(userId: "user-a")
        server.failStateReads(with: OnboardingServerStub.problem(503, "unavailable"))
        let gate = try await makeGate(serverId: serverId)

        await gate.check(profileId: "profile-1")

        XCTAssertFalse(gate.showTour)
        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state"])
        XCTAssertEqual(LegacyInviteTourSuppression.pendingUserId(for: serverId), "user-a")
    }

    @MainActor
    func testGateDropsALegacyInviteMarkerForAnotherAccountAndChecksNormally() async throws {
        let serverId = seedLegacyInviteMarker(userId: "user-b")
        let gate = try await makeGate(serverId: serverId)

        await gate.check(profileId: "profile-1")

        XCTAssertTrue(gate.showTour)
        XCTAssertEqual(server.requestLines, ["GET /api/v2/onboarding/state"])
        XCTAssertNil(LegacyInviteTourSuppression.pendingUserId(for: serverId))
    }

    // MARK: Helpers

    @MainActor
    private func makeModel(
        failProfileWrites: Bool = false,
        runtime: OnboardingRuntimeSettingsRefresherStub? = nil,
        activeProfileId: String = "profile-1"
    ) async throws -> OnboardingTourViewModel {
        let api = try await makeAPI(failProfileWrites: failProfileWrites)
        return OnboardingTourViewModel(
            api: api,
            runtimeSettingsRefresher: runtime ?? OnboardingRuntimeSettingsRefresherStub(),
            activeProfileId: { activeProfileId }
        )
    }

    @MainActor
    private func makeGate(
        serverId: String = "onboarding-gate-none",
        isUpdateRequired: Bool = false
    ) async throws -> OnboardingTourGateModel {
        let api = try await makeAPI(isUpdateRequired: isUpdateRequired)
        return OnboardingTourGateModel(
            api: api,
            activeServerId: { serverId },
            activeProfileId: { "profile-1" }
        )
    }

    private func makeAPI(
        failProfileWrites: Bool = false,
        isUpdateRequired: Bool = false
    ) async throws -> OnboardingTestAPI {
        let tokens = try await OnboardingServerStub.tokenStore(testCase: self)
        let http = HTTPClient(session: server.makeSession(), tokenStore: tokens)
        return OnboardingTestAPI(
            client: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { isUpdateRequired }),
            server: server,
            failProfileWrites: failProfileWrites
        )
    }

    /// Seeds an older build's invite-skip record for a fresh server id and
    /// removes it after the test.
    private func seedLegacyInviteMarker(userId: String) -> String {
        let serverId = "onboarding-gate-\(UUID().uuidString)"
        let record = try! JSONSerialization.data(withJSONObject: ["serverId": serverId, "userId": userId])
        SharedDefaults.shared.set(record, forKey: "onboardingTourSuppressedAccount.v2")
        addTeardownBlock {
            LegacyInviteTourSuppression.clear(serverId: serverId, userId: userId)
        }
        return serverId
    }

    private static func steps(_ steps: [String]) -> String {
        "[\(steps.joined(separator: ","))]"
    }

    private static func step(_ json: String) -> OnboardingStep {
        try! HTTPClient.makeJSONDecoder().decode(OnboardingStep.self, from: Data(json.utf8))
    }

    private static func welcomeStep(id: String) -> String {
        #"{"id":"\#(id)","kind":"welcome","title":"\#(id)"}"#
    }

    private static func featureStep(id: String, route: String) -> String {
        #"{"id":"\#(id)","kind":"feature_card","title":"\#(id)","route":"\#(route)"}"#
    }

    private static func settingStep(
        id: String,
        target: String,
        key: String,
        defaultValue: String? = nil
    ) -> String {
        let defaultMember = defaultValue.map { #","default":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","kind":"setting_choice","setting":{"target":"\#(target)","key":"\#(key)","control":"toggle"\#(defaultMember)}}"#
    }
}

/// The real v2 onboarding operations over the stub server. Profile writes
/// stay on their own path (outside this test) and are recorded in the
/// server's event list so their order against progress writes is visible.
private struct OnboardingTestAPI: OnboardingTourAPI {
    let client: APIv2Client
    let server: OnboardingServerStub
    let failProfileWrites: Bool

    func onboardingRead(surface: String?) async throws -> APIv2OnboardingSession {
        try await client.onboardingRead(surface: surface)
    }

    func onboardingWrite(
        _ request: OnboardingProgressRequest,
        session: APIv2OnboardingSession
    ) async throws -> APIv2OnboardingSession {
        try await client.onboardingWrite(request, session: session)
    }

    func currentAccountId() async throws -> String { "user-a" }

    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {
        if failProfileWrites { throw URLError(.cannotConnectToHost) }
        server.record("profile:\(profileId)")
    }
}

@MainActor
private final class OnboardingRuntimeSettingsRefresherStub: OnboardingRuntimeSettingsRefreshing {
    private(set) var refreshes: [String] = []

    func refreshAfterProfileWrite(key: String, value: String) async {
        refreshes.append("\(key)=\(value)")
    }
}
