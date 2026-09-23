import XCTest
@testable import Silo

final class OnboardingInvitationTests: XCTestCase {
    private var stub = OnboardingRequestStub()

    override func setUp() {
        super.setUp()
        stub = OnboardingRequestStub()
    }

    func testOnboardingSurfaceUsesAQueryItemInsteadOfEmbeddingQueryInPath() async throws {
        let (http, tokenStore) = await makeHTTPClient(activeURL: "https://active.example/silo")
        let api = SiloAPI(http: http, tokenStore: tokenStore)

        let flow = try await api.onboardingFlow(surface: "phone")
        XCTAssertEqual(flow.tourId, "tour-test")

        let request = try XCTUnwrap(stub.requests().last)
        XCTAssertEqual(request.url?.path, "/silo/api/v1/onboarding/flow")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems, [URLQueryItem(name: "surface", value: "phone")])
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

    @MainActor
    func testStepsWithRetiredSettingTargetsAreDroppedAtLoad() async {
        let profileStep = Self.settingStep(id: "quality", target: "profile_field", key: "quality_preference")
        let userStep = Self.settingStep(id: "user", target: "setting", key: "playback.auto_play_next")
        let deviceStep = Self.settingStep(id: "device", target: "device_setting", key: "playback.quality")
        let api = OnboardingTourAPIStub(flow: Self.flow(steps: [userStep, profileStep, deviceStep]))
        let model = OnboardingTourViewModel(api: api, activeProfileId: { "profile-1" })

        await model.load()

        XCTAssertEqual(model.steps.map(\.id), ["quality"])
        XCTAssertFalse(model.finished)
    }

    @MainActor
    func testChoosingARetiredSettingTargetWritesNothing() async {
        let api = OnboardingTourAPIStub()
        let model = OnboardingTourViewModel(api: api, activeProfileId: { "profile-1" })
        let step = Self.settingStep(id: "user", target: "setting", key: "playback.auto_play_next")

        await model.choose(step: step, value: "true")

        let events = await api.events()
        XCTAssertEqual(events, [])
        XCTAssertNil(model.selectedValues["user"])
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testFailedSettingWriteStaysVisibleAndDoesNotSelectValue() async {
        let api = OnboardingTourAPIStub(failWrites: true)
        let model = OnboardingTourViewModel(api: api, activeProfileId: { "profile-1" })
        let step = Self.settingStep(id: "failed", target: "profile_field", key: "auto_skip_intro")

        await model.choose(step: step, value: "true")

        XCTAssertNil(model.selectedValues["failed"])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.finished)
    }

    @MainActor
    func testUnrenderableFlowDismissesWhenCompletionPostFails() async {
        let api = OnboardingTourAPIStub(failProgress: true)
        let model = OnboardingTourViewModel(api: api)

        await model.load()

        XCTAssertTrue(model.finished)
        XCTAssertTrue(model.steps.isEmpty)
    }

    @MainActor
    func testFinishingFinalSettingStepPersistsDisplayedDefaultFirst() async {
        let step = Self.settingStep(
            id: "final-default",
            target: "profile_field",
            key: "auto_skip_intro",
            defaultValue: "true"
        )
        let api = OnboardingTourAPIStub(flow: Self.flow(steps: [step]))
        let model = OnboardingTourViewModel(
            api: api,
            runtimeSettingsRefresher: OnboardingRuntimeSettingsRefresherStub(),
            activeProfileId: { "profile-1" }
        )

        await model.load()
        XCTAssertTrue(model.isToggleEnabled(for: step))
        await model.finish()

        let events = await api.events()
        XCTAssertEqual(events, [
            "profile:profile-1",
            "progress:final-default:completed",
        ])
        XCTAssertEqual(model.selectedValues[step.id], "true")
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testContinueWithoutSavingPostsCompletionBeforeDismissal() async {
        let step = Self.settingStep(
            id: "failed-setting",
            target: "profile_field",
            key: "auto_skip_intro"
        )
        let api = OnboardingTourAPIStub(failWrites: true, flow: Self.flow(steps: [step]))
        let model = OnboardingTourViewModel(api: api, activeProfileId: { "profile-1" })

        await model.load()
        await model.choose(step: step, value: "true")
        await model.continueWithoutSaving()

        let events = await api.events()
        XCTAssertEqual(events, ["progress:failed-setting:completed"])
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testLoadResumesAtTheServerRecordedStep() async {
        let first = Self.welcomeStep(id: "welcome")
        let second = Self.welcomeStep(id: "features")
        let api = OnboardingTourAPIStub(flow: Self.flow(steps: [first, second]))
        let model = OnboardingTourViewModel(api: api)

        await model.load(resumeStepId: second.id)

        XCTAssertEqual(model.currentIndex, 1)
    }

    @MainActor
    func testProfileWriteRefreshesRuntimeStateAndRecapRemainsUnsupported() async {
        let runtime = OnboardingRuntimeSettingsRefresherStub()
        let api = OnboardingTourAPIStub()
        let model = OnboardingTourViewModel(
            api: api,
            runtimeSettingsRefresher: runtime,
            activeProfileId: { "profile-1" }
        )
        let intro = Self.settingStep(
            id: "intro",
            target: "profile_field",
            key: "auto_skip_intro"
        )

        await model.choose(step: intro, value: "true")

        let updatesAfterIntro = await api.profileUpdates()
        XCTAssertEqual(updatesAfterIntro, ["profile-1"])
        XCTAssertEqual(runtime.refreshes, ["auto_skip_intro=true"])

        let recap = Self.settingStep(
            id: "recap",
            target: "profile_field",
            key: "auto_skip_recap"
        )
        await model.choose(step: recap, value: "true")

        XCTAssertNotNil(model.error)
        let updatesAfterRecap = await api.profileUpdates()
        XCTAssertEqual(updatesAfterRecap, ["profile-1"])
        XCTAssertEqual(runtime.refreshes, ["auto_skip_intro=true"])
    }

    private static func flow(steps: [OnboardingStep]) -> OnboardingFlow {
        OnboardingFlow(version: 1, tourId: "tour", steps: steps)
    }

    private static func welcomeStep(id: String) -> OnboardingStep {
        OnboardingStep(
            id: id,
            kind: "welcome",
            title: id,
            body: nil,
            illustration: nil,
            setting: nil,
            route: nil,
            actionLabel: nil
        )
    }

    private static func settingStep(
        id: String,
        target: String,
        key: String,
        defaultValue: String? = nil
    ) -> OnboardingStep {
        OnboardingStep(
            id: id,
            kind: "setting_choice",
            title: nil,
            body: nil,
            illustration: nil,
            setting: OnboardingSettingSpec(
                target: target,
                key: key,
                control: "toggle",
                options: nil,
                default: defaultValue,
                label: nil
            ),
            route: nil,
            actionLabel: nil
        )
    }

    private func makeHTTPClient(activeURL: String) async -> (HTTPClient, TokenStore) {
        let suiteName = "onboarding-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "OnboardingInvitationTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.setServerUrl(activeURL)
        await tokenStore.switchActiveServer(serverId: "active")
        await tokenStore.saveTokens(accessToken: "existing-access", refreshToken: "existing-refresh")

        return (
            HTTPClient(session: stub.handler.makeSession(), tokenStore: tokenStore),
            tokenStore
        )
    }
}

private actor OnboardingTourAPIStub: OnboardingTourAPI {
    private var recordedEvents: [String] = []
    private var recordedProfileUpdates: [String] = []
    private let failWrites: Bool
    private let failProgress: Bool
    private let flow: OnboardingFlow

    init(
        failWrites: Bool = false,
        failProgress: Bool = false,
        flow: OnboardingFlow = OnboardingFlow(version: 1, tourId: "tour", steps: [])
    ) {
        self.failWrites = failWrites
        self.failProgress = failProgress
        self.flow = flow
    }

    func events() -> [String] { recordedEvents }
    func profileUpdates() -> [String] { recordedProfileUpdates }

    func onboardingFlow(surface: String) async throws -> OnboardingFlow {
        flow
    }

    func postOnboardingProgress(_ request: OnboardingProgressRequest) async throws {
        if failProgress { throw URLError(.cannotConnectToHost) }
        let disposition = request.skipped ? "skipped" : request.completed ? "completed" : "progress"
        recordedEvents.append("progress:\(request.lastStep ?? "none"):\(disposition)")
    }
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {
        if failWrites { throw URLError(.cannotConnectToHost) }
        recordedProfileUpdates.append(profileId)
        recordedEvents.append("profile:\(profileId)")
    }
}

@MainActor
private final class OnboardingRuntimeSettingsRefresherStub: OnboardingRuntimeSettingsRefreshing {
    private(set) var refreshes: [String] = []

    func refreshAfterProfileWrite(key: String, value: String) async {
        refreshes.append("\(key)=\(value)")
    }
}

/// The onboarding flow endpoint as a route on the shared stub; anything
/// else answers 500.
private final class OnboardingRequestStub {
    let handler = StubURLProtocol.Handler()

    init() {
        handler.route(StubURLProtocol.pathSuffix("/api/v1/onboarding/flow")) { _ in
            .json(#"{"version":1,"tour_id":"tour-test","steps":[]}"#)
        }
        handler.route(StubURLProtocol.any) { _ in
            .json("", status: 500)
        }
    }

    func requests() -> [URLRequest] {
        handler.requests.map(\.underlying)
    }
}
