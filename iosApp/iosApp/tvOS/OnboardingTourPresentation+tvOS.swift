import SwiftUI

#if os(tvOS)
extension View {
    /// The focus-driven 10-foot renderer remains a separate surface.
    func onboardingTourGate(router: AppRouter) -> some View { self }
}
#endif
