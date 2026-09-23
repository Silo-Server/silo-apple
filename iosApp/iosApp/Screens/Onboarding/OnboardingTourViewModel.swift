import Foundation
import os

#if !os(tvOS)
/// The v2 onboarding operations the tour and its gate use. Progress writes
/// are `non_retryable` and guarded by the state's `ETag`: every write names
/// the session from the read or receipt it follows.
protocol OnboardingTourAPI: Sendable {
    /// Reads the active profile's tour state, plus the flow for `surface`.
    func onboardingRead(surface: String?) async throws -> APIv2OnboardingSession
    /// Sends one progress write under `session`'s owner and tag and returns
    /// the receipt, which is the only session the next write may use.
    func onboardingWrite(
        _ request: OnboardingProgressRequest,
        session: APIv2OnboardingSession
    ) async throws -> APIv2OnboardingSession
    /// The signed-in account's id, as `GET /api/v2/account/me` reports it.
    func currentAccountId() async throws -> String
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws
}

extension SiloAPI: OnboardingTourAPI {
    nonisolated func onboardingRead(surface: String?) async throws -> APIv2OnboardingSession {
        try await apiV2Client.onboardingRead(surface: surface)
    }

    nonisolated func onboardingWrite(
        _ request: OnboardingProgressRequest,
        session: APIv2OnboardingSession
    ) async throws -> APIv2OnboardingSession {
        try await apiV2Client.onboardingWrite(request, session: session)
    }

    nonisolated func currentAccountId() async throws -> String {
        try await apiV2Client.currentUser().id
    }
}

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
///
/// Progress follows the v2 failure model for a `non_retryable` write. A
/// write is sent once, under the tag of the state read or receipt it follows.
/// A failed, refused (412/428/409) or unanswered write leaves no tag, so the
/// next write the user starts reads the state again first. If that read
/// shows the tour already finished elsewhere, the tour closes instead.
@Observable
@MainActor
class OnboardingTourViewModel {
    /// Step kinds this client can render; anything else is dropped at load.
    private static let knownKinds: Set<String> = ["welcome", "feature_card", "setting_choice", "handoff"]
    /// The only setting target this client can save. The server emits only
    /// `profile_field`; a `setting_choice` step naming any other target is
    /// dropped at load like an unknown kind, because it could not be saved.
    private static let supportedSettingTarget = "profile_field"
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "onboarding")

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
    /// The owner that loaded the tour. Later reads, progress writes and
    /// profile writes act only while it is still the active owner.
    private var tourOwner: CapturedOrdinaryRequestAuth?
    /// Whether the server already recorded the tour as done when it loaded,
    /// as it does for a replay from Settings.
    private var loadedDone = false
    /// The latest state read or receipt, whose tag the next progress write
    /// sends. Taken before every dispatch, so no tag is ever sent twice.
    private var session: APIv2OnboardingSession?
    private let api: any OnboardingTourAPI
    private let runtimeSettingsRefresher: any OnboardingRuntimeSettingsRefreshing
    private let activeProfileId: @MainActor () -> String?

    init(
        api: any OnboardingTourAPI = SiloAPI.shared,
        runtimeSettingsRefresher: (any OnboardingRuntimeSettingsRefreshing)? = nil,
        activeProfileId: @escaping @MainActor () -> String? = { AuthService.shared.profileId }
    ) {
        self.api = api
        self.runtimeSettingsRefresher = runtimeSettingsRefresher
            ?? OnboardingRuntimeSettingsRefresher()
        self.activeProfileId = activeProfileId
    }

    func load(resumeStepId: String? = nil) async {
        let loaded: APIv2OnboardingSession
        do {
            loaded = try await api.onboardingRead(surface: "phone")
        } catch {
            Self.logger.error("Onboarding tour load failed: \(String(describing: error), privacy: .public)")
            finished = true
            return
        }
        guard let flow = loaded.flow else {
            finished = true
            return
        }
        let renderable = flow.steps.filter(Self.isRenderable)
        if renderable.isEmpty {
            await completeUnrenderableTour(flow.tourId, session: loaded)
            finished = true
            return
        }
        tourId = flow.tourId
        tourOwner = loaded.auth
        loadedDone = loaded.state.done
        session = loaded
        steps = renderable
        if let resumeStepId,
           let resumeIndex = renderable.firstIndex(where: { $0.id == resumeStepId }) {
            currentIndex = resumeIndex
        }
        isLoading = false
    }

    /// Nothing can be shown: dismiss now and persist a retry marker before
    /// sending completion, so a failed write cannot reopen an empty modal on
    /// every launch. The gate retries after reading the state again.
    private func completeUnrenderableTour(_ tourId: String, session: APIv2OnboardingSession) async {
        // The marker belongs to the owner that read this tour.
        let serverId = session.auth.account.serverId.isEmpty ? nil : session.auth.account.serverId
        let profileId = session.auth.profileId
        if let serverId, let profileId {
            UnrenderableOnboardingTourSuppression.set(
                serverId: serverId,
                profileId: profileId,
                tourId: tourId
            )
        }
        do {
            if !session.state.done {
                _ = try await api.onboardingWrite(
                    OnboardingProgressRequest(tourId: tourId, lastStep: nil, completed: true, skipped: false),
                    session: session
                )
            }
            if let serverId, let profileId {
                UnrenderableOnboardingTourSuppression.clear(
                    serverId: serverId,
                    profileId: profileId,
                    tourId: tourId
                )
            }
        } catch {
            Self.logger.error("Onboarding completion for an empty tour failed: \(String(describing: error), privacy: .public)")
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
                if try await sendProgress(lastStep: lastStep, completed: true, skipped: false) == .saved {
                    completionRoute = currentStepRoute
                }
                finished = true
            } catch {
                report(error)
            }
            return
        }
        let stepId = steps[next].id
        do {
            switch try await sendProgress(lastStep: stepId, completed: false, skipped: false) {
            case .saved: currentIndex = next
            case .finishedElsewhere: finished = true
            }
        } catch {
            report(error)
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
            if try await sendProgress(lastStep: lastStep, completed: !skipped, skipped: skipped) == .saved {
                completionRoute = skipped ? nil : route
            }
            finished = true
        } catch {
            report(error)
        }
    }

    private enum ProgressOutcome {
        case saved
        /// A re-read found the tour finished on another device or by an
        /// earlier write whose reply was lost; nothing was sent.
        case finishedElsewhere
    }

    /// Sends one progress write. The held session is taken before dispatch;
    /// without one, the state is read again first under the tour's owner.
    private func sendProgress(lastStep: String?, completed: Bool, skipped: Bool) async throws -> ProgressOutcome {
        let held = session
        session = nil
        let current: APIv2OnboardingSession
        if let held {
            current = held
        } else {
            let fresh = try await api.onboardingRead(surface: nil)
            guard let tourOwner, fresh.auth.sameCredentialIdentity(as: tourOwner) else {
                throw HTTPError.requestIdentityChanged
            }
            guard fresh.state.tourId == tourId else { throw OnboardingProgressError.tourChanged }
            if fresh.state.done, !loadedDone { return .finishedElsewhere }
            current = fresh
        }
        session = try await api.onboardingWrite(
            OnboardingProgressRequest(tourId: tourId, lastStep: lastStep, completed: completed, skipped: skipped),
            session: current
        )
        return .saved
    }

    private func report(_ error: Error) {
        Self.logger.error("Onboarding tour save failed: \(String(describing: error), privacy: .public)")
        self.error = error.localizedDescription
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
        case Self.supportedSettingTarget:
            // Only the profile that loaded the tour may be changed by it.
            guard let profileId = activeProfileId(), profileId == tourOwner?.profileId else {
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
        default:
            throw OnboardingTourError.unsupportedSetting(spec.key)
        }
    }

    private static func isRenderable(_ step: OnboardingStep) -> Bool {
        guard knownKinds.contains(step.kind) else { return false }
        guard step.kind == "setting_choice", let target = step.setting?.target else { return true }
        return target == supportedSettingTarget
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
