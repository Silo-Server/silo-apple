//
//  SubtitleDisplayOrderTests.swift
//  SiloTests
//
//  Unit tests for `SubtitleDisplayOrder`: language grouping, preferred-
//  language-first group ordering, alphabetical fallback, format priority,
//  intra-format (full/forced/SDH/default) ordering, ISO 2↔3-letter
//  collapsing, unknown-language placement, and sort stability.
//

import XCTest
@testable import Silo

final class SubtitleDisplayOrderTests: XCTestCase {

    private struct Track {
        let id: Int
        var language: String?
        var codec: String?
        var isForced = false
        var isSDH = false
        var isDefault = false
    }

    private func order(_ tracks: [Track], preferred: String? = nil) -> [Int] {
        SubtitleDisplayOrder.order(tracks, preferredLanguage: preferred) { t in
            SubtitleDisplayOrder.Descriptor(
                language: t.language,
                codec: t.codec,
                isForced: t.isForced,
                isHearingImpaired: t.isSDH,
                isDefault: t.isDefault
            )
        }.map(\.id)
    }

    func testGroupsLanguagesAndAppliesFormatAndPreferredOrder() {
        // Mirrors the design mockup: a messy multi-language set.
        let tracks = [
            Track(id: 0, language: "en", codec: "subrip", isDefault: true),
            Track(id: 1, language: "es", codec: "ass"),
            Track(id: 2, language: "en", codec: "hdmv_pgs_subtitle", isForced: true),
            Track(id: 3, language: "fr", codec: "hdmv_pgs_subtitle"),
            Track(id: 4, language: "en", codec: "subrip"),
            Track(id: 5, language: "ja", codec: "ass"),
            Track(id: 6, language: "es", codec: "subrip"),
            Track(id: 7, language: "de", codec: "subrip", isForced: true),
        ]
        // Preferred (en) group first; remaining languages A–Z by English
        // display name (French, German, Japanese, Spanish). Within English:
        // SubRip before PGS; the default SubRip leads the non-default one.
        XCTAssertEqual(order(tracks, preferred: "en"), [0, 4, 2, 3, 7, 5, 6, 1])
    }

    func testAlphabeticalWhenNoPreferredLanguage() {
        let tracks = [
            Track(id: 0, language: "es", codec: "subrip"),
            Track(id: 1, language: "en", codec: "subrip"),
            Track(id: 2, language: "de", codec: "subrip"),
        ]
        // Sorted by English display name: English, German, Spanish.
        XCTAssertEqual(order(tracks), [1, 2, 0])
    }

    func testFormatPriorityWithinLanguage() {
        let tracks = [
            Track(id: 0, language: "en", codec: "hdmv_pgs_subtitle"),
            Track(id: 1, language: "en", codec: "webvtt"),
            Track(id: 2, language: "en", codec: "subrip"),
            Track(id: 3, language: "en", codec: "ass"),
        ]
        XCTAssertEqual(order(tracks), [2, 3, 1, 0])
    }

    func testFullBeforeForcedBeforeSDHWithinSameFormat() {
        let tracks = [
            Track(id: 0, language: "en", codec: "subrip", isSDH: true),
            Track(id: 1, language: "en", codec: "subrip", isForced: true),
            Track(id: 2, language: "en", codec: "subrip"),
        ]
        XCTAssertEqual(order(tracks), [2, 1, 0])
    }

    func testTwoAndThreeLetterCodesCollapseToOneGroup() {
        // "eng" preference must float an "en"-tagged track to the top.
        let tracks = [
            Track(id: 0, language: "fr", codec: "subrip"),
            Track(id: 1, language: "en", codec: "subrip"),
        ]
        XCTAssertEqual(order(tracks, preferred: "eng"), [1, 0])

        // And a mixed en/eng set stays a single contiguous group.
        let mixed = [
            Track(id: 0, language: "eng", codec: "ass"),
            Track(id: 1, language: "fr", codec: "subrip"),
            Track(id: 2, language: "en", codec: "subrip"),
        ]
        // English group (id 2 SubRip before id 0 ASS), then French.
        XCTAssertEqual(order(mixed, preferred: nil), [2, 0, 1])
    }

    func testUnknownLanguageSortsLast() {
        let tracks = [
            Track(id: 0, language: nil, codec: "subrip"),
            Track(id: 1, language: "en", codec: "subrip"),
            Track(id: 2, language: "und", codec: "subrip"),
        ]
        let result = order(tracks)
        XCTAssertEqual(result.first, 1)
        XCTAssertEqual(Set(result.suffix(2)), [0, 2])
    }

    func testStablePreservesOriginalOrderForEqualKeys() {
        let tracks = [
            Track(id: 0, language: "en", codec: "subrip"),
            Track(id: 1, language: "en", codec: "subrip"),
            Track(id: 2, language: "en", codec: "subrip"),
        ]
        XCTAssertEqual(order(tracks), [0, 1, 2])
    }

    func testSingleElementAndEmptyAreUntouched() {
        XCTAssertEqual(order([]), [])
        XCTAssertEqual(order([Track(id: 9, language: "es", codec: "ass")]), [9])
    }

    func testFormatRank() {
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("subrip"), SubtitleDisplayOrder.formatRank("ass"))
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("ass"), SubtitleDisplayOrder.formatRank("ssa"))
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("ssa"), SubtitleDisplayOrder.formatRank("webvtt"))
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("webvtt"), SubtitleDisplayOrder.formatRank("mov_text"))
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("mov_text"), SubtitleDisplayOrder.formatRank("hdmv_pgs_subtitle"))
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("hdmv_pgs_subtitle"), SubtitleDisplayOrder.formatRank("dvd_subtitle"))
        XCTAssertLessThan(SubtitleDisplayOrder.formatRank("dvd_subtitle"), SubtitleDisplayOrder.formatRank(nil))
        XCTAssertEqual(SubtitleDisplayOrder.formatRank("srt"), SubtitleDisplayOrder.formatRank("subrip"))
    }

    func testCanonicalLanguageKey() {
        XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey("eng"), "en")
        XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey("EN"), "en")
        XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey("en-US"), "en")
        XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey("pt_BR"), "pt")
        XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey("spa"), "es")
        XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey("xyz"), "xyz")
        XCTAssertNil(SubtitleDisplayOrder.canonicalLanguageKey("und"))
        XCTAssertNil(SubtitleDisplayOrder.canonicalLanguageKey(""))
        XCTAssertNil(SubtitleDisplayOrder.canonicalLanguageKey(nil))
    }

    /// The picker and the auto-resolver share one canonicalizer, so a 639-2
    /// code that was never in the retired 40-entry alias table now folds the
    /// same way on both sides — `tam`/`ta` and `cat`/`ca` are one group each,
    /// not two.
    func testCanonicalLanguageKeyMatchesTheAutoResolverOutsideTheRetiredTable() {
        for (alpha3, alpha2) in [("tam", "ta"), ("cat", "ca"), ("fas", "fa"), ("srp", "sr")] {
            XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey(alpha3), alpha2)
            XCTAssertEqual(SubtitleDisplayOrder.canonicalLanguageKey(alpha2), alpha2)
            XCTAssertTrue(
                SubtitleAutoResolver.languagesMatch(alpha3, alpha2),
                "\(alpha3)/\(alpha2) must be one language on both sides"
            )
        }
    }
}
