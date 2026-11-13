import XCTest
import Foundation
@testable import Silo

/// Edition is the cut; Version is which file of that cut plays. Auto never
/// changes the cut.
final class DetailEditionSelectionTests: XCTestCase {

    /// Theatrical in 1080p, and a Director's Cut in 2160p and 1080p.
    private let versions: [FileVersion] = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data("""
        [
          { "file_id": 18, "edition_raw": "Theatrical", "edition_key": "theatrical", "resolution": "1080p" },
          { "file_id": 32, "edition_raw": "Directors Cut", "edition_key": "director_cut", "resolution": "2160p" },
          { "file_id": 185, "edition_raw": "Directors Cut", "edition_key": "director_cut", "resolution": "1080p" }
        ]
        """.utf8))
    }()

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

    /// With nothing played, the page opens on the edition holding the best
    /// file for the preference.
    func testWithNothingPlayedThePageOpensOnTheBestFilesEdition() {
        XCTAssertEqual(shown(quality: "auto"), 32)
        XCTAssertEqual(shown(quality: "1080p"), 18)
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

    /// Two files of the same resolution: Auto keeps the one last played.
    func testATieKeepsTheLastPlayedFile() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let twins = try! decoder.decode([FileVersion].self, from: Data("""
        [
          { "file_id": 40, "edition_key": "director_cut", "edition_raw": "Directors Cut", "resolution": "2160p" },
          { "file_id": 41, "edition_key": "director_cut", "edition_raw": "Directors Cut", "resolution": "2160p" }
        ]
        """.utf8))
        for last in [40, 41] {
            XCTAssertEqual(DetailVersionSelection.displayVersion(
                versions: twins, selectedFileId: nil, lastFileId: last, preferredQualityId: "auto"
            )?.fileId, last)
        }
    }

    /// When no file fits the cap, Auto takes the closest one above it.
    func testAutoTakesTheClosestFileAboveTheCap() {
        XCTAssertEqual(shown(edition: "director_cut", quality: "720p"), 185)
    }
}
