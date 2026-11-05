import XCTest
@testable import Silo

/// Combined tech badges, matched against the web client's
/// `registry/tech.ts` and `overlaySuppressedBy` in `schema.ts`.
final class OverlayRegistryTests: XCTestCase {
    private func prefs(enabling ids: [String]) -> CardOverlayPrefs {
        let items = ids.map { #""\#($0)":{"enabled":true,"position":"top-left"}"# }
        return OverlaySchema.parse(#"{"version":2,"preset":"classic","order":[],"items":{\#(items.joined(separator: ","))}}"#)
    }

    private func topLeftIds(_ prefs: CardOverlayPrefs) -> [String] {
        OverlayRegistry.enabled(at: .topLeft, in: prefs).map(\.id.rawValue)
    }

    private func def(_ id: String) throws -> OverlayDef {
        try XCTUnwrap(OverlayRegistry.all.first { $0.id.rawValue == id }, "\(id) is not registered")
    }

    func testResolutionHdrAudioHidesTheBadgesItCombines() {
        // The defaults turn on resolution, hdr and audio; resolution_hdr is on too.
        let combined = prefs(enabling: ["resolution_hdr", "resolution_hdr_audio", "audio_channels"])
        XCTAssertEqual(topLeftIds(combined), ["resolution_hdr_audio", "audio_channels"])

        // Without it, resolution_hdr still hides only resolution and hdr.
        XCTAssertEqual(topLeftIds(prefs(enabling: ["resolution_hdr"])), ["resolution_hdr", "audio"])
    }

    func testResolutionHdrAudioIsOffByDefault() throws {
        XCTAssertEqual(topLeftIds(OverlaySchema.buildDefaults()), ["resolution", "hdr", "audio"])
        XCTAssertEqual(try def("resolution_hdr_audio").defaultPosition, .topLeft)
    }

    func testResolutionHdrAudioLabelJoinsThePartsTheFileHas() throws {
        let badge = try def("resolution_hdr_audio")
        let cases: [(OverlayData, String?)] = [
            (OverlayData(resolution: "2160p", hdr: "DV HDR10", audio: "Atmos"), "4K DV Atmos"),
            (OverlayData(resolution: "2160p", hdr: "HDR10+", audio: "DTS-HD"), "4K HDR10+ DTS-HD"),
            (OverlayData(resolution: "1080p", hdr: "HLG", audio: "TrueHD"), "1080p HDR TrueHD"),
            (OverlayData(resolution: "1080p", audio: "TrueHD"), "1080p TrueHD"),
            (OverlayData(resolution: "480p"), "480p"),
            (OverlayData(audio: "AAC"), "AAC"),
            (OverlayData(resolution: "", hdr: "", audio: ""), nil),
        ]
        for (data, expected) in cases {
            XCTAssertEqual(badge.getValue(data), expected)
        }
    }

    func testResolutionHdrAudioShowsOnlyTheDolbyVisionMark() throws {
        let badge = try def("resolution_hdr_audio")
        XCTAssertEqual(badge.getIcon?(OverlayData(hdr: "DV HDR10", audio: "Atmos")), .dolbyVision)
        XCTAssertNil(badge.getIcon?(OverlayData(hdr: "HDR10", audio: "Atmos")))
    }

    func testResolutionHdrNamesHdr10Plus() throws {
        XCTAssertEqual(try def("resolution_hdr").getValue(OverlayData(resolution: "2160p", hdr: "HDR10+")), "4K HDR10+")
    }
}
