import Foundation
import XCTest
@testable import Silo

final class OfflineSubtitleSelectionTests: XCTestCase {
    private func sidecar(_ index: Int, filename: String) -> SubtitleUrl {
        SubtitleUrl(index: index, language: "en", codec: "srt", label: "English",
                    source: "external", forced: false, hearingImpaired: false,
                    url: "file:///download/\(filename)")
    }

    private func track(index: Int, external: Bool) -> PlayerTrack {
        PlayerTrack(trackId: external ? SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: index) : Int64(index),
                    kind: .sub, title: "English", lang: "en", codec: external ? "srt" : "ass",
                    audioChannelCount: nil, bitrate: nil, isDefault: false, isForced: false,
                    isHearingImpaired: false, isExternal: external, isSelected: true,
                    ffIndex: external ? nil : index, srcId: external ? index : nil)
    }

    func testExternalEnglishPickUsesTheCachedFilenameInsteadOfTheMenuOrdinal() throws {
        let selection = try XCTUnwrap(OfflineSubtitleSelection.capture(
            track: track(index: 3, external: true),
            subtitles: [sidecar(0, filename: "sub_ar.srt"), sidecar(3, filename: "sub_en.srt")]
        ))
        XCTAssertEqual(selection, .sidecar(filename: "sub_en.srt"))

        // A later load can publish the same cached file at a different index.
        let restored = selection.resolve(subtitles: [sidecar(9, filename: "sub_en.srt")])
        XCTAssertNil(restored.embeddedIndex)
        XCTAssertEqual(restored.sidecarId, SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 9))
    }

    func testEmbeddedPickKeepsTheStreamIndex() throws {
        let selection = try XCTUnwrap(OfflineSubtitleSelection.capture(
            track: track(index: 2, external: false), subtitles: []
        ))
        let restored = selection.resolve(subtitles: [])
        XCTAssertEqual(restored.embeddedIndex, 2)
        XCTAssertNil(restored.sidecarId)
    }

    func testOffIsAnExplicitSelection() throws {
        let selection = try XCTUnwrap(OfflineSubtitleSelection.capture(track: nil, subtitles: []))
        XCTAssertEqual(selection, .off)
        XCTAssertEqual(selection.resolve(subtitles: []).embeddedIndex, -1)
        XCTAssertNil(selection.resolve(subtitles: []).sidecarId)
    }

    func testMissingSidecarDoesNotSelectAnotherFileAtItsOldOrdinal() {
        let restored = OfflineSubtitleSelection.sidecar(filename: "sub_en.srt")
            .resolve(subtitles: [sidecar(3, filename: "sub_ar.srt")])
        XCTAssertNil(restored.embeddedIndex)
        XCTAssertNil(restored.sidecarId)
    }

    func testLiveAndUnmappedTracksAreNotRemembered() {
        let live = PlayerTrack(trackId: SubtitleTrackIdSpace.makeAILiveTrackId(0), kind: .sub,
            title: "Live English", lang: "en", codec: "srt", audioChannelCount: nil, bitrate: nil,
            isDefault: false, isForced: false, isHearingImpaired: false, isExternal: true,
            isSelected: true, ffIndex: nil, srcId: 0)
        XCTAssertNil(OfflineSubtitleSelection.capture(track: live, subtitles: [sidecar(0, filename: "sub_en.srt")]))
        XCTAssertNil(OfflineSubtitleSelection.capture(track: track(index: 3, external: true), subtitles: []))
    }

    func testSelectionSurvivesAColdStoreLoadAndStaysInItsProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(rootDirectory: { root })
        var file = DownloadStoreFile.empty
        var record = makeRecord()
        record.subtitleSelection = try XCTUnwrap(OfflineSubtitleSelection.capture(
            track: track(index: 3, external: true), subtitles: [sidecar(3, filename: "sub_en.srt")]
        ))
        file.records[record.id] = record
        await store.save(file, serverId: "server", profileId: "one")

        let coldStore = DownloadStore(rootDirectory: { root })
        let loaded = await coldStore.load(serverId: "server", profileId: "one")
        let selection = try XCTUnwrap(loaded.records[record.id]?.subtitleSelection)
        XCTAssertEqual(selection.resolve(subtitles: [sidecar(3, filename: "sub_en.srt")]).sidecarId,
                       SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3))
        let otherProfile = await coldStore.load(serverId: "server", profileId: "two")
        let otherServer = await coldStore.load(serverId: "other-server", profileId: "one")
        XCTAssertNil(otherProfile.records[record.id])
        XCTAssertNil(otherServer.records[record.id])

        file.records[record.id]?.subtitleSelection = .off
        await store.save(file, serverId: "server", profileId: "one")
        let off = await coldStore.load(serverId: "server", profileId: "one")
        XCTAssertEqual(off.records[record.id]?.subtitleSelection, .off)
    }

    func testOlderDownloadRecordsHaveNoExplicitSubtitleChoice() throws {
        let data = try JSONEncoder().encode(makeRecord())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "subtitleSelection")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(DownloadRecord.self, from: oldData).subtitleSelection)
    }

    @MainActor
    func testRestoredSidecarWaitsForThePlayerInventory() async {
        let model = PlayerViewModel()
        let english = track(index: 3, external: true)
        model.restoreOfflineSubtitleSelection(.sidecar(filename: "sub_en.srt"),
            subtitles: [sidecar(3, filename: "sub_en.srt")])
        model.applyPendingSubtitleSelections(aetherSubtitleTracks: [], publishedSubtitleTracks: [],
                                             loadIsEstablished: false)
        XCTAssertNil(model.selectedSubtitleId)
        model.subtitleTracks = [english]
        model.applyPendingSubtitleSelections(aetherSubtitleTracks: [english], publishedSubtitleTracks: [english],
                                             loadIsEstablished: true)
        XCTAssertEqual(model.selectedSubtitleId, english.trackId)
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    @MainActor
    func testRestoredOffClearsTheContainerDefaultAfterStartup() async {
        let model = PlayerViewModel()
        model.restoreOfflineSubtitleSelection(.off, subtitles: [])
        model.selectedSubtitleId = 2
        model.applyPendingSubtitleSelections(aetherSubtitleTracks: [], publishedSubtitleTracks: [],
                                             loadIsEstablished: false)
        XCTAssertEqual(model.selectedSubtitleId, 2)
        model.applyPendingSubtitleSelections(aetherSubtitleTracks: [], publishedSubtitleTracks: [],
                                             loadIsEstablished: true)
        XCTAssertNil(model.selectedSubtitleId)
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    @MainActor
    func testCurrentExplicitPickWinsOverTheStoredChoice() async {
        let model = PlayerViewModel()
        let embedded = track(index: 2, external: false)
        model.selectSubtitle(embedded)
        model.restoreOfflineSubtitleSelection(.off, subtitles: [])
        model.applyPendingSubtitleSelections(aetherSubtitleTracks: [embedded], publishedSubtitleTracks: [embedded],
                                             loadIsEstablished: true)
        XCTAssertEqual(model.selectedSubtitleId, embedded.trackId)
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    private func makeRecord() -> DownloadRecord {
        DownloadRecord(id: "download", contentId: "series", episodeId: "episode", batchId: nil,
            mediaFileId: "42", format: "original", serverStatus: "completed", localStatus: .completed,
            fileSize: 100, bytesDownloaded: 100, mediaFilename: "media.mkv", manifestFilename: "manifest.json",
            posterFilename: nil, backdropFilename: nil, logoFilename: nil,
            subtitleFilenames: ["external:3": "sub_en.srt"], title: "Episode", subtitle: nil,
            type: "episode", seriesId: "series", posterThumbhash: nil, container: "mkv", stableIdentity: nil,
            registeredAt: Date(), downloadedAt: Date(), lastError: nil, retryCount: 0, taskIdentifier: nil)
    }
}
