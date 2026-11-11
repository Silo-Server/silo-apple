import XCTest
import Foundation
@testable import Silo

/// The rows of the title page's Media Info section.
final class DetailMediaInfoTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    private func label(_ resource: LocalizedStringResource) -> String {
        AppLanguage.string(resource, locale: english)
    }

    private func videoTrack(
        profile: String? = "Main 10",
        bitDepth: Int? = 10,
        frameRate: String? = "23.976",
        videoRangeType: String? = nil,
        dolbyVision: String? = nil,
        hdr10Plus: Bool? = nil
    ) -> VideoTrack {
        VideoTrack(
            index: nil, codec: "hevc", width: 3840, height: 2160, frameRate: frameRate, bitrate: nil,
            profile: profile, level: nil, bitDepth: bitDepth, colorRange: nil, colorSpace: nil,
            colorPrimaries: nil, colorTransfer: nil, videoRange: nil, videoRangeType: videoRangeType,
            dolbyVision: dolbyVision, hdr10Plus: hdr10Plus, title: nil, language: nil
        )
    }

    private func audioTrack(
        _ language: String?,
        title: String? = nil,
        codec: String,
        layout: String,
        isDefault: Bool = false
    ) -> AudioTrack {
        AudioTrack(
            index: nil, codec: codec, channels: nil, channelLayout: layout, bitrate: nil,
            sampleRate: nil, language: language, title: title, embeddedTitle: nil, isDefault: isDefault
        )
    }

    private func version(
        resolution: String? = "2160p",
        codecVideo: String? = "hevc",
        hdr: Bool? = true,
        container: String? = "mkv",
        fileSize: Int64? = 45_592_000_000,
        bitrate: Int? = 55_451,
        videoTracks: [VideoTrack]? = nil,
        audioTracks: [AudioTrack]? = nil,
        effectiveAudioTrackIndex: Int? = nil
    ) -> FileVersion {
        FileVersion(
            fileId: 7, fileName: "film.mkv", resolution: resolution, codecVideo: codecVideo, codecAudio: "truehd",
            hdr: hdr, container: container, fileSize: fileSize, duration: 6_960, bitrate: bitrate,
            videoTracks: videoTracks, audioTracks: audioTracks, subtitleTracks: nil, chapters: nil,
            effectiveAudioTrackIndex: effectiveAudioTrackIndex
        )
    }

    private func dynamicRange(_ version: FileVersion) -> String? {
        DetailMediaInfo.videoAndFileFacts(version, locale: english)
            .first { $0.label == label(.playerStatsDynamicRange) }?
            .value
    }

    private func frameRate(_ text: String?) -> String? {
        DetailMediaInfo.videoAndFileFacts(version(videoTracks: [videoTrack(frameRate: text)]), locale: english)
            .first { $0.label == label(.webDetailMediaInfoRowFrameRateLabel) }?
            .value
    }

    func testListsTheVideoAndFileFactsInOrder() {
        let track = videoTrack(videoRangeType: "DOVIWithHDR10", dolbyVision: "Profile 8")
        let facts = DetailMediaInfo.videoAndFileFacts(version(videoTracks: [track]), locale: english)

        XCTAssertEqual(facts.map(\.label), [
            label(.filtersFacetResolution),
            label(.playerHudVideo),
            label(.playerStatsDynamicRange),
            label(.webDetailMediaInfoRowBitDepthLabel),
            label(.webDetailMediaInfoRowFrameRateLabel),
            label(.playerStatsContainer),
            label(.downloadsOfflineDetailFactSize),
            label(.webDetailMediaInfoRowBitrate),
        ])
        XCTAssertEqual(facts.map(\.value), [
            "2160p",
            "HEVC · Main 10",
            "Dolby Vision Profile 8",
            "10-bit",
            "23.976 fps",
            "MKV",
            // The size the version picker shows for the same file.
            DetailPlaybackFormatting.formatFileSize(45_592_000_000),
            // The server sends kilobits per second.
            "55.5 Mbps",
        ])
    }

    /// A file the server never probed arrives with empty text and zeros in
    /// its required fields. None of them is a fact.
    func testLeavesOutWhatTheServerDidNotSend() {
        let unprobed = version(
            resolution: "", codecVideo: " ", hdr: false, container: "", fileSize: 0, bitrate: 0,
            videoTracks: [videoTrack(profile: "", bitDepth: 0, frameRate: "")]
        )
        XCTAssertTrue(DetailMediaInfo.videoAndFileFacts(unprobed, locale: english).isEmpty)

        let noTracks = version(hdr: false, fileSize: nil, bitrate: nil)
        XCTAssertEqual(DetailMediaInfo.videoAndFileFacts(noTracks, locale: english).map(\.value), ["2160p", "HEVC", "MKV"])
    }

    func testNamesTheDynamicRangeAsPreciselyAsTheServerDoes() {
        func range(type: String? = nil, dolbyVision: String? = nil, hdr10Plus: Bool? = nil, hdr: Bool? = true) -> String? {
            let track = videoTrack(videoRangeType: type, dolbyVision: dolbyVision, hdr10Plus: hdr10Plus)
            return dynamicRange(version(hdr: hdr, videoTracks: [track]))
        }

        XCTAssertEqual(range(type: "DOVIWithEL", dolbyVision: "Profile 7"), "Dolby Vision Profile 7")
        XCTAssertEqual(range(type: "DOVIWithHDR10Plus", dolbyVision: "Profile 8", hdr10Plus: true),
                       "Dolby Vision Profile 8 · HDR10+")
        // An older row names Dolby Vision, and HDR10+, only in its class.
        XCTAssertEqual(range(type: "DOVIWithHDR10"), "Dolby Vision")
        XCTAssertEqual(range(type: "DOVIWithHDR10Plus"), "Dolby Vision · HDR10+")
        XCTAssertEqual(range(type: "HDR10", hdr10Plus: false), "HDR10")
        XCTAssertEqual(range(type: "HDR10Plus", hdr10Plus: true), "HDR10+")
        XCTAssertEqual(range(type: "hdr10plus"), "HDR10+", "older rows differ in case")
        XCTAssertEqual(range(type: "HLG"), "HLG")
        XCTAssertEqual(range(), "HDR", "a server that sends no range class")
        XCTAssertNil(range(type: "SDR", hdr: false))
        // No video track at all: the version's own flag is all there is.
        XCTAssertEqual(dynamicRange(version(hdr: true)), "HDR")
        XCTAssertNil(dynamicRange(version(hdr: false)))
    }

    func testFrameRateDropsTrailingZerosAndSkipsWhatItCannotRead() {
        XCTAssertEqual(frameRate("23.976"), "23.976 fps")
        XCTAssertEqual(frameRate("24.000"), "24 fps")
        XCTAssertEqual(frameRate("59.940"), "59.94 fps")
        XCTAssertNil(frameRate("24000/0"))
        XCTAssertNil(frameRate("0.000"))
        XCTAssertNil(frameRate(nil))
    }

    func testListsEachAudioTrackWithTheFilesDefaultMarker() {
        let file = version(
            audioTracks: [
                audioTrack("eng", codec: "truehd", layout: "7.1", isDefault: true),
                audioTrack("fre", codec: "ac3", layout: "5.1(side)"),
            ],
            // The profile's pick is not a fact about the file.
            effectiveAudioTrackIndex: 1
        )
        let facts = DetailMediaInfo.audioFacts(file)

        XCTAssertEqual(facts.map(\.label), ["English", "French"])
        XCTAssertEqual(facts.map(\.value), ["TrueHD · 7.1 · Default", "AC3 · 5.1"])
    }

    /// The label column is narrow. A track without a language is labelled
    /// by its number, and its title leads the value.
    func testATrackWithoutALanguageIsLabelledByItsNumber() {
        let file = version(audioTracks: [
            audioTrack("eng", title: "Commentary", codec: "ac3", layout: "stereo"),
            audioTrack(nil, title: "Commentary", codec: "ac3", layout: "stereo"),
            audioTrack("und", codec: "aac", layout: "stereo"),
            // Nothing is known about this one, but the file has it.
            audioTrack(nil, codec: "", layout: ""),
        ])
        let facts = DetailMediaInfo.audioFacts(file)

        XCTAssertEqual(facts.map(\.label), ["English", "Track 2", "Track 3", "Track 4"])
        XCTAssertEqual(facts.map(\.value), ["Commentary · AC3 · Stereo", "Commentary · AC3 · Stereo", "AAC · Stereo", ""])
    }

    /// The range class and the HDR10+ flag reach the detail models from the
    /// server's `video_range_type` and `hdr10_plus`.
    func testDecodesTheRangeClassAndHDR10PlusFromTheServer() throws {
        let json = Data(#"{"codec":"hevc","video_range":"HDR","video_range_type":"HDR10Plus","hdr10_plus":true}"#.utf8)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.VideoTrack.self, from: json)
        let track = try VideoTrack(catalog: wire)

        XCTAssertEqual(track.videoRangeType, "HDR10Plus")
        XCTAssertEqual(track.hdr10Plus, true)
        XCTAssertEqual(dynamicRange(version(videoTracks: [track])), "HDR10+")
    }
}
