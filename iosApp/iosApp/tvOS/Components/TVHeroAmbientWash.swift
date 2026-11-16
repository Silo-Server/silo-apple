#if os(tvOS)
import Accelerate
import Nuke
import SwiftUI
import UIKit

/// The root hero's color wash, and a framed cover's glow, drawn as one
/// dithered bitmap. The wash ramps a dark tint across the whole screen and
/// the glow fades a cover into it, so each spans only a few 8-bit levels and
/// a SwiftUI gradient or blur rounds them into visible bands. Here they are
/// drawn into a floating-point bitmap and dithered with blue noise when
/// converted to 8 bits, which keeps the ramps smooth without changing their
/// tone.
///
/// The SwiftUI wash stays underneath for the moment before the first bitmap
/// is ready, and for surfaces whose tints never change.
struct TVHeroAmbientWash: View {
    /// The framed cover the hero is showing.
    struct Cover: Equatable {
        let url: String
        let aspect: MediaCardAspect
    }

    let tints: HeroBackdropPalette.Tints
    let isVisible: Bool
    /// Draws this cover's glow and shadow into the wash.
    let cover: Cover?
    /// False for the first paint and under Reduce Motion: changes snap.
    let animatesChanges: Bool
    let crossfadeDuration: Double

    @State private var bitmap: Bitmap?

    private struct Bitmap {
        let generation: Int
        let image: CGImage
    }

    private struct Request: Equatable {
        let tints: HeroBackdropPalette.Tints
        let isVisible: Bool
        let cover: Cover?
        let canvas: CGSize
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TVBackdropTintWash(tints: tints, isVisible: isVisible)
                    .animation(animatesChanges ? .easeInOut(duration: crossfadeDuration) : nil, value: tints)
                    .animation(animatesChanges ? .easeInOut(duration: 0.24) : nil, value: isVisible)

                if let bitmap {
                    Image(decorative: bitmap.image, scale: 1)
                        .resizable()
                        // Each bitmap pixel keeps its dithered value; scaling
                        // would blend neighbors and round them again.
                        .interpolation(.none)
                        .id(bitmap.generation)
                        .transition(.opacity)
                }
            }
            .task(id: Request(tints: tints, isVisible: isVisible, cover: cover, canvas: geometry.size)) {
                await render(canvas: geometry.size)
            }
        }
    }

    private func render(canvas: CGSize) async {
        let colors = TVHeroAmbientRenderer.Colors(tints: tints)
        var coverEffects: TVHeroAmbientRenderer.CoverEffects?
        if let cover {
            // The tint sampler already decoded this thumbnail for the cover.
            var thumbnail: CGImage?
            if let url = URL(string: cover.url) {
                thumbnail = try? await ImagePipeline.shared.image(for: PosterImageCache.paletteSampleRequest(for: url)).cgImage
                guard !Task.isCancelled else { return }
            }
            coverEffects = TVHeroAmbientRenderer.CoverEffects(
                thumbnail: thumbnail,
                coverFrame: TVRootHeroBackdrop.coverFrame(for: cover.aspect, canvas: canvas)
            )
        }
        // Runs off the main actor and inherits this task's cancellation, so
        // a wash superseded by the next focus change stops early.
        let image = await TVHeroAmbientRenderer.render(
            canvas: canvas, colors: colors, isVisible: isVisible, cover: coverEffects
        )
        guard !Task.isCancelled, let image else { return }
        let next = Bitmap(generation: (bitmap?.generation ?? 0) + 1, image: image)
        if animatesChanges, bitmap != nil {
            withAnimation(.easeInOut(duration: crossfadeDuration)) { bitmap = next }
        } else {
            bitmap = next
        }
    }
}

/// Draws the wash with the same stops and geometry as `TVBackdropTintWash`,
/// in gamma-encoded sRGB like SwiftUI, but with float precision.
enum TVHeroAmbientRenderer {
    /// Canvas points per bitmap pixel. The ramps are far smoother than this,
    /// and the dither is invisible at TV distance.
    static let pointsPerPixel: CGFloat = 2
    /// Points per pixel of the glow layer, which is blurred before drawing.
    private static let glowPointsPerPixel: CGFloat = 4
    private static let glowScale: CGFloat = 1.12
    /// Gaussian standard deviation of the glow, in points.
    private static let glowSigma: CGFloat = 36
    private static let glowOpacity: CGFloat = 0.55
    private static let shadowOpacity: CGFloat = 0.6
    private static let shadowBlur: CGFloat = 70
    private static let shadowOffsetY: CGFloat = 18

    struct Colors: Sendable {
        let background: SIMD3<Float>
        let base: SIMD3<Float>
        let accent: SIMD3<Float>
        let shadow: SIMD3<Float>

        init(tints: HeroBackdropPalette.Tints) {
            background = Self.components(Color.siloBackground)
            base = Self.components(tints.base)
            accent = Self.components(tints.accent)
            shadow = Self.components(tints.shadow)
        }

        private static func components(_ color: Color) -> SIMD3<Float> {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return SIMD3(Float(red), Float(green), Float(blue))
        }
    }

    /// A framed cover's glow, drawn soft and blurred around its frame, and
    /// its drop shadow. Without a thumbnail only the shadow is drawn.
    struct CoverEffects: @unchecked Sendable {
        let thumbnail: CGImage?
        let coverFrame: CGRect
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let floatBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    /// Nil when the calling task is cancelled; cancellation is checked
    /// between the expensive stages.
    @concurrent
    static func render(canvas: CGSize, colors: Colors, isVisible: Bool, cover: CoverEffects?) async -> CGImage? {
        let width = Int((canvas.width / pointsPerPixel).rounded(.up))
        let height = Int((canvas.height / pointsPerPixel).rounded(.up))
        guard width > 0, height > 0,
              let context = floatContext(width: width, height: height) else { return nil }
        // Top-left origin, in canvas points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1 / pointsPerPixel, y: -1 / pointsPerPixel)

        context.setFillColor(color(colors.background, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))

        let visible: CGFloat = isVisible ? 1 : 0
        // Base: top-trailing to bottom-leading.
        if let gradient = gradient(colors.base, stops: [(0, 1), (0.45, 0.5 * visible), (1, 0.18 * visible)]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: canvas.width, y: 0),
                end: CGPoint(x: 0, y: canvas.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        // EllipticalGradient lays its center and radius out in a unit square
        // stretched over the frame.
        drawEllipse(colors.accent, alpha: 0.3 * visible, center: CGPoint(x: 0.7, y: 1), radius: 0.3, in: context, canvas: canvas)
        drawEllipse(colors.shadow, alpha: 0.55 * visible, center: CGPoint(x: 0, y: 1), radius: 0.42, in: context, canvas: canvas)

        if let cover {
            guard !Task.isCancelled else { return nil }
            if let thumbnail = cover.thumbnail, let glow = blurredGlow(thumbnail, around: cover.coverFrame) {
                draw(glow.image, in: glow.frame, alpha: glowOpacity, on: context)
            }
            if let shadow = coverShadow(cover.coverFrame) {
                draw(shadow.image, in: shadow.frame, alpha: 1, on: context)
            }
        }

        guard !Task.isCancelled else { return nil }
        return ditheredImage(from: context, width: width, height: height)
    }

    /// Draws a layer at `frame` (canvas points) upright in the flipped canvas.
    private static func draw(_ image: CGImage, in frame: CGRect, alpha: CGFloat, on context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.setAlpha(alpha)
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }

    /// The cover's drop shadow alone: the rounded rect that casts it is
    /// cleared afterward, so a stale wash never shows a dark tile where a
    /// cover used to be.
    private static func coverShadow(_ cover: CGRect) -> (image: CGImage, frame: CGRect)? {
        let padding = shadowBlur * 2 + shadowOffsetY
        let outer = cover.insetBy(dx: -padding, dy: -padding)
        let width = Int((outer.width / pointsPerPixel).rounded(.up))
        let height = Int((outer.height / pointsPerPixel).rounded(.up))
        guard width > 0, height > 0,
              let context = floatContext(width: width, height: height) else { return nil }
        let scale = 1 / pointsPerPixel
        // This context is y-up, like the layer it becomes, so a negative
        // offset casts the shadow downward. Shadow offset and blur are in
        // pixels.
        let path = CGPath(
            roundedRect: CGRect(
                x: padding * scale, y: padding * scale,
                width: cover.width * scale, height: cover.height * scale
            ),
            cornerWidth: TVRootHeroBackdrop.coverCornerRadius * scale,
            cornerHeight: TVRootHeroBackdrop.coverCornerRadius * scale,
            transform: nil
        )
        context.setShadow(
            offset: CGSize(width: 0, height: -shadowOffsetY * scale),
            blur: shadowBlur * scale,
            color: color(.zero, alpha: shadowOpacity)
        )
        context.setFillColor(color(.zero, alpha: 1))
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.clear)
        context.addPath(path)
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return (image, outer)
    }

    private static func drawEllipse(
        _ rgb: SIMD3<Float>,
        alpha: CGFloat,
        center: CGPoint,
        radius: CGFloat,
        in context: CGContext,
        canvas: CGSize
    ) {
        guard alpha > 0, let gradient = gradient(rgb, stops: [(0, alpha), (1, 0)]) else { return }
        context.saveGState()
        context.scaleBy(x: canvas.width, y: canvas.height)
        context.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
        context.restoreGState()
    }

    /// The cover scaled up 12% around its frame and blurred, at a quarter of
    /// the canvas resolution. Returns the layer and where it goes, in points.
    private static func blurredGlow(_ thumbnail: CGImage, around cover: CGRect) -> (image: CGImage, frame: CGRect)? {
        let inner = cover.insetBy(dx: -cover.width * (glowScale - 1) / 2, dy: -cover.height * (glowScale - 1) / 2)
        let padding = glowSigma * 3
        let outer = inner.insetBy(dx: -padding, dy: -padding)
        let width = Int((outer.width / glowPointsPerPixel).rounded(.up))
        let height = Int((outer.height / glowPointsPerPixel).rounded(.up))
        guard width > 0, height > 0,
              let context = floatContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        let scale = 1 / glowPointsPerPixel
        context.draw(thumbnail, in: CGRect(
            x: padding * scale,
            y: padding * scale,
            width: inner.width * scale,
            height: inner.height * scale
        ))
        guard let data = context.data else { return nil }

        // Separable Gaussian: one horizontal pass, one vertical.
        let sigma = Float(glowSigma / glowPointsPerPixel)
        let radius = Int((sigma * 3).rounded(.up))
        var kernel = (-radius...radius).map { offset in exp(-Float(offset * offset) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        let rowBytes = context.bytesPerRow
        var source = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        guard let scratch = malloc(rowBytes * height) else { return nil }
        defer { free(scratch) }
        var pass = vImage_Buffer(data: scratch, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var clear: [Float] = [0, 0, 0, 0]
        let flags = vImage_Flags(kvImageBackgroundColorFill)
        guard vImageConvolve_ARGBFFFF(&source, &pass, nil, 0, 0, kernel, 1, UInt32(kernel.count), &clear, flags) == kvImageNoError,
              vImageConvolve_ARGBFFFF(&pass, &source, nil, 0, 0, kernel, UInt32(kernel.count), 1, &clear, flags) == kvImageNoError,
              let image = context.makeImage() else { return nil }
        return (image, outer)
    }

    private static func floatContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 32,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: floatBitmapInfo
        )
    }

    private static func color(_ rgb: SIMD3<Float>, alpha: CGFloat) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), alpha])
            ?? CGColor(gray: 0, alpha: alpha)
    }

    private static func gradient(_ rgb: SIMD3<Float>, stops: [(location: CGFloat, alpha: CGFloat)]) -> CGGradient? {
        CGGradient(
            colorsSpace: colorSpace,
            colors: stops.map { color(rgb, alpha: $0.alpha) } as CFArray,
            locations: stops.map(\.location)
        )
    }

    /// Converts the float canvas to 8-bit sRGB with reproducible ordered
    /// dithering from uniform blue noise, so every render gives the same
    /// result. The Gaussian variant clusters near zero and leaves bands
    /// visible.
    private static func ditheredImage(from context: CGContext, width: Int, height: Int) -> CGImage? {
        guard let data = context.data else { return nil }
        var source = vImage_Buffer(
            data: data,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: context.bytesPerRow
        )
        let rowBytes = width * 4
        var bytes = Data(count: rowBytes * height)
        var maxFloat: [Float] = [1, 1, 1, 1]
        var minFloat: [Float] = [0, 0, 0, 0]
        var permute: [UInt8] = [0, 1, 2, 3]
        let dither = Int32(kvImageConvert_DitherOrderedReproducible | kvImageConvert_OrderedUniformBlue)
        let status = bytes.withUnsafeMutableBytes { buffer -> vImage_Error in
            var destination = vImage_Buffer(
                data: buffer.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: rowBytes
            )
            return vImageConvert_ARGBFFFFtoARGB8888_dithered(
                &source, &destination, &maxFloat, &minFloat, dither, &permute, vImage_Flags(kvImageNoFlags)
            )
        }
        guard status == kvImageNoError,
              let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: outputColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
#endif
