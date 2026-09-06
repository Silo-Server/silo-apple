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
           UnrenderableOnboardingTourSuppression.pendingTourId(
               serverId: serverId,
               profileId: profileId
           ) != nil {
            // This local suppression is not a receipt authorizing another write.
            return
        }

        if await consumeLegacyInviteTourSuppressionIfNeeded() {
            return
        }

        let state = try? await SiloAPI.shared.onboardingState()
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
            let user = try await SiloAPI.shared.currentUser()
            guard user.id == expectedUserId else {
                LegacyInviteTourSuppression.clear(
                    serverId: serverId,
                    userId: expectedUserId
                )
                return false
            }

            let flow = try await SiloAPI.shared.onboardingFlow(surface: "phone")
            // Consume the legacy preference before dispatch so uncertainty
            // cannot turn the next launch into an automatic replay.
            LegacyInviteTourSuppression.clear(serverId: serverId, userId: expectedUserId)
            try await SiloAPI.shared.postOnboardingProgress(OnboardingProgressRequest(
                tourId: flow.tourId,
                lastStep: nil,
                completed: false,
                skipped: true,
                writerID: flow.writerID
            ))
            LegacyInviteTourSuppression.clear(
                serverId: serverId,
                userId: expectedUserId
            )
            return true
        } catch {
            // Never repeat a dispatched skip. Before dispatch the legacy preference remains.
            return true
        }
    }
}
#endif
