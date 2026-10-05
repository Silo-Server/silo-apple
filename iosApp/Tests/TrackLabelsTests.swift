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
        isForced: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: 3, kind: kind, title: title, lang: lang, codec: codec,
            audioChannelCount: channels, bitrate: nil, isDefault: isDefault,
            isForced: isForced, isHearingImpaired: false, isExternal: false,
            isSelected: false, ffIndex: 3, srcId: nil
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
                       DetailPlaybackFormatting.subtitleDetail(detail, isSelectable: true))
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
}
