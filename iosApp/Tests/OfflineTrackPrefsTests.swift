import Foundation
import XCTest
@testable import Silo

/// Downloaded playback honors and updates the per-series track preference
/// streaming uses: which key a download reads and writes, which audio track
/// it starts on, what an offline pick may claim, and when a queued pick may
/// overwrite the server.
final class OfflineTrackPrefsTests: XCTestCase {

    private func manifest(_ fields: [String: Any]) throws -> OfflineManifest {
        var json: [String: Any] = [
            "download_id": "d1", "content_id": "c1", "type": "episode", "title": "T",
            "quality": "original", "media_file_id": "42",
        ]
        json.merge(fields) { _, new in new }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OfflineManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func track(_ language: String?, title: String? = nil, codec: String = "eac3",
                       layout: String = "5.1", channels: Int = 6, isDefault: Bool = false) -> OfflineAudioTrack {
        OfflineAudioTrack(index: nil, title: title, language: language, codec: codec, layout: layout,
                          channels: channels, bitrate: nil, sampleRate: nil, isDefault: isDefault)
    }

    // MARK: - Key

    func testDownloadsUseTheSeriesKeyStreamingUsesAndNeverTheEpisode() throws {
        let episode = try manifest(["content_id": "series-1", "episode_id": "ep-5", "series_id": "series-1"])
        XCTAssertEqual(OfflineTrackPrefs.prefKey(manifest: episode, recordSeriesId: nil), "series-1")

        let special = try manifest(["content_id": "ep-0", "episode_id": "ep-0", "season_number": 0])
        XCTAssertEqual(OfflineTrackPrefs.prefKey(manifest: special, recordSeriesId: "series-2"), "series-2",
                       "a manifest without a series id falls back to the record's")
        XCTAssertNil(OfflineTrackPrefs.prefKey(manifest: special, recordSeriesId: nil),
                     "an episode with no known series must not publish under its own id")

        let movie = try manifest(["content_id": "movie-9", "type": "movie"])
        XCTAssertEqual(OfflineTrackPrefs.prefKey(manifest: movie, recordSeriesId: nil), "movie-9")
    }

    // MARK: - Audio selection

    func testAudioStartsFromTheSeriesPreferenceLikeTheServer() {
        // Source order: English 5.1, Japanese 5.1, Japanese commentary stereo.
        let source = [
            track("en", title: "English", isDefault: true),
            track("ja", title: "Japanese"),
            track("ja", title: "Commentary", codec: "aac", layout: "stereo", channels: 2),
        ]
        func pick(_ pref: AudioPrefRequest?, _ tracks: [OfflineAudioTrack] = source,
                  sourceOrdinals: Bool = true, fallback: Int? = 0) -> Int? {
            OfflineTrackPrefs.audioOrdinal(tracks: tracks, pref: pref, sourceOrdinals: sourceOrdinals, fallback: fallback)
        }
        let commentaryIndex = AudioPrefRequest(audioTrackIndex: 2, audioLanguage: "ja", trackSignature: nil)

        XCTAssertEqual(pick(nil), 0, "no series row keeps the track chosen at download time")
        XCTAssertEqual(pick(commentaryIndex), 2, "an original download's index is the source index")
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: 2, audioLanguage: "en", trackSignature: nil)), 0,
                       "an index whose track changed language falls through to the language")
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: -1, audioLanguage: "jpn", trackSignature: nil)), 1,
                       "ISO 639-2 matches the first track of the language")
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: -1, audioLanguage: "fr", trackSignature: nil)), 0)

        // The server's signature carries the title and embedded title apart;
        // the manifest folded them into `title`.
        let commentarySignature = AudioPrefRequest(
            audioTrackIndex: -1, audioLanguage: "ja",
            trackSignature: AudioTrackSignature(language: "ja", title: "", embeddedTitle: "Commentary",
                                                codec: "aac", layout: "stereo", channels: 2)
        )
        XCTAssertEqual(pick(commentarySignature), 2)

        // A prepared file dropped and reordered tracks, so the saved source
        // index means nothing in it.
        let prepared = [track("ja", title: "Japanese", codec: "aac", layout: "stereo", channels: 2),
                        track("en", title: "English", codec: "aac", layout: "stereo", channels: 2)]
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "en", trackSignature: nil),
                            prepared, sourceOrdinals: false), 1)
        XCTAssertEqual(pick(commentaryIndex, [], fallback: nil), nil, "no inventory, no guess")
    }

    func testOfflineAudioPickNeverSendsAPreparedOrdinal() throws {
        let tracks = [AudioTrack(index: nil, codec: "aac", channels: 2, channelLayout: "stereo", bitrate: nil,
                                 sampleRate: nil, language: "ja", title: "Japanese", embeddedTitle: nil, isDefault: true)]

        let prepared = try XCTUnwrap(OfflineTrackPrefs.audioRequest(tracks: tracks, ordinal: 0, sourceOrdinals: false))
        XCTAssertEqual(prepared.audioTrackIndex, -1)
        XCTAssertEqual(prepared.audioLanguage, "ja")
        XCTAssertNil(prepared.trackSignature, "the manifest folded the titles; a signature would be invented")

        let original = try XCTUnwrap(OfflineTrackPrefs.audioRequest(tracks: tracks, ordinal: 0, sourceOrdinals: true))
        XCTAssertEqual(original.audioTrackIndex, 0)
        XCTAssertNil(OfflineTrackPrefs.audioRequest(tracks: tracks, ordinal: 1, sourceOrdinals: true))
    }

    func testOfflineSubtitlePickSendsLanguageAndFlagsOnly() {
        let sidecar = PlayerTrack(trackId: 1_073_741_825, kind: .sub, title: "English SDH", lang: "en", codec: "subrip",
                                  audioChannelCount: nil, bitrate: nil, isDefault: false, isForced: false,
                                  isHearingImpaired: true, isExternal: true, isSelected: true, ffIndex: nil, srcId: 0)

        let request = OfflineTrackPrefs.subtitleRequest(track: sidecar)

        XCTAssertEqual(request.subtitleTrackIndex, -1, "a sidecar's position is not a server index")
        XCTAssertEqual(request.subtitleMode, "always")
        XCTAssertEqual(request.subtitleLanguage, "en")
        XCTAssertEqual(request.trackSignature, SubtitleTrackSignature(language: "en", hearingImpaired: true))
        XCTAssertNil(request.showForcedSubtitles, "omitted keeps the series' forced override")
    }

    // MARK: - Store

    func testPendingPickWinsOverTheServerRowUntilAcknowledged() {
        let row = SubtitlePrefRequest(subtitleLanguage: "en", subtitleTrackIndex: 3, externalSubtitlePath: "",
                                      subtitleMode: "always", trackSignature: nil, showForcedSubtitles: true)
        var store = TrackPrefsStore()
        store.effectiveSubtitle["s"] = EffectiveSubtitlePrefs(language: "de", mode: "auto", showForced: false, signature: nil)
        store.subtitle.observed["s"] = ObservedTrackPref(body: row, updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.subtitlePrefs(forKey: "s")?.language, "en")

        let off = store.subtitle.record(TrackSelectionPersistence.subtitleOffRequest(showForced: nil), key: "s",
                                        at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(off.baseline, .updatedAt(Date(timeIntervalSince1970: 100)))
        // A read from the server lands while the pick is queued.
        store.subtitle.observed["s"] = ObservedTrackPref(body: row, updatedAt: Date(timeIntervalSince1970: 150))
        let prefs = store.subtitlePrefs(forKey: "s")
        XCTAssertEqual(prefs?.mode, "off")
        XCTAssertEqual(prefs?.language, "de", "an empty member inherits, as on the server")

        let auto = store.subtitle.record(nil, key: "s", at: Date(timeIntervalSince1970: 300))
        store.subtitle.acknowledge(off, key: "s")
        XCTAssertEqual(store.subtitle.pending["s"], auto, "an older pick's answer must not end a newer one")
        XCTAssertEqual(store.subtitlePrefs(forKey: "s")?.language, "de", "Auto falls back to the cascade")
        store.subtitle.acknowledge(auto, key: "s")
        XCTAssertFalse(store.hasPending)
    }

    func testQueuedPickOverwritesOnlyAnOlderServerChoice() {
        let seen = Date(timeIntervalSince1970: 1_000)
        func row(at time: Date) -> TrackPrefRow<AudioPrefRequest> {
            let json = #"{"audio_track_index":1,"audio_language":"ja","updated_at":"\#(ISO8601DateFormatter().string(from: time))"}"#
            return try! HTTPClient.makeJSONDecoder().decode(TrackPrefRow<AudioPrefRequest>.self, from: Data(json.utf8))
        }
        func pick(at seconds: TimeInterval, baseline: PendingTrackPref<AudioPrefRequest>.Baseline) -> PendingTrackPref<AudioPrefRequest> {
            PendingTrackPref(body: AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "en", trackSignature: nil),
                             pickedAt: Date(timeIntervalSince1970: seconds), baseline: baseline)
        }
        let readAt = Date(timeIntervalSince1970: 5_000)
        func send(_ pick: PendingTrackPref<AudioPrefRequest>, _ row: TrackPrefRow<AudioPrefRequest>?,
                  serverDate: Date? = nil) -> Bool {
            TrackPrefLedger.shouldSend(pick, over: row, serverDate: serverDate, readAt: readAt)
        }

        XCTAssertTrue(send(pick(at: 900, baseline: .updatedAt(seen)), row(at: seen)),
                      "unchanged since the pick: the device clock is not consulted")
        XCTAssertTrue(send(pick(at: 900, baseline: .absent), nil))
        XCTAssertFalse(send(pick(at: 2_000, baseline: .updatedAt(seen)), row(at: Date(timeIntervalSince1970: 3_000))),
                       "another device chose after the offline pick")
        XCTAssertTrue(send(pick(at: 2_000, baseline: .unknown), row(at: Date(timeIntervalSince1970: 1_500))))
        // This device's clock runs 30 minutes fast: its 2_000 was the
        // server's 200, before the server row changed at 1_500.
        XCTAssertFalse(send(pick(at: 2_000, baseline: .updatedAt(seen)), row(at: Date(timeIntervalSince1970: 1_500)),
                            serverDate: readAt.addingTimeInterval(-1_800)))
    }
}
