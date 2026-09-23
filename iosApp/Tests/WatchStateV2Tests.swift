import Foundation
import XCTest
@testable import Silo

/// Offline watch state from `GET /api/v2/progress`: a bounded full paged read
/// under one owner that never returns a prefix, a merge by `updated_at`, and
/// `delete_watched` acting only on a complete read.
final class WatchStateV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, CapturedOrdinaryRequestAuth, TokenStore) {
        let name = "WatchStateV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://progress.example")
        await tokens.setProfileId("profile-one")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), try XCTUnwrap(captured), tokens)
    }

    private func entry(_ id: String, completed: Bool = false, position: Double = 60,
                       updated: String = "2026-09-23T10:00:00.000Z") -> String {
        #"{"media_item_id":"\#(id)","position_seconds":\#(position),"duration_seconds":1800,"completed":\#(completed),"updated_at":"\#(updated)"}"#
    }

    private func page(_ entries: [String], next: String? = nil) -> APIv2TestStub.Reply {
        let info = next.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return .json(200, #"{"items":[\#(entries.joined(separator: ","))],"page":\#(info)}"#)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    // MARK: Read

    func testReadCollectsEveryPageUnderTheCapturedOwner() async throws {
        let (api, auth, _) = try await client()
        stub.sequence([
            page([entry("e1"), entry("e2")], next: "c1"),
            page([entry("e3", completed: true)]),
        ])
        let entries = try await api.listAllProgress(auth: auth)
        XCTAssertEqual(entries.map(\.mediaItemId), ["e1", "e2", "e3"])
        XCTAssertEqual(entries.last?.completed, true)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/progress", "/api/v2/progress"])
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "c1"])
        XCTAssertEqual(stub.requests.map { $0.query["limit"] }, ["200", "200"])
        XCTAssertTrue(stub.requests.allSatisfy { $0.query["since"] == nil }, "v2 rejects since with 422")
        XCTAssertEqual(stub.requests.first?.header("x-profile-id"), "profile-one")
    }

    func testReadThatCannotStandForTheWholeSetThrows() async throws {
        let (api, auth, _) = try await client()
        let broken: [[APIv2TestStub.Reply]] = [
            // More pages promised without a cursor.
            [.json(200, #"{"items":[\#(entry("e1"))],"page":{"has_more":true}}"#)],
            // A repeated cursor or item.
            [page([entry("e1")], next: "c1"), page([entry("e2")], next: "c1")],
            [page([entry("e1")], next: "c1"), page([entry("e1")])],
            // Interrupted after the first page.
            [page([entry("e1", completed: true)], next: "c1"), .failure(URLError(.networkConnectionLost))],
            [page([entry("e1", completed: true)], next: "c1"), .json(503, #"{"type":"about:blank","title":"Unavailable","status":503}"#)],
            // No page information on a paginated read.
            [.json(200, #"{"items":[\#(entry("e1"))]}"#)],
        ]
        for replies in broken {
            stub.reset()
            stub.sequence(replies)
            do {
                let entries = try await api.listAllProgress(auth: auth)
                XCTFail("returned a partial read: \(entries.map(\.mediaItemId))")
            } catch {}
        }
    }

    func testReadStopsAtTheHundredPageBound() async throws {
        let (api, auth, _) = try await client()
        stub.sequence((0..<101).map { page([entry("e\($0)")], next: "c\($0)") })
        do {
            _ = try await api.listAllProgress(auth: auth)
            XCTFail("an unbounded read must fail instead of truncating")
        } catch {
            XCTAssertEqual(error as? ProgressReadError, .incompleteRead)
        }
        XCTAssertEqual(stub.requests.count, APIv2Client.progressMaxPages)
    }

    func testReadIsRefusedOnceTheOwnerChanged() async throws {
        let (api, auth, tokens) = try await client()
        await tokens.setProfileId("profile-two")
        do {
            _ = try await api.listAllProgress(auth: auth)
            XCTFail("a read for a replaced owner must not be sent")
        } catch HTTPError.requestIdentityChanged {}
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Merge

    func testMergeKeepsTheNewerSideAndDropsWhatTheServerNoLongerHas() throws {
        let readStart = try date("2026-09-23T12:00:00Z")
        let older = try date("2026-09-23T09:00:00Z")
        let newer = try date("2026-09-23T11:00:00Z")
        let local: [String: LocalProgressEntry] = [
            // The server wrote later (another device marked it unwatched).
            "stale": LocalProgressEntry(position: 1700, duration: 1800, completed: true, updatedAt: older),
            // Written on this device after the server's value.
            "local-newer": LocalProgressEntry(position: 900, duration: 1800, completed: false, updatedAt: newer),
            // Cleared on the server and not queued here: dropped.
            "cleared": LocalProgressEntry(position: 1800, duration: 1800, completed: true, updatedAt: older),
            // Absent from the read but still waiting to upload: kept.
            "queued": LocalProgressEntry(position: 300, duration: 1800, completed: false, updatedAt: older),
            // Written while the read was in flight: kept.
            "during-read": LocalProgressEntry(position: 30, duration: 1800, completed: false,
                                              updatedAt: readStart.addingTimeInterval(1)),
        ]
        let read = [
            APIv2ProgressEntry(mediaItemId: "stale", positionSeconds: 0, durationSeconds: 1800,
                               completed: false, updatedAt: newer),
            APIv2ProgressEntry(mediaItemId: "local-newer", positionSeconds: 100, durationSeconds: 1800,
                               completed: true, updatedAt: older),
            APIv2ProgressEntry(mediaItemId: "new", positionSeconds: 42, durationSeconds: 0,
                               completed: false, updatedAt: older),
        ]

        let merged = DownloadManager.mergeProgress(local, read: read, readStartedAt: readStart, queuedItemIds: ["queued"])

        XCTAssertEqual(Set(merged.keys), ["stale", "local-newer", "queued", "during-read", "new"])
        XCTAssertEqual(merged["stale"], LocalProgressEntry(position: 0, duration: 1800, completed: false, updatedAt: newer))
        XCTAssertEqual(merged["local-newer"], local["local-newer"])
        XCTAssertEqual(merged["queued"], local["queued"])
        XCTAssertEqual(merged["new"]?.position, 42)
    }

    // MARK: delete_watched

    /// Captures one read the way `refreshWatchState()` does.
    private func read(_ api: APIv2Client, _ auth: CapturedOrdinaryRequestAuth) async -> Result<[APIv2ProgressEntry], Error> {
        do { return .success(try await api.listAllProgress(auth: auth)) } catch { return .failure(error) }
    }

    func testInterruptedReadDeletesNothing() async throws {
        let (api, auth, _) = try await client()
        // Already marked watched locally, so a missing gate would delete it.
        var file = try retentionFile()
        let watched = LocalProgressEntry(position: 1800, duration: 1800, completed: true,
                                         updatedAt: try date("2026-09-20T10:00:00Z"))
        file.localProgress["episode-1"] = watched
        XCTAssertEqual(DownloadManager.watchedDownloadIds(in: file), ["download-1"])

        // The first page says the episode was watched, then the read breaks.
        stub.sequence([page([entry("episode-1", completed: true)], next: "c1"),
                       .failure(URLError(.networkConnectionLost))])
        let interrupted = await read(api, auth)
        XCTAssertNil(DownloadManager.applyWatchStateRead(interrupted, ownerStillCurrent: true,
                                                         to: file, readStartedAt: Date()))
        XCTAssertEqual(DownloadManager.retentionDeletions(readApplied: false, ownerStillCurrent: true, in: file), [])
        XCTAssertEqual(file.localProgress, ["episode-1": watched])
    }

    func testReadWhoseOwnerChangedDeletesNothing() async throws {
        let (api, auth, _) = try await client()
        var file = try retentionFile()
        file.localProgress["episode-1"] = LocalProgressEntry(position: 1800, duration: 1800, completed: true,
                                                             updatedAt: try date("2026-09-20T10:00:00Z"))
        stub.sequence([page([entry("episode-1", completed: true)])])
        let complete = await read(api, auth)

        // The read finished, but the scope changed before it was applied.
        XCTAssertNil(DownloadManager.applyWatchStateRead(complete, ownerStillCurrent: false,
                                                         to: file, readStartedAt: Date()))
        // Or after it was applied, while the run's reconcile was in flight.
        XCTAssertEqual(DownloadManager.retentionDeletions(readApplied: true, ownerStillCurrent: false, in: file), [])
    }

    func testCompleteReadThatSaysWatchedDeletesTheDownload() async throws {
        let (api, auth, _) = try await client()
        var file = try retentionFile()
        stub.sequence([page([entry("episode-1", completed: true)], next: "c1"), page([])])
        let complete = await read(api, auth)

        let merged = try XCTUnwrap(DownloadManager.applyWatchStateRead(complete, ownerStillCurrent: true,
                                                                       to: file, readStartedAt: Date()))
        file.localProgress = merged
        XCTAssertEqual(merged["episode-1"]?.completed, true)
        XCTAssertEqual(DownloadManager.retentionDeletions(readApplied: true, ownerStillCurrent: true, in: file),
                       ["download-1"])
    }

    func testCompleteReadWithoutTheItemKeepsTheDownload() throws {
        var file = try retentionFile()
        file.localProgress["episode-1"] = LocalProgressEntry(
            position: 1800, duration: 1800, completed: true, updatedAt: try date("2026-09-20T10:00:00Z"))
        XCTAssertEqual(DownloadManager.watchedDownloadIds(in: file), ["download-1"])

        // Marked unwatched elsewhere: the server no longer lists the item.
        file.localProgress = try XCTUnwrap(DownloadManager.applyWatchStateRead(.success([]), ownerStillCurrent: true,
                                                                               to: file, readStartedAt: Date()))
        XCTAssertEqual(DownloadManager.retentionDeletions(readApplied: true, ownerStillCurrent: true, in: file), [])
    }

    /// A completed episode download under a monitor with `delete_watched`.
    private func retentionFile() throws -> DownloadStoreFile {
        let monitor = #"{"id":"m1","series_id":"series-1","mode":"all","season_numbers":[],"delete_watched":true,"max_storage_bytes":0,"active":true,"created_at":"2026-09-23T10:00:00.000Z","updated_at":"2026-09-23T10:00:00.000Z","etag":"\"e1\""}"#
        let server = try HTTPClient.makeJSONDecoder().decode(ServerSubscription.self, from: Data(monitor.utf8))
        var file = DownloadStoreFile.empty
        file.subscriptions = [DownloadSubscription(from: server, seriesTitle: "Show")]
        file.records["download-1"] = DownloadRecord(
            id: "download-1", contentId: "series-1", episodeId: "episode-1", batchId: nil,
            mediaFileId: "file-1", format: "original", serverStatus: "ready", localStatus: .completed,
            fileSize: 10, bytesDownloaded: 10, mediaFilename: "media.mkv", subtitleFilenames: [:],
            seriesId: "series-1", registeredAt: Date(), retryCount: 0)
        return file
    }
}
