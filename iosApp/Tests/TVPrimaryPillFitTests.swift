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
            let overflow = try litColumnsPastPill(title: title, fixedWidth: pillWidth)
            XCTAssertEqual(overflow, 0, "\(title) draws past the pill")
        }
    }

    /// Without a fixed width the pill grows to its title instead of shrinking it.
    func testUnfixedPillGrowsToFitTitle() throws {
        let overflow = try litColumnsPastPill(title: "Продолжить 20 нояб. 2026 г.", fixedWidth: nil)
        XCTAssertGreaterThan(overflow, 0)
    }

    /// Counts pixel columns right of the fixed pill width that hold bright
    /// (title) pixels. The canvas is black, so only the label can light them.
    private func litColumnsPastPill(title: String, fixedWidth: CGFloat?) throws -> Int {
        let view = TVPrimaryPillButton(
            icon: "play.fill",
            title: title,
            stabilizesFocusMotion: true,
            fixedWidth: fixedWidth,
            action: {}
        )
        .frame(width: canvasWidth, height: 100, alignment: .leading)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A few points of slack for antialiasing at the capsule's edge.
        let firstColumn = Int(pillWidth) + 4
        var lit = 0
        for x in firstColumn..<width {
            for y in 0..<height where pixels[(y * width + x) * 4] > 128 {
                lit += 1
                break
            }
        }
        return lit
    }
}
#endif
