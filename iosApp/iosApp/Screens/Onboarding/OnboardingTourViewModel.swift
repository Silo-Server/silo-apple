import Foundation

#if !os(tvOS)
/// Drives the server-driven first-run tour. setting_choice steps write
/// through the existing profile-update path immediately, so by the last
/// step the profile is genuinely configured.
@Observable
class OnboardingTourViewModel {
    /// Step kinds this client can render; anything else is dropped at load.
    private static let knownKinds: Set<String> = ["welcome", "feature_card", "setting_choice", "handoff"]

    var isLoading: Bool = true
    var steps: [OnboardingStep] = []
    var currentIndex: Int = 0
    var finished: Bool = false
    /// Chosen setting values keyed by step id (UI selection state).
    var selectedValues: [String: String] = [:]

    private var tourId: String = ""
    private let api = ContinuumAPI.shared

    func load() async {
        // Already done (any device) → straight through to Home. Any error
        // also skips: the tour must never block first run.
        do {
            let state = try await api.onboardingState()
            if state.done {
                finished = true
                return
            }
        } catch {
            finished = true
            return
        }
        do {
            let flow = try await api.onboardingFlow(surface: "phone")
            let renderable = flow.steps.filter { Self.knownKinds.contains($0.kind) }
            if renderable.isEmpty {
                // Nothing we can show: mark complete so we never loop.
                try? await api.postOnboardingProgress(OnboardingProgressRequest(
                    tourId: flow.tourId, lastStep: nil, completed: true, skipped: false))
                finished = true
                return
            }
            tourId = flow.tourId
            steps = renderable
            isLoading = false
        } catch {
            finished = true
        }
    }

    func advance() {
        let next = currentIndex + 1
        guard next < steps.count else {
            finish()
            return
        }
        let stepId = steps[next].id
        Task {
            try? await api.postOnboardingProgress(OnboardingProgressRequest(
                tourId: tourId, lastStep: stepId, completed: false, skipped: false))
        }
        currentIndex = next
    }

    func back() {
        currentIndex = max(0, currentIndex - 1)
    }

    func skip() { end(skipped: true) }

    func finish() { end(skipped: false) }

    private func end(skipped: Bool) {
        let lastStep = steps.indices.contains(currentIndex) ? steps[currentIndex].id : nil
        let id = tourId
        Task {
            try? await ContinuumAPI.shared.postOnboardingProgress(OnboardingProgressRequest(
                tourId: id, lastStep: lastStep, completed: !skipped, skipped: skipped))
        }
        finished = true
    }

    /// Writes one setting_choice value through the profile-update API.
    /// Unknown keys (a newer server) no-op rather than failing the tour.
    func choose(step: OnboardingStep, value: String) {
        selectedValues[step.id] = value
        guard let spec = step.setting, spec.target == "profile_field" else { return }
        guard let profileId = AuthService.shared.profileId else { return }

        var body = UpdateProfileBody()
        switch spec.key {
        case "quality_preference": body.qualityPreference = value
        case "subtitle_language": body.subtitleLanguage = value
        case "subtitle_mode": body.subtitleMode = value
        default: return
        }
        Task {
            try? await ContinuumAPI.shared.updateProfile(profileId: profileId, body: body)
        }
    }
}
#endif
