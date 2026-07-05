import XCTest
@testable import Silo

final class SubtitleAutoResolverTests: XCTestCase {
    private func track(
        id: Int64,
        lang: String?,
        forced: Bool = false,
        hearingImpaired: Bool = false,
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
            isHearingImpaired: hearingImpaired,
            isVisualImpaired: false,
            isExternal: false,
            isSelected: false,
            ffIndex: Int(id),
            srcId: nil
        )
    }

    private func inputs(
        preferredLanguage: String?,
        mode: SubtitleMode?,
        showForced: Bool,
        tracks: [PlayerTrack],
        audioLanguage: String?
    ) -> SubtitleAutoResolver.Inputs {
        SubtitleAutoResolver.Inputs(
            preferredLanguage: preferredLanguage,
            mode: mode,
            showForced: showForced,
            trackSignature: nil,
            availableSubtitles: tracks,
            currentAudioLanguage: audioLanguage
        )
    }

    /// The living-room regression: foreign-language audio, English sub
    /// preference, "show forced" ON. The forced (signs-only) track must
    /// not win over the full dialogue track — signs tracks go silent for
    /// whole dialogue scenes and read as "subtitles stopped working".
    func testShowForcedDoesNotStealFullDialoguePick() {
        let forced = track(id: 13, lang: "eng", forced: true, title: "English (Forced)")
        let full = track(id: 14, lang: "eng", title: "English")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [forced, full],
            audioLanguage: "kor"
        ))
        XCTAssertEqual(result, .select(full))
    }

    /// Auto mode with audio already in the preferred language: full subs
    /// are redundant, and THIS is the case "show forced" exists for —
    /// select the forced track instead of disabling (Android parity).
    func testAudioLanguageMatchSelectsForcedWhenWanted() {
        let forced = track(id: 13, lang: "eng", forced: true)
        let full = track(id: 14, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [forced, full],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(forced))
    }

    func testAudioLanguageMatchDisablesWhenForcedNotWanted() {
        let forced = track(id: 13, lang: "eng", forced: true)
        let full = track(id: 14, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: false,
            tracks: [forced, full],
            audioLanguage: "en"
        ))
        XCTAssertEqual(result, .disable)
    }

    /// Full-dialogue preference also skips SDH tracks when a plain
    /// track exists in the language.
    func testFullPickPrefersNonHearingImpaired() {
        let sdh = track(id: 12, lang: "eng", hearingImpaired: true, title: "English (SDH)")
        let full = track(id: 14, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [sdh, full],
            audioLanguage: "kor"
        ))
        XCTAssertEqual(result, .select(full))
    }
}
