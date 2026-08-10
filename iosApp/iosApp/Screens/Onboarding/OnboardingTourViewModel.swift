import Foundation

#if !os(tvOS)
protocol OnboardingTourAPI: Sendable {
    func onboardingFlow(surface: String) async throws -> OnboardingFlow
    func postOnboardingProgress(_ request: OnboardingProgressRequest) async throws
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws
    func setSetting(key: String, value: String) async throws
    func setDeviceSetting(key: String, value: String) async throws
}

extension ContinuumAPI: OnboardingTourAPI {}

private enum OnboardingTourError: LocalizedError {
    case unsupportedSetting(String)
    case missingProfile

    var errorDescription: String? {
        switch self {
        case .unsupportedSetting(let key):
            return "This version of Silo cannot save the \(key) setting yet."
        case .missingProfile:
            return "Select a profile before saving this setting."
        }
    }
}

/// Drives the server-driven first-run tour. setting_choice steps write
/// through the existing profile-update path immediately, so by the last
/// step the profile is genuinely configured.
@Observable
@MainActor
class OnboardingTourViewModel {
    /// Step kinds this client can render; anything else is dropped at load.
    private static let knownKinds: Set<String> = ["welcome", "feature_card", "setting_choice", "handoff"]

    var isLoading: Bool = true
    var steps: [OnboardingStep] = []
    var currentIndex: Int = 0
    var finished: Bool = false
    var isSaving: Bool = false
    var error: String?
    var completionRoute: String?
    /// Chosen setting values keyed by step id (UI selection state).
    var selectedValues: [String: String] = [:]

    private var tourId: String = ""
    private let api: any OnboardingTourAPI
    private let runtimeSettingsRefresher: any OnboardingRuntimeSettingsRefreshing
    private let activeProfileId: @MainActor () -> String?

    init(
        api: any OnboardingTourAPI = ContinuumAPI.shared,
        runtimeSettingsRefresher: (any OnboardingRuntimeSettingsRefreshing)? = nil,
        activeProfileId: @escaping @MainActor () -> String? = { AuthService.shared.profileId }
    ) {
        self.api = api
        self.runtimeSettingsRefresher = runtimeSettingsRefresher
            ?? OnboardingRuntimeSettingsRefresher()
        self.activeProfileId = activeProfileId
    }

    func load(resumeStepId: String? = nil) async {
        do {
            let flow = try await api.onboardingFlow(surface: "phone")
            let renderable = flow.steps.filter { Self.knownKinds.contains($0.kind) }
            if renderable.isEmpty {
                // Nothing we can show: dismiss now and persist a retry marker
                // before posting completion so a transient failure cannot
                // reopen an empty modal on every launch.
                let serverId = ServerRegistry.shared.activeServerId
                let profileId = AuthService.shared.profileId
                if let serverId, let profileId {
                    UnrenderableOnboardingTourSuppression.set(
                        serverId: serverId,
                        profileId: profileId,
                        tourId: flow.tourId
                    )
                }
                do {
                    try await api.postOnboardingProgress(OnboardingProgressRequest(
                        tourId: flow.tourId,
                        lastStep: nil,
                        completed: true,
                        skipped: false
                    ))
                    if let serverId, let profileId {
                        UnrenderableOnboardingTourSuppression.clear(
                            serverId: serverId,
                            profileId: profileId,
                            tourId: flow.tourId
                        )
                    }
                } catch {
                    // The durable marker makes the gate retry without showing
                    // an empty tour, so dismissal is still safe here.
                }
                finished = true
                return
            }
            tourId = flow.tourId
            steps = renderable
            if let resumeStepId,
               let resumeIndex = renderable.firstIndex(where: { $0.id == resumeStepId }) {
                currentIndex = resumeIndex
            }
            isLoading = false
        } catch {
            finished = true
        }
    }

    func advance() async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        do {
            try await persistDefaultForCurrentStepIfNeeded()
        } catch {
            self.error = error.localizedDescription
            return
        }

        let next = currentIndex + 1
        guard next < steps.count else {
            let lastStep = steps.indices.contains(currentIndex) ? steps[currentIndex].id : nil
            do {
                try await api.postOnboardingProgress(OnboardingProgressRequest(
                    tourId: tourId,
                    lastStep: lastStep,
                    completed: true,
                    skipped: false
                ))
                completionRoute = currentStepRoute
                finished = true
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        let stepId = steps[next].id
        do {
            try await api.postOnboardingProgress(OnboardingProgressRequest(
                tourId: tourId,
                lastStep: stepId,
                completed: false,
                skipped: false
            ))
            currentIndex = next
        } catch {
            self.error = error.localizedDescription
        }
    }

    func back() {
        currentIndex = max(0, currentIndex - 1)
    }

    func skip() async { await end(skipped: true, route: nil) }

    func finish(route: String? = nil) async {
        await end(skipped: false, route: route ?? currentStepRoute)
    }

    private func end(
        skipped: Bool,
        route: String?,
        persistCurrentDefault: Bool = true
    ) async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let lastStep = steps.indices.contains(currentIndex) ? steps[currentIndex].id : nil
        do {
            if !skipped, persistCurrentDefault {
                try await persistDefaultForCurrentStepIfNeeded()
            }
            try await api.postOnboardingProgress(OnboardingProgressRequest(
                tourId: tourId,
                lastStep: lastStep,
                completed: !skipped,
                skipped: skipped
            ))
            completionRoute = skipped ? nil : route
            finished = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func continueWithoutSaving() async {
        await end(
            skipped: false,
            route: currentStepRoute,
            persistCurrentDefault: false
        )
    }

    /// Writes one setting-choice value through its declared API. Unknown
    /// targets or keys remain visible as a recoverable error.
    func choose(step: OnboardingStep, value: String) async {
        guard !isSaving, let spec = step.setting else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        do {
            try await writeSetting(spec: spec, value: value)
            selectedValues[step.id] = value
        } catch {
            self.error = error.localizedDescription
        }
    }

    func isToggleEnabled(for step: OnboardingStep) -> Bool {
        guard let spec = step.setting else { return false }
        let value = selectedValues[step.id] ?? spec.default ?? "false"
        return (try? boolean(value, key: spec.key)) ?? false
    }

    private var currentStepRoute: String? {
        steps.indices.contains(currentIndex) ? steps[currentIndex].route : nil
    }

    private func persistDefaultForCurrentStepIfNeeded() async throws {
        guard steps.indices.contains(currentIndex) else { return }
        let step = steps[currentIndex]
        guard step.kind == "setting_choice",
              selectedValues[step.id] == nil,
              let spec = step.setting,
              let value = spec.default else { return }
        try await writeSetting(spec: spec, value: value)
        selectedValues[step.id] = value
    }

    private func writeSetting(spec: OnboardingSettingSpec, value: String) async throws {
        switch spec.target {
        case "profile_field":
            guard let profileId = activeProfileId() else {
                throw OnboardingTourError.missingProfile
            }

            var body = UpdateProfileBody()
            switch spec.key {
            case "quality_preference": body.qualityPreference = value
            case "subtitle_language": body.subtitleLanguage = value
            case "subtitle_mode": body.subtitleMode = value
            case "auto_skip_intro": body.autoSkipIntro = try boolean(value, key: spec.key)
            case "auto_skip_credits": body.autoSkipCredits = try boolean(value, key: spec.key)
            default: throw OnboardingTourError.unsupportedSetting(spec.key)
            }
            try await api.updateProfile(profileId: profileId, body: body)
            await runtimeSettingsRefresher.refreshAfterProfileWrite(
                key: spec.key,
                value: value
            )
        case "setting":
            try await api.setSetting(key: spec.key, value: value)
        case "device_setting":
            try await api.setDeviceSetting(key: spec.key, value: value)
        default:
            throw OnboardingTourError.unsupportedSetting(spec.key)
        }
    }

    private func boolean(_ value: String, key: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw OnboardingTourError.unsupportedSetting(key)
        }
    }
}
#endif
