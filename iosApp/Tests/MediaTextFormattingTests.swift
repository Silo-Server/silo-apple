import Foundation
import XCTest
@testable import Silo

/// Every screen that shows an item's resolution or runtime must print the
/// same text for the same value. The shared rules are the card overlays',
/// which match the web client and Android; each surface test compares a
/// screen's output with those rules.
final class MediaTextFormattingTests: XCTestCase {
    func testResolutionLabelsFollowTheCardOverlayRules() {
        let cases: [(input: String?, expected: String?)] = [
            ("2160p", "4K"), ("4k", "4K"), ("UHD", "4K"),
            ("4320p", "8K"), ("8k", "8K"),
            ("1080p", "1080p"), ("1080P", "1080p"), ("720p", "720p"), ("480p", "480p"),
            (" 1080p\n", "1080p"),
            ("sd", "SD"), ("p", "P"), ("hdp", "HDP"),
            (nil, nil), ("", nil), ("  ", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MediaTextFormatting.resolution(input), expected, "input: \(String(describing: input))")
        }
    }

    func testRuntimeLabelsUseHoursAndMinutes() {
        let cases: [(minutes: Int?, expected: String?)] = [
            (1, "1m"), (45, "45m"), (59, "59m"),
            (60, "1h 0m"), (65, "1h 5m"), (229, "3h 49m"),
            (0, nil), (-5, nil), (nil, nil),
        ]
        for (minutes, expected) in cases {
            XCTAssertEqual(MediaTextFormatting.runtime(minutes: minutes), expected, "minutes: \(String(describing: minutes))")
        }
    }

    /// The overlay labels mirror web's registry. Moving them onto the shared
    /// helper must not change them.
    func testCardOverlaysKeepTheirLabels() {
        var data = OverlayData()
        data.resolution = "1080p"
        data.hdr = "HDR10"
        data.runtime = 45
        XCTAssertEqual(overlayValue(.resolution, data), "1080p")
        XCTAssertEqual(overlayValue(.resolutionHdr, data), "1080p HDR")
        XCTAssertEqual(overlayValue(.runtime, data), "45m")

        data.resolution = "2160p"
        data.runtime = 60
        XCTAssertEqual(overlayValue(.resolution, data), "4K")
        XCTAssertEqual(overlayValue(.resolutionHdr, data), "4K HDR")
        XCTAssertEqual(overlayValue(.runtime, data), "1h 0m")
    }

#if os(tvOS)
    func testMarqueeChipsAndRuntimeMatchTheCardOverlay() throws {
        let item = try sectionItem(
            #"{"contentId":"movie","type":"movie","title":"Movie","runtime":45,"overlaySummary":{"resolution":"1080p"}}"#
        )
        let content = TVMarqueeContent(item: item, rowTitle: "Movies")
        let overlay = OverlayData.from(item)

        XCTAssertEqual(content.badges, ["1080p"])
        XCTAssertEqual(content.badges.first, overlayValue(.resolution, overlay))
        XCTAssertEqual(content.runtimeText, "45m")
        XCTAssertEqual(content.runtimeText, overlayValue(.runtime, overlay))
        XCTAssertEqual(content.metaParts, ["45m"])
    }

    func testContinueWatchingMarqueeLineUsesOneMinuteStyle() throws {
        let item = try sectionItem(
            #"{"contentId":"episode","type":"episode","title":"Hide and Seek","seriesTitle":"Severance","seasonNumber":2,"episodeNumber":7,"runtime":45,"positionSeconds":1320,"durationSeconds":2700}"#
        )
        let content = TVMarqueeContent(item: item, rowTitle: "Continue Watching", isContinueWatching: true)

        XCTAssertEqual(content.metaParts, ["S2 E7", "Hide and Seek", "45m", "23m left"])
    }

    func testMarqueeEnrichmentRuntimeMatchesTheDetailHero() throws {
        let detail = try itemDetail(#"{"content_id":"movie","type":"movie","title":"Movie","runtime":60}"#)

        XCTAssertEqual(TVMarqueeEnrichment(detail: detail).runtimeText, "1h 0m")
        XCTAssertEqual(TVHeroMetadata.movieFactsLine(from: detail), [.text("1h 0m")])
    }

    func testDetailHeroPrintsTheEpisodeRailMinuteStyle() throws {
        let movie = try itemDetail(#"{"content_id":"movie","type":"movie","title":"Movie","runtime":45}"#)
        let episode = try episodeListItem(runtime: 45)

        XCTAssertEqual(TVHeroMetadata.movieFactsLine(from: movie), [.text("45m")])
        XCTAssertEqual(
            TVHeroMetadata.seriesEpisodeFactsLine(episode: episode, playbackDetail: nil, selectedVersion: nil),
            [.text("45m")]
        )
    }

    @MainActor
    func testContinueWatchingSavedFileChipMatchesTheCardOverlay() async throws {
        let id = "media-format-\(UUID().uuidString)"
        let cache = ResponseCache.shared
        defer { cache.removeItemMetadata(contentId: id) }
        let detail = try itemDetail("""
        {
          "content_id":"\(id)","type":"movie","title":"Movie",
          "user_data":{"played":false,"last_file_id":2},
          "versions":[{"file_id":1,"resolution":"2160p"},{"file_id":2,"resolution":"1080p"}]
        }
        """)
        cache.set(detail, for: CacheKey.itemDetail(id))

        let store = TVContinueWatchingPlaybackMetadataStore.shared
        _ = await store.load(contentId: id, progressUpdatedAt: "rev-1", baseOverlayData: OverlayData())
        let presentation = try XCTUnwrap(store.presentation(for: id))

        XCTAssertEqual(presentation.badges.first, "1080p")
        XCTAssertEqual(presentation.badges.first, overlayValue(.resolution, presentation.overlayData))
    }
#else
    func testPhoneHeroPrintsTheEpisodeRowMinuteStyle() throws {
        let movie = try itemDetail(#"{"content_id":"movie","type":"movie","title":"Movie","runtime":45}"#)

        XCTAssertEqual(PhoneHeroMetadata.movieFactsLine(from: movie), [.text("45m")])
        XCTAssertEqual(PhoneEpisodeFormatting.metadataLine(for: try episodeListItem(runtime: 45)), "45m")
        XCTAssertEqual(PhoneEpisodeFormatting.metadataLine(for: try episodeListItem(runtime: 60)), "1h 0m")
    }

    func testHomeResumeCaptionUsesTheSharedRuntime() {
        XCTAssertEqual(HomeFeedMeta.remaining(position: 1320, duration: 2700), "23m left")
        XCTAssertEqual(HomeFeedMeta.remaining(position: 600, duration: 4200), "1h 0m left")
        XCTAssertEqual(HomeFeedMeta.remaining(position: 600, duration: 4500), "1h 5m left")
    }
#endif

    // MARK: - Helpers

    private func overlayValue(_ id: OverlayId, _ data: OverlayData) -> String? {
        OverlayRegistry.all.first { $0.id == id }?.getValue(data)
    }

    private func sectionItem(_ json: String) throws -> SectionItem {
        try JSONDecoder().decode(SectionItem.self, from: Data(json.utf8))
    }

    private func itemDetail(_ json: String) throws -> ItemDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }

    private func episodeListItem(runtime: Int) throws -> EpisodeListItem {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            EpisodeListItem.self,
            from: Data(#"{"content_id":"episode","season_number":1,"episode_number":1,"runtime":\#(runtime)}"#.utf8)
        )
    }
}
