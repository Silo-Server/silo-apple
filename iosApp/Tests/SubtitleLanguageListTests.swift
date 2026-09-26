//
//  SubtitleLanguageListTests.swift
//  SiloTests
//
//  The language list shared by the in-player subtitle search and AI subtitle
//  menus: which rows float to the top, how aliases collapse, and the order
//  the rest appear in. Options are injected so the tests don't depend on the
//  generated settings contract.
//

import XCTest
@testable import Silo

final class SubtitleLanguageListTests: XCTestCase {
    private let options: [PlaybackLanguageOption] = [
        PlaybackLanguageOption(code: "fr", label: "French"),
        PlaybackLanguageOption(code: "en", label: "English"),
        PlaybackLanguageOption(code: "de", label: "German"),
        PlaybackLanguageOption(code: "ja", label: "Japanese"),
    ]

    func testPreferredLanguageLeadsAndIsNotRepeatedUnderAnAlias() {
        let list = SubtitleLanguageList(preferred: "eng", options: options)

        XCTAssertEqual(list.suggested.map(\.code), ["eng"])
        XCTAssertEqual(list.suggested.map(\.suggestion), [.preferred])
        XCTAssertEqual(list.suggested.first?.hint, "Preferred")
        XCTAssertEqual(list.suggested.first?.label, "English")
        XCTAssertFalse(list.other.contains { $0.code == "en" })
        XCTAssertEqual(list.other.map(\.code), ["fr", "de", "ja"])
    }

    func testSpokenLanguageFollowsPreferredAsOriginalLanguage() {
        let list = SubtitleLanguageList(preferred: "fr", spoken: "ja", options: options)

        XCTAssertEqual(list.suggested.map(\.code), ["fr", "ja"])
        XCTAssertEqual(list.suggested.map(\.suggestion), [.preferred, .originalLanguage])
        XCTAssertEqual(list.suggested.map(\.hint), ["Preferred", "Original language"])
        XCTAssertEqual(list.other.map(\.code), ["en", "de"])
    }

    func testSpokenLanguageMatchingPreferredKeepsOnlyThePreferredRow() {
        let list = SubtitleLanguageList(preferred: "en", spoken: "eng", options: options)

        XCTAssertEqual(list.suggested.map(\.code), ["en"])
        XCTAssertEqual(list.suggested.map(\.suggestion), [.preferred])
        XCTAssertFalse(list.other.contains { $0.code == "en" || $0.code == "eng" })
    }

    func testOtherLanguagesSortByLabelWhileOrderedKeepsContractOrder() {
        let list = SubtitleLanguageList(preferred: nil, options: options)

        XCTAssertTrue(list.suggested.isEmpty)
        XCTAssertEqual(list.other.map(\.label), ["English", "French", "German", "Japanese"])
        // The search menu seeds its selection from `ordered.first` when there
        // is no preferred language, so contract order must survive.
        XCTAssertEqual(list.ordered.map(\.code), ["fr", "en", "de", "ja"])
    }

    func testBlankPreferredIsIgnored() {
        let list = SubtitleLanguageList(preferred: "  ", options: options)

        XCTAssertTrue(list.suggested.isEmpty)
        XCTAssertEqual(list.displayOrder, list.other)
        XCTAssertEqual(list.displayOrder.count, options.count)
    }

    func testDisplayNamePrefersCuratedLabelThenLocaleName() {
        let curated = [PlaybackLanguageOption(code: "fr", label: "Français")]

        XCTAssertEqual(SubtitleLanguageChoice.displayName("FR", options: curated), "Français")
        XCTAssertEqual(SubtitleLanguageChoice.displayName("sw", options: curated), "Swahili")
    }
}
