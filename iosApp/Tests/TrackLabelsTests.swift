import XCTest
@testable import Silo

/// The detail page and the player describe the same track the same way.
final class TrackLabelsTests: XCTestCase {
    private func playerTrack(
        kind: PlayerTrack.Kind,
        title: String?,
        lang: String?,
        codec: String?,
        channels: Int? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        ffIndex: Int = 3
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: 3, kind: kind, title: title, lang: lang, codec: codec,
            audioChannelCount: channels, bitrate: nil, isDefault: isDefault,
            isForced: isForced, isHearingImpaired: false, isExternal: false,
            isSelected: false, ffIndex: ffIndex, srcId: nil
        )
    }

    func testAudioReadsTheSameOnTheDetailPageAndInThePlayer() {
        let detail = AudioTrack(
            index: 3, codec: "eac3", channels: 6, channelLayout: nil, bitrate: nil,
            sampleRate: nil, language: "eng", title: "Commentary", embeddedTitle: nil, isDefault: true
        )
        let player = playerTrack(kind: .audio, title: "Commentary", lang: "eng", codec: "eac3",
                                 channels: 6, isDefault: true)

        XCTAssertEqual(player.primaryLabel, DetailPlaybackFormatting.audioTitle(detail, ordinal: 0))
        XCTAssertEqual(player.primaryLabel, "English")
        XCTAssertEqual(player.attributesLabel,
                       DetailPlaybackFormatting.audioDetail(detail, ordinal: 0, version: nil))
        XCTAssertEqual(player.attributesLabel, "Commentary · EAC3 · 5.1 · Default")
    }

    func testCodecOnlyAudioTitleGivesWayToTheLanguage() {
        let player = playerTrack(kind: .audio, title: "Dolby TrueHD 7.1", lang: "jpn", codec: "truehd", channels: 8)
        XCTAssertEqual(player.primaryLabel, "Japanese")
        XCTAssertNil(player.detailLabel)
        XCTAssertEqual(player.attributePillLabels(), ["TrueHD", "7.1"])
    }

    func testSubtitlesReadTheSameOnTheDetailPageAndInThePlayer() {
        let detail = SubtitleTrack(
            index: 4, codec: "subrip", language: "fre", title: "Signs & Songs", embeddedTitle: nil,
            forced: true, hearingImpaired: nil, isDefault: nil, external: nil, externalPath: nil
        )
        let player = playerTrack(kind: .sub, title: "Signs & Songs", lang: "fre", codec: "subrip", isForced: true)

        XCTAssertEqual(player.primaryLabel, DetailPlaybackFormatting.subtitleTitle(detail, ordinal: 0))
        XCTAssertEqual(player.primaryLabel, "French")
        XCTAssertEqual(player.attributesLabel,
                       DetailPlaybackFormatting.subtitleDetail(detail, ordinal: 0, isSelectable: true))
        XCTAssertEqual(player.attributesLabel, "Signs & Songs · SRT · Forced")
    }

    func testFormatNameSubtitleTitleIsDroppedAndTitleFlagsBecomePills() {
        let player = playerTrack(kind: .sub, title: "SDH", lang: "eng", codec: "hdmv_pgs_subtitle")
        XCTAssertEqual(player.primaryLabel, "English")
        XCTAssertNil(player.detailLabel)
        XCTAssertEqual(player.attributePillLabels(), ["PGS", "SDH"])
        XCTAssertEqual(
            playerTrack(kind: .sub, title: "ASS", lang: nil, codec: "ass").primaryLabel,
            "Track 3"
        )
    }

    func testAudioTitleDropsCodecNamesButKeepsWordsThatContainThem() {
        for codecTitle in ["AAC2.0", "DTS-HD MA 5.1", "DTSHD", "Dolby TrueHD Atmos", "E-AC-3 JOC", "EAC3", "FLAC"] {
            XCTAssertNil(TrackLabels.audioTitle(codecTitle), codecTitle)
        }
        for title in ["Commentary by Isaac", "Midtsommar Director's Cut", "Flack Interview"] {
            XCTAssertEqual(TrackLabels.audioTitle(title), title)
        }
    }

    /// A role named alongside the codec is the part worth showing; without
    /// it, "Main AAC" and "Director Commentary AAC" read the same.
    func testAudioTitleKeepsTheRoleBesideTheCodec() {
        let cases: [(String, String)] = [
            ("Main AAC", "Main"),
            ("Director Commentary AAC", "Director Commentary"),
            ("Commentary (DTS-HD MA 5.1)", "Commentary"),
            ("Descriptive Audio - Dolby Digital Plus 5.1", "Descriptive Audio"),
            ("AAC2.0 Isolated Score", "Isolated Score"),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(TrackLabels.audioTitle(title), expected, title)
        }
        for codecTitle in ["DTS-HD Master Audio 7.1", "DTS:X", "Dolby Digital Plus 5.1", "DD+ 5.1", "Stereo", "6ch", "atsc a/52b (ac-3, e-ac-3)"] {
            XCTAssertNil(TrackLabels.audioTitle(codecTitle), codecTitle)
        }

        let commentary = playerTrack(kind: .audio, title: "Director Commentary AAC", lang: "eng", codec: "aac", channels: 2)
        let main = playerTrack(kind: .audio, title: "Main AAC", lang: "eng", codec: "aac", channels: 2)
        XCTAssertEqual(commentary.attributesLabel, "Director Commentary · AAC · Stereo")
        XCTAssertEqual(main.attributesLabel, "Main · AAC · Stereo")
        // What is left is only the language the row already leads with.
        XCTAssertNil(playerTrack(kind: .audio, title: "English AC3 5.1", lang: "eng", codec: "ac3", channels: 6).detailLabel)
    }

    /// An untitled stream reaches the player as AetherEngine's made-up name,
    /// "ENG (eac3)" or "Track 1 (aac)". It restates the language and codec,
    /// so the row reads like the detail page: "English" / "EAC3 · 5.1".
    func testDemuxerMadeUpNamesAddNoDetailLine() {
        let english = playerTrack(kind: .audio, title: "ENG (eac3)", lang: "eng", codec: "eac3",
                                  channels: 6, isDefault: true)
        XCTAssertEqual(english.primaryLabel, "English")
        XCTAssertNil(english.detailLabel)
        XCTAssertEqual(english.attributesLabel, "EAC3 · 5.1 · Default")

        let french = playerTrack(kind: .audio, title: "FRE (ac3)", lang: "fre", codec: "ac3", channels: 2)
        XCTAssertEqual(french.primaryLabel, "French")
        XCTAssertEqual(french.attributesLabel, "AC3 · Stereo")

        let unnamed = playerTrack(kind: .audio, title: "Track 1 (aac)", lang: nil, codec: "aac", ffIndex: 1)
        XCTAssertEqual(unnamed.primaryLabel, "Track 3")
        XCTAssertNil(unnamed.detailLabel)

        let subtitle = playerTrack(kind: .sub, title: "ENG (subrip)", lang: "eng", codec: "subrip")
        XCTAssertEqual(subtitle.primaryLabel, "English")
        XCTAssertEqual(subtitle.attributesLabel, "SRT")

        // The same names arriving without the track ids that identify them
        // as made up still reduce to nothing.
        XCTAssertNil(TrackLabels.audioTitle("ENG (eac3)", language: "eng"))
        XCTAssertNil(TrackLabels.audioTitle("FRE (ac3)", language: "fr"))
        XCTAssertNil(TrackLabels.audioTitle("Track 1 (aac)"))
    }

    func testAudioTitleDropsWordsNamingTheTracksLanguage() {
        XCTAssertEqual(TrackLabels.audioTitle("English Commentary", language: "en"), "Commentary")
        XCTAssertEqual(TrackLabels.audioTitle("Commentary (ENG)", language: "eng"), "Commentary")
        XCTAssertEqual(TrackLabels.audioTitle("Japanese Dub", language: "jpn"), "Dub")
        // A title naming another language is what tells the track apart.
        XCTAssertEqual(TrackLabels.audioTitle("English Dub", language: "jpn"), "English Dub")

        let detail = AudioTrack(
            index: 1, codec: "ac3", channels: 6, channelLayout: nil, bitrate: nil,
            sampleRate: nil, language: "eng", title: "English 5.1", embeddedTitle: nil, isDefault: nil
        )
        XCTAssertEqual(DetailPlaybackFormatting.audioDetail(detail, ordinal: 0, version: nil), "AC3 · 5.1")
    }

    func testAudioTitleDropsMoreCodecNames() {
        for codecTitle in ["Opus 5.1", "MP3", "PCM", "pcm_s24le", "Vorbis Stereo", "ALAC", "FLAC 2.0",
                           "EC-3", "True HD 7.1", "DTS-HD HRA", "DTS-ES 6.1", "DTSX"] {
            XCTAssertNil(TrackLabels.audioTitle(codecTitle), codecTitle)
        }
        XCTAssertEqual(TrackLabels.audioTitle("Commentary (Opus)"), "Commentary")
    }

    /// Release groups stamp every track with the release name; it never
    /// leads a row or fills its detail line.
    func testReleaseNameTitlesAreDropped() {
        let release = "Movie (2026) [Remux-2160p HEVC DV]"
        let subtitle = playerTrack(kind: .sub, title: release, lang: "eng", codec: "subrip")
        XCTAssertEqual(subtitle.primaryLabel, "English")
        XCTAssertNil(subtitle.detailLabel)
        XCTAssertEqual(playerTrack(kind: .sub, title: release, lang: nil, codec: "subrip").primaryLabel, "Track 3")

        let audio = playerTrack(kind: .audio, title: "Movie.2026.1080p.BluRay.x264", lang: "eng", codec: "aac", channels: 2)
        XCTAssertEqual(audio.primaryLabel, "English")
        XCTAssertNil(audio.detailLabel)
    }

    /// Surfaces that show only a name, such as the phone remote, keep what
    /// tells same-language tracks apart.
    func testSingleLineLabelCarriesTheQualifiers() {
        XCTAssertEqual(
            playerTrack(kind: .audio, title: "Commentary", lang: "eng", codec: "aac").singleLineLabel,
            "English (Commentary)"
        )
        XCTAssertEqual(playerTrack(kind: .audio, title: nil, lang: "eng", codec: "aac").singleLineLabel, "English")
        XCTAssertEqual(
            playerTrack(kind: .sub, title: "Signs & Songs", lang: "fre", codec: "ass", isForced: true).singleLineLabel,
            "French (Signs & Songs, Forced)"
        )
        XCTAssertEqual(playerTrack(kind: .sub, title: "SDH", lang: "eng", codec: "subrip").singleLineLabel, "English (SDH)")
    }

    /// Without a language the title names the row, so neither screen repeats
    /// it on the detail line.
    func testUntaggedSubtitleTitleIsNotRepeated() {
        let detail = SubtitleTrack(
            index: 2, codec: "subrip", language: nil, title: "Signs & Songs", embeddedTitle: nil,
            forced: nil, hearingImpaired: nil, isDefault: nil, external: nil, externalPath: nil
        )
        let player = playerTrack(kind: .sub, title: "Signs & Songs", lang: nil, codec: "subrip")

        XCTAssertEqual(DetailPlaybackFormatting.subtitleTitle(detail, ordinal: 0), "Signs & Songs")
        XCTAssertEqual(player.primaryLabel, "Signs & Songs")
        XCTAssertEqual(DetailPlaybackFormatting.subtitleDetail(detail, ordinal: 0, isSelectable: true), "SRT")
        XCTAssertEqual(player.attributesLabel, "SRT")
    }
}
