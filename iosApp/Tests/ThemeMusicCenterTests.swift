import Foundation
import XCTest
@testable import Silo

/// When a title page plays its theme: the setting, the server capability, the
/// page's own lifecycle, other media and the selected season decide.
@MainActor
final class ThemeMusicCenterTests: XCTestCase {
    private final class FakeOutput: ThemeAudioOutput {
        var volume: Float = 1
        var isLooping = false
        var isPlaying = false
        var isTornDown = false
        var tearDowns = 0
        var onEnded: (() -> Void)?
        var onFailed: (() -> Void)?
        var onProgress: (() -> Void)?
        func play() { isPlaying = true }
        func pause() { isPlaying = false }
        func tearDown() { isPlaying = false; isTornDown = true; tearDowns += 1 }
    }

    private var grants: [String] = []
    private var outputs: [FakeOutput] = []
    private var capabilityAvailable = true
    private var capabilityReads = 0
    private var seasonThemes: [String: ThemeSongSet] = [:]
    private var seasonReads: [String] = []
    private var heldSeason: String?
    private var heldSeasonLookup: CheckedContinuation<Void, Never>?
    private var identity = "server-1/profile-a"

    private func makeCenter() -> ThemeMusicCenter {
        let controller = ThemeMusicController(
            grant: { [unowned self] owner, theme in
                grants.append("\(owner)#\(theme)")
                return ThemeMusicGrant(url: URL(string: "https://silo.example/\(owner)/\(theme)")!, isConverted: false)
            },
            makeOutput: { [unowned self] _ in
                let output = FakeOutput()
                outputs.append(output)
                return output
            },
            fade: { output, target, done in
                output.volume = target
                done()
            }
        )
        return ThemeMusicCenter(
            controller: controller,
            identity: { [unowned self] in identity },
            capability: { [unowned self] in
                capabilityReads += 1
                return capabilityAvailable
            },
            seasonThemes: { [unowned self] id in
                seasonReads.append(id)
                if id == heldSeason {
                    await withCheckedContinuation { heldSeasonLookup = $0 }
                }
                return seasonThemes[id]
            }
        )
    }

    private func themes(_ owner: String, _ id: String = "7") -> ThemeSongSet {
        ThemeSongSet(ownerId: owner, items: [ThemeSong(id: id, title: nil, durationSeconds: nil, container: "mp3")])
    }

    private func page(_ themes: ThemeSongSet?, season: String? = nil, enabled: Bool = true, loop: Bool = false,
                      loading: Bool = false, visible: Bool = true, otherMedia: Bool = false) -> ThemeMusicPage {
        ThemeMusicPage(themes: themes, seasonContentId: season, isLoading: loading, isVisible: visible,
                       isOtherMediaActive: otherMedia, enabled: enabled, loop: loop)
    }

    func testAnOpenPagePlaysItsThemeWhenEnabledAndAvailable() async {
        let center = makeCenter()
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertEqual(grants, ["movie:heat#7"])
        XCTAssertEqual(outputs.first?.isPlaying, true)
    }

    func testThemeMusicIsOptIn() async {
        let center = makeCenter()
        center.show(page(themes("movie:heat"), enabled: false), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertTrue(grants.isEmpty)
        XCTAssertEqual(capabilityReads, 0, "a profile that never opted in asks the server nothing")
    }

    func testAServerWithoutTheCapabilityStaysSilent() async {
        capabilityAvailable = false
        let center = makeCenter()
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertEqual(capabilityReads, 1)
        XCTAssertTrue(grants.isEmpty)
    }

    func testLeavingThePageStopsTheTheme() async {
        let center = makeCenter()
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        center.leave(id: "page-1")

        XCTAssertEqual(outputs.first?.isTornDown, true)
    }

    func testAnOlderPageLeavingAfterTheNextOneOpenedKeepsTheNewTheme() async {
        // Pushing B over A: SwiftUI can report B's appearance before A's disappearance.
        let center = makeCenter()
        center.show(page(themes("movie:a")), id: "page-a")
        await center.waitUntilSettled()
        center.show(page(themes("movie:b")), id: "page-b")
        await center.waitUntilSettled()

        center.leave(id: "page-a")

        XCTAssertEqual(grants, ["movie:a#7", "movie:b#7"])
        XCTAssertEqual(outputs.last?.isPlaying, true)
    }

    func testStartingOtherMediaStopsTheThemeAtOnce() async {
        let center = makeCenter()
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()
        outputs.first?.onProgress?()

        center.show(page(themes("movie:heat"), otherMedia: true), id: "page-1")

        XCTAssertEqual(outputs.first?.isTornDown, true)
        XCTAssertEqual(outputs.first?.volume, ThemeMusicController.themeVolume, "torn down without a fade under the player")
    }

    func testAHiddenOrLoadingPageSuspendsAndResumesInPlace() async {
        let center = makeCenter()
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        center.show(page(themes("movie:heat"), visible: false), id: "page-1")
        XCTAssertEqual(outputs.first?.isPlaying, false)
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(outputs.first?.isPlaying, true)
    }

    func testASeasonWithItsOwnThemesPlaysThem() async {
        seasonThemes["season:alpha-2"] = themes("season:alpha-2", "11")
        let center = makeCenter()
        center.show(page(themes("series:alpha"), season: "season:alpha-2"), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertEqual(seasonReads, ["season:alpha-2"])
        XCTAssertEqual(grants.last, "season:alpha-2#11")
    }

    func testASeasonThatInheritsKeepsTheSeriesThemePlaying() async {
        seasonThemes["season:alpha-1"] = themes("series:alpha")
        let center = makeCenter()
        center.show(page(themes("series:alpha"), season: "season:alpha-1"), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertEqual(grants, ["series:alpha#7"])
        XCTAssertEqual(outputs.count, 1)
    }

    func testAnotherProfileStopsTheThemeAndAsksAgain() async {
        let center = makeCenter()
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        identity = "server-1/profile-b"
        center.show(page(themes("movie:heat")), id: "page-1")
        await center.waitUntilSettled()

        XCTAssertEqual(outputs.first?.isTornDown, true)
        XCTAssertEqual(capabilityReads, 2, "the capability is the profile's")
    }

    func testSwitchingSeasonsKeepsTheThemePlayingWhileTheNewSeasonResolves() async {
        seasonThemes["season:alpha-1"] = themes("series:alpha")
        seasonThemes["season:alpha-2"] = themes("season:alpha-2", "11")
        heldSeason = "season:alpha-2"
        let center = makeCenter()
        center.show(page(themes("series:alpha"), season: "season:alpha-1"), id: "page-1")
        await center.waitUntilSettled()

        center.show(page(themes("series:alpha"), season: "season:alpha-2"), id: "page-1")
        while heldSeasonLookup == nil { await Task.yield() }

        XCTAssertEqual(outputs.first?.isPlaying, true, "no silence while the season's own set is looked up")

        heldSeasonLookup?.resume()
        await center.waitUntilSettled()
        XCTAssertEqual(grants.last, "season:alpha-2#11")
    }

    func testAnotherPagesThemePausesWhileTheNewPagesSeasonResolves() async {
        seasonThemes["season:beta-1"] = themes("season:beta-1", "21")
        heldSeason = "season:beta-1"
        let center = makeCenter()
        center.show(page(themes("movie:a")), id: "page-a")
        await center.waitUntilSettled()

        center.show(page(themes("series:beta"), season: "season:beta-1"), id: "page-b")
        while heldSeasonLookup == nil { await Task.yield() }

        XCTAssertEqual(outputs.first?.isPlaying, false, "title A's theme does not play over title B")

        heldSeasonLookup?.resume()
        await center.waitUntilSettled()
        XCTAssertEqual(grants.last, "season:beta-1#21")
    }
}
