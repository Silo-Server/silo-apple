import XCTest
import Foundation
@testable import Silo

/// Pins the surfaces that were de-duplicated out of the detail screens: the
/// one runtime label, and the pre-play "Auto: …" subtitle preview now that it
/// runs the player's own `SubtitleAutoResolver` instead of a private mirror.
final class DetailSharedFormattingTests: XCTestCase {

    // MARK: - RuntimeLabel

    func testRuntimeLabelStylesDifferOnlyBelowAnHour() {
        XCTAssertEqual(RuntimeLabel.minutes(64, style: .compact), "1h 4m")
        XCTAssertEqual(RuntimeLabel.minutes(64, style: .spelled), "1h 4m")
        XCTAssertEqual(RuntimeLabel.minutes(42, style: .compact), "42m")
        XCTAssertEqual(RuntimeLabel.minutes(42, style: .spelled), "42 min")
    }

    func testRuntimeLabelElidesAZeroRemainderAndDropsEmptyRuntimes() {
        XCTAssertEqual(RuntimeLabel.minutes(120, style: .compact), "2h")
        XCTAssertEqual(RuntimeLabel.minutes(120, style: .spelled), "2h")
        XCTAssertNil(RuntimeLabel.minutes(0, style: .compact))
        XCTAssertNil(RuntimeLabel.minutes(-5, style: .compact))
        XCTAssertNil(RuntimeLabel.minutes(nil, style: .spelled))
    }

    // MARK: - Auto subtitle preview

    private func version(_ json: String) -> FileVersion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data(json.utf8))[0]
    }

    private var twoLanguageVersion: FileVersion {
        version("""
        [
          {
            "file_id": 1,
            "subtitle_tracks": [
              { "index": 2, "codec": "subrip", "language": "eng" },
              { "index": 3, "codec": "subrip", "language": "jpn" }
            ]
          }
        ]
        """)
    }

    private func autoLabel(
        version: FileVersion,
        context: DetailPlaybackFormatting.SubtitleAutoContext
    ) -> String {
        DetailPlaybackFormatting.subtitleValueLabel(
            version: version,
            selectedSubtitleTrackIndex: nil,
            autoContext: context
        )
    }

    func testAutoPreviewPicksThePreferredLanguageTrack() {
        let label = autoLabel(
            version: twoLanguageVersion,
            context: .init(preferredLanguage: "jpn", mode: "auto", signature: nil)
        )
        XCTAssertEqual(label, "Auto: Japanese · SRT")
    }

    func testAutoPreviewIsOffWhenTheAudioAlreadyMatchesTheSubtitleLanguage() {
        let label = autoLabel(
            version: twoLanguageVersion,
            context: .init(
                preferredLanguage: "eng",
                mode: "auto",
                signature: nil,
                audioLanguage: "eng"
            )
        )
        XCTAssertEqual(label, "Auto: Off")
    }

    func testAutoPreviewIsOffWhenTheModeIsOff() {
        let label = autoLabel(
            version: twoLanguageVersion,
            context: .init(preferredLanguage: "jpn", mode: "off", signature: nil)
        )
        XCTAssertEqual(label, "Auto: Off")
    }

    func testAutoPreviewFollowsARememberedTrackSignature() {
        let label = autoLabel(
            version: twoLanguageVersion,
            context: .init(
                preferredLanguage: "eng",
                mode: "auto",
                signature: SubtitleTrackSignature(language: "jpn", codec: "subrip"),
                audioLanguage: "eng"
            )
        )
        XCTAssertEqual(label, "Auto: Japanese · SRT")
    }

    /// With no preference the resolver reports "leave the player alone"; the
    /// player then keeps the media's default track, which is what
    /// `PlaybackSessionBridge` freezes into the plan — so the pill has to
    /// show that track rather than "Off".
    func testAutoPreviewShowsTheDefaultTrackWhenThereIsNoPreference() {
        let version = version("""
        [
          {
            "file_id": 1,
            "subtitle_tracks": [
              { "index": 2, "codec": "subrip", "language": "eng" },
              { "index": 3, "codec": "subrip", "language": "jpn", "default": true }
            ]
          }
        ]
        """)
        let label = autoLabel(
            version: version,
            context: .init(preferredLanguage: nil, mode: "auto", signature: nil)
        )
        XCTAssertEqual(label, "Auto: Japanese · SRT")
    }
}
