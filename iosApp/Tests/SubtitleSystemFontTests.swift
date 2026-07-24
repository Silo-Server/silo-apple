import XCTest

@testable import SiloTV

final class SubtitleSystemFontTests: XCTestCase {
    func testSystemFontIsTheFirstSubtitleFontChoice() {
        XCTAssertEqual(SubtitleFontFamilyPreset.allCases.first, .system)
        XCTAssertEqual(SubtitleFontFamilyPreset.system.rawValue, "system")
        XCTAssertEqual(SubtitleFontFamilyPreset.system.label, "System")
        XCTAssertEqual(
            SubtitleFontFamilyPreset.allCases.filter {
                $0.assFontName == SubtitleSystemFont.assFontName
            }.count,
            1
        )
    }

    func testSystemFontResolvesToReadableRuntimeFontData() throws {
        let resource = try XCTUnwrap(SubtitleSystemFont.loadResource())

        XCTAssertEqual(SubtitleFontFamilyPreset.system.assFontName, resource.assFontName)
        XCTAssertNotEqual(resource.assFontName, SubtitleFontFamilyPreset.sansSerif.assFontName)
        XCTAssertFalse(resource.data.isEmpty)
    }

    func testSystemFontNameFlowsIntoGeneratedASSStyles() throws {
        var appearance = SubtitleAppearance.default
        appearance.fontFamily = .system

        let params = SubtitleStylingOverride.Parameters.from(
            appearance: appearance,
            syncOffsetMs: 0
        )
        let header = SubtitleStylingOverride.syntheticHeader(params: params, slot: .primary)

        XCTAssertEqual(params.fontFamilyName, SubtitleSystemFont.assFontName)
        XCTAssertTrue(header.contains("Style: Default,\(SubtitleSystemFont.assFontName),"))
    }

    func testSystemFontRendersDifferentlyFromArial() throws {
        let systemRender = try renderSubtitle(using: .system)
        let arialRender = try renderSubtitle(using: .sansSerif)

        XCTAssertNotEqual(systemRender, arialRender)
    }

    private func renderSubtitle(
        using fontFamily: SubtitleFontFamilyPreset
    ) throws -> RenderedSubtitle {
        var appearance = SubtitleAppearance.default
        appearance.fontFamily = fontFamily
        appearance.backgroundStyle = .none
        let params = SubtitleStylingOverride.Parameters.from(
            appearance: appearance,
            syncOffsetMs: 0
        )
        let document = SubtitleStylingOverride.syntheticHeader(params: params, slot: .primary)
            + "Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Hamburgefonts\n"
        let renderer = SubtitleRenderer()

        renderer.applySettings(params)
        renderer.installFullASS(slot: .primary, assDocument: document, isNativeASS: false)
        let output = renderer.sessionQueue.sync {
            renderer.renderOnSessionQueue(
                atMilliseconds: 1_000,
                frameSize: CGSize(width: 1_920, height: 1_080),
                scale: 1
            )
        }
        let image = try XCTUnwrap(output.image)
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        return RenderedSubtitle(width: image.width, height: image.height, pixels: pixels)
    }
}

private struct RenderedSubtitle: Equatable {
    let width: Int
    let height: Int
    let pixels: Data
}
