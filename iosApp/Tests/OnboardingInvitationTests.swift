import XCTest
@testable import Silo

final class OnboardingInvitationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OnboardingRequestStubProtocol.reset()
    }

    func testOnboardingSurfaceUsesAQueryItemInsteadOfEmbeddingQueryInPath() async throws {
        let (http, tokenStore) = await makeHTTPClient(activeURL: "https://active.example/silo")
        let api = ContinuumAPI(http: http, tokenStore: tokenStore)

        let flow = try await api.onboardingFlow(surface: "phone")
        XCTAssertEqual(flow.tourId, "tour-test")

        let request = try XCTUnwrap(OnboardingRequestStubProtocol.requests().last)
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
    func testSettingTargetsAreAwaitedAndDispatchedToTheirOwnEndpoints() async throws {
        let api = OnboardingTourAPIStub()
        let model = OnboardingTourViewModel(api: api)

        let userStep = Self.settingStep(id: "user", target: "setting", key: "playback.auto_play_next")
        await model.choose(step: userStep, value: "true")
        let deviceStep = Self.settingStep(id: "device", target: "device_setting", key: "playback.quality")
        await model.choose(step: deviceStep, value: "1080p")

        let writes = await api.writes()
        XCTAssertEqual(writes, [
            "setting:playback.auto_play_next=true",
            "device:playback.quality=1080p",
        ])
        XCTAssertEqual(model.selectedValues["user"], "true")
        XCTAssertEqual(model.selectedValues["device"], "1080p")
        XCTAssertNil(model.error)
    }

    @MainActor
    func testFailedSettingWriteStaysVisibleAndDoesNotSelectValue() async {
        let api = OnboardingTourAPIStub(failWrites: true)
        let model = OnboardingTourViewModel(api: api)
        let step = Self.settingStep(id: "failed", target: "setting", key: "playback.auto_play_next")

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
            target: "setting",
            key: "playback.auto_play_next",
            defaultValue: "true"
        )
        let api = OnboardingTourAPIStub(flow: Self.flow(steps: [step]))
        let model = OnboardingTourViewModel(api: api)

        await model.load()
        XCTAssertTrue(model.isToggleEnabled(for: step))
        await model.finish()

        let events = await api.events()
        XCTAssertEqual(events, [
            "setting:playback.auto_play_next=true",
            "progress:final-default:completed",
        ])
        XCTAssertEqual(model.selectedValues[step.id], "true")
        XCTAssertTrue(model.finished)
    }

    @MainActor
    func testContinueWithoutSavingPostsCompletionBeforeDismissal() async {
        let step = Self.settingStep(
            id: "failed-setting",
            target: "setting",
            key: "playback.auto_play_next"
        )
        let api = OnboardingTourAPIStub(failWrites: true, flow: Self.flow(steps: [step]))
        let model = OnboardingTourViewModel(api: api)

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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingRequestStubProtocol.self]
        return (
            HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokenStore),
            tokenStore
        )
    }
}

private actor OnboardingTourAPIStub: OnboardingTourAPI {
    private var recordedWrites: [String] = []
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

    func writes() -> [String] { recordedWrites }
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

    func setSetting(key: String, value: String) async throws {
        if failWrites { throw URLError(.cannotConnectToHost) }
        recordedWrites.append("setting:\(key)=\(value)")
        recordedEvents.append("setting:\(key)=\(value)")
    }

    func setDeviceSetting(key: String, value: String) async throws {
        if failWrites { throw URLError(.cannotConnectToHost) }
        recordedWrites.append("device:\(key)=\(value)")
        recordedEvents.append("device:\(key)=\(value)")
    }
}

@MainActor
private final class OnboardingRuntimeSettingsRefresherStub: OnboardingRuntimeSettingsRefreshing {
    private(set) var refreshes: [String] = []

    func refreshAfterProfileWrite(key: String, value: String) async {
        refreshes.append("\(key)=\(value)")
    }
}

private final class OnboardingRequestStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []

    static func reset() {
        lock.withLock { recordedRequests = [] }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.recordedRequests.append(request) }
        let path = request.url?.path ?? ""
        let status: Int
        let body: Data
        if path.hasSuffix("/api/v1/onboarding/flow") {
            status = 200
            body = Data(#"{"version":1,"tour_id":"tour-test","steps":[]}"#.utf8)
        } else {
            status = 500
            body = Data()
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
