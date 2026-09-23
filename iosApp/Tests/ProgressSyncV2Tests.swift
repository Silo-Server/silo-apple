import Foundation
import XCTest
@testable import Silo

/// `POST /api/v2/sync/progress`: the wire shape, the three dispatch outcomes
/// of a `non_retryable` operation, and the offline queue rules built on them.
final class ProgressSyncV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, TokenStore) {
        let name = "ProgressSyncV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://progress.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private func item(_ id: String, position: Double = 12.3456, updatedAt: Date? = nil) throws -> SyncProgressItem {
        try XCTUnwrap(SyncProgressItem(mediaItemId: id, position: position, duration: 5400,
            forceOverwrite: false, updatedAt: updatedAt))
    }

    private func success(_ index: Int, _ id: String) -> String {
        #"{"index":\#(index),"media_item_id":"\#(id)","status":"success"}"#
    }

    private func failure(_ index: Int, _ id: String) -> String {
        #"{"index":\#(index),"media_item_id":"\#(id)","status":"failure","failure":{"type":"https://silo.example/problems/not_found","title":"Not Found","status":404,"detail":"Catalog item not found."}}"#
    }

    private func batch(_ rows: [String], succeeded: Int, failed: Int) -> String {
        #"{"items":[\#(rows.joined(separator: ","))],"summary":{"total":\#(rows.count),"succeeded":\#(succeeded),"failed":\#(failed)}}"#
    }

    // MARK: Wire

    func testBatchSendsIntegerMillisecondsAndMapsMixedResultsByIndex() async throws {
        let (api, _) = try await client()
        let event = Date(timeIntervalSince1970: 1_767_323_045.5)
        // Results arrive out of order; the client keys them back by index.
        stub.reply(200, batch([failure(1, "episode-2"), success(0, "movie-1")], succeeded: 1, failed: 1))

        let outcome = await api.syncProgress([try item("movie-1", updatedAt: event), try item("episode-2")])

        guard case .answered(let results) = outcome else { return XCTFail("unexpected \(outcome)") }
        XCTAssertEqual(results.map(\.mediaItemId), ["movie-1", "episode-2"])
        XCTAssertEqual(results.map(\.succeeded), [true, false])
        XCTAssertEqual(results[1].failure?.status, 404)
        XCTAssertFalse(outcome.allSucceeded)

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/sync/progress")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["media_item_id"] as? String, "movie-1")
        XCTAssertEqual(items[0]["position_ms"] as? Int, 12_346)
        XCTAssertEqual(items[0]["duration_ms"] as? Int, 5_400_000)
        XCTAssertEqual(items[0]["force_overwrite"] as? Bool, false)
        XCTAssertEqual(items[0]["updated_at"] as? String, "2026-01-02T03:04:05.500Z")
        XCTAssertNil(items[1]["updated_at"])
        XCTAssertEqual(Set(items[0].keys), ["media_item_id", "position_ms", "duration_ms", "force_overwrite", "updated_at"])
    }

    func testUnsendableValuesNeverBecomeItems() {
        XCTAssertNil(SyncProgressItem(mediaItemId: " ", position: 1, duration: 1, forceOverwrite: false))
        XCTAssertNil(SyncProgressItem(mediaItemId: "a", position: -1, duration: 1, forceOverwrite: false))
        XCTAssertNil(SyncProgressItem(mediaItemId: "a", position: .nan, duration: 1, forceOverwrite: false))
        let unknownRuntime = SyncProgressItem(mediaItemId: "a", position: 1, duration: .infinity, forceOverwrite: true)
        XCTAssertEqual(unknownRuntime?.durationMs, 0)
    }

    func testInvalidBatchesAreRefusedWithoutDispatch() async throws {
        let (api, _) = try await client()
        let tooMany = try (0...SyncProgressRequest.maxItems).map { try item("item-\($0)") }
        for items in [[], [try item("same"), try item("same", position: 20)], tooMany] {
            let outcome = await api.syncProgress(items)
            guard case .notSent(let error) = outcome else { return XCTFail("dispatched \(items.count) items: \(outcome)") }
            XCTAssertEqual(error as? ProgressSyncError, .invalidBatch)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Outcomes

    private func problem(_ status: Int, _ type: String) -> String {
        #"{"type":"https://silo.example/problems/\#(type)","title":"Problem","status":\#(status),"detail":"Problem."}"#
    }

    func testPermanentRejectionsAreRejected() async throws {
        let (api, _) = try await client()
        for (status, body) in [
            (422, problem(422, "validation_failed")),
            (400, problem(400, "invalid_request")),
            (403, problem(403, "forbidden")),
            (404, problem(404, "not_found")),
            (500, problem(500, "internal_error")),
        ] {
            stub.reset()
            stub.reply(status, body)
            guard case .rejected = await api.syncProgress([try item("movie-1")]) else { return XCTFail("\(status) not rejected") }
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    /// The server applied nothing and says so: the batch may go out again.
    func testTransientAndUpdateRequiredAnswersAreDeferred() async throws {
        let (api, _) = try await client()
        for (status, body) in [
            (503, problem(503, "service_unavailable")),
            (429, problem(429, "rate_limited")),
            (408, "timeout"),
            (410, problem(410, "client_upgrade_required")),
            (404, "404 page not found\n"),
        ] {
            stub.reset()
            stub.reply(status, body)
            guard case .deferred = await api.syncProgress([try item("movie-1")]) else { return XCTFail("\(status) not deferred") }
            XCTAssertEqual(stub.requests.count, 1, "\(status) was re-sent")
        }
    }

    func testLostConnectionAfterSendIsUncertainAndNotResent() async throws {
        let (api, _) = try await client()
        for code in [URLError.Code.networkConnectionLost, .timedOut] {
            stub.reset()
            stub.fail(code)
            guard case .uncertain = await api.syncProgress([try item("movie-1")]) else { return XCTFail("\(code) not uncertain") }
            XCTAssertEqual(stub.requests.count, 1, "\(code) was re-sent")
        }
    }

    func testConnectionNeverEstablishedIsNotSent() async throws {
        let (api, _) = try await client()
        stub.fail(.cannotConnectToHost)
        guard case .notSent = await api.syncProgress([try item("movie-1")]) else { return XCTFail("expected notSent") }
    }

    func testAnswerThatDoesNotMatchTheBatchIsUncertain() async throws {
        let (api, _) = try await client()
        let items = [try item("movie-1"), try item("episode-2")]
        for body in [
            batch([success(0, "movie-1")], succeeded: 1, failed: 0),
            batch([success(0, "movie-1"), success(1, "someone-else")], succeeded: 2, failed: 0),
            batch([success(0, "movie-1"), success(0, "episode-2")], succeeded: 2, failed: 0),
            "{}",
        ] {
            stub.reply(200, body)
            guard case .uncertain = await api.syncProgress(items) else { return XCTFail("accepted \(body)") }
        }
    }

    func testOwnerChangeBeforeDispatchSendsNothing() async throws {
        let (api, tokens) = try await client()
        let captured = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        await tokens.setProfileId("profile-two")
        guard case .notSent = await api.syncProgress([try item("movie-1")], auth: auth) else {
            return XCTFail("dispatched under a replaced profile")
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Offline queue

    private func queued(_ ids: [String]) -> [QueuedProgress] {
        var queue: [QueuedProgress] = []
        for (offset, id) in ids.enumerated() {
            OfflineProgressQueue.record(&queue, mediaItemId: id, position: Double(offset + 1), duration: 60,
                at: Date(timeIntervalSince1970: TimeInterval(offset)))
        }
        return queue
    }

    func testUncertainBatchIsHeldAndNeverOfferedAgain() {
        var queue = queued(["a", "b"])
        let batch = OfflineProgressQueue.nextBatch(queue)
        OfflineProgressQueue.claim(&queue, ids: Set(batch.map(\.id)))
        OfflineProgressQueue.resolve(&queue, batch: batch, outcome: .uncertain(URLError(.timedOut)))

        XCTAssertTrue(OfflineProgressQueue.nextBatch(queue).isEmpty)
        XCTAssertEqual(OfflineProgressQueue.held(queue, inFlight: []).map(\.mediaItemId), ["a", "b"])
        // While the flush is still waiting, the same entries are in flight, not held.
        XCTAssertTrue(OfflineProgressQueue.held(queue, inFlight: Set(batch.map(\.id))).isEmpty)

        // A newer event replaces the held entry with a fresh pending write.
        OfflineProgressQueue.record(&queue, mediaItemId: "a", position: 99, duration: 60, at: Date())
        XCTAssertEqual(OfflineProgressQueue.nextBatch(queue).map(\.position), [99])
        XCTAssertEqual(OfflineProgressQueue.held(queue, inFlight: []).map(\.mediaItemId), ["b"])

        OfflineProgressQueue.discardHeld(&queue, inFlight: [])
        XCTAssertEqual(queue.map(\.mediaItemId), ["a"])
    }

    func testDefiniteOutcomesReleaseAndUnappliedBatchesReturnToPending() {
        let rejected422 = APIv2Error.problem(APIv2Problem(type: "https://silo.example/problems/validation_failed",
            title: "Unprocessable", status: 422, detail: "", instance: nil, errors: nil))
        for outcome: ProgressSyncOutcome in [.answered([]), .rejected(rejected422)] {
            var queue = queued(["a"])
            let batch = OfflineProgressQueue.nextBatch(queue)
            OfflineProgressQueue.claim(&queue, ids: Set(batch.map(\.id)))
            OfflineProgressQueue.resolve(&queue, batch: batch, outcome: outcome)
            XCTAssertTrue(queue.isEmpty, "\(outcome) kept the entry")
        }

        for outcome: ProgressSyncOutcome in [
            .notSent(URLError(.notConnectedToInternet)),
            APIv2Client.progressSyncFailure(APIv2Error.httpStatus(503)),
            APIv2Client.progressSyncFailure(APIv2Error.httpStatus(429)),
            APIv2Client.progressSyncFailure(APIv2Error.serverUpdateRequired),
        ] {
            var queue = queued(["a"])
            let batch = OfflineProgressQueue.nextBatch(queue)
            OfflineProgressQueue.claim(&queue, ids: Set(batch.map(\.id)))
            OfflineProgressQueue.resolve(&queue, batch: batch, outcome: outcome)
            XCTAssertEqual(OfflineProgressQueue.nextBatch(queue).map(\.id), batch.map(\.id), "\(outcome) dropped the entry")
            XCTAssertTrue(OfflineProgressQueue.held(queue, inFlight: []).isEmpty)
        }
    }

    /// One outage or rejection costs at most the batch that met it.
    func testFlushSendsTheNextBatchOnlyAfterAnAnswer() {
        XCTAssertTrue(OfflineProgressQueue.flushContinues(after: .answered([])))
        for outcome: ProgressSyncOutcome in [
            .rejected(APIv2Error.httpStatus(422)),
            .deferred(APIv2Error.httpStatus(503)),
            .notSent(URLError(.cannotConnectToHost)),
            .uncertain(URLError(.timedOut)),
        ] {
            XCTAssertFalse(OfflineProgressQueue.flushContinues(after: outcome), "\(outcome) kept flushing")
        }
    }

    func testEntryReplacedInFlightSurvivesItsBatch() {
        var queue = queued(["a"])
        let batch = OfflineProgressQueue.nextBatch(queue)
        OfflineProgressQueue.claim(&queue, ids: Set(batch.map(\.id)))
        OfflineProgressQueue.record(&queue, mediaItemId: "a", position: 42, duration: 60, at: Date())
        OfflineProgressQueue.resolve(&queue, batch: batch, outcome: .answered([]))
        XCTAssertEqual(queue.map(\.position), [42])
        XCTAssertEqual(queue.first?.state, .pending)
    }

    func testBatchesHoldAtMostOneHundredDistinctItems() {
        var queue = queued((0..<150).map { "item-\($0)" })
        // A duplicate and an unusable entry, as an older store might hold.
        queue.append(QueuedProgress(id: UUID(), mediaItemId: "item-0", position: 1, duration: 60,
            updatedAt: .distantPast))
        queue.append(QueuedProgress(id: UUID(), mediaItemId: "", position: 1, duration: 60, updatedAt: Date()))
        OfflineProgressQueue.dropUnsendable(&queue)
        XCTAssertEqual(queue.count, 150)
        let batch = OfflineProgressQueue.nextBatch(queue)
        XCTAssertEqual(batch.count, 100)
        XCTAssertTrue(SyncProgressRequest(items: batch.compactMap(\.syncItem)).isValidBatch)
    }

    func testStoredEntryWithoutStateDecodesAsPending() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","mediaItemId":"a","position":1,"duration":2,"updatedAt":0,"attempts":3}"#
        let entry = try JSONDecoder().decode(QueuedProgress.self, from: Data(json.utf8))
        XCTAssertEqual(entry.state, .pending)
    }
}
