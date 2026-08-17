import CoreImage
import Nuke
import SwiftUI

/// Color palette sampled from an audiobook cover, used to build the
/// PlexAmp-style ambient backdrop behind the player. Four quadrant
/// averages drive the mesh gradient corners, the full-frame average
/// anchors its center, and the most vivid quadrant becomes the accent
/// that tints the transport controls.
struct AudioCoverPalette: Equatable {
    /// Quadrant averages in [topLeading, topTrailing, bottomLeading,
    /// bottomTrailing] order, normalized toward the OLED-dark theme.
    let corners: [Color]
    let center: Color
    let accent: Color

    /// Neutral near-black palette shown before sampling resolves (or
    /// when the book has no cover): reads as the plain app background
    /// with a faint cool cast rather than a sudden color flash.
    static let fallback = AudioCoverPalette(
        corners: [
            Color(red: 0.10, green: 0.11, blue: 0.15),
            Color(red: 0.07, green: 0.08, blue: 0.12),
            Color(red: 0.06, green: 0.06, blue: 0.10),
            Color(red: 0.09, green: 0.09, blue: 0.13),
        ],
        center: Color(red: 0.07, green: 0.08, blue: 0.11),
        accent: .siloPrimary
    )
}

/// Samples `AudioCoverPalette` values off the main actor. Mirrors
/// `HeroBackdropPalette`: Nuke downsamples during decode, then
/// `CIAreaAverage` collapses each region to a single color.
enum AudioCoverPaletteSampler {
    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
    ])

    static func palette(for urlString: String?) async -> AudioCoverPalette? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let request = ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: CGSize(width: 64, height: 64),
                    contentMode: .aspectFill,
                    upscale: false
                )
            ],
            priority: .low
        )
        guard let image = try? await ImagePipeline.shared.image(for: request) else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            samplePalette(from: image)
        }.value
    }

    private static func samplePalette(from image: PlatformImage) -> AudioCoverPalette? {
        #if canImport(UIKit)
        guard let ciImage = CIImage(image: image) else { return nil }
        #elseif canImport(AppKit)
        guard let data = image.tiffRepresentation,
              let ciImage = CIImage(data: data) else {
            return nil
        }
        #endif

        let extent = ciImage.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let halfWidth = extent.width / 2
        let halfHeight = extent.height / 2
        // CIImage origin is bottom-left; order the rects so the palette
        // reads in SwiftUI's top-leading-first orientation.
        let quadrants = [
            CGRect(x: extent.minX, y: extent.midY, width: halfWidth, height: halfHeight),
            CGRect(x: extent.midX, y: extent.midY, width: halfWidth, height: halfHeight),
            CGRect(x: extent.minX, y: extent.minY, width: halfWidth, height: halfHeight),
            CGRect(x: extent.midX, y: extent.minY, width: halfWidth, height: halfHeight),
        ]

        var rawCorners: [RGB] = []
        for rect in quadrants {
            guard let rgb = averageColor(of: ciImage, in: rect) else { return nil }
            rawCorners.append(rgb)
        }
        guard let rawCenter = averageColor(of: ciImage, in: extent) else { return nil }

        let accentSource = rawCorners.max(by: { $0.vividness < $1.vividness }) ?? rawCenter
        return AudioCoverPalette(
            corners: rawCorners.map { $0.dimmedForBackdrop().color },
            center: rawCenter.dimmedForBackdrop().color,
            accent: accentSource.boostedForAccent().color
        )
    }

    private static func averageColor(of image: CIImage, in rect: CGRect) -> RGB? {
        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
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
        return RGB(
            r: Double(bitmap[0]) / 255.0,
            g: Double(bitmap[1]) / 255.0,
            b: Double(bitmap[2]) / 255.0
        )
    }
}

private struct RGB {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var saturation: Double {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        guard maxC > 0 else { return 0 }
        return (maxC - minC) / maxC
    }

    /// Saturation weighted by brightness — favors colors that read as
    /// "the" cover color over both dark mud and washed-out highlights.
    var vividness: Double { saturation * (0.35 + 0.65 * max(r, g, b)) }

    /// Pull the sample down toward the OLED background so the mesh sits
    /// behind controls without fighting them, keeping a floor so very
    /// dark covers still read as tinted.
    func dimmedForBackdrop() -> RGB {
        let target = 0.16
        let lum = luminance
        let scale: Double
        if lum <= 0.001 {
            return RGB(r: 0.05, g: 0.05, b: 0.07)
        } else if lum > target {
            scale = target / lum
        } else {
            scale = min(1.6, target / max(lum, 0.04))
        }
        return RGB(r: min(1, r * scale), g: min(1, g * scale), b: min(1, b * scale))
    }

    /// Lift the sample into a control tint: bright enough to pass on
    /// the dark backdrop, desaturated enough to keep glyphs readable.
    func boostedForAccent() -> RGB {
        let maxC = max(r, g, b)
        // Near-grey sample (black-and-white covers): keep the app's
        // monochrome primary instead of inventing a hue.
        guard saturation > 0.12, maxC > 0.001 else {
            return RGB(r: 0.93, g: 0.93, b: 0.93)
        }
        let targetBrightness = 0.92
        let scale = targetBrightness / maxC
        var boosted = RGB(r: min(1, r * scale), g: min(1, g * scale), b: min(1, b * scale))
        // Blend toward white a touch so saturated accents stay legible
        // as fills behind dark glyphs.
        let lift = 0.18
        boosted.r = boosted.r + (1 - boosted.r) * lift
        boosted.g = boosted.g + (1 - boosted.g) * lift
        boosted.b = boosted.b + (1 - boosted.b) * lift
        return boosted
    }
}
