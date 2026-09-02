import SwiftUI

/// Loads an image from a URL with placeholder and error states.
/// Placeholder uses surfaceElevated (Plezy PlaceholderContainer style).
struct AsyncImageView: View {
    let url: String
    var thumbhash: String? = nil
    var targetSize: CGSize? = nil
    var contentMode: ContentMode = .fill
    var placeholderStyle: ImagePlaceholderStyle = .surface
    var onImageLoaded: (() -> Void)? = nil

    var body: some View {
        CachedAsyncImage(
            url: url,
            targetSize: targetSize,
            thumbhash: thumbhash,
            contentMode: contentMode,
            placeholderStyle: placeholderStyle,
            onImageLoaded: onImageLoaded
        )
    }
}
