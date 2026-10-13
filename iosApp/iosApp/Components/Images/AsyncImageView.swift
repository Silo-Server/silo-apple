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
/// - A load that fails on a transient error retries with backoff while the
///   view is on screen (see `ArtworkRetryPolicy`), and again when the app
///   becomes active.
struct AsyncImageView: View {
    let url: String
    var thumbhash: String? = nil
    /// The size the artwork is drawn at, in points. When nil the view
    /// measures itself.
    var targetSize: CGSize? = nil
    var contentMode: ContentMode = .fill
    var placeholderStyle: ImagePlaceholderStyle = .surface
    /// Mark drawn when the artwork is missing. Pass the item's type through
    /// `ArtworkPlaceholderSymbol` so a series without artwork does not show a
    /// film reel. Nil draws no mark, for cards that centre a play button over
    /// the artwork.
    var placeholderSymbol: String? = ArtworkPlaceholderSymbol.fallback
    var onImageLoaded: (() -> Void)? = nil

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(tvOS)
    @Environment(\.tvArtworkLoadingEnabled) private var artworkLoadingEnabled
    #else
    private let artworkLoadingEnabled = true
    #endif

    /// Bumped to rebuild the `LazyImage`, which starts a fresh load.
    @State private var loadAttempt = 0
    @State private var backoff = ArtworkRetryBackoff()
    @State private var pendingRetry: Task<Void, Never>?

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
    private func artwork(drawnAt pointSize: CGSize, frame: CGSize?) -> some View {
        // Outside the branches: a URL change can also move the view between
        // them, and the old URL's backoff and pending retry must not carry
        // over to the new one.
        loadedArtwork(drawnAt: pointSize, frame: frame)
            .onChange(of: url) { resetRetry() }
            // A tvOS row that leaves the viewport stays mounted with loading
            // off rather than disappearing, so treat that as leaving the screen.
            .onChange(of: artworkLoadingEnabled) { resetRetry() }
    }

    @ViewBuilder
    private func loadedArtwork(drawnAt pointSize: CGSize, frame: CGSize?) -> some View {
        let resolved = resolveArtwork(drawnAt: pointSize)
        if let cached = resolved.cached, cached.isSufficient {
            artworkImage(cached.image, frame: frame)
        } else if url.isEmpty || URL(string: url) == nil {
            // Nothing to load, so draw what stands in for the artwork on the
            // first frame rather than after an empty request fails.
            missingPlaceholder(frame: frame)
        } else {
            // Read here so a retry being scheduled re-renders the load state.
            let retryIsPending = pendingRetry != nil
            LazyImage(
                request: artworkLoadingEnabled ? resolved.request : nil,
                transaction: Transaction(
                    animation: reduceMotion || resolved.cached != nil
                        ? nil
                        : .easeOut(duration: SiloTheme.fastDuration)
                )
            ) { state in
                loadState(state, resolved: resolved, retryIsPending: retryIsPending, frame: frame)
                    // On every state, not just the missing placeholder: a
                    // failed load can also be showing a smaller cached decode.
                    .onReceive(NotificationCenter.default.publisher(for: Self.appDidBecomeActive)) { _ in
                        if ArtworkRetryPolicy.retriesOnActivation(
                            after: state.error,
                            loadingEnabled: artworkLoadingEnabled
                        ) {
                            retry(resettingBackoff: true)
                        }
                    }
            }
            // Ahead of warm-ups, which run at normal priority or lower.
            .priority(.high)
            .onDisappear(.cancel)
            .onCompletion { handleCompletion($0) }
            .id(LoadIdentity(url: url, attempt: loadAttempt))
            // The next appearance gets the full retry schedule again.
            .onDisappear(perform: resetRetry)
        }
    }

    @ViewBuilder
    private func loadState(
        _ state: any LazyImageState,
        resolved: ResolvedArtwork,
        retryIsPending: Bool,
        frame: CGSize?
    ) -> some View {
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
        } else if let error = state.error, !Self.isUnstartedRequest(error), !retryIsPending {
            // Only once no retry is waiting, so a blip keeps the ThumbHash up
            // rather than flashing the missing artwork.
            missingPlaceholder(frame: frame)
        } else {
            placeholder(frame: frame)
        }
    }

    // MARK: - Retry

    private struct LoadIdentity: Hashable {
        let url: String
        let attempt: Int
    }

    #if os(macOS)
    private static let appDidBecomeActive = NSApplication.didBecomeActiveNotification
    #else
    private static let appDidBecomeActive = UIApplication.didBecomeActiveNotification
    #endif

    private func handleCompletion(_ result: Result<ImageResponse, Error>) {
        switch result {
        case .success:
            backoff.reset()
        case let .failure(error):
            guard let delay = backoff.delay(afterFailure: error) else { return }
            cancelPendingRetry()
            pendingRetry = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                retry(resettingBackoff: false)
            }
        }
    }

    private func retry(resettingBackoff: Bool) {
        cancelPendingRetry()
        if resettingBackoff { backoff.reset() }
        loadAttempt += 1
    }

    private func cancelPendingRetry() {
        pendingRetry?.cancel()
        pendingRetry = nil
    }

    /// Ends this load's retry schedule, so the next failure starts it over.
    private func resetRetry() {
        cancelPendingRetry()
        backoff.reset()
    }

    /// No request was made: a tvOS row loading offscreen, or no size yet. The
    /// artwork is not known to be missing, and the error lingers for a frame
    /// after the request arrives.
    private static func isUnstartedRequest(_ error: Error) -> Bool {
        if case .imageRequestMissing = error as? ImagePipeline.Error { return true }
        return false
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
            case .surface, .artwork:
                ThumbhashImage(thumbhash: thumbhash)
            case .clear:
                Color.clear
            }
        }
        .framed(frame)
        .clipped()
    }

    /// Shown once the artwork is known to be missing: there is no URL, or
    /// it failed to load.
    @ViewBuilder
    private func missingPlaceholder(frame: CGSize?) -> some View {
        let hasThumbhash = ThumbHashImageCache.shared.image(for: thumbhash) != nil
        switch placeholderStyle.whenMissing(hasThumbhash: hasThumbhash) {
        case .placeholder:
            placeholder(frame: frame)
        case .glyph:
            placeholder(frame: frame)
                .overlay {
                    if let placeholderSymbol {
                        ArtworkPlaceholderGlyph(symbol: placeholderSymbol)
                    }
                }
        case .defaultArtwork:
            DefaultArtwork(symbol: placeholderSymbol)
                .framed(frame)
                .clipped()
        }
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

/// The mark a missing poster shows, chosen by the item's catalog type.
enum ArtworkPlaceholderSymbol {
    /// Used when the type is unknown, and for movies.
    static let fallback = "film"
    static let television = "tv"
    static let audiobook = "headphones"
    static let book = "book.closed"

    static func forMediaType(_ type: String?) -> String {
        guard let type else { return fallback }
        if SiloMediaType.isAudiobook(type) { return audiobook }
        if SiloMediaType.isSeries(type) || SiloMediaType.isEpisode(type) { return television }
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        // "season_premiere" is a calendar event type.
        case "season", "season_premiere":
            return television
        case "podcast", "podcasts":
            return audiobook
        case "ebook", "ebooks", "manga", "comic", "comics":
            return book
        default:
            return fallback
        }
    }
}

/// The faint glyph drawn over missing images that are not media artwork.
///
/// It is decoration: the enclosing view's label already names the item, and
/// the symbol's own label ("Movie", "Tv") would misstate it. An `Image` with
/// `accessibilityHidden` is gone for VoiceOver but still listed in the
/// UI-automation tree that XCUITest and Maestro read, so the symbol is drawn
/// into a canvas, which exposes no element for it.
private struct ArtworkPlaceholderGlyph: View {
    let symbol: String

    var body: some View {
        Canvas { context, size in
            var glyph = context.resolve(Image(systemName: symbol))
            glyph.shading = .color(Color.siloOnSurface.opacity(0.3))
            context.draw(glyph, at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

enum ImagePlaceholderStyle {
    case surface
    case clear
    /// Posters, covers and stills: a missing image shows `DefaultArtwork`
    /// instead of a glyph.
    case artwork

    /// What fills the slot once the image is known to be missing.
    enum Missing: Equatable {
        /// The loading placeholder stays: the ThumbHash, the surface, or nothing.
        case placeholder
        /// The loading placeholder with the faint type glyph over it.
        case glyph
        case defaultArtwork
    }

    func whenMissing(hasThumbhash: Bool) -> Missing {
        switch self {
        case .surface: .glyph
        case .clear: .placeholder
        // A ThumbHash already shows the real artwork's colours.
        case .artwork: hasThumbhash ? .placeholder : .defaultArtwork
        }
    }
}
