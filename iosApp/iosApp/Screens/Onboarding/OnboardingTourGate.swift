import SwiftUI

#if !os(tvOS)
/// Presents the first-run tour over the authenticated UI when the active
/// profile has never completed or skipped it. State is server-side per
/// profile, so finishing on any device (web, Android, here) silences the
/// rest. Errors and "already done" both mean: show nothing.
struct OnboardingTourGate: ViewModifier {
    var router: AppRouter
    @State private var showTour = false
    @State private var checkedProfileId: String?

    func body(content: Content) -> some View {
        content
            .task(id: AuthService.shared.profileId) {
                guard let profileId = AuthService.shared.profileId else { return }
                guard checkedProfileId != profileId else { return }
                checkedProfileId = profileId
                if let state = try? await ContinuumAPI.shared.onboardingState(), !state.done {
                    showTour = true
                }
            }
            #if os(macOS)
            // macOS has no fullScreenCover; a sheet is the platform-correct
            // modal for a one-time walkthrough.
            .sheet(isPresented: $showTour) {
                OnboardingTourView(router: router, onDismiss: { showTour = false })
                    .frame(minWidth: 560, minHeight: 640)
            }
            #else
            .fullScreenCover(isPresented: $showTour) {
                OnboardingTourView(router: router, onDismiss: { showTour = false })
            }
            #endif
    }
}

extension View {
    /// Attach to the authenticated root so a first-run profile gets the tour.
    func onboardingTourGate(router: AppRouter) -> some View {
        modifier(OnboardingTourGate(router: router))
    }
}

#else

extension View {
    /// tvOS follow-up: the manifest already carries surface=tv; the 10-foot
    /// renderer lands separately. No-op keeps the call site uniform.
    func onboardingTourGate(router: AppRouter) -> some View { self }
}

#endif
