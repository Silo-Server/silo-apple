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
    /// Drawn when the artwork cannot load. Pass the item's type and title so
    /// the card shows a stand-in poster rather than a bare film reel.
    var missingArtwork = MissingArtwork()
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
                                MissingArtworkView(
                                    artwork: missingArtwork,
                                    // A ThumbHash already colours the slot
                                    // with the real artwork's palette.
                                    isTinted: ThumbHashImageCache.shared.image(for: thumbhash) == nil
                                )
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

/// What a card shows when its artwork is missing. With a title it becomes a
/// stand-in poster; without one, only the faint type glyph is drawn.
struct MissingArtwork {
    var symbol: String = ArtworkPlaceholderSymbol.fallback
    var title: String? = nil
    /// A second line under the title, such as the year.
    var subtitle: String? = nil
}

extension MissingArtwork {
    init(mediaType: String?, title: String? = nil, subtitle: String? = nil) {
        self.init(symbol: ArtworkPlaceholderSymbol.forMediaType(mediaType), title: title, subtitle: subtitle)
    }
}

/// Drawn over missing artwork. With room and a title, it is a stand-in
/// poster: a muted tint picked from the title, the type glyph, the title and
/// its second line, centred so it clears overlay badges in any corner.
/// Narrower artwork, or artwork with no title, keeps the faint glyph alone.
///
/// It is decoration: the enclosing card's label already names the item, and
/// the symbol's own label ("Movie", "Tv") would misstate it. An `Image` or
/// `Text` with `accessibilityHidden` is gone for VoiceOver but still listed
/// in the UI-automation tree that XCUITest and Maestro read, so everything is
/// drawn into a canvas, which exposes no element for it or its symbols.
struct MissingArtworkView: View {
    let artwork: MissingArtwork
    /// False when something behind the view already colours the slot; the
    /// title then sits on a dimming scrim instead of a tint.
    var isTinted = true

    /// Narrower artwork has no room for a readable title.
    static let titleMinWidth: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            let title = titleToDraw(in: geometry.size)
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                guard let title, let card = context.resolveSymbol(id: 0) else {
                    var glyph = context.resolve(Image(systemName: artwork.symbol))
                    glyph.shading = .color(Color.siloOnSurface.opacity(0.3))
                    context.draw(glyph, at: CGPoint(x: bounds.midX, y: bounds.midY))
                    return
                }
                if isTinted {
                    // Lowercased so "The Office" and "the office" match.
                    context.fill(Path(bounds), with: .linearGradient(
                        PlaceholderTint.gradient(for: title.lowercased()),
                        startPoint: .zero,
                        endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)
                    ))
                } else {
                    // Dark enough that white text clears WCAG AA over a
                    // near-white ThumbHash.
                    context.fill(Path(bounds), with: .color(.black.opacity(0.55)))
                }
                context.draw(card, in: bounds)
            } symbols: {
                if let title {
                    TitleCard(artwork: artwork, title: title, size: geometry.size)
                        .tag(0)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func titleToDraw(in size: CGSize) -> String? {
        guard size.width >= Self.titleMinWidth,
              let title = artwork.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }
}

/// The glyph, title and second line, scaled to the artwork's size.
private struct TitleCard: View {
    let artwork: MissingArtwork
    let title: String
    let size: CGSize

    var body: some View {
        // Sized from the shorter dimension so a wide still does not get a
        // title too tall for it.
        let base = min(size.width, size.height * 0.75)
        let titleSize = min(max(base * 0.13, 12), 40)
        let isWide = size.width > size.height
        VStack(spacing: titleSize * 0.4) {
            Image(systemName: artwork.symbol)
                .font(.system(size: titleSize * 1.1, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(isWide ? 2 : 4)
                .minimumScaleFactor(0.75)
            if let subtitle = artwork.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: max(titleSize * 0.7, 10), weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .padding(base * 0.1)
        .frame(width: size.width, height: size.height)
    }
}

enum ImagePlaceholderStyle {
    case surface
    case clear

    var showsErrorIcon: Bool {
        self == .surface
    }
}
