#if os(tvOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// The movie and series pages give Play/Resume a fixed width so focus never
/// shifts the row. A long localized title must stay inside that capsule.
@MainActor
final class TVPrimaryPillFitTests: XCTestCase {
    private let pillWidth: CGFloat = 340
    private let canvasWidth: CGFloat = 720

    func testLongTitleStaysInsideFixedWidthPill() throws {
        for title in ["Продължаване на S1·E2", "Продолжить 20 нояб. 2026 г.", "Resume S2026·E296"] {
            let columns = try litColumns(title: title, fixedWidth: pillWidth)
            XCTAssertGreaterThan(columns.inside, 0, "\(title) drew nothing")
            XCTAssertEqual(columns.outside, 0, "\(title) draws past the pill")
        }
    }

    /// Without a fixed width the pill grows to its title instead of shrinking it.
    func testUnfixedPillGrowsToFitTitle() throws {
        let columns = try litColumns(title: "Продолжить 20 нояб. 2026 г.", fixedWidth: nil)
        XCTAssertGreaterThan(columns.outside, 0)
    }

    /// Renders the pill centred on a black canvas and counts pixel columns
    /// holding bright (icon or title) pixels inside the fixed pill's bounds
    /// and outside them on either side.
    private func litColumns(title: String, fixedWidth: CGFloat?) throws -> (inside: Int, outside: Int) {
        let view = TVPrimaryPillButton(
            icon: "play.fill",
            title: title,
            stabilizesFocusMotion: true,
            fixedWidth: fixedWidth,
            action: {}
        )
        .frame(width: canvasWidth, height: 100)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)

        // A few points of slack for antialiasing at the capsule's edges.
        let pillStart = (Int(canvasWidth) - Int(pillWidth)) / 2
        let pillEnd = pillStart + Int(pillWidth)
        var columns = (inside: 0, outside: 0)
        for x in 0..<width {
            let isLit = (0..<height).contains { y in pixels[(y * width + x) * 4] > 128 }
            guard isLit else { continue }
            if x >= pillStart && x < pillEnd {
                columns.inside += 1
            } else if x < pillStart - 4 || x >= pillEnd + 4 {
                columns.outside += 1
            }
        }
        return columns
    }
}
#endif
