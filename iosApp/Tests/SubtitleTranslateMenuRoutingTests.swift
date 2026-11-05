//
//  SubtitleTranslateMenuRoutingTests.swift
//  SiloTests
//
//  The AI subtitle menu transcribes the audio track whose language decided
//  the job kind, so a German track the viewer selected is the one sent.
//

import XCTest
@testable import Silo

final class SubtitleTranslateMenuRoutingTests: XCTestCase {
    private func audio(_ ordinal: Int, lang: String, isDefault: Bool = false, isSelected: Bool = false,
                       srcId: Int? = nil) -> PlayerTrack {
        PlayerTrack(trackId: Int64(ordinal), kind: .audio, title: nil, lang: lang, codec: "aac",
                    audioChannelCount: 2, bitrate: nil, isDefault: isDefault, isForced: false,
                    isHearingImpaired: false, isExternal: false, isSelected: isSelected,
                    ffIndex: ordinal + 1, srcId: srcId ?? ordinal)
    }

    func testTranscriptionSendsTheSelectedAudioTrack() {
        let tracks = [audio(0, lang: "eng", isDefault: true), audio(1, lang: "ger", isSelected: true)]
        XCTAssertEqual(SubtitleTranslateMenu.transcriptionSourceIndex(tracks), 1)
    }

    func testTranscriptionFallsBackToTheDefaultTrack() {
        let tracks = [audio(0, lang: "eng"), audio(1, lang: "ger", isDefault: true)]
        XCTAssertEqual(SubtitleTranslateMenu.transcriptionSourceIndex(tracks), 1)
    }

    func testTranscriptionUsesTheServerDefaultWithoutAnOrdinal() {
        let track = PlayerTrack(trackId: 3, kind: .audio, title: nil, lang: "eng", codec: "aac",
                                audioChannelCount: 2, bitrate: nil, isDefault: true, isForced: false,
                                isHearingImpaired: false, isExternal: false, isSelected: true,
                                ffIndex: 1, srcId: nil)
        XCTAssertEqual(SubtitleTranslateMenu.transcriptionSourceIndex([track]), -1)
        XCTAssertEqual(SubtitleTranslateMenu.transcriptionSourceIndex([]), -1)
    }
}
