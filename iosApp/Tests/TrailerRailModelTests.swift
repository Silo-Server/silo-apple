//
//  TrailerRailModelTests.swift
//  SiloTests
//
//  Shaping rules for the merged "Trailers & More" rail: what appears, in
//  what order, and the URLs each remote card is built from. Both platform
//  rails render from `TrailerRail.entries`, so these are the tests that keep
//  iOS and tvOS showing the same list.
//

import XCTest
import Foundation
@testable import Silo

final class TrailerRailModelTests: XCTestCase {

    // MARK: - Fixtures

    private func video(
        _ siteKey: String,
        kind: String = "trailer",
        site: String = "youtube",
        name: String? = nil,
        official: Bool = true
    ) -> ItemVideo {
        ItemVideo(kind: kind, site: site, siteKey: siteKey, name: name, isOfficial: official)
    }

    private func extra(
        _ contentId: String,
        kind: String = "featurette",
        title: String? = nil
    ) -> ItemExtra {
        ItemExtra(contentId: contentId, kind: kind, title: title, durationSeconds: 120, fileId: 1)
    }

    // MARK: - Merge order

    func testRemoteVideosComeBeforeLocalExtrasInServerOrder() {
        let entries = TrailerRail.entries(
            videos: [video("k1"), video("k2", kind: "teaser")],
            extras: [extra("extra:1"), extra("extra:2")],
            allowRemote: true
        )

        XCTAssertEqual(
            entries.map(\.id),
            ["remote:youtube:k1", "remote:youtube:k2", "local:extra:1", "local:extra:2"],
            "remotes must lead in the server's order, then extras in theirs"
        )
    }

    func testNonYouTubeSitesAreDropped() {
        // The clients can only play YouTube; anything else would render a
        // card that cannot open.
        let entries = TrailerRail.entries(
            videos: [video("v1", site: "vimeo"), video("k1"), video("d1", site: "dailymotion")],
            extras: nil,
            allowRemote: true
        )

        XCTAssertEqual(entries.map(\.id), ["remote:youtube:k1"])
    }

    func testSiteMatchIsCaseInsensitive() {
        let entries = TrailerRail.entries(
            videos: [video("k1", site: "YouTube")],
            extras: nil,
            allowRemote: true
        )

        XCTAssertEqual(entries.count, 1)
    }

    func testAllowRemoteFalseDropsEveryRemoteButKeepsExtras() {
        // tvOS without the YouTube app installed: the local extras rail must
        // still render.
        let entries = TrailerRail.entries(
            videos: [video("k1"), video("k2")],
            extras: [extra("extra:1")],
            allowRemote: false
        )

        XCTAssertEqual(entries.map(\.id), ["local:extra:1"])
    }

    func testNilInputsProduceAnEmptyRail() {
        XCTAssertTrue(TrailerRail.entries(videos: nil, extras: nil, allowRemote: true).isEmpty)
        XCTAssertTrue(TrailerRail.entries(videos: [], extras: [], allowRemote: true).isEmpty)
    }

    func testRemoteAndLocalIdsCannotCollide() {
        // A local extra whose contentId equals a YouTube key must not shadow
        // the remote card in a ForEach.
        let entries = TrailerRail.entries(
            videos: [video("dup")],
            extras: [extra("dup")],
            allowRemote: true
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    }

    // MARK: - Titles

    func testEntryTitlePrefersServerNameThenFallsBackToKindLabel() {
        let named = TrailerRailEntry.remote(video("k1", name: "Official Trailer"))
        XCTAssertEqual(named.title, "Official Trailer")

        let unnamed = TrailerRailEntry.remote(video("k2", kind: "behind_the_scenes"))
        XCTAssertEqual(unnamed.title, "Behind the Scenes")

        let titled = TrailerRailEntry.local(extra("extra:1", title: "Making Of"))
        XCTAssertEqual(titled.title, "Making Of")

        let untitled = TrailerRailEntry.local(extra("extra:2", kind: "deleted_scene"))
        XCTAssertEqual(untitled.title, "Deleted Scene")
    }

    func testBlankServerNameFallsBackToKindLabel() {
        let blank = TrailerRailEntry.remote(video("k1", kind: "clip", name: "   "))
        XCTAssertEqual(blank.title, "Clip")
    }

    // MARK: - Kind labels

    func testKindLabelsMatchTheWebVocabulary() {
        XCTAssertEqual(ExtraKindLabels.label(for: "trailer"), "Trailer")
        XCTAssertEqual(ExtraKindLabels.label(for: "teaser"), "Teaser")
        XCTAssertEqual(ExtraKindLabels.label(for: "featurette"), "Featurette")
        XCTAssertEqual(ExtraKindLabels.label(for: "clip"), "Clip")
        XCTAssertEqual(ExtraKindLabels.label(for: "behind_the_scenes"), "Behind the Scenes")
        XCTAssertEqual(ExtraKindLabels.label(for: "bloopers"), "Bloopers")
        XCTAssertEqual(ExtraKindLabels.label(for: "deleted_scene"), "Deleted Scene")
        XCTAssertEqual(ExtraKindLabels.label(for: "other"), "Extra")
    }

    func testGroupLabelsMatchTheWebVocabulary() {
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "trailer"), "Trailers")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "teaser"), "Teasers")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "featurette"), "Featurettes")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "clip"), "Clips")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "behind_the_scenes"), "Behind the Scenes")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "bloopers"), "Bloopers")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "deleted_scene"), "Deleted Scenes")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "other"), "Other")
    }

    func testUnknownKindFallsBack() {
        // A kind the server grows later must never surface as a raw id.
        XCTAssertEqual(ExtraKindLabels.label(for: "opening_credits"), "Extra")
        XCTAssertEqual(ExtraKindLabels.groupLabel(for: "opening_credits"), "Other")
        XCTAssertEqual(ExtraKindLabels.label(for: ""), "Extra")
    }

    // MARK: - URLs

    func testRemoteURLConstruction() {
        let key = "tFMo3UJ4B4g"
        XCTAssertEqual(
            TrailerRail.thumbnailURL(siteKey: key)?.absoluteString,
            "https://i.ytimg.com/vi/tFMo3UJ4B4g/hqdefault.jpg"
        )
        // Full-URL form: the tvOS YouTube app ignores the iOS-style short
        // form `youtube://watch?v=` (opens on Home, id dropped) but plays
        // this one. Hardware-verified; see TrailerRail.youtubeDeepLinkURL.
        XCTAssertEqual(
            TrailerRail.youtubeDeepLinkURL(siteKey: key)?.absoluteString,
            "youtube://www.youtube.com/watch?v=tFMo3UJ4B4g"
        )
        XCTAssertEqual(
            TrailerRail.youtubeWatchURL(siteKey: key)?.absoluteString,
            "https://www.youtube.com/watch?v=tFMo3UJ4B4g"
        )
    }

    func testKeysWithUnderscoresAndHyphensSurviveURLConstruction() {
        // Real YouTube ids use the URL-safe base64 alphabet.
        let key = "a-B_c1D2e3F"
        XCTAssertEqual(
            TrailerRail.youtubeDeepLinkURL(siteKey: key)?.absoluteString,
            "youtube://www.youtube.com/watch?v=a-B_c1D2e3F"
        )
        XCTAssertEqual(
            TrailerRail.thumbnailURL(siteKey: key)?.absoluteString,
            "https://i.ytimg.com/vi/a-B_c1D2e3F/hqdefault.jpg"
        )
        XCTAssertEqual(
            TrailerRail.youtubeWatchURL(siteKey: key)?.absoluteString,
            "https://www.youtube.com/watch?v=a-B_c1D2e3F"
        )
    }
}
