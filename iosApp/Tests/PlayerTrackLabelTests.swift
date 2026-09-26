import XCTest
@testable import Silo

/// Subtitle rows lead with the language, because embedded titles are often
/// the release name and made every track look the same.
final class PlayerTrackLabelTests: XCTestCase {
    private let releaseName = "Toy Story 5 (2026) [Remux-2160p HEVC DV HDR10PLUS 10-bit TrueHD Atmos 7.1]"

    func testReleaseNameTitleIsNotUsedAsDetail() {
        let track = subtitle(lang: "eng", title: releaseName, codec: "hdmv_pgs_subtitle")

        XCTAssertEqual(track.languageFirstPrimaryLabel, "English")
        XCTAssertNil(track.languageFirstDetailLabel)
        XCTAssertEqual(track.languageFirstSingleLineLabel, "English")
        XCTAssertEqual(track.languageFirstAttributesLabel, "HDMV_PGS_SUBTITLE")
    }

    func testSameLanguageTracksGetDistinctSingleLineLabels() {
        let plain = subtitle(lang: "eng", title: releaseName)
        let forced = subtitle(lang: "eng", title: releaseName, forced: true)
        let sdh = subtitle(lang: "eng", title: releaseName, hearingImpaired: true)

        XCTAssertEqual(plain.languageFirstSingleLineLabel, "English")
        XCTAssertEqual(forced.languageFirstSingleLineLabel, "English (Forced)")
        XCTAssertEqual(sdh.languageFirstSingleLineLabel, "English (SDH)")
    }

    func testMeaningfulTitleSurvivesAsDetail() {
        let track = subtitle(lang: "eng", title: "Signs & Songs", forced: true)

        XCTAssertEqual(track.languageFirstDetailLabel, "Signs & Songs")
        XCTAssertEqual(track.languageFirstSingleLineLabel, "English (Signs & Songs, Forced)")
        XCTAssertEqual(track.languageFirstAttributesLabel, "Signs & Songs · SUBRIP · Forced")
    }

    func testMissingLanguageFallsBackToTitle() {
        let track = subtitle(lang: nil, title: "Commentary")

        XCTAssertEqual(track.languageFirstPrimaryLabel, "Commentary")
        XCTAssertEqual(track.languageFirstSingleLineLabel, "Commentary")
    }

    private func subtitle(
        lang: String?,
        title: String?,
        codec: String = "subrip",
        forced: Bool = false,
        hearingImpaired: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: 1,
            kind: .sub,
            title: title,
            lang: lang,
            codec: codec,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: forced,
            isHearingImpaired: hearingImpaired,
            isExternal: false,
            isSelected: false,
            ffIndex: 1,
            srcId: nil
        )
    }
}
