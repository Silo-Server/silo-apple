import SwiftUI

#if !os(tvOS)
/// Platform-neutral state for the iOS full-screen cover and macOS sheet.
/// A completed request is committed only if the same profile is still active,
/// preventing a slow response from presenting a stale profile's tour.
@Observable
@MainActor
final class OnboardingTourGateModel {
    var showTour = false
    var resumeStepId: String?
    private var checkedProfileId: String?

    func check(profileId: String?) async {
        guard let profileId else {
            checkedProfileId = nil
            showTour = false
            resumeStepId = nil
            return
        }
        guard checkedProfileId != profileId else { return }

        checkedProfileId = profileId
        showTour = false
        resumeStepId = nil

        if let serverId = ServerRegistry.shared.activeServerId,
           let tourId = UnrenderableOnboardingTourSuppression.pendingTourId(
               serverId: serverId,
               profileId: profileId
           ) {
            do {
                try await ContinuumAPI.shared.postOnboardingProgress(OnboardingProgressRequest(
                    tourId: tourId,
                    lastStep: nil,
                    completed: true,
                    skipped: false
                ))
                UnrenderableOnboardingTourSuppression.clear(
                    serverId: serverId,
                    profileId: profileId,
                    tourId: tourId
                )
            } catch {
                // Keep suppressing the empty UI and retry this completion on
                // the next authenticated launch.
            }
            return
        }

        if await consumeLegacyInviteTourSuppressionIfNeeded() {
            return
        }

        let state = try? await ContinuumAPI.shared.onboardingState()
        guard !Task.isCancelled,
              AuthService.shared.profileId == profileId else { return }
        guard let state, !state.done else { return }
        resumeStepId = state.lastStep
        showTour = true
    }

    func dismiss() {
        showTour = false
    }

    /// Finishes consuming an account-bound preference written by older builds.
    /// No current flow creates this marker; it remains only for upgrade safety.
    private func consumeLegacyInviteTourSuppressionIfNeeded() async -> Bool {
        guard let serverId = ServerRegistry.shared.activeServerId,
              let expectedUserId = LegacyInviteTourSuppression.pendingUserId(for: serverId) else {
            return false
        }

        do {
            let user = try await ContinuumAPI.shared.currentUser()
            guard user.id == expectedUserId else {
                LegacyInviteTourSuppression.clear(
                    serverId: serverId,
                    userId: expectedUserId
                )
                return false
            }

            let flow = try await ContinuumAPI.shared.onboardingFlow(surface: "phone")
            try await ContinuumAPI.shared.postOnboardingProgress(OnboardingProgressRequest(
                tourId: flow.tourId,
                lastStep: nil,
                completed: false,
                skipped: true
            ))
            LegacyInviteTourSuppression.clear(
                serverId: serverId,
                userId: expectedUserId
            )
            return true
        } catch {
            // Preserve the marker and retry on the next authenticated launch.
            return true
        }
    }
}
#endif
