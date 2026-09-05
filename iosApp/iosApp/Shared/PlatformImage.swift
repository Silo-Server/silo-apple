#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    static func siloImage(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return PlatformImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return PlatformImage(cgImage: cgImage, size: .zero)
        #endif
    }

    static func siloImage(data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }
}
