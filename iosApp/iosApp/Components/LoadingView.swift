import SwiftUI

/// Full-screen loading indicator.
struct LoadingView: View {
    var message: String? = nil
    var usesPageBackground = false

    var body: some View {
        ZStack {
            if usesPageBackground {
                SiloPageBackdrop()
            } else {
                Color.siloBackground.ignoresSafeArea()
            }

            VStack(spacing: 20) {
                SiloWordmarkView(width: 132)

                ProgressView()
                    .tint(.siloOnSurface)
                    .scaleEffect(1.2)

                if let message {
                    Text(message)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }
            }
        }
    }
}
