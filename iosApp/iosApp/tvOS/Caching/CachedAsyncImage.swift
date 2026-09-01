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
    /// Placement inside this view's resolved frame. Artwork keeps the
    /// centered default; transparent logos opt into `.bottomLeading` so the
    /// visible mark shares the metadata column's true leading edge.
    var alignment: Alignment = .center
    var placeholderStyle: ImagePlaceholderStyle = .surface

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let resolvedSize = targetSize ?? geometry.size
            let warmedImage = prefetchedImage()
            let loadAnimation: Animation? = reduceMotion || warmedImage != nil
                ? nil
                : .easeOut(duration: ContinuumTheme.slowDuration)
            LazyImage(
                request: request(for: resolvedSize),
                transaction: Transaction(animation: loadAnimation)
            ) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: alignment
                        )
                        .clipped()
                        .transition(.opacity)
                } else if state.error == nil, let warmedImage {
                    // The startup/grid prefetchers warm the memory cache under
                    // the bare-URL key, while the request above is keyed by
                    // URL + resize processor — a miss for Nuke's synchronous
                    // first check. Painting the warmed full-size decode here
                    // makes a prefetched card render finished on its first
                    // frame; the downsampled result then swaps in with
                    // identical pixels, so the handoff is invisible.
                    Image(platformImage: warmedImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: alignment
                        )
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
        }
    }

    /// Synchronous memory-cache lookup for the unprocessed URL the
    /// prefetchers warm. Cheap dictionary access — safe to call from `body`.
    private func prefetchedImage() -> PlatformImage? {
        guard let url = URL(string: url) else { return nil }
        return ImagePipeline.shared.cache[ImageRequest(url: url)]?.image
    }

    // MARK: - Request construction

    private func request(for size: CGSize) -> ImageRequest? {
        guard let url = URL(string: url) else { return nil }
        // Scale by the native display scale so we ask the decoder for the
        // exact pixel dimensions we render at.
        let pixelSize = CGSize(
            width: size.width * displayScale,
            height: size.height * displayScale
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
