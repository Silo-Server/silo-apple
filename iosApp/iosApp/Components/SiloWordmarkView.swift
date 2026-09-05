import SwiftUI

struct SiloWordmarkView: View {
    var width: CGFloat = 150
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image("SiloWordmark")
                .resizable()
                .scaledToFit()
                .frame(width: width)
                .accessibilityLabel("Silo")

            if let subtitle {
                Text(subtitle)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .tracking(2)
            }
        }
    }
}
