import Foundation
import XCTest
@testable import Silo

/// The v2 series monitors: create (`non_retryable`), PATCH and DELETE under
/// `If-Match` (412 re-reads and applies again once, 428 is never retried),
/// and the per-monitor, per-page sync that keeps its validator and cursor on
/// retry and starts over after a 409.
final class DownloadSubscriptionsV2Tests: XCTestCase {
    private var stub = APIv2TestStub()
    private let device = AppleDeviceIdentity.current.id

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, CapturedOrdinaryRequestAuth) {
        let name = "DownloadSubscriptionsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://downloads.example")
        await tokens.setProfileId("profile-one")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), try XCTUnwrap(captured))
    }

    private func monitor(_ id: String = "m1", series: String = "series-1", mode: String = "all",
                         active: Bool = true, etag: String = #"\"e1\""#,
                         created: String = "2026-09-23T10:00:00.000Z") -> String {
        #"{"id":"\#(id)","series_id":"\#(series)","mode":"\#(mode)","season_numbers":[],"delete_watched":false,"max_storage_bytes":0,"active":\#(active),"created_at":"\#(created)","updated_at":"\#(created)","etag":"\#(etag)"}"#
    }

    private func syncPage(_ id: String = "m1", registered: Int, next: String? = nil) -> String {
        let info = next.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"subscription_id":"\#(id)","registered":\#(registered),"examined":10,"page":\#(info)}"#
    }

    private func problem(_ status: Int, _ type: String) -> String {
        #"{"type":"https://silo.example/problems/\#(type)","title":"Problem","status":\#(status),"detail":"Problem."}"#
    }

    private func json(_ request: StubURLProtocol.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    private func status(_ operation: () async throws -> Void) async -> Int? {
        do {
            try await operation()
            XCTFail("expected a failure")
            return nil
        } catch {
            return APIv2Client.downloadStatus(of: error)
        }
    }

    // MARK: Create

    func testCreateSendsOnceWithDeviceAndReturnsTheMonitor() async throws {
        let (api, auth) = try await client()
        stub.reply(200, monitor())
        let request = CreateSubscriptionRequest(seriesId: "series-1", mode: "all", seasonNumbers: nil,
            deleteWatched: true, maxStorageBytes: 0)

        let created = try await api.createDownloadSubscription(request, auth: auth)

        XCTAssertEqual(created.id, "m1")
        XCTAssertEqual(created.etag, #""e1""#)
        let sent = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/api/v2/downloads/subscriptions")
        XCTAssertEqual(sent.header("x-silo-device-id"), device)
        XCTAssertEqual(sent.header("x-profile-id"), "profile-one")
        let body = try json(sent)
        XCTAssertEqual(body["series_id"] as? String, "series-1")
        XCTAssertEqual(body["delete_watched"] as? Bool, true)
        XCTAssertNil(body["season_numbers"])
    }

    func testCreateIsNeverSentTwice() async throws {
        let (api, auth) = try await client()
        let request = CreateSubscriptionRequest(seriesId: "series-1", mode: "all", seasonNumbers: nil,
            deleteWatched: false, maxStorageBytes: 0)

        stub.fail(.timedOut)
        do {
            _ = try await api.createDownloadSubscription(request, auth: auth)
            XCTFail("created without an answer")
        } catch {
            XCTAssertEqual(APIv2Client.downloadRegistryFailure(error), .uncertain)
        }
        XCTAssertEqual(stub.requests.count, 1)

        // A monitor for another series is not this create's answer.
        stub.reset()
        stub.reply(200, monitor(series: "series-2"))
        do {
            _ = try await api.createDownloadSubscription(request, auth: auth)
            XCTFail("accepted another series' monitor")
        } catch {
            XCTAssertEqual(error as? DownloadSubscriptionError, .unexpectedReceipt)
            XCTAssertEqual(APIv2Client.downloadRegistryFailure(error), .uncertain)
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    // MARK: Update

    func testUpdateSendsIfMatchAndOmitsUnsetFields() async throws {
        let (api, auth) = try await client()
        stub.reply(200, monitor(mode: "future", etag: #"\"e2\""#))
        let patch = UpdateSubscriptionRequest(mode: "future", seasonNumbers: nil, deleteWatched: nil,
            maxStorageBytes: nil, active: true)

        let updated = try await api.updateDownloadSubscription(id: "m1", etag: #""e1""#, patch: patch, auth: auth)

        XCTAssertEqual(updated.etag, #""e2""#)
        let sent = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(sent.method, "PATCH")
        XCTAssertEqual(sent.path, "/api/v2/downloads/subscriptions/m1")
        XCTAssertEqual(sent.header("if-match"), #""e1""#)
        XCTAssertEqual(sent.header("x-silo-device-id"), device)
        // The server rejects null monitor fields, so unset ones are absent.
        XCTAssertEqual(try json(sent).keys.sorted(), ["active", "mode"])
    }

    func testUpdateRereadsAndAppliesAgainOnceAfter412() async throws {
        let (api, auth) = try await client()
        stub.sequence([
            .json(412, problem(412, "precondition_failed"), headers: ["ETag": #""e2""#]),
            .json(200, monitor(etag: #"\"e2\""#)),
            .json(200, monitor(mode: "future", etag: #"\"e3\""#)),
        ])
        let patch = UpdateSubscriptionRequest(mode: "future", seasonNumbers: nil, deleteWatched: nil,
            maxStorageBytes: nil, active: nil)

        let updated = try await api.updateDownloadSubscription(id: "m1", etag: #""e1""#, patch: patch, auth: auth)

        XCTAssertEqual(updated.etag, #""e3""#)
        XCTAssertEqual(stub.methods, ["PATCH", "GET", "PATCH"])
        XCTAssertEqual(stub.requests.map { $0.header("if-match") }, [#""e1""#, nil, #""e2""#])
        XCTAssertEqual(stub.requests[0].body, stub.requests[2].body)

        // A second 412 is surfaced instead of looping.
        stub.reset()
        stub.sequence([
            .json(412, problem(412, "precondition_failed")),
            .json(200, monitor(etag: #"\"e2\""#)),
            .json(412, problem(412, "precondition_failed")),
        ])
        let failed = await status { _ = try await api.updateDownloadSubscription(id: "m1", etag: #""e1""#, patch: patch, auth: auth) }
        XCTAssertEqual(failed, 412)
        XCTAssertEqual(stub.methods, ["PATCH", "GET", "PATCH"])
    }

    func testUpdateWithoutStoredValidatorReadsItFirst() async throws {
        let (api, auth) = try await client()
        stub.sequence([.json(200, monitor(etag: #"\"e7\""#)), .json(200, monitor(etag: #"\"e8\""#))])
        let patch = UpdateSubscriptionRequest(mode: nil, seasonNumbers: nil, deleteWatched: true,
            maxStorageBytes: nil, active: nil)

        _ = try await api.updateDownloadSubscription(id: "m1", etag: nil, patch: patch, auth: auth)

        XCTAssertEqual(stub.methods, ["GET", "PATCH"])
        XCTAssertEqual(stub.requests[0].path, "/api/v2/downloads/subscriptions/m1")
        XCTAssertEqual(stub.requests[1].header("if-match"), #""e7""#)
    }

    func test428IsNeverRetried() async throws {
        let (api, auth) = try await client()
        let patch = UpdateSubscriptionRequest(mode: "all", seasonNumbers: nil, deleteWatched: nil,
            maxStorageBytes: nil, active: nil)
        stub.reply(428, problem(428, "precondition_required"))

        let update = await status { _ = try await api.updateDownloadSubscription(id: "m1", etag: #""e1""#, patch: patch, auth: auth) }
        XCTAssertEqual(update, 428)
        XCTAssertEqual(stub.methods, ["PATCH"])

        stub.reset()
        stub.reply(428, problem(428, "precondition_required"))
        let delete = await status { try await api.deleteDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth) }
        XCTAssertEqual(delete, 428)
        XCTAssertEqual(stub.methods, ["DELETE"])
        XCTAssertEqual(APIv2Client.downloadRegistryFailure(APIv2Error.httpStatus(428)), .rejected)
    }

    // MARK: Delete

    func testDeleteSendsIfMatchAndTreatsAMissingMonitorAsDone() async throws {
        let (api, auth) = try await client()
        stub.reply(.response(StubURLProtocol.Response(status: 204, headers: [:], body: Data())))
        try await api.deleteDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth)
        let sent = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.path, "/api/v2/downloads/subscriptions/m1")
        XCTAssertEqual(sent.header("if-match"), #""e1""#)
        XCTAssertEqual(sent.header("x-silo-device-id"), device)

        stub.reset()
        stub.reply(404, problem(404, "not_found"))
        try await api.deleteDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth)
        XCTAssertEqual(stub.methods, ["DELETE"])

        // A stale validator: read the monitor, then delete it under the new one.
        stub.reset()
        stub.sequence([
            .json(412, problem(412, "precondition_failed")),
            .json(200, monitor(etag: #"\"e2\""#)),
            .response(StubURLProtocol.Response(status: 204, headers: [:], body: Data())),
        ])
        try await api.deleteDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth)
        XCTAssertEqual(stub.methods, ["DELETE", "GET", "DELETE"])
        XCTAssertEqual(stub.requests.last?.header("if-match"), #""e2""#)

        // Gone by the time it is read again.
        stub.reset()
        stub.sequence([.json(412, problem(412, "precondition_failed")), .json(404, problem(404, "not_found"))])
        try await api.deleteDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth)
        XCTAssertEqual(stub.methods, ["DELETE", "GET"])
    }

    // MARK: Sync

    func testSyncPagesUnderTheCapturedValidator() async throws {
        let (api, auth) = try await client()
        stub.sequence([
            .json(200, syncPage(registered: 3, next: "c1")),
            .json(200, syncPage(registered: 2)),
        ])

        let outcome = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)

        XCTAssertEqual(outcome.registered, 5)
        XCTAssertFalse(outcome.removed)
        XCTAssertNil(outcome.reloaded)
        XCTAssertEqual(stub.requestedPaths, Array(repeating: "/api/v2/downloads/subscriptions/sync", count: 2))
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "c1"])
        XCTAssertEqual(stub.requests.map { $0.query["limit"] }, ["100", "100"])
        for request in stub.requests {
            XCTAssertEqual(request.header("x-silo-device-id"), device)
            let body = try json(request)
            XCTAssertEqual(body["subscription_id"] as? String, "m1")
            XCTAssertEqual(body["etag"] as? String, #""e1""#)
        }
    }

    func testSyncRetriesAPageWithTheSameValidatorAndCursor() async throws {
        let (api, auth) = try await client()
        stub.sequence([
            .json(200, syncPage(registered: 1, next: "c1")),
            .failure(URLError(.networkConnectionLost)),
            .json(500, problem(500, "internal")),
            .json(200, syncPage(registered: 4)),
        ])

        let outcome = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)

        XCTAssertEqual(outcome.registered, 5)
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "c1", "c1", "c1"])
        XCTAssertEqual(Set(stub.requests.compactMap(\.body)).count, 1)
    }

    func testSyncReloadsTheMonitorAndStartsOverAfter409() async throws {
        let (api, auth) = try await client()
        stub.sequence([
            .json(200, syncPage(registered: 2, next: "c1")),
            .json(409, problem(409, "conflict")),
            .json(200, monitor(mode: "future", etag: #"\"e2\""#)),
            .json(200, syncPage(registered: 1)),
        ])

        let outcome = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)

        XCTAssertEqual(outcome.registered, 3)
        XCTAssertEqual(outcome.reloaded?.etag, #""e2""#)
        XCTAssertEqual(stub.methods, ["POST", "POST", "GET", "POST"])
        let last = try XCTUnwrap(stub.requests.last)
        XCTAssertNil(last.query["cursor"])
        XCTAssertEqual(try json(last)["etag"] as? String, #""e2""#)
    }

    func testSyncEndsWhenTheMonitorWasDeletedOrPaused() async throws {
        let (api, auth) = try await client()
        stub.sequence([.json(409, problem(409, "conflict")), .json(404, problem(404, "not_found"))])
        let removed = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)
        XCTAssertTrue(removed.removed)
        XCTAssertEqual(stub.methods, ["POST", "GET"])

        stub.reset()
        stub.sequence([.json(409, problem(409, "conflict")), .json(200, monitor(active: false, etag: #"\"e2\""#))])
        let paused = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)
        XCTAssertEqual(paused.reloaded?.active, false)
        XCTAssertEqual(stub.methods, ["POST", "GET"])
    }

    func testSyncPage404MeansRemovedOnlyWhenTheMonitorIsGone() async throws {
        let (api, auth) = try await client()
        stub.sequence([.json(404, problem(404, "not_found")), .json(404, problem(404, "not_found"))])
        let removed = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)
        XCTAssertTrue(removed.removed)
        XCTAssertEqual(stub.methods, ["POST", "GET"])

        // The monitor still exists, so its series is what the server hid.
        stub.reset()
        stub.sequence([.json(404, problem(404, "not_found")), .json(200, monitor())])
        let failed = await status { _ = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0) }
        XCTAssertEqual(failed, 404)
        XCTAssertEqual(stub.methods, ["POST", "GET"])
    }

    func testSyncStopsWhenTheRequestNeverLeft() async throws {
        let (api, auth) = try await client()
        stub.fail(.notConnectedToInternet)
        do {
            _ = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0)
            XCTFail("synced offline")
        } catch {
            XCTAssertEqual(APIv2Client.downloadRegistryFailure(error), .notApplied)
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSyncStopsAfterRepeated409() async throws {
        let (api, auth) = try await client()
        stub.sequence([
            .json(409, problem(409, "conflict")), .json(200, monitor(etag: #"\"e2\""#)),
            .json(409, problem(409, "conflict")), .json(200, monitor(etag: #"\"e3\""#)),
            .json(409, problem(409, "conflict")),
        ])
        let failed = await status { _ = try await api.syncDownloadSubscription(id: "m1", etag: #""e1""#, auth: auth, retryDelay: 0) }
        XCTAssertEqual(failed, 409)
        XCTAssertEqual(stub.methods, ["POST", "GET", "POST", "GET", "POST"])
    }

    // MARK: List

    func testListReadsEveryPageAndNeverReturnsAPrefix() async throws {
        let (api, auth) = try await client()
        stub.sequence([
            .json(200, #"{"items":[\#(monitor("m1"))],"page":{"has_more":true,"next_cursor":"c1"}}"#),
            .json(200, #"{"items":[\#(monitor("m2", series: "series-2"))],"page":{"has_more":false}}"#),
        ])
        let monitors = try await api.listDownloadSubscriptions(auth: auth)
        XCTAssertEqual(monitors.map(\.id), ["m1", "m2"])
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "c1"])
        XCTAssertEqual(stub.requests.first?.header("x-silo-device-id"), device)

        let broken: [[APIv2TestStub.Reply]] = [
            [.json(200, #"{"items":[\#(monitor("m1"))],"page":{"has_more":true}}"#)],
            [.json(200, #"{"items":[\#(monitor("m1", etag: ""))]}"#)],
            [.json(200, #"{"items":[\#(monitor("m1"))],"page":{"has_more":true,"next_cursor":"c1"}}"#),
             .json(200, #"{"items":[\#(monitor("m1"))]}"#)],
        ]
        for replies in broken {
            stub.reset()
            stub.sequence(replies)
            do {
                _ = try await api.listDownloadSubscriptions(auth: auth)
                XCTFail("returned an incomplete monitor list")
            } catch {
                XCTAssertEqual(error as? DownloadSubscriptionError, .incompleteList)
            }
        }
    }

    // MARK: Local list

    func testMergeKeepsTitlesAndDropsStoppedAndEarlierVersionsMonitors() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        func server(_ id: String, created: String) throws -> ServerSubscription {
            try decoder.decode(ServerSubscription.self, from: Data(monitor(id, series: "s-\(id)", etag: #"\"\#(id)-2\""#, created: created).utf8))
        }
        let known = DownloadSubscription(from: try server("known", created: "2026-01-01T00:00:00.000Z"), seriesTitle: "Known Show")
        let gone = DownloadSubscription(from: try server("gone", created: "2026-09-01T00:00:00.000Z"), seriesTitle: "Gone")
        let merged = DownloadManager.mergeSubscriptions(
            local: [known, gone],
            listed: [
                try server("known", created: "2026-01-01T00:00:00.000Z"),
                try server("stopped", created: "2026-09-20T00:00:00.000Z"),
                try server("earlier", created: "2026-09-01T00:00:00.000Z"),
                try server("new", created: "2026-09-20T00:00:00.000Z"),
            ],
            stopped: ["stopped"],
            legacy: ["earlier"]
        )

        XCTAssertEqual(merged.map(\.id), ["known", "new"])
        XCTAssertEqual(merged[0].seriesTitle, "Known Show")
        XCTAssertEqual(merged[0].etag, #""known-2""#)
        XCTAssertNil(merged[1].seriesTitle)
    }

    func testEarlierVersionsMonitorsAreTheUnknownOnesOfTheFirstListNotTheOldOnes() throws {
        // The first complete list of a scope the removal carried: whatever
        // the store doesn't know is the earlier version's, however its
        // createdAt compares with the device clock.
        let decoder = HTTPClient.makeJSONDecoder()
        func server(_ id: String, created: String) throws -> ServerSubscription {
            try decoder.decode(ServerSubscription.self, from: Data(monitor(id, series: "s-\(id)", created: created).utf8))
        }
        let mine = DownloadSubscription(from: try server("mine", created: "2020-01-01T00:00:00.000Z"), seriesTitle: "Mine")
        let listed = [
            try server("mine", created: "2020-01-01T00:00:00.000Z"),
            try server("earlier", created: "2099-01-01T00:00:00.000Z"),
            try server("stopped", created: "2020-01-01T00:00:00.000Z"),
        ]
        XCTAssertEqual(DownloadManager.unknownMonitorIds(local: [mine], listed: listed, stopped: ["stopped"]), ["earlier"])

        // A reinstall flags no scope: this device's own monitors, however old,
        // are kept and synced.
        let reinstalled = DownloadManager.mergeSubscriptions(local: [], listed: listed, stopped: [], legacy: [])
        XCTAssertEqual(reinstalled.map(\.id), ["mine", "earlier", "stopped"])
    }

    func testListReadBeforeADeleteLandedDoesNotBringTheMonitorBack() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        func server(_ id: String) throws -> ServerSubscription {
            try decoder.decode(ServerSubscription.self, from: Data(monitor(id, series: "s-\(id)").utf8))
        }
        let kept = DownloadSubscription(from: try server("kept"), seriesTitle: "Kept")
        var writes = SubscriptionWriteLedger()

        // The list read starts, then the DELETE for "stopped" lands and its
        // pending entry goes away before the list answers.
        let started = writes.generation
        writes.deleteSent("stopped")
        XCTAssertFalse(writes.deleteAnswered("stopped", landed: true))
        let landed = writes.landed(since: started)
        let merged = DownloadManager.mergeSubscriptions(
            local: [kept], listed: [try server("kept"), try server("stopped")],
            stopped: landed.deleted, createdDuringRead: landed.created, legacy: [])
        writes.listCompleted(startedAt: started)
        XCTAssertEqual(merged.map(\.id), ["kept"])

        // The next read started after the DELETE, so it no longer needs it.
        XCTAssertTrue(writes.wasDeleted("stopped"))
        writes.listCompleted(startedAt: writes.generation)
        XCTAssertFalse(writes.wasDeleted("stopped"))
    }

    func testListReadBeforeACreateAnsweredKeepsTheCreatedMonitor() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let created = DownloadSubscription(
            from: try decoder.decode(ServerSubscription.self, from: Data(monitor("new").utf8)), seriesTitle: "New")
        var writes = SubscriptionWriteLedger()

        let started = writes.generation
        writes.createAnswered("new", cancelledPendingDelete: false)
        let landed = writes.landed(since: started)
        let merged = DownloadManager.mergeSubscriptions(
            local: [created], listed: [], stopped: landed.deleted, createdDuringRead: landed.created,
            legacy: [])
        XCTAssertEqual(merged.map(\.id), ["new"])

        // A read that started after the create is authoritative again.
        writes.listCompleted(startedAt: started)
        let later = writes.landed(since: writes.generation)
        XCTAssertTrue(DownloadManager.mergeSubscriptions(
            local: [created], listed: [], stopped: later.deleted, createdDuringRead: later.created,
            legacy: []).isEmpty)
    }

    func testCreateAnsweredDuringItsMonitorsDeleteDependsOnThatDelete() {
        // The DELETE lands after a create answered with the same monitor:
        // the created monitor is gone.
        var writes = SubscriptionWriteLedger()
        writes.deleteSent("m1")
        writes.createAnswered("m1", cancelledPendingDelete: true)
        XCTAssertTrue(writes.awaitsDelete("m1"))
        XCTAssertTrue(writes.deleteAnswered("m1", landed: true))
        XCTAssertTrue(writes.wasDeleted("m1"))
        XCTAssertFalse(writes.awaitsDelete("m1"))

        // The DELETE was refused: the monitor the create returned stays.
        writes = SubscriptionWriteLedger()
        writes.deleteSent("m1")
        writes.createAnswered("m1", cancelledPendingDelete: true)
        XCTAssertFalse(writes.deleteAnswered("m1", landed: false))
        XCTAssertFalse(writes.wasDeleted("m1"))

        // A pending DELETE that was never sent leaves nothing to wait for.
        writes = SubscriptionWriteLedger()
        writes.createAnswered("m1", cancelledPendingDelete: true)
        XCTAssertFalse(writes.awaitsDelete("m1"))
    }

    func testCreateAnsweredWithDifferentOptionsNeedsAnEdit() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let existing = DownloadSubscription(
            from: try decoder.decode(ServerSubscription.self, from: Data(monitor(mode: "specific_seasons").utf8)),
            seriesTitle: nil)
        func request(_ mode: String, seasons: [Int]? = nil, deleteWatched: Bool = false) -> CreateSubscriptionRequest {
            CreateSubscriptionRequest(seriesId: "series-1", mode: mode, seasonNumbers: seasons,
                deleteWatched: deleteWatched, maxStorageBytes: 0)
        }
        XCTAssertTrue(DownloadManager.monitorMatches(existing, request("specific_seasons", seasons: [])))
        XCTAssertFalse(DownloadManager.monitorMatches(existing, request("specific_seasons", seasons: [2])))
        XCTAssertFalse(DownloadManager.monitorMatches(existing, request("all")))
        XCTAssertFalse(DownloadManager.monitorMatches(existing, request("specific_seasons", seasons: [], deleteWatched: true)))
    }

    func testMonitorsStoredWithoutAValidatorStillDecode() throws {
        let stored = #"{"id":"m1","seriesId":"series-1","seriesTitle":"Show","mode":"all","deleteWatched":false,"maxStorageBytes":0,"active":true}"#
        let monitor = try JSONDecoder().decode(DownloadSubscription.self, from: Data(stored.utf8))
        XCTAssertNil(monitor.etag)
        XCTAssertEqual(monitor.seriesTitle, "Show")
    }
}
