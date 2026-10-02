#if !os(tvOS)
import SwiftUI

/// A sign-in provider's icon from discovery, or a key symbol when it has
/// none or the image cannot be drawn (an SVG, for one).
struct ProviderIconView: View {
    let url: URL?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: "person.badge.key.fill")
            .resizable()
            .scaledToFit()
    }
}
#endif
