import XCTest
@testable import Silo

/// Covers telling an external subtitle's catalog ordinal apart from an
/// embedded FFmpeg stream index.
///
/// The catalog reports both in the same field. A sidecar picked on the item
/// card therefore reached playback looking like an explicit embedded choice:
/// it selected a stream the file does not have, and it suppressed the
/// resolver that restores the pick from the stored signature, so the player
/// started with subtitles off.
final class ExternalSubtitleIndexTests: XCTestCase {
    private func tracks(_ json: String) throws -> [SubtitleTrack] {
        // Decode the way HTTPClient does, so a fixture that spells a wire key
        // in snake_case (external_path, hearing_impaired) exercises the same
        // mapping production uses instead of silently arriving nil.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([SubtitleTrack].self, from: Data(json.utf8))
    }

    /// An embedded track and a sidecar that the server numbered as well.
    private func mixedTracks() throws -> [SubtitleTrack] {
        try tracks("""
        [
          {"index": 2, "language": "eng", "codec": "subrip", "external": false},
          {"index": 4, "language": "pol", "codec": "srt", "external": true}
        ]
        """)
    }

    func testAnExternalOrdinalIsNotAnEmbeddedIndex() throws {
        XCTAssertTrue(
            PlayerViewModel.namesExternalSubtitle(4, in: try mixedTracks()),
            "Index 4 belongs to the sidecar, not to an FFmpeg stream."
        )
    }

    func testAnEmbeddedIndexIsLeftAlone() throws {
        XCTAssertFalse(
            PlayerViewModel.namesExternalSubtitle(2, in: try mixedTracks()),
            "A genuine embedded pick must still reach the player."
        )
    }

    func testTheOffSentinelIsNeverTreatedAsATrack() throws {
        XCTAssertFalse(
            PlayerViewModel.namesExternalSubtitle(-1, in: try mixedTracks()),
            "-1 means subtitles off and must survive untouched."
        )
    }

    func testAnUnknownIndexIsLeftAlone() throws {
        XCTAssertFalse(PlayerViewModel.namesExternalSubtitle(9, in: try mixedTracks()))
    }

    func testNoIndexAndNoTracksAreHandled() throws {
        XCTAssertFalse(PlayerViewModel.namesExternalSubtitle(nil, in: try mixedTracks()))
        XCTAssertFalse(PlayerViewModel.namesExternalSubtitle(4, in: nil))
        XCTAssertFalse(PlayerViewModel.namesExternalSubtitle(4, in: []))
    }

    /// An embedded track may omit `index`; `selectionIndex` reads that as
    /// stream 0, and stream 0 must not be mistaken for a sidecar.
    func testAnEmbeddedTrackWithoutAnIndexIsStreamZero() throws {
        let t = try tracks("""
        [{"language": "eng", "codec": "subrip", "external": false}]
        """)
        XCTAssertFalse(PlayerViewModel.namesExternalSubtitle(0, in: t))
    }

    /// A sidecar the server did not number has no index at all, so nothing
    /// can be confused with it.
    func testAnUnnumberedSidecarMatchesNothing() throws {
        let t = try tracks("""
        [{"language": "pol", "codec": "srt", "external": true}]
        """)
        XCTAssertFalse(PlayerViewModel.namesExternalSubtitle(0, in: t))
    }
}
