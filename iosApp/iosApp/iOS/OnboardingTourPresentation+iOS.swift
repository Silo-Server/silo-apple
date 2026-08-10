import SwiftUI

#if os(iOS)
private struct OnboardingTourGateModifier: ViewModifier {
    var router: AppRouter
    @State private var model = OnboardingTourGateModel()

    func body(content: Content) -> some View {
        content
            .task(id: AuthService.shared.profileId) {
                await model.check(profileId: AuthService.shared.profileId)
            }
            .fullScreenCover(isPresented: $model.showTour) {
                OnboardingTourView(
                    router: router,
                    resumeStepId: model.resumeStepId,
                    onDismiss: model.dismiss
                )
            }
    }
}

extension View {
    func onboardingTourGate(router: AppRouter) -> some View {
        modifier(OnboardingTourGateModifier(router: router))
    }

    func onboardingPageStyle() -> some View {
        tabViewStyle(.page(indexDisplayMode: .never))
    }
}
#endif
