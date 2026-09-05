import SwiftUI
import NukeUI
import Nuke

/// Nuke-backed image renderer. Drop-in replacement for the stock
/// `AsyncImageView` that:
///
/// - Reads from the shared `PosterImageCache` pipeline (persistent memory +
///   disk cache)
/// - Decodes straight to the target render size through ImageIO's thumbnail
///   path, so a 780×1170 poster is never held in memory at full resolution
///   (or decoded and then resized on the CPU) just to draw at 176×264
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
    var onImageLoaded: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    @Environment(\.tvArtworkLoadingEnabled) private var artworkLoadingEnabled
    #else
    private let artworkLoadingEnabled = true
    #endif

    var body: some View {
        GeometryReader { geometry in
            let resolvedSize = targetSize ?? geometry.size
            let imageRequest = request(for: resolvedSize)
            // A gated rail must not discard artwork that has already been
            // decoded at its display size when LazyImage's request becomes nil.
            // This is a memory-cache lookup only; it starts no image work.
            let retainedImage = artworkLoadingEnabled ? nil : imageRequest.flatMap {
                ImagePipeline.shared.cache[$0]?.image
            }
            let warmedImage = retainedImage ?? prefetchedImage()
            let loadAnimation: Animation? = reduceMotion || warmedImage != nil
                ? nil
                : .easeOut(duration: SiloTheme.slowDuration)
            LazyImage(
                request: artworkLoadingEnabled ? imageRequest : nil,
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
                        .onAppear(perform: notifyImageLoaded)
                } else if state.error == nil, let warmedImage {
                    // The startup/grid prefetchers warm the memory cache under
                    // the shared card-size thumbnail key, while the request
                    // above is keyed by the exact render size — a miss for
                    // Nuke's synchronous first check. Painting the warmed
                    // decode here makes a prefetched card render finished on
                    // its first frame; it is at least as sharp as the card's
                    // own decode, so the swap-in is invisible.
                    Image(platformImage: warmedImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: alignment
                        )
                        .clipped()
                        .onAppear(perform: notifyImageLoaded)
                } else if state.error != nil && artworkLoadingEnabled {
                    placeholder(in: geometry.size)
                        .overlay {
                            if placeholderStyle.showsErrorIcon {
                                Image(systemName: "film")
                                    .foregroundColor(.siloOnSurface.opacity(0.3))
                            }
                        }
                } else {
                    placeholder(in: geometry.size)
                }
            }
            .priority(.normal)
            .onDisappear(.cancel)
        }
    }

    /// Synchronous memory-cache lookup for the card-size decode the
    /// prefetchers warm. Cheap dictionary access — safe to call from `body`.
    private func prefetchedImage() -> PlatformImage? {
        guard let url = URL(string: url) else { return nil }
        return PosterImageCache.warmedCardImage(for: url)
    }

    private func notifyImageLoaded() {
        onImageLoaded?()
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
        return PosterImageCache.displayRequest(url: url, pixelSize: pixelSize)
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

#if os(tvOS)
/// Episode strips retain the painted image independently of the request gate.
/// Pausing new work must never replace every visible card's image subtree.
struct TVEpisodeArtwork: View {
    let url: String
    let thumbhash: String?
    let size: CGSize
    let isVisible: Bool

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tvArtworkLoadingEnabled) private var loadingEnabled
    @State private var retainedImage: PlatformImage?
    @State private var retainedKey: ImageKey?

    private struct ImageKey: Hashable {
        let url: String
        let width: CGFloat
        let height: CGFloat
    }

    private struct LoadKey: Hashable {
        let image: ImageKey
        let visible: Bool
        let enabled: Bool
    }

    var body: some View {
        let key = ImageKey(url: url, width: size.width * displayScale, height: size.height * displayScale)
        let request = URL(string: url).map {
            PosterImageCache.displayRequest(url: $0, pixelSize: CGSize(width: key.width, height: key.height))
        }
        let cached = isVisible ? request.flatMap { ImagePipeline.shared.cache[$0]?.image } : nil
        let image = isVisible ? (retainedKey == key ? retainedImage : nil) ?? cached : nil
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if isVisible {
                ThumbhashImage(thumbhash: thumbhash)
            } else {
                Color.siloSurface
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: LoadKey(image: key, visible: isVisible, enabled: loadingEnabled)) {
            guard isVisible else {
                retainedImage = nil
                retainedKey = nil
                return
            }
            guard retainedKey != key || retainedImage == nil else { return }
            // Cached artwork paints even during a fast scroll. No request or
            // decode is needed, and the image branch keeps the same identity.
            if let cached {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    retainedKey = key
                    retainedImage = cached
                }
                return
            }
            guard loadingEnabled, let request else { return }
            do {
                let loaded = try await ImagePipeline.shared.image(for: request)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    retainedKey = key
                    retainedImage = loaded
                }
            } catch {
                // Keep the placeholder; the next visibility/settle change can
                // retry. Cancelled work must never repaint a departed card.
            }
        }
        .onDisappear {
            retainedImage = nil
            retainedKey = nil
        }
    }
}
#endif

#if os(tvOS)
private struct TVArtworkLoadingEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Focusable rows stay mounted offscreen. Their image requests can still
    /// be cancelled independently when the row leaves the vertical viewport.
    var tvArtworkLoadingEnabled: Bool {
        get { self[TVArtworkLoadingEnabledKey.self] }
        set { self[TVArtworkLoadingEnabledKey.self] = newValue }
    }
}
#endif

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
