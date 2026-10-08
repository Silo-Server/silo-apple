import XCTest
@testable import Silo

final class SubtitleAutoResolverTests: XCTestCase {
    private func track(
        id: Int64,
        lang: String?,
        forced: Bool = false,
        hearingImpaired: Bool = false,
        title: String? = nil,
        codec: String = "subrip",
        external: Bool = false,
        downloaded: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: id,
            kind: .sub,
            title: title,
            lang: lang,
            codec: codec,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: forced,
            isHearingImpaired: hearingImpaired,
            isExternal: external || downloaded,
            isSelected: false,
            ffIndex: external || downloaded ? nil : Int(id),
            srcId: external || downloaded ? Int(id) : nil,
            isDownloaded: downloaded
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
        disableWhenNoLanguageMatch: Bool = false,
        signature: SubtitleTrackSignature? = nil,
        sourceContainer: String? = nil
    ) -> SubtitleAutoResolver.Inputs {
        SubtitleAutoResolver.Inputs(
            preferredLanguage: preferredLanguage,
            additionalPreferredLanguages: additionalLanguages,
            mode: mode,
            showForced: showForced,
            forcedOnly: forcedOnly,
            preferAccessibilityTracks: preferAccessibility,
            disableWhenNoLanguageMatch: disableWhenNoLanguageMatch,
            trackSignature: signature,
            availableSubtitles: tracks,
            currentAudioLanguage: audioLanguage,
            sourceContainer: sourceContainer
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

    // MARK: - Embedded, external, and downloaded tracks (silo-server #1849)

    private func englishPick(
        _ tracks: [PlayerTrack],
        showForced: Bool = false,
        sourceContainer: String? = nil
    ) -> SubtitleAutoSelection {
        SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .always,
            showForced: showForced,
            tracks: tracks,
            audioLanguage: "ja",
            sourceContainer: sourceContainer
        ))
    }

    /// External sidecars come first in the V3 combined order, but one may
    /// have been cut for another release: the muxed track wins the tie.
    func testEmbeddedBeatsExternalInSameLanguage() {
        let external = track(id: 0, lang: "eng", codec: "srt", external: true)
        let embedded = track(id: 3, lang: "eng")
        XCTAssertEqual(englishPick([external, embedded]), .select(embedded))
    }

    func testExternalBeatsDownloaded() {
        let downloaded = track(id: 0, lang: "eng", codec: "srt", downloaded: true)
        let external = track(id: 1, lang: "eng", codec: "srt", external: true)
        XCTAssertEqual(englishPick([downloaded, external]), .select(external))
    }

    /// Track class outranks source: a file's own forced or SDH track never
    /// displaces the full external track the viewer asked for.
    func testEmbeddedForcedOrSDHDoesNotDisplaceFullExternal() {
        let external = track(id: 0, lang: "eng", codec: "srt", external: true)
        let forced = track(id: 3, lang: "eng", forced: true)
        let sdh = track(id: 4, lang: "eng", hearingImpaired: true)
        XCTAssertEqual(englishPick([external, forced, sdh], showForced: true), .select(external))
    }

    /// Original-file playback draws embedded PGS itself, so being a bitmap
    /// is no reason to lose to an external text file.
    func testEmbeddedPGSBeatsExternalText() {
        let external = track(id: 0, lang: "eng", codec: "srt", external: true)
        let pgs = track(id: 3, lang: "eng", codec: "hdmv_pgs_subtitle")
        XCTAssertFalse(SubtitleAutoResolver.needsBurnIn(pgs))
        XCTAssertEqual(englishPick([external, pgs]), .select(pgs))
    }

    /// A bitmap sidecar or download needs a server burn-in here, as does an
    /// embedded codec Aether has no decoder for.
    func testBurnInTracksLoseToRenderableTracks() {
        let externalPGS = track(id: 0, lang: "eng", codec: "pgs", external: true)
        let externalText = track(id: 1, lang: "eng", codec: "srt", external: true)
        let xsub = track(id: 3, lang: "eng", codec: "xsub")
        XCTAssertTrue(SubtitleAutoResolver.needsBurnIn(externalPGS))
        XCTAssertTrue(SubtitleAutoResolver.needsBurnIn(xsub))
        XCTAssertEqual(englishPick([externalPGS, xsub, externalText]), .select(externalText))
    }

    /// Native embedded bitmap rendering is per container: MKV only. Embedded
    /// PGS in MP4 or a Blu-ray M2TS needs a burn-in, so a sidecar wins there.
    func testEmbeddedPGSOutsideMKVLosesToExternalText() {
        let external = track(id: 0, lang: "eng", codec: "srt", external: true)
        let pgs = track(id: 3, lang: "eng", codec: "hdmv_pgs_subtitle")
        XCTAssertEqual(englishPick([external, pgs], sourceContainer: "mkv"), .select(pgs))
        XCTAssertEqual(englishPick([external, pgs], sourceContainer: "mp4"), .select(external))
        XCTAssertEqual(englishPick([external, pgs], sourceContainer: "m2ts"), .select(external))
    }

    func testBurnInTrackStillWinsWhenItIsTheOnlyMatch() {
        let externalPGS = track(id: 0, lang: "eng", codec: "pgs", external: true)
        let french = track(id: 3, lang: "fra")
        XCTAssertEqual(englishPick([externalPGS, french]), .select(externalPGS))
    }

    /// The remembered per-series track is not re-ranked: a signature that
    /// names an external track restores it over a same-language embedded one.
    func testSignatureNamingExternalTrackStillRestoresIt() {
        let external = track(id: 0, lang: "eng", title: "English (Director)", codec: "srt", external: true)
        let embedded = track(id: 3, lang: "eng", title: "English")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .always,
            showForced: false,
            tracks: [external, embedded],
            audioLanguage: "ja",
            signature: SubtitleTrackSignature(
                source: "external",
                language: "en",
                codec: "srt",
                label: "Director",
                forced: false,
                hearingImpaired: false
            )
        ))
        XCTAssertEqual(result, .select(external))
    }
}
