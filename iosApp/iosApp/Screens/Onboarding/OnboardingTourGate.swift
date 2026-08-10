import SwiftUI

#if !os(tvOS)
/// Platform-neutral state for the iOS full-screen cover and macOS sheet.
/// A completed request is committed only if the same profile is still active,
/// preventing a slow response from presenting a stale profile's tour.
@Observable
@MainActor
final class OnboardingTourGateModel {
    var showTour = false
    private var checkedProfileId: String?

    func check(profileId: String?) async {
        guard let profileId else {
            checkedProfileId = nil
            showTour = false
            return
        }
        guard checkedProfileId != profileId else { return }

        checkedProfileId = profileId
        showTour = false

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

        if OnboardingTourSuppression.applies(to: ServerRegistry.shared.activeServerId) {
            do {
                let flow = try await ContinuumAPI.shared.onboardingFlow(surface: "phone")
                try await ContinuumAPI.shared.postOnboardingProgress(OnboardingProgressRequest(
                    tourId: flow.tourId,
                    lastStep: nil,
                    completed: false,
                    skipped: true
                ))
                OnboardingTourSuppression.clear()
            } catch {
                // Keep the durable hint for a future authenticated launch.
            }
            return
        }

        let state = try? await ContinuumAPI.shared.onboardingState()
        guard !Task.isCancelled,
              AuthService.shared.profileId == profileId else { return }
        showTour = state.map { !$0.done } ?? false
    }

    func dismiss() {
        showTour = false
    }
}
#endif
