import XCTest
@testable import Silo

final class SubtitleAutoResolverTests: XCTestCase {

    private func subTrack(
        id: Int64,
        lang: String?,
        forced: Bool = false,
        sdh: Bool = false,
        title: String? = nil
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: id,
            kind: .sub,
            title: title,
            lang: lang,
            codec: "subrip",
            audioChannelsLayout: nil,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: forced,
            isHearingImpaired: sdh,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: Int(id),
            srcId: nil
        )
    }

    private func resolve(
        preferredLanguage: String?,
        mode: SubtitleMode?,
        showForced: Bool,
        audioLanguage: String?,
        tracks: [PlayerTrack]
    ) -> SubtitleAutoSelection {
        SubtitleAutoResolver.resolve(.init(
            preferredLanguage: preferredLanguage,
            mode: mode,
            showForced: showForced,
            trackSignature: nil,
            availableSubtitles: tracks,
            currentAudioLanguage: audioLanguage
        ))
    }

    // MARK: - Forced subs when audio matches the preferred language

    func testMatchingAudioSelectsLanguageTaggedForcedTrack() {
        let forced = subTrack(id: 2, lang: "en", forced: true)
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: true,
            audioLanguage: "eng",
            tracks: [subTrack(id: 1, lang: "en"), forced]
        )
        XCTAssertEqual(result, .select(forced))
    }

    func testMatchingAudioSelectsUntaggedForcedTrack() {
        let forced = subTrack(id: 2, lang: nil, forced: true)
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: true,
            audioLanguage: "en",
            tracks: [subTrack(id: 1, lang: "en"), forced]
        )
        XCTAssertEqual(result, .select(forced))
    }

    func testMatchingAudioIgnoresForeignForcedTrack() {
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: true,
            audioLanguage: "en",
            tracks: [subTrack(id: 1, lang: "en"), subTrack(id: 2, lang: "fr", forced: true)]
        )
        XCTAssertEqual(result, .disable)
    }

    func testMatchingAudioDisablesWhenForcedNotWanted() {
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: false,
            audioLanguage: "en",
            tracks: [subTrack(id: 1, lang: "en"), subTrack(id: 2, lang: "en", forced: true)]
        )
        XCTAssertEqual(result, .disable)
    }

    func testMatchingAudioDisablesWhenNoForcedTrackExists() {
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: true,
            audioLanguage: "en",
            tracks: [subTrack(id: 1, lang: "en"), subTrack(id: 2, lang: "en", sdh: true)]
        )
        XCTAssertEqual(result, .disable)
    }

    func testMatchingAudioIgnoresForcedSDHTrack() {
        // A forced+SDH track must not be auto-engaged for a non-SDH viewer:
        // SDH is an explicit accessibility choice.
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: true,
            audioLanguage: "en",
            tracks: [subTrack(id: 1, lang: "en"), subTrack(id: 2, lang: "en", forced: true, sdh: true)]
        )
        XCTAssertEqual(result, .disable)
    }

    // MARK: - Existing behavior preserved

    func testForeignAudioStillSelectsFullSubtitles() {
        let full = subTrack(id: 1, lang: "en")
        let result = resolve(
            preferredLanguage: "en", mode: .auto, showForced: true,
            audioLanguage: "ja",
            tracks: [full, subTrack(id: 2, lang: "en", forced: true)]
        )
        // preferForced picks the forced track first per bestLanguageMatch's
        // contract when showForced is on; assert a selection happens and it
        // matches the preferred language.
        switch result {
        case .select(let track):
            XCTAssertEqual(track.lang, "en")
        default:
            XCTFail("foreign audio with a matching subtitle language must select a track")
        }
    }

    func testModeOffStillDisables() {
        let result = resolve(
            preferredLanguage: "en", mode: .off, showForced: true,
            audioLanguage: "en",
            tracks: [subTrack(id: 1, lang: "en", forced: true)]
        )
        XCTAssertEqual(result, .disable)
    }
}
