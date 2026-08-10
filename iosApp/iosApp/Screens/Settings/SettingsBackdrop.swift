import SwiftUI

/// Quiet atmospheric backdrop shared by the native Settings experiences.
/// It mirrors the web app's dark canvas and restrained blue signal glow
/// without competing with controls or reducing text contrast.
struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color.continuumBackground

            RadialGradient(
                colors: [
                    Color.continuumAccent.opacity(0.14),
                    Color(hex: "#162235").opacity(0.07),
                    .clear,
                ],
                center: UnitPoint(x: 0.82, y: 0.04),
                startRadius: 0,
                endRadius: 620
            )

            RadialGradient(
                colors: [
                    Color.continuumBrandOrange.opacity(0.045),
                    .clear,
                ],
                center: UnitPoint(x: 0.08, y: 0.72),
                startRadius: 0,
                endRadius: 440
            )

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.4)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
