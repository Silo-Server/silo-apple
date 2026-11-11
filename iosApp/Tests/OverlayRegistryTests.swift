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

    func testNoBadgeDefaultsToTheWatchStatusCorner() throws {
        // Ratings sit on the left rail and ribbons on the right, as on web;
        // a stored `top-right` reads as the right rail.
        XCTAssertEqual(try def("rating_imdb").defaultPosition, .leftEdge)
        XCTAssertEqual(try def("rating_rt_audience").defaultPosition, .leftEdge)
        XCTAssertEqual(try def("show_status").defaultPosition, .rightEdge)
        XCTAssertEqual(OverlayPosition(stored: "top-right"), .rightEdge)
        XCTAssertNil(OverlayPosition(stored: "middle"))
    }

    func testValueKeysAreTheApiValuesNotTheLabels() throws {
        let data = OverlayData(resolution: "2160p", hdr: "DV HDR10", audio: "Atmos", showStatus: "Returning Series")
        XCTAssertEqual(try def("resolution").getValueKey?(data), "2160p")
        XCTAssertEqual(try def("resolution_hdr").getValueKey?(data), "2160p DV HDR10")
        XCTAssertEqual(try def("resolution_hdr_audio").getValueKey?(data), "2160p DV HDR10 Atmos")
        XCTAssertEqual(try def("resolution_hdr_audio").getValueKey?(OverlayData(resolution: "1080p", audio: "TrueHD")), "1080p TrueHD")
        XCTAssertNil(try def("resolution_hdr").getValueKey?(OverlayData(hdr: "HDR10")))
        XCTAssertEqual(try def("show_status").getValueKey?(data), "Returning")
        // Scores are continuous, so a rating takes no per-value image.
        XCTAssertNil(try def("rating_imdb").getValueKey)
    }

    func testRatingBadgeCarriesItsSourceMarkAndBareScore() throws {
        let imdb = try def("rating_imdb")
        let data = OverlayData(ratingImdb: 9.24, ratingRtCritic: 89)
        XCTAssertEqual(imdb.getValue(data), "IMDb 9.2")
        XCTAssertEqual(imdb.sourceMark, "IMDb")
        XCTAssertEqual(imdb.getScore?(data), "9.2")
        XCTAssertEqual(try def("rating_rt").getScore?(data), "89%")
        XCTAssertNil(imdb.getValue(OverlayData()))
    }

    func testAtmosMarkNeedsAnExactAtmosValue() throws {
        let audio = try def("audio")
        XCTAssertEqual(audio.getIcon?(OverlayData(audio: "Atmos")), .atmos)
        XCTAssertEqual(audio.getIcon?(OverlayData(audio: "ATMOS")), .atmos)
        // The mark would not say "TrueHD", so the label stays whole beside the plain icon.
        XCTAssertEqual(audio.getIcon?(OverlayData(audio: "TrueHD Atmos")), .volume)
    }

    func testStudioAndNetworkAreTheFirstNameWithTextTrimmed() throws {
        let item = try HTTPClient.makeJSONDecoder().decode(
            BrowseItem.self,
            from: Data(#"{"content_id":"movie:a","type":"movie","title":"A","studios":[" ","  A24 "],"networks":[]}"#.utf8)
        )
        let data = OverlayData.from(item)
        XCTAssertEqual(data.studio, "A24")
        XCTAssertEqual(try def("studio").getValueKey?(data), "A24")
        XCTAssertNil(data.network)
    }

    func testResolutionHdrNamesHdr10Plus() throws {
        XCTAssertEqual(try def("resolution_hdr").getValue(OverlayData(resolution: "2160p", hdr: "HDR10+")), "4K HDR10+")
    }
}
