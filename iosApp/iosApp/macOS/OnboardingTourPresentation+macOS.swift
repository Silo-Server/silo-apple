import SwiftUI

#if os(macOS)
private struct OnboardingTourGateModifier: ViewModifier {
    var router: AppRouter
    @State private var model = OnboardingTourGateModel()

    func body(content: Content) -> some View {
        content
            .task(id: AuthService.shared.profileId) {
                await model.check(profileId: AuthService.shared.profileId)
            }
            .sheet(isPresented: $model.showTour) {
                OnboardingTourView(router: router, onDismiss: model.dismiss)
                    .frame(minWidth: 560, minHeight: 640)
            }
    }
}

extension View {
    func onboardingTourGate(router: AppRouter) -> some View {
        modifier(OnboardingTourGateModifier(router: router))
    }

    func onboardingPageStyle() -> some View { self }
}
#endif
