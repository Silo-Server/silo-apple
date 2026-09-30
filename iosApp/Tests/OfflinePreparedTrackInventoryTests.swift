import XCTest
@testable import Silo

/// Offline playback of a server-prepared MP4: every source audio track, timed
/// text inside the file, and ASS/PGS sidecars from the manifest.
final class OfflinePreparedTrackInventoryTests: XCTestCase {

    // MARK: - Factories

    private func track(
        id: Int64,
        kind: PlayerTrack.Kind,
        title: String?,
        lang: String?,
        codec: String?,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: id,
            kind: kind,
            title: title,
            lang: lang,
            codec: codec,
            audioChannelCount: kind == .audio ? 2 : nil,
            bitrate: nil,
            isDefault: isDefault,
            isForced: isForced,
            isHearingImpaired: false,
            isExternal: isExternal,
            isSelected: false,
            ffIndex: isExternal ? nil : Int(id),
            srcId: nil
        )
    }

    private func manifestAudio(title: String?, language: String?) -> AudioTrack {
        AudioTrack(
            index: nil,
            codec: "aac",
            channels: 2,
            channelLayout: "stereo",
            bitrate: nil,
            sampleRate: nil,
            language: language,
            title: title,
            embeddedTitle: nil,
            isDefault: nil
        )
    }

    private func manifest(deliveryFormat: String?) throws -> OfflineManifest {
        var fields = [
            "\"download_id\": \"d1\"",
            "\"content_id\": \"c1\"",
            "\"type\": \"movie\"",
            "\"title\": \"Movie\"",
            "\"quality\": \"medium\"",
            "\"media_file_id\": \"42\""
        ]
        if let deliveryFormat { fields.append("\"delivery_format\": \"\(deliveryFormat)\"") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            OfflineManifest.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8)
        )
    }

    // MARK: - Prepared-file detection

    func testOnlyRemuxAndTranscodeDeliveriesArePreparedFiles() throws {
        XCTAssertTrue(try manifest(deliveryFormat: "transcode").isServerPreparedFile)
        XCTAssertTrue(try manifest(deliveryFormat: "remux").isServerPreparedFile)
        XCTAssertFalse(try manifest(deliveryFormat: "original").isServerPreparedFile)
        XCTAssertFalse(try manifest(deliveryFormat: nil).isServerPreparedFile)
    }

    // MARK: - Audio

    func testAudioTitlesComeFromTheManifestByPosition() {
        let probed = [
            track(id: 1, kind: .audio, title: "ENG (aac)", lang: "eng", codec: "aac", isDefault: true),
            track(id: 2, kind: .audio, title: "JPN (aac)", lang: "jpn", codec: "aac"),
            track(id: 3, kind: .audio, title: "Track 3 (aac)", lang: nil, codec: "aac"),
        ]
        let described = [
            manifestAudio(title: "English 5.1", language: "en"),
            manifestAudio(title: nil, language: "ja"),
            manifestAudio(title: "Commentary", language: "en"),
        ]

        let tracks = OfflinePreparedTrackInventory.audioTracks(probed, manifestTracks: described)

        XCTAssertEqual(tracks.map(\.title), ["English 5.1", nil, "Commentary"])
        XCTAssertEqual(tracks.map(\.lang), ["eng", "jpn", "en"])
        XCTAssertEqual(tracks.map(\.primaryLabel), ["English 5.1", "Japanese", "Commentary"])
        XCTAssertEqual(tracks.map(\.trackId), [1, 2, 3])
        XCTAssertEqual(tracks.map(\.isDefault), [true, false, false])
    }

    func testUndeterminedProbedLanguageTakesTheManifestLanguage() {
        let probed = [track(id: 1, kind: .audio, title: "UND (aac)", lang: "und", codec: "aac")]
        let tracks = OfflinePreparedTrackInventory.audioTracks(
            probed,
            manifestTracks: [manifestAudio(title: nil, language: "de")]
        )
        XCTAssertEqual(tracks.first?.lang, "de")
    }

    func testRealAudioTitleIsKept() {
        let probed = [track(id: 1, kind: .audio, title: "Director's Cut Mix", lang: "eng", codec: "aac")]
        let tracks = OfflinePreparedTrackInventory.audioTracks(
            probed,
            manifestTracks: [manifestAudio(title: "English", language: "en")]
        )
        XCTAssertEqual(tracks.first?.title, "Director's Cut Mix")
    }

    func testMismatchedManifestDoesNotRelabelByPosition() {
        let probed = [
            track(id: 1, kind: .audio, title: "ENG (aac)", lang: "eng", codec: "aac"),
            track(id: 2, kind: .audio, title: "FRE (aac)", lang: "fre", codec: "aac"),
        ]
        let tracks = OfflinePreparedTrackInventory.audioTracks(
            probed,
            manifestTracks: [manifestAudio(title: "Commentary", language: "en")]
        )
        XCTAssertEqual(tracks.map(\.title), [nil, nil])
        XCTAssertEqual(tracks.map(\.primaryLabel), ["English", "French"])
    }

    // MARK: - Default audio ordinal

    func testManifestAudioOrdinalResolvesToTheProbedStream() {
        XCTAssertEqual(AetherLoadSpec.offlineAudioStreamIndex(manifestOrdinal: 1, probedTrackIDs: [1, 2, 3]), 2)
        XCTAssertEqual(AetherLoadSpec.offlineAudioStreamIndex(manifestOrdinal: 0, probedTrackIDs: [1]), 1)
    }

    func testOutOfRangeAudioOrdinalFallsBackToTheFileDefault() {
        XCTAssertNil(AetherLoadSpec.offlineAudioStreamIndex(manifestOrdinal: 3, probedTrackIDs: [1, 2, 3]))
        XCTAssertNil(AetherLoadSpec.offlineAudioStreamIndex(manifestOrdinal: -1, probedTrackIDs: [1]))
        XCTAssertNil(AetherLoadSpec.offlineAudioStreamIndex(manifestOrdinal: 0, probedTrackIDs: []))
    }

    // MARK: - Subtitles

    private var preparedSubtitles: [PlayerTrack] {
        [
            // The MP4 muxer flags the first timed-text track default.
            track(id: 4, kind: .sub, title: "ENG (mov_text)", lang: "eng", codec: "mov_text", isDefault: true),
            track(id: 5, kind: .sub, title: "SDH", lang: "eng", codec: "mov_text"),
            track(id: 6, kind: .sub, title: "FRE (mov_text)", lang: "fre", codec: "mov_text", isForced: true),
            track(id: 0x4000_0000, kind: .sub, title: "Japanese", lang: "ja", codec: "ass", isExternal: true),
        ]
    }

    func testTimedTextDropsTheMuxerDefaultAndSynthesizedNames() {
        let tracks = OfflinePreparedTrackInventory.subtitleTracks(preparedSubtitles)

        XCTAssertEqual(tracks.map(\.isDefault), [false, false, false, false])
        XCTAssertEqual(tracks.map(\.title), [nil, "SDH", nil, "Japanese"])
        XCTAssertEqual(tracks.map(\.isForced), [false, false, true, false])
        XCTAssertEqual(tracks.map(\.languageFirstPrimaryLabel), ["English", "English", "French", "Japanese"])
        XCTAssertNil(tracks[0].attributesLabel?.range(of: "Default"))
    }

    func testMuxerDefaultDoesNotEnableSubtitlesOffline() {
        // Offline manifests carry no server-resolved subtitle policy, so the
        // snapshot is empty; nothing may turn a track on from the file flag.
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: nil,
            mode: nil,
            showForced: false,
            trackSignature: nil,
            availableSubtitles: OfflinePreparedTrackInventory.subtitleTracks(preparedSubtitles),
            currentAudioLanguage: "eng"
        ))
        XCTAssertEqual(pick, .noChange)
    }

    func testForcedPreferenceSelectsTheForcedTimedTextTrack() {
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: "fr",
            mode: .auto,
            showForced: true,
            trackSignature: nil,
            availableSubtitles: OfflinePreparedTrackInventory.subtitleTracks(preparedSubtitles),
            currentAudioLanguage: "fre"
        ))
        XCTAssertEqual(pick, .select(OfflinePreparedTrackInventory.subtitleTracks(preparedSubtitles)[2]))
    }

    // MARK: - Sidecar codecs

    func testSupSidecarClassifiesAsPGS() {
        let codec = SubtitleCodecClassifier.externalTrackCodec(engineCodec: "subrip", declaredFormat: "sup")
        XCTAssertEqual(codec, "sup")
        XCTAssertTrue(SubtitleCodecClassifier.isBitmap(codec))
    }

    func testRecognizedSidecarCodecsKeepTheEngineName() {
        XCTAssertEqual(SubtitleCodecClassifier.externalTrackCodec(engineCodec: "ass", declaredFormat: "ass"), "ass")
        XCTAssertEqual(SubtitleCodecClassifier.externalTrackCodec(engineCodec: "subrip", declaredFormat: "srt"), "subrip")
        XCTAssertEqual(SubtitleCodecClassifier.externalTrackCodec(engineCodec: "webvtt", declaredFormat: "vtt"), "webvtt")
        XCTAssertEqual(SubtitleCodecClassifier.externalTrackCodec(engineCodec: "subrip", declaredFormat: nil), "subrip")
        XCTAssertFalse(SubtitleCodecClassifier.isBitmap("subrip"))
    }
}
