import CoreGraphics
import SwiftLibass

/// Blends libass output into a premultiplied BGRA canvas.
///
/// libass returns one alpha mask per glyph run, border, or drawing, each with a flat
/// colour. Blending those masks straight into an 8-bit canvas costs time in
/// proportion to the drawn area. The float pipeline it replaces allocated and
/// converted the whole bounding box of every frame, which on a full-screen sign
/// came to tens of megabytes per frame.
enum ASSImageCompositor {
    /// Composites `images` in list order over `canvas` and returns the clipped
    /// area it touched, or nil when nothing was drawn.
    ///
    /// The canvas is 32-bit premultiplied BGRA (little-endian ARGB words).
    @discardableResult
    static func composite(_ images: UnsafeMutablePointer<ASS_Image>?, into canvas: UnsafeMutableRawPointer,
                          width: Int, height: Int, bytesPerRow: Int) -> CGRect? {
        var dirty: CGRect?
        var next = images
        while let image = next {
            next = image.pointee.next
            let w = Int(image.pointee.w), h = Int(image.pointee.h)
            let opacity = 255 &- Int(image.pointee.color & 0xFF)
            guard w > 0, h > 0, opacity > 0, let bitmap = image.pointee.bitmap else { continue }
            let originX = Int(image.pointee.dst_x), originY = Int(image.pointee.dst_y)
            let minX = max(0, originX), minY = max(0, originY)
            let maxX = min(width, originX &+ w), maxY = min(height, originY &+ h)
            guard minX < maxX, minY < maxY else { continue }
            blend(bitmap: bitmap, stride: Int(image.pointee.stride),
                  color: image.pointee.color, opacity: opacity,
                  sourceX: minX &- originX, sourceY: minY &- originY,
                  into: canvas, bytesPerRow: bytesPerRow,
                  minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            dirty = dirty.map { $0.union(rect) } ?? rect
        }
        return dirty
    }

    /// One mask, already clipped to the canvas. Wrapping arithmetic keeps the
    /// inner loop free of overflow traps; every product stays below 255 × 255.
    private static func blend(bitmap: UnsafeMutablePointer<UInt8>, stride: Int, color: UInt32, opacity: Int,
                              sourceX: Int, sourceY: Int, into canvas: UnsafeMutableRawPointer, bytesPerRow: Int,
                              minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let red = Int((color >> 24) & 0xFF)
        let green = Int((color >> 16) & 0xFF)
        let blue = Int((color >> 8) & 0xFF)
        let solid = UInt32(0xFF00_0000) | UInt32(red << 16) | UInt32(green << 8) | UInt32(blue)
        let count = maxX &- minX
        var mask = bitmap + (sourceY &* stride &+ sourceX)
        var row = (canvas + (minY &* bytesPerRow)).assumingMemoryBound(to: UInt32.self) + minX
        for _ in minY..<maxY {
            var x = 0
            while x < count {
                let coverage = Int(mask[x])
                if coverage != 0 {
                    let alpha = opacity == 255 ? coverage : div255(coverage &* opacity)
                    if alpha == 255 {
                        row[x] = solid
                    } else if alpha != 0 {
                        let inverse = 255 &- alpha
                        let pixel = row[x]
                        let a = alpha &+ div255(Int(pixel >> 24) &* inverse)
                        let r = div255(red &* alpha &+ Int((pixel >> 16) & 0xFF) &* inverse)
                        let g = div255(green &* alpha &+ Int((pixel >> 8) & 0xFF) &* inverse)
                        let b = div255(blue &* alpha &+ Int(pixel & 0xFF) &* inverse)
                        row[x] = UInt32(a << 24 | r << 16 | g << 8 | b)
                    }
                }
                x &+= 1
            }
            mask += stride
            row = (UnsafeMutableRawPointer(row) + bytesPerRow).assumingMemoryBound(to: UInt32.self)
        }
    }

    /// Exact `round(value / 255)` for `value` in 0...65_025.
    @inline(__always)
    private static func div255(_ value: Int) -> Int {
        let biased = value &+ 128
        return (biased &+ (biased &>> 8)) &>> 8
    }
}
