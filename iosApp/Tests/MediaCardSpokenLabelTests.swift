@testable import Silo
import XCTest

/// A card's spoken label says the second line the card shows.
final class MediaCardSpokenLabelTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testASeriesCardSpeaksItsYearsLine() {
        XCTAssertEqual(
            mediaCardAccessibilityLabel(
                title: "Show", episodeLabel: nil, year: 2021, subtitle: "2021 – Present",
                isWatched: false, locale: english
            ),
            "Show, 2021 – Present"
        )
    }

    /// The episode label already spells out the code and title its line shows.
    func testAnEpisodeCardKeepsItsYear() {
        XCTAssertEqual(
            mediaCardAccessibilityLabel(
                title: "Show", episodeLabel: "Season 1, Episode 2, Pilot", year: 2021,
                subtitle: "S01E02 · Pilot", isWatched: true, locale: english
            ),
            "Show, Season 1, Episode 2, Pilot, 2021, Watched"
        )
    }
}
