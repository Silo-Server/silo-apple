import CoreImage
import Nuke
import SwiftUI

/// Samples a dominant tint color from a hero backdrop URL so the Home
/// screen can render a Plex-style page gradient that ties the featured
/// artwork into the rest of the scroll view.
///
/// Color extraction runs on a detached utility task and downsamples to
/// a 1×1 pixel via `CIAreaAverage`, which is the cheapest reliable way
/// to pull an average color from a `UIImage`. The result is nudged
/// toward the app's dark theme: near-black samples stay subdued,
/// darker midtones get a mild lift, and bright samples are darkened
/// so the gradient never overpowers the section rows below.
enum HeroBackdropPalette {
    /// Shared CIContext. Construction is relatively expensive and the
    /// context is safe to reuse across renders.
    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
    ])

    /// Sampled tints keyed by backdrop URL. Sampling is deterministic per
    /// URL, so surfaces seeded on cold entry can read a previously-warmed
    /// tint synchronously and paint it on their first frame.
    @MainActor private static var tintCache: [String: Color] = [:]

    /// Synchronous lookup of a previously-sampled tint. `nil` when the
    /// URL hasn't been sampled this session — fall back to `tintColor(for:)`.
    @MainActor static func cachedTint(for url: URL) -> Color? {
        tintCache[url.absoluteString]
    }

    /// Fetch and sample a tint color for the given URL. Returns `nil`
    /// if the image can't be loaded or sampled — callers should fall
    /// back to the app background.
    static func tintColor(for url: URL) async -> Color? {
        // Downsample during decode: we only need an average color, so a
        // 64 px thumbnail is plenty of signal. ImageIO decodes it directly
        // from the data, so the full w1920 backdrop is never decoded just
        // to run CIAreaAverage on it.
        let request = PosterImageCache.paletteSampleRequest(for: url)

        do {
            let image = try await ImagePipeline.shared.image(for: request)
            let tint = await Task.detached(priority: .utility) {
                sampleTint(from: image)
            }.value
            if let tint {
                await MainActor.run { tintCache[url.absoluteString] = tint }
            }
            return tint
        } catch {
            return nil
        }
    }

    private static func sampleTint(from image: PlatformImage) -> Color? {
        #if canImport(UIKit)
        guard let ciImage = CIImage(image: image) else { return nil }
        #elseif canImport(AppKit)
        guard let data = image.tiffRepresentation,
              let ciImage = CIImage(data: data) else {
            return nil
        }
        #endif

        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let output = filter?.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0

        return normalize(r: r, g: g, b: b)
    }

    /// Clamp luminance so the resulting gradient sits comfortably on
    /// top of the OLED-black background — bright backdrops get dimmed,
    /// very dark ones get a mild lift so they still read as tinted
    /// rather than identical to `siloBackground`.
    private static func normalize(r: Double, g: Double, b: Double) -> Color {
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let targetLuminance: Double = 0.22
        let scale: Double
        if luminance <= 0.001 {
            scale = 0
        } else if luminance > targetLuminance {
            scale = targetLuminance / luminance
        } else {
            scale = max(1.0, targetLuminance / max(luminance, 0.05))
        }

        let scaled = (
            r: min(1, r * scale),
            g: min(1, g * scale),
            b: min(1, b * scale)
        )
        return Color(red: scaled.r, green: scaled.g, blue: scaled.b)
    }
}
