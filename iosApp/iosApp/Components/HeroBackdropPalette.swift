import CoreGraphics
import Nuke
import SwiftUI

/// Samples tint colors from a hero backdrop URL so the Home screen can
/// render a Plex-style page gradient that ties the featured artwork into
/// the rest of the scroll view.
///
/// Sampling runs on a detached utility task over a tiny redraw of the
/// 64 px palette thumbnail. Each color is nudged toward the app's dark
/// theme: near-black samples stay subdued, darker midtones get a mild
/// lift, and bright samples are darkened so the gradient never
/// overpowers the section rows below.
enum HeroBackdropPalette {
    /// The three washes the tvOS ambient backdrop paints: the overall
    /// average, the artwork's strongest hue, and its shadows. Surfaces that
    /// only need one color read `base`.
    struct Tints: Equatable {
        var base: Color
        var accent: Color
        var shadow: Color

        /// One color for every stop, for surfaces that render flat.
        static func flat(_ color: Color) -> Tints {
            Tints(base: color, accent: color, shadow: color)
        }
    }

    /// sRGB triple in 0...1, kept separate from `Color` so the sampling
    /// math is testable.
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double

        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    /// Edge of the square bitmap the thumbnail is redrawn into. A few
    /// hundred pixels is plenty for an average, a hue histogram, and a
    /// shadow percentile.
    private static let sampleEdge = 24

    private static let baseLuminance: Double = 0.22
    private static let accentLuminance: Double = 0.22
    private static let shadowLuminance: Double = 0.07

    /// Sampled tints keyed by backdrop URL. Sampling is deterministic per
    /// URL, so surfaces seeded on cold entry can read previously-warmed
    /// tints synchronously and paint them on their first frame.
    @MainActor private static var tintCache: [String: Tints] = [:]

    /// Synchronous lookup of previously-sampled tints. `nil` when the URL
    /// hasn't been sampled this session — fall back to `tints(for:)`.
    @MainActor static func cachedTints(for url: URL) -> Tints? {
        tintCache[url.absoluteString]
    }

    /// Synchronous lookup of a previously-sampled base tint.
    @MainActor static func cachedTint(for url: URL) -> Color? {
        cachedTints(for: url)?.base
    }

    /// Fetch and sample a tint color for the given URL. Returns `nil`
    /// if the image can't be loaded or sampled — callers should fall
    /// back to the app background.
    static func tintColor(for url: URL) async -> Color? {
        await tints(for: url)?.base
    }

    /// Fetch and sample all three tints for the given URL.
    static func tints(for url: URL) async -> Tints? {
        // Downsample during decode: we only need color statistics, so a
        // 64 px thumbnail is plenty of signal. ImageIO decodes it directly
        // from the data, so the full w1920 backdrop is never decoded just
        // to sample it.
        let request = PosterImageCache.paletteSampleRequest(for: url)

        do {
            let image = try await ImagePipeline.shared.image(for: request)
            // Detached on purpose: CPU-bound sampling runs at utility
            // priority and never on the caller's actor.
            let tints = await Task.detached(priority: .utility) {
                sampleTints(from: image)
            }.value
            if let tints {
                await MainActor.run { tintCache[url.absoluteString] = tints }
            }
            return tints
        } catch {
            return nil
        }
    }

    private static func sampleTints(from image: PlatformImage) -> Tints? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        #endif

        let edge = sampleEdge
        var bitmap = [UInt8](repeating: 0, count: edge * edge * 4)
        let drawn = bitmap.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: edge,
                height: edge,
                bitsPerComponent: 8,
                bytesPerRow: edge * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return nil }

        let pixels = stride(from: 0, to: bitmap.count, by: 4).map { index in
            RGB(
                r: Double(bitmap[index]) / 255.0,
                g: Double(bitmap[index + 1]) / 255.0,
                b: Double(bitmap[index + 2]) / 255.0
            )
        }
        guard let sampled = sample(pixels: pixels) else { return nil }
        return Tints(
            base: sampled.base.color,
            accent: sampled.accent.color,
            shadow: sampled.shadow.color
        )
    }

    /// Base, accent, and shadow tints for a set of pixels, already
    /// normalized for the dark theme.
    static func sample(pixels: [RGB]) -> (base: RGB, accent: RGB, shadow: RGB)? {
        guard !pixels.isEmpty else { return nil }

        let base = normalize(mean(pixels), targetLuminance: baseLuminance)

        // Shadows: the darkest quarter, so the bottom-left of the page
        // keeps the art's low-key color instead of going neutral black.
        let darkest = pixels
            .sorted { $0.luminance < $1.luminance }
            .prefix(max(1, pixels.count / 4))
        let shadow = normalize(mean(Array(darkest)), targetLuminance: shadowLuminance)

        let accent = dominantHue(in: pixels)
            .map { normalize($0, targetLuminance: accentLuminance) } ?? base

        return (base, accent, shadow)
    }

    /// Mean color of the strongest hue bucket, weighting each pixel by
    /// (saturation × value)², so a small vivid area outweighs a much larger
    /// muted one. `nil` for near-grayscale art, where the accent falls back
    /// to the base.
    private static func dominantHue(in pixels: [RGB]) -> RGB? {
        let binCount = 12
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: binCount)

        for pixel in pixels {
            let maxChannel = max(pixel.r, pixel.g, pixel.b)
            let minChannel = min(pixel.r, pixel.g, pixel.b)
            let chroma = maxChannel - minChannel
            guard maxChannel > 0.15, chroma > 0 else { continue }
            let saturation = chroma / maxChannel
            guard saturation > 0.2 else { continue }

            var hue: Double
            if maxChannel == pixel.r {
                hue = (pixel.g - pixel.b) / chroma
            } else if maxChannel == pixel.g {
                hue = (pixel.b - pixel.r) / chroma + 2
            } else {
                hue = (pixel.r - pixel.g) / chroma + 4
            }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }

            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            let vividness = saturation * maxChannel
            let weight = vividness * vividness
            weights[bin] += weight
            sums[bin].r += pixel.r * weight
            sums[bin].g += pixel.g * weight
            sums[bin].b += pixel.b * weight
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] >= Double(pixels.count) * 0.01 else { return nil }
        let weight = weights[best]
        return RGB(r: sums[best].r / weight, g: sums[best].g / weight, b: sums[best].b / weight)
    }

    private static func mean(_ pixels: [RGB]) -> RGB {
        let count = Double(pixels.count)
        let total = pixels.reduce(RGB(r: 0, g: 0, b: 0)) {
            RGB(r: $0.r + $1.r, g: $0.g + $1.g, b: $0.b + $1.b)
        }
        return RGB(r: total.r / count, g: total.g / count, b: total.b / count)
    }

    /// Clamp luminance so the resulting gradient sits comfortably on
    /// top of the OLED-black background — bright samples get dimmed,
    /// very dark ones get a mild lift so they still read as tinted
    /// rather than identical to `siloBackground`.
    private static func normalize(_ rgb: RGB, targetLuminance: Double) -> RGB {
        let luminance = rgb.luminance
        let scale: Double
        if luminance <= 0.001 {
            scale = 0
        } else if luminance > targetLuminance {
            scale = targetLuminance / luminance
        } else {
            scale = max(1.0, targetLuminance / max(luminance, 0.05))
        }

        return RGB(
            r: min(1, rgb.r * scale),
            g: min(1, rgb.g * scale),
            b: min(1, rgb.b * scale)
        )
    }
}
