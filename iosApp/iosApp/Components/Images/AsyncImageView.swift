import SwiftUI
import NukeUI
import Nuke

/// Artwork backed by the shared `PosterImageCache` pipeline.
///
/// - A decode of the same URL already in memory that is large enough paints
///   on the first frame without a request.
/// - Otherwise the artwork is decoded on the size ladder just above its drawn
///   size, showing a smaller cached decode or the ThumbHash meanwhile, and
///   fades in quickly so the placeholder is gone as soon as it can be.
struct AsyncImageView: View {
    let url: String
    var thumbhash: String? = nil
    /// The size the artwork is drawn at, in points. When nil the view
    /// measures itself.
    var targetSize: CGSize? = nil
    var contentMode: ContentMode = .fill
    var placeholderStyle: ImagePlaceholderStyle = .surface
    /// Glyph drawn when the artwork cannot load. Pass the item's type
    /// through `ArtworkPlaceholderSymbol` so a series without artwork does
    /// not show a film reel.
    var placeholderSymbol: String = ArtworkPlaceholderSymbol.fallback
    var onImageLoaded: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    @Environment(\.tvArtworkLoadingEnabled) private var artworkLoadingEnabled
    #else
    private let artworkLoadingEnabled = true
    #endif

    var body: some View {
        if let targetSize {
            // Callers that know the size frame this view themselves, so the
            // artwork just fills it; no geometry pass per card.
            artwork(drawnAt: targetSize, frame: nil)
        } else {
            GeometryReader { geometry in
                artwork(drawnAt: geometry.size, frame: geometry.size)
            }
        }
    }

    /// `frame` is the measured container when there is one; otherwise the
    /// artwork fills whatever frame the caller gives this view.
    @ViewBuilder
    private func artwork(drawnAt pointSize: CGSize, frame: CGSize?) -> some View {
        let resolved = resolveArtwork(drawnAt: pointSize)
        if let cached = resolved.cached, cached.isSufficient {
            artworkImage(cached.image, frame: frame)
        } else {
            LazyImage(
                request: artworkLoadingEnabled ? resolved.request : nil,
                transaction: Transaction(
                    animation: reduceMotion || resolved.cached != nil
                        ? nil
                        : .easeOut(duration: SiloTheme.fastDuration)
                )
            ) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .framed(frame)
                        .clipped()
                        .transition(.opacity)
                        .onAppear(perform: notifyImageLoaded)
                } else if let cached = resolved.cached {
                    artworkImage(cached.image, frame: frame)
                } else if state.error != nil && artworkLoadingEnabled {
                    placeholder(frame: frame)
                        .overlay {
                            if placeholderStyle.showsErrorIcon {
                                ArtworkPlaceholderGlyph(symbol: placeholderSymbol)
                            }
                        }
                } else {
                    placeholder(frame: frame)
                }
            }
            // Ahead of warm-ups, which run at normal priority or lower.
            .priority(.high)
            .onDisappear(.cancel)
        }
    }

    private struct ResolvedArtwork {
        var request: ImageRequest?
        var cached: (image: PlatformImage, isSufficient: Bool)?
    }

    private func resolveArtwork(drawnAt pointSize: CGSize) -> ResolvedArtwork {
        guard let url = URL(string: url),
              let pixelSize = PosterImageCache.decodePixelSize(forPointSize: pointSize, scale: displayScale) else {
            return ResolvedArtwork()
        }
        return ResolvedArtwork(
            request: PosterImageCache.displayRequest(url: url, pointSize: pointSize, scale: displayScale),
            cached: PosterImageCache.cachedVariant(of: url, for: pixelSize)
        )
    }

    private func artworkImage(_ image: PlatformImage, frame: CGSize?) -> some View {
        Image(platformImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .framed(frame)
            .clipped()
            .onAppear(perform: notifyImageLoaded)
    }

    private func notifyImageLoaded() {
        onImageLoaded?()
    }

    private func placeholder(frame: CGSize?) -> some View {
        Group {
            switch placeholderStyle {
            case .surface:
                ThumbhashImage(thumbhash: thumbhash)
            case .clear:
                Color.clear
            }
        }
        .framed(frame)
        .clipped()
    }
}

private extension View {
    /// An exact frame when the container was measured, else fill the frame
    /// the caller set.
    @ViewBuilder
    func framed(_ size: CGSize?) -> some View {
        if let size {
            frame(width: size.width, height: size.height)
        } else {
            frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if os(tvOS)
extension EnvironmentValues {
    /// Focusable rows stay mounted offscreen. Their image requests can still
    /// be cancelled independently when the row leaves the vertical viewport.
    @Entry var tvArtworkLoadingEnabled = true
}
#endif

/// The glyph a missing poster shows, chosen by the item's catalog type.
enum ArtworkPlaceholderSymbol {
    /// Used when the type is unknown, and for movies.
    static let fallback = "film"

    static func forMediaType(_ type: String?) -> String {
        guard let type else { return fallback }
        if SiloMediaType.isAudiobook(type) { return "headphones" }
        if SiloMediaType.isSeries(type) { return "tv" }
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "season", "episode":
            return "tv"
        default:
            return fallback
        }
    }
}

/// What is drawn over missing artwork: the Silo mark above "Artwork pending"
/// when there is room, else the faint type glyph.
///
/// It is decoration: the enclosing card's label already names the item, and
/// the symbol's own label ("Movie", "Tv") would misstate it. An `Image` with
/// `accessibilityHidden` is gone for VoiceOver but still listed in the
/// UI-automation tree that XCUITest and Maestro read, so everything is drawn
/// into a canvas, which exposes no element for it.
struct ArtworkPlaceholderGlyph: View {
    let symbol: String

    /// Narrower artwork cannot fit the label on one line.
    static let brandedMinWidth: CGFloat = 100
    static let label = "Artwork pending"

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            guard size.width >= Self.brandedMinWidth else {
                var glyph = context.resolve(Image(systemName: symbol))
                glyph.shading = .color(Color.siloOnSurface.opacity(0.3))
                context.draw(glyph, at: center)
                return
            }
            let mark = context.resolve(Image("SiloMark"))
            // Capped so a hero backdrop does not get a billboard-sized mark.
            let markHeight = min(size.height * 0.3, 120)
            let markWidth = markHeight * mark.size.width / max(mark.size.height, 1)
            let label = context.resolve(
                Text(Self.label).font(.siloCaption).foregroundColor(.siloSecondaryText)
            )
            let labelHeight = label.measure(in: size).height
            let spacing: CGFloat = 8
            let top = center.y - (markHeight + spacing + labelHeight) / 2
            context.draw(mark, in: CGRect(x: center.x - markWidth / 2, y: top, width: markWidth, height: markHeight))
            context.draw(label, at: CGPoint(x: center.x, y: top + markHeight + spacing + labelHeight / 2))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

enum ImagePlaceholderStyle {
    case surface
    case clear

    var showsErrorIcon: Bool {
        self == .surface
    }
}
