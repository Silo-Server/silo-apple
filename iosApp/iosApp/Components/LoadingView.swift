import SwiftUI

/// Full-screen loading indicator.
struct LoadingView: View {
    var message: String? = nil

    var body: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()

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
