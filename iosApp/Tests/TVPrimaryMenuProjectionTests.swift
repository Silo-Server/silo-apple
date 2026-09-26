#if os(tvOS)
import XCTest
@testable import Silo

/// The Apple TV top bar and the Customize Top Menu editor share
/// `TVPrimaryMenuProjection`, so every destination the editor lists and
/// counts must become a bar root in the same order.
final class TVPrimaryMenuProjectionTests: XCTestCase {
    private let movies = Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
    private let audiobooks = Library(id: 5, name: "Audiobooks", type: "audiobooks", sortOrder: 1, posterUrl: nil)
    private let mixed = Library(id: 10, name: "Kids", type: "mixed", sortOrder: 2, posterUrl: nil)
    private let music = Library(id: 11, name: "Music", type: "music", sortOrder: 3, posterUrl: nil)

    func testExplicitAudiobooksEntryBecomesRootWhenAudiobookLibraryExists() {
        let roots = TVPrimaryMenuProjection.roots(
            for: [.builtin(.home), .builtin(.audiobooks), .builtin(.calendar)],
            libraries: [audiobooks]
        )

        XCTAssertEqual(roots, [.home, .libraryType(.audiobooks), .calendar])
    }

    func testPinnedAudiobookLibraryBecomesShortcutRoot() {
        let roots = TVPrimaryMenuProjection.roots(
            for: [.builtin(.home), .library(libraryId: 5, label: "Audiobooks")],
            libraries: [audiobooks]
        )

        XCTAssertEqual(roots, [.home, .libraryShortcut(libraryId: 5, label: "Audiobooks")])
        XCTAssertEqual(roots.map(\.title), ["Home", "Audiobooks"])
    }

    func testBarRootCountMatchesEditorCount() {
        let menu: [PrimaryMenuItem] = [
            .builtin(.home),
            .builtin(.movies),
            .builtin(.series),
            .builtin(.music),
            .builtin(.audiobooks),
            .builtin(.forYou),
            .builtin(.calendar),
            .library(libraryId: 10, label: "Kids"),
            .library(libraryId: 99, label: "Gone"),
            .section(libraryId: 10, sectionId: "s1", label: "Section"),
            .collection(collectionId: "c1", label: "Collection", libraryId: nil),
        ]
        let librarySets: [[Library]] = [
            [],
            [movies, audiobooks],
            [mixed, music],
        ]

        for libraries in librarySets {
            let ids = libraries.map(\.id)
            let visible = TVPrimaryMenuProjection.visibleItems(in: menu, libraries: libraries)
            let roots = TVPrimaryMenuProjection.roots(for: menu, libraries: libraries)

            XCTAssertEqual(roots.count, visible.count, "libraries \(ids)")
            let expected = visible.compactMap(Self.expectedRoot(for:))
            XCTAssertEqual(roots, expected, "libraries \(ids)")
            XCTAssertEqual(roots.map(\.title), expected.map(\.title), "libraries \(ids)")
        }
    }

    func testUnavailableAndUnsupportedItemsAreHidden() {
        let roots = TVPrimaryMenuProjection.roots(
            for: [
                .builtin(.home),
                .builtin(.audiobooks),
                .builtin(.music),
                .library(libraryId: 99, label: "Gone"),
                .section(libraryId: 1, sectionId: "s1", label: "Section"),
                .collection(collectionId: "c1", label: "Collection", libraryId: nil),
                .builtin(.forYou),
                .builtin(.calendar),
            ],
            libraries: [movies]
        )

        XCTAssertEqual(roots, [.home, .recommendations, .calendar])
    }

    func testHomeIsInsertedFirstAndDuplicatesCollapse() {
        let roots = TVPrimaryMenuProjection.roots(
            for: [.builtin(.movies), .builtin(.calendar), .builtin(.movies)],
            libraries: [movies]
        )

        XCTAssertEqual(roots, [.home, .libraryType(.movies), .calendar])
    }

    /// Independent statement of the editor-item to bar-root mapping, so the
    /// order check does not reuse the projection's own switch.
    private static func expectedRoot(for item: PrimaryMenuItem) -> TVRootDestination? {
        switch item {
        case .builtin(.home): return .home
        case .builtin(.movies): return .libraryType(.movies)
        case .builtin(.series): return .libraryType(.series)
        case .builtin(.music): return .libraryType(.music)
        case .builtin(.audiobooks): return .libraryType(.audiobooks)
        case .builtin(.forYou): return .recommendations
        case .builtin(.calendar): return .calendar
        case .library(let libraryId, let label): return .libraryShortcut(libraryId: libraryId, label: label)
        case .section, .collection: return nil
        }
    }
}
#endif
