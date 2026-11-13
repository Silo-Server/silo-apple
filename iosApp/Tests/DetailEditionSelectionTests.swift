import XCTest
import Foundation
@testable import Silo

/// Edition is the cut; Version is which file of that cut plays. Auto never
/// changes the cut.
final class DetailEditionSelectionTests: XCTestCase {

    private func decode(_ json: String) -> [FileVersion] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data(json.utf8))
    }

    /// Theatrical in 1080p, and a Director's Cut in 2160p and 1080p.
    private lazy var versions: [FileVersion] = decode("""
    [
      { "file_id": 18, "edition_raw": "Theatrical", "edition_key": "theatrical", "resolution": "1080p" },
      { "file_id": 32, "edition_raw": "Directors Cut", "edition_key": "director_cut", "resolution": "2160p" },
      { "file_id": 185, "edition_raw": "Directors Cut", "edition_key": "director_cut", "resolution": "1080p" }
    ]
    """)

    private func shown(
        pinned: Int? = nil,
        edition: String? = nil,
        lastFileId: Int? = nil,
        lastEditionKey: String? = nil,
        quality: String
    ) -> Int? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: pinned,
            lastFileId: lastFileId,
            lastFileInProgress: false,
            preferredQualityId: quality,
            editionId: edition,
            lastEditionKey: lastEditionKey
        )?.fileId
    }

    /// The viewer last watched the 4K Director's Cut, then capped quality at
    /// 1080p. The page stays on the Director's Cut and Auto takes its 1080p
    /// file, not the last-played 4K one or the Theatrical 1080p file.
    func testAutoStaysInTheLastPlayedCutUnderAQualityCap() {
        XCTAssertEqual(shown(lastFileId: 32, quality: "1080p"), 185)
        XCTAssertEqual(shown(lastFileId: 32, lastEditionKey: "director_cut", quality: "1080p"), 185)
        XCTAssertEqual(shown(lastFileId: 32, quality: "auto"), 32)
    }

    /// The last-played edition is `last_edition_key`, else the edition of
    /// `last_file_id`; an empty key falls through to the file.
    func testTheLastPlayedEditionComesFromTheEditionKeyThenTheFile() {
        XCTAssertEqual(shown(lastFileId: 32, lastEditionKey: "theatrical", quality: "auto"), 18)
        XCTAssertEqual(shown(lastFileId: 18, lastEditionKey: "", quality: "auto"), 18)
        XCTAssertEqual(shown(lastFileId: 18, lastEditionKey: " Director_Cut ", quality: "auto"), 32)
    }

    /// With nothing played, each cut's Auto file competes: a file that fits
    /// beats one above the cap beats an unknown one, then the higher rank,
    /// then HDR, then the standard cut before a theatrical one before the
    /// rest. File size never decides between cuts.
    func testWithNothingPlayedThePageComparesEachCutsAutoFile() {
        XCTAssertEqual(shown(quality: "auto"), 32)
        XCTAssertEqual(shown(quality: "1080p"), 18, "a 1080p tie goes to Theatrical over the Director's Cut")

        let cuts = decode("""
        [
          { "file_id": 1, "edition_key": "theatrical", "edition_raw": "Theatrical", "resolution": "1080p", "file_size": 90 },
          { "file_id": 2, "resolution": "1080p", "file_size": 10 },
          { "file_id": 3, "edition_key": "extended", "edition_raw": "Extended", "resolution": "1080p", "hdr": true },
          { "file_id": 4, "edition_key": "imax", "edition_raw": "IMAX", "resolution": "" }
        ]
        """)
        func opening(_ ids: [Int], quality: String = "auto") -> Int? {
            DetailVersionSelection.displayVersion(
                versions: cuts.filter { ids.contains($0.fileId) },
                selectedFileId: nil,
                lastFileId: nil,
                lastFileInProgress: false,
                preferredQualityId: quality
            )?.fileId
        }
        XCTAssertEqual(opening([1, 2]), 2, "the unnamed cut over Theatrical, though its file is smaller")
        XCTAssertEqual(opening([1, 2, 3]), 3, "HDR before edition preference")
        XCTAssertEqual(opening([3, 4], quality: "720p"), 3, "above the cap before unknown")
    }

    /// Picking an edition keeps Auto: its best file, even when another
    /// edition holds a better one. A pinned file wins over both.
    func testAPickedEditionKeepsAutoWithinIt() {
        XCTAssertEqual(shown(edition: "theatrical", lastFileId: 32, quality: "auto"), 18)
        XCTAssertEqual(shown(edition: "director_cut", lastFileId: 18, quality: "1080p"), 185)
        XCTAssertEqual(shown(pinned: 32, edition: "director_cut", quality: "1080p"), 32)
    }

    /// Version opens only when the current edition has a choice.
    func testVersionOpensOnlyWithTwoFilesInTheEdition() {
        let byId = Dictionary(uniqueKeysWithValues: versions.map { ($0.fileId, $0) })
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableVersionSelector(versions: versions, currentVersion: byId[18]))
        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableVersionSelector(versions: versions, currentVersion: byId[185]))
    }

    /// Within a cut Auto follows the server's order: rank (8K included),
    /// then HDR, then the larger file. The last-played file breaks no tie.
    func testAutoFollowsTheServersFileOrder() {
        let files = decode("""
        [
          { "file_id": 40, "resolution": "2160p", "hdr": false, "file_size": 90 },
          { "file_id": 41, "resolution": "2160p", "hdr": true, "file_size": 40 },
          { "file_id": 42, "resolution": "2160p", "hdr": true, "file_size": 60 },
          { "file_id": 43, "resolution": "4320p" }
        ]
        """)
        func auto(_ ids: [Int], lastFileId: Int? = nil) -> Int? {
            DetailVersionSelection.displayVersion(
                versions: files.filter { ids.contains($0.fileId) },
                selectedFileId: nil,
                lastFileId: lastFileId,
                lastFileInProgress: false,
                preferredQualityId: "auto"
            )?.fileId
        }
        XCTAssertEqual(auto([40, 41, 42, 43]), 43)
        XCTAssertEqual(auto([40, 41]), 41, "HDR before SDR")
        XCTAssertEqual(auto([41, 42], lastFileId: 41), 42, "the larger file")
    }

    /// A file of unknown resolution never fits a cap: one above the cap
    /// plays first, and the unknown one only when nothing else is known.
    func testUnknownResolutionIsALastResort() {
        let files = decode("""
        [
          { "file_id": 50, "resolution": "" },
          { "file_id": 51, "resolution": "2160p" }
        ]
        """)
        XCTAssertEqual(DetailVersionSelection.displayVersion(
            versions: files, selectedFileId: nil, lastFileId: nil, lastFileInProgress: false, preferredQualityId: "1080p"
        )?.fileId, 51)
        XCTAssertEqual(DetailVersionSelection.displayVersion(
            versions: [files[0]], selectedFileId: nil, lastFileId: nil, lastFileInProgress: false, preferredQualityId: "1080p"
        )?.fileId, 50)
    }

    /// Auto ranks first parts only, merging a cut's single file with its
    /// multi-part set. While the title is in progress, a later part last
    /// played stays on the page so Resume continues it.
    func testAutoSkipsLaterPartsButResumesOne() {
        let files = decode("""
        [
          { "file_id": 60, "resolution": "2160p" },
          { "file_id": 61, "resolution": "1080p", "presentation_group_key": "g",
            "presentation_part_index": 1, "presentation_part_total": 2 },
          { "file_id": 62, "resolution": "4320p", "presentation_group_key": "g",
            "presentation_part_index": 2, "presentation_part_total": 2 }
        ]
        """)
        func shown(lastFileId: Int?, pinned: Int? = nil) -> FileVersion? {
            DetailVersionSelection.displayVersion(
                versions: files, selectedFileId: pinned, lastFileId: lastFileId, lastFileInProgress: true, preferredQualityId: "auto"
            )
        }
        XCTAssertEqual(shown(lastFileId: nil)?.fileId, 60)
        XCTAssertEqual(shown(lastFileId: 62)?.fileId, 62)
        XCTAssertEqual(shown(lastFileId: 62, pinned: 60)?.fileId, 60)
    }

    /// Play resolves its file from the watch state its resume position came
    /// from, and sends the page's track picks only with the file they were
    /// made on. Start Over on part 2 starts part 1 without part 2's picks
    /// (Off stays); a position another device saved on part 2 resumes part
    /// 2, not the part 1 the page's older snapshot showed. Play keeps the
    /// cut on screen: a position saved on another cut starts this one's Auto
    /// at 0, not at the other cut's position.
    func testPlayStartsThePartItsPositionBelongsTo() throws {
        let parts = decode("""
        [
          { "file_id": 61, "resolution": "1080p", "presentation_group_key": "g",
            "presentation_part_index": 1, "presentation_part_total": 2 },
          { "file_id": 62, "resolution": "1080p", "presentation_group_key": "g",
            "presentation_part_index": 2, "presentation_part_total": 2 },
          { "file_id": 70, "resolution": "1080p", "edition_key": "theatrical", "edition_raw": "Theatrical" }
        ]
        """)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let onPartTwo = try decoder.decode(LeafItemUserData.self, from: Data(
            #"{ "played": false, "position_seconds": 600, "last_file_id": 62 }"#.utf8
        ))
        let finished = try decoder.decode(LeafItemUserData.self, from: Data(
            #"{ "played": true, "position_seconds": 0, "last_file_id": 62 }"#.utf8
        ))
        let onTheatrical = try decoder.decode(LeafItemUserData.self, from: Data(
            #"{ "played": false, "position_seconds": 900, "last_file_id": 70, "last_edition_key": "theatrical" }"#.utf8
        ))
        func start(
            shownWith snapshot: LeafItemUserData,
            startsWith watchState: LeafItemUserData,
            fromBeginning: Bool,
            subtitle: Int? = 3
        ) -> DetailVersionSelection.PageStart {
            DetailVersionSelection.pageStart(
                versions: parts, pinnedFileId: nil, editionId: nil,
                shownWith: snapshot, startsWith: watchState,
                resumePosition: fromBeginning ? nil : watchState.positionSeconds, preferredQualityId: "auto",
                startFromBeginning: fromBeginning, audioTrackIndex: 2, subtitleTrackIndex: subtitle
            )
        }
        typealias Start = DetailVersionSelection.PageStart
        XCTAssertEqual(start(shownWith: onPartTwo, startsWith: onPartTwo, fromBeginning: false),
                       Start(fileId: 62, audioTrackIndex: 2, subtitleTrackIndex: 3, resumePosition: 600))
        XCTAssertEqual(start(shownWith: onPartTwo, startsWith: onPartTwo, fromBeginning: true),
                       Start(fileId: 61, audioTrackIndex: nil, subtitleTrackIndex: nil, resumePosition: nil))
        XCTAssertEqual(start(shownWith: onPartTwo, startsWith: onPartTwo, fromBeginning: true, subtitle: -1),
                       Start(fileId: 61, audioTrackIndex: nil, subtitleTrackIndex: -1, resumePosition: nil))
        XCTAssertEqual(start(shownWith: finished, startsWith: onPartTwo, fromBeginning: false),
                       Start(fileId: 62, audioTrackIndex: nil, subtitleTrackIndex: nil, resumePosition: 600))
        XCTAssertEqual(start(shownWith: onPartTwo, startsWith: onTheatrical, fromBeginning: false),
                       Start(fileId: 61, audioTrackIndex: nil, subtitleTrackIndex: nil, resumePosition: 0),
                       "Theatrical's 900 s doesn't apply; 0, not nil, so the player won't read it back")
    }

    /// Without a position Resume would offer, a later part last played no
    /// longer holds Auto: a title finished on its last part rewatches from
    /// part 1, as does one stopped in its first seconds. A rewatch in
    /// progress keeps its part, though the title stays played.
    func testAFinishedMultipartTitleStartsAtPartOne() throws {
        let parts = decode("""
        [
          { "file_id": 61, "resolution": "1080p", "presentation_group_key": "g",
            "presentation_part_index": 1, "presentation_part_total": 2 },
          { "file_id": 62, "resolution": "1080p", "presentation_group_key": "g",
            "presentation_part_index": 2, "presentation_part_total": 2 }
        ]
        """)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func shown(_ userData: String) throws -> Int? {
            let user = try decoder.decode(LeafItemUserData.self, from: Data(userData.utf8))
            return DetailVersionSelection.displayVersion(
                versions: parts,
                selectedFileId: nil,
                lastFileId: user.lastFileId,
                lastFileInProgress: user.hasResumePoint,
                preferredQualityId: "auto"
            )?.fileId
        }
        XCTAssertEqual(try shown(#"{ "played": true, "position_seconds": 0, "last_file_id": 62 }"#), 61)
        XCTAssertEqual(try shown(#"{ "played": true, "position_seconds": 600, "last_file_id": 62 }"#), 62)
        XCTAssertEqual(try shown(#"{ "played": false, "position_seconds": 10, "last_file_id": 62 }"#), 61)
    }

    /// A start without a detail page (a home card's Play, a deep link)
    /// picks the way the page does, so it doesn't switch to the Theatrical
    /// file that also fits the 1080p cap. Continue Watching still resumes
    /// the last-played file, and when that file is gone, Auto in its cut.
    func testAStartWithoutThePageStaysInTheLastPlayedCut() {
        func start(lastFileId: Int = 32, lastEditionKey: String? = nil, resuming: Bool = false) -> Int {
            PlaybackSessionBridge.startSelection(
                versions: versions,
                requestedFileId: nil,
                lastFileId: lastFileId,
                lastFileInProgress: false,
                lastEditionKey: lastEditionKey,
                prefersLastUsedVersion: resuming,
                startsAtFirstPart: false,
                preferredQualityOverride: nil,
                settingsQuality: AppleQualityAxes(resolution: "1080p", bitrateKbps: nil)
            ).version.fileId
        }
        XCTAssertEqual(start(), 185)
        XCTAssertEqual(start(lastEditionKey: "director_cut"), 185)
        XCTAssertEqual(start(lastEditionKey: "theatrical"), 18)
        XCTAssertEqual(start(resuming: true), 32)
        XCTAssertEqual(start(lastFileId: 99, lastEditionKey: "director_cut", resuming: true), 185)
        XCTAssertEqual(start(), shown(lastFileId: 32, quality: "1080p"))
    }

    /// A quality picked in the player and carried to a reload (`1080p-low`
    /// is a server rung, not a Settings id) still caps by its resolution.
    func testAnInPlayerQualityOverrideStillCapsTheStart() {
        let start = PlaybackSessionBridge.startSelection(
            versions: versions,
            requestedFileId: nil,
            lastFileId: 32,
            lastFileInProgress: false,
            lastEditionKey: "director_cut",
            prefersLastUsedVersion: false,
            startsAtFirstPart: false,
            preferredQualityOverride: "1080p-low",
            settingsQuality: .auto
        )
        XCTAssertEqual(start.version.fileId, 185)
        XCTAssertEqual(shown(lastFileId: 32, lastEditionKey: "director_cut", quality: "junk"), 32, "an unknown id is Auto")
    }

    /// When the connection moves the selected episode to another file, Auto
    /// and Off carry over; a track index named a stream of the old file and
    /// is replaced by what Auto picks on the new one.
    func testASubtitleChoiceAcrossAFileChangeKeepsAutoAndOff() {
        let reseed = { Optional(4) }
        XCTAssertNil(DetailPlaybackFormatting.subtitleIndexAfterFileChange(nil, reseed: reseed), "Auto")
        XCTAssertEqual(DetailPlaybackFormatting.subtitleIndexAfterFileChange(-1, reseed: reseed), -1, "Off")
        XCTAssertEqual(DetailPlaybackFormatting.subtitleIndexAfterFileChange(2, reseed: reseed), 4)
        XCTAssertNil(DetailPlaybackFormatting.subtitleIndexAfterFileChange(2) { nil })
    }

    /// When no file fits the cap, Auto takes the closest one above it.
    func testAutoTakesTheClosestFileAboveTheCap() {
        XCTAssertEqual(shown(edition: "director_cut", quality: "720p"), 185)
    }
}
