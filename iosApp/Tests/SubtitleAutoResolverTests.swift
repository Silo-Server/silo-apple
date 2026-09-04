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
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: forced,
            isHearingImpaired: hearingImpaired,
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
        audioLanguage: String?,
        additionalLanguages: [String] = [],
        forcedOnly: Bool = false,
        preferAccessibility: Bool = false,
        disableWhenNoLanguageMatch: Bool = false
    ) -> SubtitleAutoResolver.Inputs {
        SubtitleAutoResolver.Inputs(
            preferredLanguage: preferredLanguage,
            additionalPreferredLanguages: additionalLanguages,
            mode: mode,
            showForced: showForced,
            forcedOnly: forcedOnly,
            preferAccessibilityTracks: preferAccessibility,
            disableWhenNoLanguageMatch: disableWhenNoLanguageMatch,
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

    /// Tracks labelled CC/SDH in the title but missing the ffmpeg
    /// hearing-impaired disposition flag are still demoted below a plain
    /// track in the same language.
    func testFullPickDemotesTitleOnlyCCTracks() {
        let cc = track(id: 12, lang: "eng", title: "English (CC)")
        let sdh = track(id: 13, lang: "eng", title: "English SDH")
        let full = track(id: 14, lang: "eng", title: "English")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: false,
            tracks: [cc, sdh, full],
            audioLanguage: "kor"
        ))
        XCTAssertEqual(result, .select(full))
    }

    /// The CC token check must not misread ordinary words containing
    /// "cc" — a title like "Soccer Cut" is a normal dialogue track.
    func testCCTokenDoesNotMatchInsideWords() {
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesHearingImpaired("Soccer Cut"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesHearingImpaired("English (CC)"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesHearingImpaired("English [SDH]"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesHearingImpaired("Closed Captions"))
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesHearingImpaired(nil))
    }

    func testSystemLanguageStackFallsBackInOrder() {
        let french = track(id: 10, lang: "fra")
        let spanish = track(id: 11, lang: "spa")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "de-DE",
            mode: .always,
            showForced: false,
            tracks: [spanish, french],
            audioLanguage: "eng",
            additionalLanguages: ["es-ES", "fr-FR"]
        ))
        XCTAssertEqual(result, .select(spanish))
    }

    func testExactRegionalLanguageWinsBeforePrimarySubtagFallback() {
        let brazilianPortuguese = track(id: 10, lang: "pt-BR")
        let portugalPortuguese = track(id: 11, lang: "pt-PT")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "pt-PT",
            mode: .always,
            showForced: false,
            tracks: [brazilianPortuguese, portugalPortuguese],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(portugalPortuguese))
    }

    func testFullDialogueTrackBeatsExactRegionalForcedTrack() {
        let exactForced = track(id: 10, lang: "pt-PT", forced: true)
        let genericFull = track(id: 11, lang: "pt")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "pt-PT",
            mode: .always,
            showForced: true,
            tracks: [exactForced, genericFull],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(genericFull))
    }

    func testRegionalLanguageStackExhaustsExactMatchesBeforeFallback() {
        let arbitraryFallback = track(id: 10, lang: "pt-AO")
        let exactSecondPreference = track(id: 11, lang: "pt-PT")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "pt-BR",
            mode: .always,
            showForced: false,
            tracks: [arbitraryFallback, exactSecondPreference],
            audioLanguage: "eng",
            additionalLanguages: ["pt-PT"]
        ))
        XCTAssertEqual(result, .select(exactSecondPreference))
    }

    func testSystemLanguageMatchesArbitraryISOThreeLetterMetadata() {
        let dutch = track(id: 10, lang: "nld")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "nl-NL",
            mode: .always,
            showForced: false,
            tracks: [dutch],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(dutch))
        XCTAssertTrue(SubtitleAutoResolver.languagesMatch("dut", "nl-NL"))
    }

    func testSystemAccessibilityCharacteristicPrefersSDH() {
        let plain = track(id: 10, lang: "eng", title: "English")
        let sdh = track(id: 11, lang: "eng", hearingImpaired: true, title: "English SDH")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .always,
            showForced: false,
            tracks: [plain, sdh],
            audioLanguage: "eng",
            preferAccessibility: true
        ))
        XCTAssertEqual(result, .select(sdh))
    }

    func testSystemForcedOnlyNeverSelectsFullDialogueTrack() {
        let full = track(id: 10, lang: "eng")
        let forcedSpanish = track(id: 11, lang: "spa", forced: true)
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [full, forcedSpanish],
            audioLanguage: "eng",
            additionalLanguages: ["es"],
            forcedOnly: true
        ))
        XCTAssertEqual(result, .select(forcedSpanish))
    }

    func testSystemForcedOnlyDisablesWhenNoForcedTrackExists() {
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [track(id: 10, lang: "eng")],
            audioLanguage: "eng",
            forcedOnly: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testSystemPolicyDisablesWhenNoSubtitleTracksAreAvailable() {
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .always,
            showForced: false,
            tracks: [],
            audioLanguage: "eng",
            disableWhenNoLanguageMatch: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testSystemForcedOnlyDoesNotSelectUnrequestedLanguage() {
        let frenchForced = track(id: 11, lang: "fra", forced: true)
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [frenchForced],
            audioLanguage: "eng",
            forcedOnly: true,
            disableWhenNoLanguageMatch: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testSystemLanguageMissClearsExistingServerSelection() {
        let english = track(id: 10, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "es",
            mode: .always,
            showForced: false,
            tracks: [english],
            audioLanguage: "eng",
            disableWhenNoLanguageMatch: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testServerLanguageMissStillLeavesExistingSelectionAlone() {
        let english = track(id: 10, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "es",
            mode: .always,
            showForced: false,
            tracks: [english],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .noChange)
    }
}
