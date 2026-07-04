import SwiftUI
import NukeUI
import Nuke

/// Nuke-backed image renderer. Drop-in replacement for the stock
/// `AsyncImageView` that:
///
/// - Reads from the shared `PosterImageCache` pipeline (persistent memory +
///   disk cache)
/// - Downsamples to the target render size during decode so a 1080×1620
///   poster isn't held in memory at full resolution just to draw at 260×390
/// - Cross-fades in with the same duration as the rest of the app
/// - Shows a solid surface placeholder that blends with the grid background
struct CachedAsyncImage: View {
    let url: String
    var targetSize: CGSize? = nil
    var thumbhash: String? = nil
    var contentMode: ContentMode = .fill
    var placeholderStyle: ImagePlaceholderStyle = .surface

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let resolvedSize = targetSize ?? geometry.size
            LazyImage(request: request(for: resolvedSize)) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if state.error != nil {
                    placeholder(in: geometry.size)
                        .overlay {
                            if placeholderStyle.showsErrorIcon {
                                Image(systemName: "film")
                                    .foregroundColor(.continuumOnSurface.opacity(0.3))
                            }
                        }
                } else {
                    placeholder(in: geometry.size)
                }
            }
            .priority(.normal)
            .transition(.opacity)
            .animation(.easeOut(duration: ContinuumTheme.slowDuration), value: url)
        }
    }

    // MARK: - Request construction

    private func request(for size: CGSize) -> ImageRequest? {
        guard let url = URL(string: url) else { return nil }
        // Scale by the native display scale so we ask the decoder for the
        // exact pixel dimensions we render at.
        // tvOS reports displayScale 1.0 (logical 1920×1080 canvas) while an
        // Apple TV 4K composites the UI at 3840×2160 — decoding at point
        // size hands the panel a 2× upscale, visibly soft on photographic
        // content (episode stills especially). Decode at 4K pixel density;
        // `upscale: false` below keeps smaller sources unpadded.
        #if os(tvOS)
        let renderScale: CGFloat = 2.0
        #else
        let renderScale = displayScale
        #endif
        let pixelSize = CGSize(
            width: size.width * renderScale,
            height: size.height * renderScale
        )
        return ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(size: pixelSize, contentMode: .aspectFill, upscale: false)
            ]
        )
    }

    private func placeholder(in size: CGSize) -> some View {
        Group {
            switch placeholderStyle {
            case .surface:
                ThumbhashImage(thumbhash: thumbhash)
            case .clear:
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

enum ImagePlaceholderStyle {
    case surface
    case clear

    var showsErrorIcon: Bool {
        switch self {
        case .surface:
            return true
        case .clear:
            return false
        }
    }
}
