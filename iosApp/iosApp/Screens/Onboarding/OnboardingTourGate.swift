import SwiftUI
import os

#if !os(tvOS)
/// Platform-neutral state for the iOS full-screen cover and macOS sheet.
/// A completed request is committed only if the same profile is still active,
/// preventing a slow response from presenting a stale profile's tour.
///
/// The tour opens only when the server confirms the active profile's tour is
/// not done. Any error, including an update-required server, a revoked
/// session or a changed profile, leaves it closed until the next check.
@Observable
@MainActor
final class OnboardingTourGateModel {
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "onboarding")

    var showTour = false
    var resumeStepId: String?
    private var checkedProfileId: String?
    private let api: any OnboardingTourAPI
    private let activeServerId: @MainActor () -> String?
    private let activeProfileId: @MainActor () -> String?

    init(
        api: any OnboardingTourAPI = SiloAPI.shared,
        activeServerId: @escaping @MainActor () -> String? = { ServerRegistry.shared.activeServerId },
        activeProfileId: @escaping @MainActor () -> String? = { AuthService.shared.profileId }
    ) {
        self.api = api
        self.activeServerId = activeServerId
        self.activeProfileId = activeProfileId
    }

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

        if let serverId = activeServerId(),
           let tourId = UnrenderableOnboardingTourSuppression.pendingTourId(
               serverId: serverId,
               profileId: profileId
           ) {
            await completeUnrenderableTour(tourId, serverId: serverId, profileId: profileId)
            return
        }

        if await consumeLegacyInviteTourSuppressionIfNeeded(profileId: profileId) {
            return
        }

        let state: OnboardingState
        do {
            let session = try await api.onboardingRead(surface: nil)
            guard session.auth.profileId == profileId else { return }
            state = session.state
        } catch {
            Self.logger.error("Onboarding state read failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard !Task.isCancelled,
              activeProfileId() == profileId,
              !state.done else { return }
        resumeStepId = state.lastStep
        showTour = true
    }

    func dismiss() {
        showTour = false
    }

    /// Retries the completion of a tour this client could not render. The
    /// state is read first, so a completion whose reply was lost earlier is
    /// seen as done instead of being sent again. The empty tour stays
    /// suppressed until the server confirms it is done or replaced.
    private func completeUnrenderableTour(_ tourId: String, serverId: String, profileId: String) async {
        do {
            let session = try await api.onboardingRead(surface: nil)
            guard session.auth.profileId == profileId else { return }
            if session.state.tourId == tourId, !session.state.done {
                _ = try await api.onboardingWrite(
                    OnboardingProgressRequest(tourId: tourId, lastStep: nil, completed: true, skipped: false),
                    session: session
                )
            }
            UnrenderableOnboardingTourSuppression.clear(
                serverId: serverId,
                profileId: profileId,
                tourId: tourId
            )
        } catch {
            Self.logger.error("Onboarding completion retry failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Finishes consuming an account-bound preference written by older builds.
    /// No current flow creates this marker; it remains only for upgrade safety.
    /// Returns true while the marker still applies, so the tour stays closed
    /// when the skip could not be confirmed.
    private func consumeLegacyInviteTourSuppressionIfNeeded(profileId: String) async -> Bool {
        guard let serverId = activeServerId(),
              let expectedUserId = LegacyInviteTourSuppression.pendingUserId(for: serverId) else {
            return false
        }

        do {
            let userId = try await api.currentAccountId()
            guard userId == expectedUserId else {
                LegacyInviteTourSuppression.clear(
                    serverId: serverId,
                    userId: expectedUserId
                )
                return false
            }

            let session = try await api.onboardingRead(surface: nil)
            guard session.auth.profileId == profileId else { return true }
            if !session.state.done {
                _ = try await api.onboardingWrite(
                    OnboardingProgressRequest(
                        tourId: session.state.tourId,
                        lastStep: nil,
                        completed: false,
                        skipped: true
                    ),
                    session: session
                )
            }
            LegacyInviteTourSuppression.clear(
                serverId: serverId,
                userId: expectedUserId
            )
            return true
        } catch {
            // Keep the marker and the tour closed. The next check reads the
            // state again before it writes.
            Self.logger.error("Onboarding legacy skip failed: \(String(describing: error), privacy: .public)")
            return true
        }
    }
}
#endif
