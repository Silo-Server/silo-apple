import XCTest
@testable import Silo

/// The `ui.card_overlays` document, matched against the web client's
/// `parseOverlayPrefs` in `schema.ts` and the contract's `card-overlays.json`.
final class OverlaySchemaTests: XCTestCase {
    private static let ref = String(repeating: "0a", count: 32) + ".webp"

    private func parse(_ items: String, preset: String = "classic", style: String? = nil) -> CardOverlayPrefs {
        let styleMember = style.map { #","style":\#($0)"# } ?? ""
        return OverlaySchema.parse(#"{"version":2,"preset":"\#(preset)"\#(styleMember),"order":[],"items":{\#(items)}}"#)
    }

    func testStoredTopRightDrawsOnTheRightEdgeRail() {
        let prefs = parse(#"""
        "rating_imdb":{"enabled":true,"position":"top-right"},
        "rating_rt":{"enabled":true,"position":"right-edge"},
        "show_status":{"enabled":true,"position":"left-edge"},
        "year":{"enabled":true,"position":"nowhere"}
        """#)
        XCTAssertEqual(prefs.items[.ratingImdb]?.position, .rightEdge)
        XCTAssertEqual(OverlayRegistry.enabled(at: .rightEdge, in: prefs).map(\.id), [.ratingImdb, .ratingRt])
        XCTAssertEqual(OverlayRegistry.enabled(at: .leftEdge, in: prefs).map(\.id), [.showStatus])
        // An unknown position keeps the badge's default.
        XCTAssertEqual(prefs.items[.year]?.position, .bottomLeft)
    }

    func testPlateAndBandPresetsParseAndAnUnknownPresetIsClassic() {
        XCTAssertEqual(parse("", preset: "plate").preset, .plate)
        XCTAssertEqual(parse("", preset: "band").preset, .band)
        XCTAssertEqual(parse("", preset: "neon").preset, .classic)
    }

    func testStyleKeepsValidFieldsAndDropsTheRest() {
        let prefs = parse("", style: #"""
        {"size":1.25,"shape":"pill","background":"#102030cc","textColor":"#ffffff",
         "borderColor":"#ffffff40","borderWidth":2,"fontWeight":"extrabold","uppercase":false,"shadow":true}
        """#)
        XCTAssertEqual(prefs.style, OverlayStyle(
            size: 1.25, shape: .pill, background: "#102030cc", textColor: "#ffffff",
            borderColor: "#ffffff40", borderWidth: 2, fontWeight: .extrabold, uppercase: false, shadow: true
        ))

        // Out of range, wrong type or wrong format: each is dropped on its own.
        let invalid = parse("", style: #"""
        {"size":3,"shape":"blob","background":"#102030","textColor":"#ffffffff",
         "borderWidth":1.5,"fontWeight":"black","uppercase":"yes","shadow":1}
        """#)
        XCTAssertNil(invalid.style, "a style with no valid field is no style")
        // `true` is not the size 1.
        XCTAssertNil(parse("", style: #"{"size":true}"#).style)
        XCTAssertEqual(parse("", style: #"{"size":0.75,"borderWidth":0}"#).style, OverlayStyle(size: 0.75, borderWidth: 0))
        XCTAssertNil(parse("").style)
    }

    func testImageRefsParseAndInvalidOnesAreDropped() {
        let prefs = parse(#"""
        "resolution":{"enabled":true,"position":"top-left","image":"\#(Self.ref)",
                      "valueImages":{"2160p":"\#(Self.ref)","1080p":"not-a-ref","":"\#(Self.ref)"}},
        "hdr":{"enabled":true,"position":"top-left","image":"logo.png"}
        """#)
        XCTAssertEqual(prefs.items[.resolution]?.image, Self.ref)
        XCTAssertEqual(prefs.items[.resolution]?.valueImages, ["2160p": Self.ref])
        XCTAssertNil(prefs.items[.hdr]?.image)
        XCTAssertEqual(prefs.items[.hdr]?.valueImages, [:])
    }

    func testUnlistedImagesAreDroppedFromTheRenderedDocument() {
        let other = String(repeating: "ff", count: 32) + ".webp"
        let prefs = parse(#"""
        "resolution":{"enabled":true,"position":"top-left","image":"\#(other)",
                      "valueImages":{"2160p":"\#(Self.ref)","1080p":"\#(other)"}}
        """#)
        let rendered = OverlaySchema.withoutUnlistedImages(prefs, listed: [Self.ref])
        XCTAssertNil(rendered.items[.resolution]?.image)
        XCTAssertEqual(rendered.items[.resolution]?.valueImages, ["2160p": Self.ref])
        // Nothing else moves.
        XCTAssertEqual(rendered.items[.hdr], prefs.items[.hdr])
        XCTAssertEqual(OverlaySchema.withoutUnlistedImages(prefs, listed: [Self.ref, other]), prefs)
    }

    func testDocumentWithoutAVersionButWithPresetAndItemsIsV2() {
        let prefs = OverlaySchema.parse(#"{"preset":"pill","items":{"year":{"enabled":true,"position":"bottom-right"}}}"#)
        XCTAssertEqual(prefs.preset, .pill)
        XCTAssertEqual(prefs.items[.year]?.position, .bottomRight)
    }
}
