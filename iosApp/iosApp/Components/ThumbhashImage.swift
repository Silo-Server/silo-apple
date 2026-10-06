import CoreGraphics
import Foundation
import SwiftUI

/// Renders the compact ThumbHash preview supplied alongside server artwork,
/// on the first frame: decodes are tiny and cached, so they run inline.
struct ThumbhashImage: View {
    let thumbhash: String?

    var body: some View {
        if let image = ThumbHashImageCache.shared.image(for: thumbhash) {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Color.siloSurfaceVariant
        }
    }
}

/// Decoded ThumbHash previews shared by every artwork placeholder. Invalid
/// hashes are cached too, so corrupt server data is decoded once.
final class ThumbHashImageCache: @unchecked Sendable {
    static let shared = ThumbHashImageCache()

    private final class Entry {
        let image: PlatformImage?

        init(image: PlatformImage?) {
            self.image = image
        }
    }

    private let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 512
        return cache
    }()

    func image(for thumbhash: String?) -> PlatformImage? {
        guard let value = thumbhash?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let key = value as NSString
        if let entry = entries.object(forKey: key) {
            return entry.image
        }
        let image = ThumbHashDecoder.platformImage(from: value)
        entries.setObject(Entry(image: image), forKey: key)
        return image
    }
}

/// ThumbHash decoder adapted from Evan Wallace's MIT-licensed reference Swift
/// implementation at revision a652ce6ed691242f459f468f0a8756cda3b90a82.
/// Reference implementation Copyright (c) 2023 Evan Wallace.
/// Only the decode path is retained, with bounds checks added before the
/// reference algorithm indexes packed coefficient bytes.
enum ThumbHashDecoder {
    struct RGBAImage {
        let width: Int
        let height: Int
        var pixels: Data
    }

    static func platformImage(from encodedThumbhash: String) -> PlatformImage? {
        guard var decoded = decodeRGBA(encodedThumbhash) else { return nil }

        let pixelCount = decoded.width * decoded.height
        decoded.pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var pixel = baseAddress.bindMemory(to: UInt8.self, capacity: rawBuffer.count)
            var index = 0
            while index < pixelCount {
                let alpha = UInt16(pixel[3])
                if alpha < 255 {
                    pixel[0] = UInt8(UInt16(pixel[0]) * alpha / 255)
                    pixel[1] = UInt8(UInt16(pixel[1]) * alpha / 255)
                    pixel[2] = UInt8(UInt16(pixel[2]) * alpha / 255)
                }
                pixel = pixel.advanced(by: 4)
                index += 1
            }
        }

        guard let provider = CGDataProvider(data: decoded.pixels as CFData),
              let cgImage = CGImage(
                width: decoded.width,
                height: decoded.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: decoded.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .perceptual
              ) else {
            return nil
        }
        return PlatformImage.siloImage(cgImage: cgImage)
    }

    static func decodeRGBA(_ encodedThumbhash: String) -> RGBAImage? {
        let normalized = encodedThumbhash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let hash = Data(base64Encoded: normalized),
              let header = validatedHeader(for: hash) else {
            return nil
        }

        let h0 = UInt32(hash[0])
        let h1 = UInt32(hash[1])
        let h2 = UInt32(hash[2])
        let h3 = UInt16(hash[3])
        let h4 = UInt16(hash[4])
        let header24 = h0 | (h1 << 8) | (h2 << 16)
        let header16 = h3 | (h4 << 8)

        let lDC = Float32(header24 & 63) / 63
        let pDC = Float32((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Float32((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Float32((header24 >> 18) & 31) / 31
        let pScale = Float32((header16 >> 3) & 63) / 63
        let qScale = Float32((header16 >> 9) & 63) / 63
        var aDC: Float32 = 1
        var aScale: Float32 = 1
        if header.hasAlpha {
            aDC = Float32(hash[5] & 15) / 15
            aScale = Float32(hash[5] >> 4) / 15
        }

        var acIndex = 0
        func decodeChannel(nx: Int, ny: Int, scale: Float32) -> [Float32] {
            var coefficients: [Float32] = []
            var cy = 0
            while cy < ny {
                var cx = cy > 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let packed = hash[header.acStart + (acIndex >> 1)]
                    let nibble = (packed >> ((acIndex & 1) << 2)) & 15
                    coefficients.append((Float32(nibble) / 7.5 - 1) * scale)
                    acIndex += 1
                    cx += 1
                }
                cy += 1
            }
            return coefficients
        }

        let lAC = decodeChannel(nx: header.lx, ny: header.ly, scale: lScale)
        let pAC = decodeChannel(nx: 3, ny: 3, scale: pScale * 1.25)
        let qAC = decodeChannel(nx: 3, ny: 3, scale: qScale * 1.25)
        let aAC = header.hasAlpha
            ? decodeChannel(nx: 5, ny: 5, scale: aScale)
            : []

        let ratio = Float32(header.lx) / Float32(header.ly)
        let width = Int(round(ratio > 1 ? 32 : 32 * ratio))
        let height = Int(round(ratio > 1 ? 32 / ratio : 32))
        guard width > 0, height > 0 else { return nil }

        // Cosine bases depend on only one axis, so compute them once per
        // column and row instead of per pixel.
        let cxStop = max(header.lx, header.hasAlpha ? 5 : 3)
        let cyStop = max(header.ly, header.hasAlpha ? 5 : 3)
        let fxTable = (0..<width).flatMap { x in
            (0..<cxStop).map { cx in
                cos(Float32.pi / Float32(width) * (Float32(x) + 0.5) * Float32(cx))
            }
        }
        let fyTable = (0..<height).flatMap { y in
            (0..<cyStop).map { cy in
                cos(Float32.pi / Float32(height) * (Float32(y) + 0.5) * Float32(cy))
            }
        }

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { pixelBuffer in
            guard let pixelBase = pixelBuffer.baseAddress else { return }
            var pixel = pixelBase.bindMemory(to: UInt8.self, capacity: pixelBuffer.count)
            for y in 0..<height {
                let fy = fyTable[(y * cyStop)..<((y + 1) * cyStop)]
                for x in 0..<width {
                    let fx = fxTable[(x * cxStop)..<((x + 1) * cxStop)]
                    var l = lDC
                    var p = pDC
                    var q = qDC
                    var a = aDC

                    var coefficientIndex = 0
                    for cy in 0..<header.ly {
                        var cx = cy > 0 ? 0 : 1
                        let fy2 = fy[fy.startIndex + cy] * 2
                        while cx * header.ly < header.lx * (header.ly - cy) {
                            l += lAC[coefficientIndex] * fx[fx.startIndex + cx] * fy2
                            coefficientIndex += 1
                            cx += 1
                        }
                    }

                    coefficientIndex = 0
                    for cy in 0..<3 {
                        var cx = cy > 0 ? 0 : 1
                        let fy2 = fy[fy.startIndex + cy] * 2
                        while cx < 3 - cy {
                            let factor = fx[fx.startIndex + cx] * fy2
                            p += pAC[coefficientIndex] * factor
                            q += qAC[coefficientIndex] * factor
                            coefficientIndex += 1
                            cx += 1
                        }
                    }

                    if header.hasAlpha {
                        coefficientIndex = 0
                        for cy in 0..<5 {
                            var cx = cy > 0 ? 0 : 1
                            let fy2 = fy[fy.startIndex + cy] * 2
                            while cx < 5 - cy {
                                a += aAC[coefficientIndex] * fx[fx.startIndex + cx] * fy2
                                coefficientIndex += 1
                                cx += 1
                            }
                        }
                    }

                    var blue = l - 2 / 3 * p
                    var red = (3 * l - blue + q) / 2
                    var green = red - q
                    red = max(0, 255 * min(1, red))
                    green = max(0, 255 * min(1, green))
                    blue = max(0, 255 * min(1, blue))
                    a = max(0, 255 * min(1, a))
                    pixel[0] = UInt8(red)
                    pixel[1] = UInt8(green)
                    pixel[2] = UInt8(blue)
                    pixel[3] = UInt8(a)
                    pixel = pixel.advanced(by: 4)
                }
            }
        }

        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    private struct Header {
        let hasAlpha: Bool
        let lx: Int
        let ly: Int
        let acStart: Int
    }

    private static func validatedHeader(for hash: Data) -> Header? {
        guard hash.count >= 5 else { return nil }

        let hasAlpha = (hash[2] & 0x80) != 0
        let dimension = Int(hash[3] & 7)
        guard dimension > 0, hash.count >= (hasAlpha ? 6 : 5) else { return nil }

        let isLandscape = (hash[4] & 0x80) != 0
        let rawLX = isLandscape ? (hasAlpha ? 5 : 7) : dimension
        let rawLY = isLandscape ? dimension : (hasAlpha ? 5 : 7)
        let lx = max(3, rawLX)
        let ly = max(3, rawLY)
        let acStart = hasAlpha ? 6 : 5
        let coefficientCount = acCoefficientCount(nx: lx, ny: ly)
            + acCoefficientCount(nx: 3, ny: 3) * 2
            + (hasAlpha ? acCoefficientCount(nx: 5, ny: 5) : 0)
        let expectedByteCount = acStart + (coefficientCount + 1) / 2
        guard hash.count == expectedByteCount else { return nil }

        return Header(
            hasAlpha: hasAlpha,
            lx: lx,
            ly: ly,
            acStart: acStart
        )
    }

    private static func acCoefficientCount(nx: Int, ny: Int) -> Int {
        var count = 0
        var cy = 0
        while cy < ny {
            var cx = cy > 0 ? 0 : 1
            while cx * ny < nx * (ny - cy) {
                count += 1
                cx += 1
            }
            cy += 1
        }
        return count
    }
}
