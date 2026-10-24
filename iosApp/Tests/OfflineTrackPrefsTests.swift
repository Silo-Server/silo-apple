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

    private func row<Body: TrackPrefBody>(_ body: Body, at seconds: TimeInterval) -> TrackPrefRow<Body> {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var json = try! JSONSerialization.jsonObject(with: encoder.encode(body)) as! [String: Any]
        json["updated_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        return try! HTTPClient.makeJSONDecoder().decode(TrackPrefRow<Body>.self,
                                                        from: JSONSerialization.data(withJSONObject: json))
    }

    private func audio(_ language: String) -> AudioPrefRequest {
        AudioPrefRequest(audioTrackIndex: -1, audioLanguage: language, trackSignature: nil)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

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

    func testFoldedTitlesThatMatchTwoTracksFallBackToTheSavedIndex() {
        // Source titles both `English`; embedded titles `Commentary` and `Main`.
        // The manifest folds each to `English`.
        let source = [track("en", title: "English"), track("en", title: "English")]
        let main = AudioPrefRequest(
            audioTrackIndex: 1, audioLanguage: "en",
            trackSignature: AudioTrackSignature(language: "en", title: "English", embeddedTitle: "Main",
                                                codec: "eac3", layout: "5.1", channels: 6)
        )
        XCTAssertEqual(OfflineTrackPrefs.audioOrdinal(tracks: source, pref: main, sourceOrdinals: true, fallback: 0), 1)
    }

    func testUndecodableTracksAreSkippedLikeTheServer() {
        let source = [track("en", codec: ""), track("en", codec: "aac", layout: "stereo", channels: 2),
                      track("ja", codec: "unknown")]
        func pick(_ pref: AudioPrefRequest, _ tracks: [OfflineAudioTrack] = source) -> Int? {
            OfflineTrackPrefs.audioOrdinal(tracks: tracks, pref: pref, sourceOrdinals: true, fallback: 1)
        }
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: 0, audioLanguage: "en", trackSignature: nil)), 1,
                       "a saved index on a track with no codec moves to a playable one")
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: -1, audioLanguage: "ja", trackSignature: nil)), 1,
                       "the only Japanese track can't be decoded, so the download-time track stays")

        let unnamed = [track("en", codec: ""), track("ja", codec: "")]
        XCTAssertEqual(pick(AudioPrefRequest(audioTrackIndex: 1, audioLanguage: "ja", trackSignature: nil), unnamed), 1,
                       "when no track names a codec, none is ruled out")
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

    func testAudioPickOnADownloadWithoutAnAudioListKeepsItsLanguage() throws {
        let probed = PlayerTrack(trackId: 2, kind: .audio, title: nil, lang: "ja", codec: "aac", audioChannelCount: 2,
                                 bitrate: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                                 isExternal: false, isSelected: true, ffIndex: 2, srcId: 1)

        let request = try XCTUnwrap(OfflineTrackPrefs.audioRequest(
            track: probed, ordinal: 1, shownTrackCount: 2, manifestTracks: nil, sourceOrdinals: true))

        XCTAssertEqual(request.audioTrackIndex, -1, "without the manifest list the ordinal names no source track")
        XCTAssertEqual(request.audioLanguage, "ja")
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

        let off = store.record(TrackSelectionPersistence.subtitleOffRequest(showForced: nil), key: "s",
                               in: \.subtitle, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(off.baseline, .updatedAt(Date(timeIntervalSince1970: 100)))
        // A read from the server lands while the pick is queued.
        store.subtitle.observed["s"] = ObservedTrackPref(body: row, updatedAt: Date(timeIntervalSince1970: 150))
        let prefs = store.subtitlePrefs(forKey: "s")
        XCTAssertEqual(prefs?.mode, "off")
        XCTAssertEqual(prefs?.language, "de", "an empty member inherits, as on the server")

        let auto = store.record(SubtitlePrefRequest?.none, key: "s", in: \.subtitle, at: Date(timeIntervalSince1970: 300))
        store.acknowledge(off, key: "s", in: \.subtitle, serverDate: nil)
        XCTAssertEqual(store.subtitle.pending["s"]?.id, auto.id, "an older pick's answer must not end a newer one")
        store.acknowledge(auto, key: "s", in: \.subtitle, serverDate: nil)
        XCTAssertFalse(store.hasPending)
    }

    func testOmittedForcedOverrideKeepsTheSeriesRowValue() {
        let seriesRow = SubtitlePrefRequest(subtitleLanguage: "en", subtitleTrackIndex: 3, externalSubtitlePath: "",
                                            subtitleMode: "always", trackSignature: nil, showForcedSubtitles: false)
        let sidecar = PlayerTrack(trackId: 1_073_741_825, kind: .sub, title: nil, lang: "ja", codec: "subrip",
                                  audioChannelCount: nil, bitrate: nil, isDefault: false, isForced: false,
                                  isHearingImpaired: false, isExternal: true, isSelected: true, ffIndex: nil, srcId: 0)
        var store = TrackPrefsStore()
        store.observe(row(seriesRow, at: 100), key: "s", in: \.subtitle, since: store.subtitle.revision("s"))

        let pick = store.record(OfflineTrackPrefs.subtitleRequest(track: sidecar), key: "s", in: \.subtitle, at: at(200))
        XCTAssertEqual(store.subtitlePrefs(forKey: "s")?.showForced, false, "the server keeps its override")
        store.acknowledge(pick, key: "s", in: \.subtitle, serverDate: at(201))
        XCTAssertEqual(store.subtitlePrefs(forKey: "s")?.showForced, false)
        XCTAssertEqual(store.subtitlePrefs(forKey: "s")?.language, "ja")
    }

    func testClearingTheSeriesRowDropsTheCascadeSeenWithIt() {
        let off = TrackSelectionPersistence.subtitleOffRequest(showForced: nil)
        // Streaming resolved Off from the series row.
        let streamedUnderOff = EffectiveSubtitlePrefs(language: nil, mode: "off", showForced: true, signature: nil)
        var store = TrackPrefsStore()
        store.wrote(off, key: "auto", in: \.subtitle, sentAt: at(100), stored: true, serverDate: at(101))
        store.effectiveSubtitle["auto"] = streamedUnderOff
        store.wrote(SubtitlePrefRequest?.none, key: "auto", in: \.subtitle, sentAt: at(200), stored: true,
                    serverDate: at(201))
        XCTAssertNil(store.subtitlePrefs(forKey: "auto"), "Auto must not keep the Off the cascade inherited")

        store.observe(row(off, at: 100), key: "elsewhere", in: \.subtitle, since: store.subtitle.revision("elsewhere"))
        store.effectiveSubtitle["elsewhere"] = streamedUnderOff
        store.observe(TrackPrefRow<SubtitlePrefRequest>?.none, key: "elsewhere", in: \.subtitle,
                      since: store.subtitle.revision("elsewhere"))
        XCTAssertNil(store.subtitlePrefs(forKey: "elsewhere"), "another device cleared the row")

        let profileDefault = EffectiveSubtitlePrefs(language: "en", mode: "auto", showForced: true, signature: nil)
        store.effectiveSubtitle["never"] = profileDefault
        store.observe(TrackPrefRow<SubtitlePrefRequest>?.none, key: "never", in: \.subtitle,
                      since: store.subtitle.revision("never"))
        XCTAssertEqual(store.subtitlePrefs(forKey: "never"), profileDefault, "no row was seen, so none was in it")
    }

    func testAReadThatStartedBeforeAWriteDoesNotUndoIt() {
        var store = TrackPrefsStore()
        let revision = store.audio.revision("s")
        let pick = store.record(audio("fr"), key: "s", in: \.audio, at: at(200))
        store.acknowledge(pick, key: "s", in: \.audio, serverDate: at(201))

        store.observe(row(audio("ja"), at: 100), key: "s", in: \.audio, since: revision)

        XCTAssertEqual(store.audioPref(forKey: "s")?.audioLanguage, "fr")
    }

    func testThisDevicesOwnWriteIsNotANewerChoice() throws {
        let later = at(9_000)
        func sends(_ pick: PendingTrackPref<AudioPrefRequest>, over updatedAt: TimeInterval) -> Bool {
            TrackPrefLedger.shouldSend(pick, over: row(audio("ja"), at: updatedAt), serverDate: later, readAt: later)
        }
        var store = TrackPrefsStore()
        store.observe(row(audio("en"), at: 1_000), key: "s", in: \.audio, since: store.audio.revision("s"))

        // The second pick is made while the first one's write is under way,
        // and the server stamps that write after it.
        let first = store.record(audio("ja"), key: "s", in: \.audio, at: at(2_000))
        let second = store.record(audio("fr"), key: "s", in: \.audio, at: at(2_001))
        store.acknowledge(first, key: "s", in: \.audio, serverDate: at(2_002))
        let queued = try XCTUnwrap(store.audio.pending["s"])
        XCTAssertEqual(queued.id, second.id)
        XCTAssertTrue(sends(queued, over: 2_002.4), "the first write is this device's own")
        XCTAssertFalse(sends(queued, over: 2_010), "a choice made elsewhere after it still wins")

        // The same for a write sent while streaming.
        let offline = store.record(audio("de"), key: "t", in: \.audio, at: at(3_001))
        store.wrote(audio("ja"), key: "t", in: \.audio, sentAt: at(3_000), stored: true, serverDate: at(3_002))
        let kept = try XCTUnwrap(store.audio.pending["t"], "a pick made after the write was sent is newer")
        XCTAssertEqual(kept.id, offline.id)
        XCTAssertTrue(sends(kept, over: 3_002.4))

        store.record(audio("de"), key: "u", in: \.audio, at: at(3_999))
        store.wrote(audio("ja"), key: "u", in: \.audio, sentAt: at(4_000), stored: false, serverDate: nil)
        XCTAssertNil(store.audio.pending["u"], "a later choice supersedes an older pick even if it failed to send")
    }

    func testOnlyAPermanentRefusalDropsAQueuedPick() throws {
        func problem(_ status: Int) throws -> Error {
            let json = #"{"type":"https://siloserver.org/problems/x","title":"X","status":\#(status),"detail":"x"}"#
            return APIv2Error.problem(try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: Data(json.utf8)))
        }
        let refused = OfflineTrackPrefs.isRefusedForGood

        XCTAssertTrue(refused(try problem(422)))
        XCTAssertTrue(refused(try problem(403)), "a demo account may never write preferences")
        XCTAssertTrue(refused(APIv2Error.httpStatus(404)), "a body that is not a problem document")
        XCTAssertFalse(refused(try problem(429)))
        XCTAssertFalse(refused(APIv2Error.httpStatus(401)))
        XCTAssertFalse(refused(try problem(503)))
        XCTAssertFalse(refused(URLError(.notConnectedToInternet)))
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
