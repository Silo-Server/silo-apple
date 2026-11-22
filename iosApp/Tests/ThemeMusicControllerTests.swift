import Foundation
import XCTest
@testable import Silo

/// The detail-page theme player, driven through its public surface with a fake
/// grant source and a fake audio output. Mirrors the web player's lifecycle
/// (`web/src/lib/themeMusic.ts` in silo-server).
@MainActor
final class ThemeMusicControllerTests: XCTestCase {
    private final class FakeOutput: ThemeAudioOutput {
        let url: URL
        var volume: Float = 1
        var isLooping = false
        var isPlaying = false
        var playCount = 0
        var isTornDown = false
        var tearDowns = 0
        var onEnded: (() -> Void)?
        var onFailed: (() -> Void)?
        var onProgress: (() -> Void)?

        init(url: URL) { self.url = url }
        func play() { isPlaying = true; playCount += 1 }
        func pause() { isPlaying = false }
        func tearDown() { isPlaying = false; isTornDown = true; tearDowns += 1 }
    }

    private struct Request: Equatable {
        let owner: String
        let theme: String
    }

    private var requests: [Request] = []
    private var outputs: [FakeOutput] = []
    private var deliveries: [Bool] = []
    private var grantFailures = 0
    private var heldGrant: CheckedContinuation<Void, Never>?
    private var holdNextGrant = false
    /// Fades ramp at once unless held; a held fade's completion waits here.
    private var holdFades = false
    private var heldFadeCompletions: [@MainActor () -> Void] = []

    private func makeController() -> ThemeMusicController {
        ThemeMusicController(
            grant: { [unowned self] owner, theme in
                requests.append(Request(owner: owner, theme: theme))
                if holdNextGrant {
                    holdNextGrant = false
                    await withCheckedContinuation { heldGrant = $0 }
                }
                if grantFailures > 0 {
                    grantFailures -= 1
                    throw URLError(.badServerResponse)
                }
                let converted = deliveries.isEmpty ? false : deliveries.removeFirst()
                return ThemeMusicGrant(url: URL(string: "https://silo.example/theme/\(theme)/\(requests.count)")!,
                                       isConverted: converted)
            },
            makeOutput: { [unowned self] grant in
                let output = FakeOutput(url: grant.url)
                outputs.append(output)
                return output
            },
            fade: { [unowned self] output, target, done in
                guard !holdFades else {
                    heldFadeCompletions.append(done)
                    return
                }
                output.volume = target
                done()
            }
        )
    }

    private func set(_ owner: String = "series:alpha", _ ids: String...) -> ThemeSongSet {
        ThemeSongSet(ownerId: owner, items: (ids.isEmpty ? ["7"] : ids).map {
            ThemeSong(id: $0, title: nil, durationSeconds: nil, container: "mp3")
        })
    }

    func testSelectingAThemeSetPlaysItsFirstThemeAtThemeVolume() async {
        let music = makeController()

        music.select(set("series:alpha", "7", "8"), loop: true)
        await music.waitUntilSettled()

        XCTAssertEqual(requests, [Request(owner: "series:alpha", theme: "7")])
        let output = try! XCTUnwrap(outputs.first)
        XCTAssertTrue(output.isPlaying)
        XCTAssertTrue(output.isLooping, "original audio loops in place")
        output.onProgress?()
        XCTAssertEqual(output.volume, ThemeMusicController.themeVolume)
    }

    func testTheFadeInWaitsUntilTheAudioIsActuallyPlaying() async {
        // A converted theme is downloaded before it can start; a fade run
        // meanwhile would leave it starting abruptly at full theme volume.
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()
        XCTAssertEqual(outputs[0].volume, 0)

        outputs[0].onProgress?()

        XCTAssertEqual(outputs[0].volume, ThemeMusicController.themeVolume)
    }

    func testAThemeSuspendedBeforeItsAudioStartedStaysSilent() async {
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        music.suspend()
        outputs[0].onProgress?()

        XCTAssertFalse(outputs[0].isPlaying)
        XCTAssertEqual(outputs[0].volume, 0)
    }

    func testTheSameThemeKeepsPlayingAcrossPagesThatInheritIt() async {
        // Series, then one of its seasons without its own themes.
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        music.select(set(), loop: false)
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertTrue(outputs[0].isPlaying)
        XCTAssertFalse(outputs[0].isLooping)
    }

    func testAnotherOwnerReplacesTheTheme() async {
        let music = makeController()
        music.select(set("movie:a"), loop: false)
        await music.waitUntilSettled()

        music.select(set("movie:b"), loop: false)
        await music.waitUntilSettled()

        XCTAssertEqual(requests.map(\.owner), ["movie:a", "movie:b"])
        XCTAssertTrue(outputs[0].isTornDown)
        XCTAssertTrue(outputs[1].isPlaying)
    }

    func testAnEmptyOrMissingSetStopsTheTheme() async {
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        music.select(ThemeSongSet(ownerId: "series:alpha", items: []), loop: false)
        await music.waitUntilSettled()

        XCTAssertTrue(outputs[0].isTornDown)
    }

    func testStopFadesOutAndTearsDown() async {
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        music.stop()

        XCTAssertEqual(outputs[0].volume, 0)
        XCTAssertTrue(outputs[0].isTornDown)
    }

    func testAGrantThatArrivesAfterStopIsDiscarded() async {
        let music = makeController()
        holdNextGrant = true
        music.select(set(), loop: false)
        while heldGrant == nil { await Task.yield() }

        music.stop()
        heldGrant?.resume()
        await music.waitUntilSettled()

        XCTAssertTrue(outputs.isEmpty, "a page left before its grant arrived must stay silent")
    }

    func testSuspendPausesAndReselectingResumesWithoutANewGrant() async {
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        music.suspend()
        XCTAssertFalse(outputs[0].isPlaying)

        music.select(set(), loop: false)
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertTrue(outputs[0].isPlaying)
    }

    func testAConvertedThemeLoopsWithAFreshGrant() async {
        deliveries = [true, true]
        let music = makeController()
        music.select(set(), loop: true)
        await music.waitUntilSettled()
        XCTAssertFalse(outputs[0].isLooping, "a converted stream cannot seek back to its start")

        outputs[0].onProgress?()
        outputs[0].onEnded?()
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertNotEqual(outputs[0].url, outputs[1].url)
        XCTAssertTrue(outputs[0].isTornDown)
        XCTAssertTrue(outputs[1].isPlaying)
    }

    func testAConvertedThemeWithoutLoopPlaysOnce() async {
        deliveries = [true]
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        outputs[0].onProgress?()
        outputs[0].onEnded?()
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 1)
    }

    func testAFailedStreamRetriesOnceWithAFreshGrant() async {
        let music = makeController()
        music.select(set(), loop: true)
        await music.waitUntilSettled()

        outputs[0].onFailed?()
        await music.waitUntilSettled()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(outputs[1].isPlaying)

        outputs[1].onFailed?()
        await music.waitUntilSettled()
        XCTAssertEqual(requests.count, 2, "a second failure gives up")
        XCTAssertTrue(outputs[1].isTornDown)
    }

    func testPlaybackProgressRestoresTheRetryForALaterExpiry() async {
        let music = makeController()
        music.select(set(), loop: true)
        await music.waitUntilSettled()

        outputs[0].onFailed?()
        await music.waitUntilSettled()
        outputs[1].onProgress?()
        outputs[1].onFailed?()
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(outputs[2].isPlaying)
    }

    func testAConvertedStreamThatEndsWithoutPlayingShareTheSingleRetry() async {
        deliveries = [true, true, true]
        let music = makeController()
        music.select(set(), loop: true)
        await music.waitUntilSettled()

        outputs[0].onEnded?()
        await music.waitUntilSettled()
        outputs[1].onEnded?()
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 2, "a conversion that fails cleanly cannot replay forever")
    }

    func testARefusedGrantLeavesThePageSilent() async {
        grantFailures = 1
        let music = makeController()
        music.select(set(), loop: true)
        await music.waitUntilSettled()

        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(outputs.isEmpty)
    }

    func testTurningLoopOnLaterAppliesToThePlayingOriginal() async {
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()

        music.select(set(), loop: true)

        XCTAssertTrue(outputs[0].isLooping)
        XCTAssertEqual(requests.count, 1)
    }

    func testAnImmediateStopSilencesAThemeStillFadingOut() async {
        // Leaving a page fades its theme out; a player starting meanwhile must
        // not play under it, nor lose the audio session to its late teardown.
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()
        outputs[0].onProgress?()
        holdFades = true
        music.stop()
        XCTAssertFalse(outputs[0].isTornDown, "still fading out")

        music.stop(.handOff)

        XCTAssertTrue(outputs[0].isTornDown)
        heldFadeCompletions.forEach { $0() }
        XCTAssertEqual(outputs[0].tearDowns, 1, "the finished fade does not tear it down again")
    }

    func testAThemeThatEndedWithoutLoopingIsLetGoAndStaysFinished() async {
        let music = makeController()
        music.select(set(), loop: false)
        await music.waitUntilSettled()
        outputs[0].onProgress?()

        outputs[0].onEnded?()

        XCTAssertTrue(outputs[0].isTornDown, "the finished player is let go")

        // The page staying open, or coming back from the background, does not replay it.
        music.select(set(), loop: false)
        music.suspend()
        music.select(set(), loop: false)
        await music.waitUntilSettled()
        XCTAssertEqual(requests.count, 1)
    }

    func testAThemeFadingOutFinishesItsFadeWhenNoPlayerTakesOver() async {
        // Leaving A, then opening B while A fades: B resolving is no player
        // starting, so A fades out fully instead of being cut off.
        let music = makeController()
        music.select(set("movie:a"), loop: false)
        await music.waitUntilSettled()
        outputs[0].onProgress?()
        holdFades = true
        music.stop()

        music.suspend()
        music.stop(.silence)
        XCTAssertFalse(outputs[0].isTornDown)

        heldFadeCompletions.forEach { $0() }
        XCTAssertEqual(outputs[0].tearDowns, 1)
    }
}
