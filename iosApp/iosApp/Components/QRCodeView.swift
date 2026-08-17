import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a QR code for arbitrary string content using Core Image's
/// built-in `CIQRCodeGenerator`. No third-party dependency required.
///
/// Interpolation is disabled so the pixel grid stays crisp at any size;
/// the source image is upscaled before rasterization to avoid blurry
/// edges when SwiftUI scales to fit.
struct QRCodeView: View {
    let content: String
    var size: CGFloat = 240

    var body: some View {
        Group {
            if let image = Self.makeImage(for: content) {
                Image(platformImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }

    private static let context = CIContext()

    private static func makeImage(for content: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return PlatformImage.siloImage(cgImage: cgImage)
    }
}
