#if os(tvOS)
import XCTest
@testable import Silo

/// Apple TV search includes audiobooks when the top bar shows an audiobook
/// destination, however it got into the menu, or when the legacy per-device
/// opt-in is on and an audiobook library exists.
final class TVPrimaryMenuAudiobookSearchTests: XCTestCase {
    private let movies = Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
    private let books = Library(id: 4, name: "Audiobooks", type: "audiobooks", sortOrder: 1, posterUrl: nil)

    func testIncludesAudiobooksWhenTheMenuShowsThemOrTheLegacyOptInIsOn() {
        let videoOnly: [PrimaryMenuItem] = [.builtin(.home), .builtin(.movies)]
        let cases: [(String, [PrimaryMenuItem], [Library], Bool, Bool)] = [
            ("Audiobooks tab added in Customize Top Menu",
             [.builtin(.home), .builtin(.movies), .builtin(.audiobooks)], [movies, books], false, true),
            ("pinned audiobook library",
             [.builtin(.home), .library(libraryId: 4, label: "Audiobooks")], [movies, books], false, true),
            ("menu without audiobooks",
             videoOnly, [movies, books], false, false),
            ("Audiobooks tab but no audiobook library",
             [.builtin(.home), .builtin(.audiobooks)], [movies], false, false),
            ("pinned movie library only",
             [.builtin(.home), .library(libraryId: 1, label: "Movies")], [movies, books], false, false),
            ("legacy opt-in with a video-only synced menu",
             videoOnly, [movies, books], true, true),
            ("legacy opt-in without an audiobook library",
             videoOnly, [movies], true, false),
        ]
        for (name, items, libraries, legacyOptIn, expected) in cases {
            XCTAssertEqual(
                TVPrimaryMenuProjection.searchIncludesAudiobooks(
                    menuItems: items,
                    libraries: libraries,
                    legacyOptIn: legacyOptIn
                ),
                expected,
                name
            )
        }
    }
}
#endif
