#if os(macOS)
import NukeUI
import SwiftUI

/// A title's logo artwork, fitted inside `size` and pinned to the leading
/// edge so it lines up with the text beneath it. The shared image view
/// centres a fitted image, which floats a narrow logo away from that text.
struct MacTitleLogo: View {
    let url: String
    let size: CGSize
    var onLoaded: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        LazyImage(request: request) { state in
            if let image = state.image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .onAppear { onLoaded?() }
            }
        }
        .frame(maxWidth: size.width, maxHeight: size.height)
    }

    private var request: ImageRequest? {
        guard let url = URL(string: url) else { return nil }
        return PosterImageCache.displayRequest(url: url, pointSize: size, scale: displayScale)
    }
}
#endif
