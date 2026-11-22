import XCTest
@testable import Silo

/// The stream badges describe what is playing now: the selected audio track
/// and the file the session is on, not what the load started with.
@MainActor
final class PlayerStreamBadgeTests: XCTestCase {
    func testAudioBadgeFollowsTheSelectedTrack() {
        let player = playerOn(film, badges: ["4K", "HDR", "HEVC", "TRUEHD"])
        player.audioTracks = filmTracks
        player.selectedAudioId = 1
        XCTAssertEqual(player.metadata.badges, ["4K", "HDR", "HEVC", "TRUEHD"])

        player.selectedAudioId = 2

        XCTAssertEqual(player.metadata.badges, ["4K", "HDR", "HEVC", "AAC"])
    }

    /// The engine names a track by its decoder (`dca` for DTS); the badge
    /// keeps the catalog's name for the same stream.
    func testAudioBadgeKeepsTheCatalogNameForAnEngineTrack() {
        let player = playerOn(
            version(
                fileId: 44, resolution: "1920x1080", codecVideo: "h264", hdr: false,
                audio: [("ac3", 6), ("dts", 6)]
            ),
            badges: ["FHD", "H264", "AC3"]
        )
        player.audioTracks = [
            pickerTrack(id: 1, ordinal: 0, codec: "ac3", channels: 6),
            pickerTrack(id: 2, ordinal: 1, codec: "dca", channels: 6),
        ]

        player.selectedAudioId = 2

        XCTAssertEqual(player.metadata.badges, ["FHD", "H264", "DTS"])
    }

    /// A download saved without a track list has no catalog row to name the
    /// selection, so the file's own codec stands.
    func testAudioBadgeKeepsTheFilesCodecWithoutACatalogTrackList() {
        let player = playerOn(
            version(fileId: 45, resolution: "1920x1080", codecVideo: "h264", hdr: false, audioCodec: "dts", audio: nil),
            badges: ["FHD", "H264", "DTS"]
        )
        player.audioTracks = [pickerTrack(id: 1, ordinal: 0, codec: "dca", channels: 6)]

        player.selectedAudioId = 1

        XCTAssertEqual(player.metadata.badges, ["FHD", "H264", "DTS"])
    }

    func testBadgesFollowTheFileAReplanLandsOn() {
        let player = playerOn(film, badges: ["4K", "HDR", "HEVC", "TRUEHD"])
        player.audioTracks = filmTracks
        player.selectedAudioId = 2

        player.adoptReplannedVersion(version(
            fileId: 43, resolution: "1920x1080", codecVideo: "h264", hdr: false,
            audio: [("dts", 6), ("ac3", 2)]
        ))

        // The published tracks still list the outgoing file, so its second
        // track does not name this file's.
        XCTAssertEqual(player.metadata.badges, ["FHD", "H264", "DTS"])

        player.audioTracks = [
            pickerTrack(id: 1, ordinal: 0, codec: "dca", channels: 6),
            pickerTrack(id: 2, ordinal: 1, codec: "ac3", channels: 2),
        ]
        player.selectedAudioId = 2

        XCTAssertEqual(player.metadata.badges, ["FHD", "H264", "AC3"])
    }

    func testBadgesReturnToTheSelectedTrackWhenAReplanRollsBack() {
        let player = playerOn(film, badges: ["4K", "HDR", "HEVC", "TRUEHD"])
        player.audioTracks = filmTracks
        player.selectedAudioId = 2
        player.adoptReplannedVersion(version(
            fileId: 43, resolution: "1920x1080", codecVideo: "h264", hdr: false,
            audio: [("dts", 6), ("ac3", 2)]
        ))

        player.adoptReplannedVersion(film)

        XCTAssertEqual(player.metadata.badges, ["4K", "HDR", "HEVC", "AAC"])
    }

    // MARK: - Fixtures

    private var film: FileVersion {
        version(
            fileId: 42, resolution: "3840x2160", codecVideo: "hevc", hdr: true,
            audio: [("truehd", 8), ("aac", 2)]
        )
    }

    private var filmTracks: [PlayerTrack] {
        [
            pickerTrack(id: 1, ordinal: 0, codec: "truehd", channels: 8),
            pickerTrack(id: 2, ordinal: 1, codec: "aac", channels: 2),
        ]
    }

    /// A player on `version`, as its load leaves it: `badges` are the pills
    /// that load built from the file.
    private func playerOn(_ version: FileVersion, badges: [String]) -> PlayerViewModel {
        let player = PlayerViewModel()
        player.metadata = PlayerMetadata(
            seriesTitle: nil, episodeTag: nil, primaryTitle: "Film", year: 2012, overview: nil,
            badges: badges
        )
        player.bindMarkerReconciliationForTesting(
            sessionId: "session-1",
            detail: WatchDetail(
                contentId: "film-1", type: "movie", title: "Film", year: 2012, overview: nil,
                versions: [version], subtitles: nil,
                intro: nil, credits: nil, userData: nil,
                seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
                effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
                effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
            ),
            version: version
        )
        return player
    }

    /// `audioCodec` is the file's own codec; it defaults to the first track's.
    private func version(
        fileId: Int, resolution: String, codecVideo: String, hdr: Bool, audioCodec: String? = nil,
        audio: [(codec: String, channels: Int)]?
    ) -> FileVersion {
        FileVersion(
            fileId: fileId, fileName: "film.mkv", resolution: resolution, codecVideo: codecVideo,
            codecAudio: audioCodec ?? audio?.first?.codec, hdr: hdr, container: "mkv", fileSize: 1_000,
            duration: 60, bitrate: 1_000_000, videoTracks: nil,
            audioTracks: audio?.enumerated().map { ordinal, track in
                AudioTrack(
                    index: ordinal + 1, codec: track.codec, channels: track.channels, channelLayout: nil,
                    bitrate: nil, sampleRate: 48_000, language: "eng", title: nil, embeddedTitle: nil,
                    isDefault: ordinal == 0
                )
            },
            subtitleTracks: nil, chapters: nil
        )
    }

    /// A picker row as the engine publishes it on direct play: its own stream
    /// id, and the track's ordinal among the file's audio streams.
    private func pickerTrack(id: Int64, ordinal: Int, codec: String, channels: Int) -> PlayerTrack {
        PlayerTrack(
            trackId: id, kind: .audio, title: nil, lang: "eng", codec: codec, audioChannelCount: channels,
            bitrate: nil, isDefault: ordinal == 0, isForced: false, isHearingImpaired: false,
            isExternal: false, isSelected: false, ffIndex: Int(id), srcId: ordinal
        )
    }
}
