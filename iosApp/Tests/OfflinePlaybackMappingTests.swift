import XCTest
import Foundation
@testable import Silo

/// Contract coverage for the offline manifest → player metadata mapping in
/// `OfflinePlaybackBuilder`.
///
/// The manifest's `index` is the ordinal within its own audio list, while
/// `AudioTrack.index` means a source stream identifier. AetherEngine probes
/// the delivered file and maps the ordinal at load time. These tests lock down
/// the stored-manifest boundary and decode through the same
/// `.convertFromSnakeCase` strategy the API client uses.
final class OfflinePlaybackMappingTests: XCTestCase {

    // MARK: - Factories

    private func manifest(
        audioTracksJSON: String? = nil,
        selectedAudioTrackIndex: Int? = nil,
        targetBitrateKbps: Int? = nil,
        fileSize: Int64? = 1_000_000_000,
        durationSeconds: Double? = 1358.176
    ) throws -> OfflineManifest {
        var fields = [
            "\"download_id\": \"d1\"",
            "\"content_id\": \"c1\"",
            "\"type\": \"episode\"",
            "\"title\": \"Test Episode\"",
            "\"quality\": \"original\"",
            "\"media_file_id\": 42",
            "\"container\": \"mkv\"",
            "\"codec_video\": \"hevc\"",
            "\"codec_audio\": \"eac3\""
        ]
        if let fileSize { fields.append("\"file_size\": \(fileSize)") }
        if let durationSeconds { fields.append("\"duration_seconds\": \(durationSeconds)") }
        if let audioTracksJSON { fields.append("\"audio_tracks\": \(audioTracksJSON)") }
        if let selectedAudioTrackIndex {
            fields.append("\"selected_audio_track_index\": \(selectedAudioTrackIndex)")
        }
        if let targetBitrateKbps {
            fields.append("\"target_bitrate_kbps\": \(targetBitrateKbps)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            OfflineManifest.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    private func prepared(_ manifest: OfflineManifest) -> PreparedPlayback {
        OfflinePlaybackBuilder.makePreparedPlayback(
            leafContentId: "leaf",
            manifest: manifest,
            mediaURL: URL(fileURLWithPath: "/tmp/media.mkv"),
            subtitleURLs: [],
            resumePosition: nil
        )
    }

    /// One 5.1 EAC-3 track, shaped exactly as the server writes it: `index` is
    /// the loop counter over the audio list, not the probed stream index.
    private let singleEAC3Track = """
    [{
      "index": 0,
      "title": "Surround 5.1",
      "language": "eng",
      "codec": "eac3",
      "layout": "5.1(side)",
      "channels": 6,
      "bitrate": 640000,
      "sample_rate": 48000,
      "default": true
    }]
    """

    // MARK: - Audio track identity

    func testManifestOrdinalIsNotForwardedAsAStreamIndex() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        // The manifest said `index: 0`. Forwarding it would claim the audio
        // lives on stream 0, which on any normal file is the video stream.
        XCTAssertNil(track.index)
    }

    func testAudioTrackDetailSurvivesTheWire() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        XCTAssertEqual(track.codec, "eac3")
        XCTAssertEqual(track.language, "eng")
        XCTAssertEqual(track.channels, 6)
        XCTAssertEqual(track.title, "Surround 5.1")
        // `layout` feeds the detail badge; `sample_rate` only survives
        // `.convertFromSnakeCase` if the coding key
        // is spelled in its converted camelCase form.
        XCTAssertEqual(track.channelLayout, "5.1(side)")
        XCTAssertEqual(track.bitrate, 640_000)
        XCTAssertEqual(track.sampleRate, 48_000)
        XCTAssertEqual(track.isDefault, true)
    }

    func testEmbeddedTitleIsNotFabricated() throws {
        let version = prepared(try manifest(audioTracksJSON: singleEAC3Track)).selectedVersion
        let track = try XCTUnwrap(version.audioTracks?.first)

        // The server collapsed title and embedded title into one field. Echoing
        // the same string back as both would corrupt the audio-pref signature,
        // which compares them separately.
        XCTAssertNil(track.embeddedTitle)
    }

    func testAbsentAudioTracksStayAbsent() throws {
        let version = prepared(try manifest()).selectedVersion

        // Manifests written before the client decoded these fields carry no
        // audio list at all; they must degrade to nil rather than an empty
        // array that would claim the file has no audio.
        XCTAssertNil(version.audioTracks)
    }

    // MARK: - Selected track

    func testSelectedAudioTrackIndexReachesTheSession() throws {
        let session = prepared(try manifest(
            audioTracksJSON: singleEAC3Track,
            selectedAudioTrackIndex: 0
        )).session

        // Ordinal into `version.audioTracks` — the same space the server's
        // `audio_track_index` uses.
        XCTAssertEqual(session.audioTrackIndex, 0)
    }

    // MARK: - Bitrate

    func testBitrateIsDerivedFromTheDeliveredFile() throws {
        let version = prepared(try manifest()).selectedVersion

        // 1_000_000_000 bytes * 8 / 1358.176s / 1000 ≈ 5890 kbps.
        XCTAssertEqual(version.bitrate, 5890)
    }

    func testBitrateFallsBackToTargetWhenDurationIsUnusable() throws {
        let version = prepared(try manifest(
            targetBitrateKbps: 4000,
            durationSeconds: 0
        )).selectedVersion

        XCTAssertEqual(version.bitrate, 4000)
    }

    func testUnusableDurationDoesNotTrapOnConversion() throws {
        // A sub-second duration divides into a value `Int(_:)` traps on.
        // Nothing to assert beyond "this returned at all", plus that it did
        // not invent a bitrate from the corrupt pair.
        let version = prepared(try manifest(durationSeconds: 0.000_001)).selectedVersion

        XCTAssertNil(version.bitrate)
    }

    func testBitrateIsAbsentWhenTheManifestCannotSupportIt() throws {
        let version = prepared(try manifest(fileSize: nil, durationSeconds: nil)).selectedVersion

        XCTAssertNil(version.bitrate)
    }
}
