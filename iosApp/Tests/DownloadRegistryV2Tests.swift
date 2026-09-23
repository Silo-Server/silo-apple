import Foundation
import XCTest
@testable import Silo

/// The v2 download registry: capability, create (`non_retryable`), paged
/// list, status events (`domain_identity`) and delete, with the failure
/// outcome each answer maps to.
final class DownloadRegistryV2Tests: XCTestCase {
    private var stub = APIv2TestStub()
    private let device = AppleDeviceIdentity.current.id

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, TokenStore, CapturedOrdinaryRequestAuth) {
        let name = "DownloadRegistryV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://downloads.example")
        await tokens.setProfileId("profile-one")
        let captured = await tokens.captureOrdinaryRequestAuth()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens, try XCTUnwrap(captured))
    }

    private func entry(_ id: String, content: String = "movie-1", episode: String? = nil, file: String = "42",
                       quality: String = "original", revision: Int = 1, device: String? = nil) -> String {
        let episodeField = episode.map { #""episode_id":"\#($0)","# } ?? ""
        return #"{"id":"\#(id)","content_id":"\#(content)",\#(episodeField)"device_id":"\#(device ?? self.device)","media_file_id":"\#(file)","file_size":1000,"bytes_sent":0,"kind":"queued","status":"ready","quality":"\#(quality)","effective_quality":"\#(quality)","delivery_format":"original","target_bitrate_kbps":0,"revision":\#(revision),"created_at":"2026-09-23T10:00:00.000Z"}"#
    }

    private func page(_ entries: [String], next: String? = nil) -> String {
        let info = next.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"items":[\#(entries.joined(separator: ","))],"page":\#(info)}"#
    }

    private func created(_ entries: [String], batch: String? = nil, next: String? = nil, skipped: String = "") -> String {
        let info = next.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        let batchField = batch.map { #","batch_id":"\#($0)""# } ?? ""
        return #"{"items":[\#(entries.joined(separator: ","))],"skipped":[\#(skipped)],"page":\#(info)\#(batchField)}"#
    }

    private func problem(_ status: Int, _ type: String) -> String {
        #"{"type":"https://silo.example/problems/\#(type)","title":"Problem","status":\#(status),"detail":"Problem."}"#
    }

    private func json(_ request: StubURLProtocol.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    private func failure(_ operation: () async throws -> Void) async -> DownloadRegistryFailure? {
        do {
            try await operation()
            return nil
        } catch {
            return APIv2Client.downloadRegistryFailure(error)
        }
    }

    // MARK: Capability

    func testCapabilityIsUsableOnlyWhenAvailableAndAllowed() async throws {
        let (api, _, auth) = try await client()
        func body(state: String, allowed: Bool) -> String {
            #"{"state":"\#(state)","allowed":\#(allowed),"revision":"r1","enabled":true,"download_allowed":true,"quality_presets":["original","5mbps"],"transcode_enabled":true,"transcode_user_allowed":false,"season_download":true,"series_monitoring":false,"monitoring_modes":[],"bounded_creation":true,"subscription_mutations":true,"bounded_subscription_sync":true,"subscription_reads":true,"bounded_manifests":true,"file_delivery":true,"proxy_delivery":false,"ordered_status":true}"#
        }
        stub.reply(200, body(state: "available", allowed: true))
        let capability = try await api.downloadCapability(auth: auth)
        XCTAssertTrue(capability.isUsable)
        XCTAssertEqual(capability.qualityPresets, ["original", "5mbps"])
        XCTAssertTrue(capability.seasonDownload)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/capabilities/downloads")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")

        stub.reply(200, body(state: "available", allowed: false))
        let demo = try await api.downloadCapability(auth: auth)
        XCTAssertFalse(demo.isUsable)
        stub.reply(200, body(state: "not_configured", allowed: true))
        let unconfigured = try await api.downloadCapability(auth: auth)
        XCTAssertFalse(unconfigured.isUsable)

        // A required field the app reads is never defaulted.
        stub.reply(200, #"{"state":"available","allowed":true,"enabled":true,"download_allowed":true}"#)
        do {
            _ = try await api.downloadCapability(auth: auth)
            XCTFail("decoded a capability without its presets")
        } catch {}
    }

    func testCapabilityCachedWithoutStateReadsAsUnusable() throws {
        let cached = #"{"enabled":true,"downloadAllowed":true,"qualityPresets":["original"],"transcodeEnabled":false,"transcodeUserAllowed":false,"seasonDownload":false,"seriesMonitoring":false,"monitoringModes":[]}"#
        let capability = try JSONDecoder().decode(DownloadCapability.self, from: Data(cached.utf8))
        XCTAssertFalse(capability.isUsable)
    }

    // MARK: List

    func testListReadsEveryPageForThisDevice() async throws {
        let (api, _, auth) = try await client()
        stub.sequence([
            .json(200, page([entry("d1"), entry("d2", content: "series-1", episode: "ep-1", file: "7")], next: "c1")),
            .json(200, page([entry("d3")])),
        ])

        let entries = try await api.listDownloads(auth: auth)

        XCTAssertEqual(entries.map(\.id), ["d1", "d2", "d3"])
        XCTAssertEqual(entries[1].mediaFileId, "7")
        XCTAssertEqual(stub.requests.map(\.path), ["/api/v2/downloads", "/api/v2/downloads"])
        XCTAssertEqual(stub.requests.map { $0.query["limit"] }, ["100", "100"])
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "c1"])
        for request in stub.requests {
            XCTAssertEqual(request.header("x-silo-device-id"), device)
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
    }

    func testListNeverReturnsAPrefix() async throws {
        let (api, _, auth) = try await client()
        let broken: [[APIv2TestStub.Reply]] = [
            // More pages promised without a cursor.
            [.json(200, #"{"items":[\#(entry("d1"))],"page":{"has_more":true}}"#)],
            // The same cursor twice.
            [.json(200, page([entry("d1")], next: "c1")), .json(200, page([entry("d2")], next: "c1"))],
            // The same entry twice.
            [.json(200, page([entry("d1")], next: "c1")), .json(200, page([entry("d1")]))],
            // Another device's entry.
            [.json(200, page([entry("d1", device: "someone-else")]))],
            // An entry without a revision a status event could name.
            [.json(200, page([entry("d1", revision: 0)]))],
            // A failing later page.
            [.json(200, page([entry("d1")], next: "c1")), .json(503, problem(503, "service_unavailable"))],
        ]
        for replies in broken {
            stub.reset()
            stub.sequence(replies)
            do {
                let entries = try await api.listDownloads(auth: auth)
                XCTFail("returned \(entries.map(\.id))")
            } catch {}
        }
    }

    func testListStopsAfterOneHundredPages() async throws {
        let (api, _, auth) = try await client()
        stub.sequence((0..<101).map { .json(200, page([entry("d\($0)")], next: "c\($0)")) })
        do {
            _ = try await api.listDownloads(auth: auth)
            XCTFail("read past the page bound")
        } catch {
            XCTAssertEqual(error as? DownloadRegistryError, .incompleteRegistry)
        }
        XCTAssertEqual(stub.requests.count, APIv2Client.downloadRegistryMaxPages)
    }

    // MARK: Create

    func testSingleCreateSendsAGuardedManagedRequest() async throws {
        let (api, _, auth) = try await client()
        stub.reply(202, created([entry("d1", content: "series-1", episode: "ep-1", file: "42", quality: "5mbps")]))

        let answer = try await api.createDownloads(.single(contentId: "series-1", episodeId: "ep-1", mediaFileId: "42",
            quality: "5mbps", caps: .current(), expected: .absent), auth: auth)

        XCTAssertEqual(answer.items.map(\.id), ["d1"])
        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/downloads")
        XCTAssertTrue(request.query.isEmpty)
        XCTAssertEqual(request.header("x-silo-device-id"), device)
        let body = try json(request)
        XCTAssertEqual(body["content_id"] as? String, "series-1")
        XCTAssertEqual(body["episode_id"] as? String, "ep-1")
        XCTAssertEqual(body["media_file_id"] as? String, "42")
        XCTAssertEqual(body["quality"] as? String, "5mbps")
        XCTAssertEqual(body["expected_revision"] as? Int, 0)
        XCTAssertNil(body["expected_download_id"])
        XCTAssertNil(body["series"])
        XCTAssertNil(body["batch_id"])
        let caps = try XCTUnwrap(body["caps"] as? [String: Any])
        XCTAssertNotNil(caps["codecs_video"])
        XCTAssertNotNil(caps["max_resolution"])

        stub.reset()
        stub.reply(202, created([entry("d1", revision: 4)]))
        _ = try await api.createDownloads(.single(contentId: "movie-1", episodeId: nil, mediaFileId: nil,
            quality: "original", caps: .current(), expected: .entry(id: "d1", revision: 3)), auth: auth)
        let replacement = try json(XCTUnwrap(stub.requests.first))
        XCTAssertEqual(replacement["expected_revision"] as? Int, 3)
        XCTAssertEqual(replacement["expected_download_id"] as? String, "d1")
        XCTAssertNil(replacement["media_file_id"])
        XCTAssertNil(replacement["episode_id"])
    }

    func testCreateIsSentOnceWhateverTheOutcome() async throws {
        let (api, _, auth) = try await client()
        let single = APIv2DownloadCreateRequest.single(contentId: "movie-1", episodeId: nil, mediaFileId: "42",
            quality: "original", caps: .current(), expected: .absent)
        let cases: [(APIv2TestStub.Reply, DownloadRegistryFailure)] = [
            (.json(409, problem(409, "conflict")), .conflict),
            (.json(422, problem(422, "validation_failed")), .rejected),
            (.json(403, problem(403, "permission_denied")), .rejected),
            (.json(429, problem(429, "rate_limited")), .notApplied),
            (.json(410, problem(410, "client_upgrade_required")), .notApplied),
            (.text(404, "404 page not found\n", contentType: "text/plain"), .notApplied),
            (.json(500, problem(500, "internal_error")), .uncertain),
            (.failure(URLError(.networkConnectionLost)), .uncertain),
            (.failure(URLError(.cannotConnectToHost)), .notApplied),
            // Answered, but not for this item: the server already acted.
            (.json(202, created([entry("d1", file: "99")])), .uncertain),
            (.json(202, created([entry("d1"), entry("d2")])), .uncertain),
            (.json(201, created([entry("d1")])), .uncertain),
        ]
        for (reply, expected) in cases {
            stub.reset()
            stub.reply(reply)
            let outcome = await failure { _ = try await api.createDownloads(single, auth: auth) }
            XCTAssertEqual(outcome, expected, "\(reply)")
            XCTAssertEqual(stub.requests.count, 1, "\(reply) was re-sent")
        }
    }

    func testSeriesPagesRepeatTheBatchAndFollowTheCursor() async throws {
        let (api, _, auth) = try await client()
        let request = APIv2DownloadCreateRequest.seriesPage(seriesId: "series-1", seasonNumber: 2, batchId: "batch-1",
            caps: .current())
        stub.sequence([
            .json(202, created([entry("d1", content: "series-1", episode: "ep-1")], batch: "batch-1", next: "c1")),
            .json(202, created([entry("d2", content: "series-1", episode: "ep-2")], batch: "batch-1",
                skipped: #"{"episode_id":"ep-3","reason":"no_file"}"#)),
        ])

        let first = try await api.createDownloads(request, auth: auth)
        let second = try await api.createDownloads(request, cursor: first.page.nextCursor, auth: auth)

        XCTAssertEqual(second.skipped.map(\.episodeId), ["ep-3"])
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "c1"])
        XCTAssertEqual(stub.requests.map { $0.query["limit"] }, ["100", "100"])
        for request in stub.requests {
            let body = try json(request)
            XCTAssertEqual(body["content_id"] as? String, "series-1")
            XCTAssertEqual(body["series"] as? Bool, true)
            XCTAssertEqual(body["season_number"] as? Int, 2)
            XCTAssertEqual(body["batch_id"] as? String, "batch-1")
            XCTAssertEqual(body["quality"] as? String, "original")
            XCTAssertNil(body["expected_revision"])
            XCTAssertNil(body["media_file_id"])
        }

        stub.reset()
        stub.reply(202, created([entry("d1", content: "series-1", episode: "ep-1")], batch: "another-batch"))
        let outcome = await failure { _ = try await api.createDownloads(request, auth: auth) }
        XCTAssertEqual(outcome, .uncertain)
    }

    func testCreateRefusesShapesTheServerWouldRejectWithoutSending() async throws {
        let (api, _, auth) = try await client()
        let invalid: [(APIv2DownloadCreateRequest, String?)] = [
            (.single(contentId: "", episodeId: nil, mediaFileId: nil, quality: "original", caps: .current(), expected: .absent), nil),
            (.single(contentId: "m", episodeId: nil, mediaFileId: nil, quality: "original", caps: .current(),
                expected: .entry(id: "d1", revision: 0)), nil),
            // A cursor belongs to a series request only.
            (.single(contentId: "m", episodeId: nil, mediaFileId: nil, quality: "original", caps: .current(), expected: .absent), "c1"),
            (.seriesPage(seriesId: "s", seasonNumber: nil, batchId: "", caps: .current()), nil),
        ]
        for (request, cursor) in invalid {
            let outcome = await failure { _ = try await api.createDownloads(request, cursor: cursor, auth: auth) }
            XCTAssertEqual(outcome, .rejected)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testOwnerChangeBeforeDispatchSendsNothing() async throws {
        let (api, tokens, auth) = try await client()
        await tokens.setProfileId("profile-two")
        let outcome = await failure {
            _ = try await api.createDownloads(.single(contentId: "movie-1", episodeId: nil, mediaFileId: nil,
                quality: "original", caps: .current(), expected: .absent), auth: auth)
        }
        XCTAssertEqual(outcome, .notApplied)
        let listOutcome = await failure { _ = try await api.listDownloads(auth: auth) }
        XCTAssertEqual(listOutcome, .notApplied)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Status events

    func testStatusRetrySendsTheSameEvent() async throws {
        let (api, _, auth) = try await client()
        let event = DownloadStatusEvent(status: .completed, updatedAt: Date(timeIntervalSince1970: 1_790_000_000.25),
            revision: 3)
        stub.sequence([.failure(URLError(.networkConnectionLost)), .json(200, entry("d/1", revision: 3))])

        let first = await failure { _ = try await api.reportDownloadStatus(id: "d/1", event: event, auth: auth) }
        XCTAssertEqual(first, .uncertain)
        XCTAssertEqual(DownloadManager.statusReportResolution(URLError(.networkConnectionLost)), .retryLater)
        // The event survives the store unchanged, so the retry is identical.
        let stored = try JSONDecoder().decode(DownloadStatusEvent.self, from: JSONEncoder().encode(event))
        let answer = try await api.reportDownloadStatus(id: "d/1", event: stored, auth: auth)

        XCTAssertEqual(answer.id, "d/1")
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.requests[0].body, stub.requests[1].body)
        let request = stub.requests[1]
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.url?.absoluteString.hasSuffix("/api/v2/downloads/d%2F1"), true)
        XCTAssertEqual(request.header("x-silo-device-id"), device)
        let body = try json(request)
        XCTAssertEqual(body["status"] as? String, "completed")
        XCTAssertEqual(body["updated_at"] as? String, "2026-09-21T14:13:20.250Z")
        XCTAssertEqual(body["revision"] as? Int, 3)
        XCTAssertEqual(Set(body.keys), ["status", "updated_at", "revision"])
    }

    func testStatusAnswersDecideWhetherTheEventIsKept() async throws {
        let (api, _, auth) = try await client()
        let event = DownloadStatusEvent(status: .downloading, updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            revision: 2)
        let cases: [(APIv2TestStub.Reply, DownloadManager.StatusReportResolution)] = [
            (.json(200, entry("d1", revision: 2)), .settled),
            // The entry's bytes were replaced: drop the event, read the registry.
            (.json(409, problem(409, "conflict")), .reconcile),
            (.json(404, problem(404, "not_found")), .settled),
            (.json(400, problem(400, "malformed_request")), .settled),
            (.json(503, problem(503, "service_unavailable")), .retryLater),
            (.json(500, problem(500, "internal_error")), .retryLater),
            (.json(410, problem(410, "client_upgrade_required")), .retryLater),
            (.json(200, entry("someone-else", revision: 2)), .retryLater),
        ]
        for (reply, expected) in cases {
            stub.reset()
            stub.reply(reply)
            var thrown: Error?
            do { _ = try await api.reportDownloadStatus(id: "d1", event: event, auth: auth) } catch { thrown = error }
            XCTAssertEqual(DownloadManager.statusReportResolution(thrown), expected, "\(reply)")
            XCTAssertEqual(stub.requests.count, 1)
        }
    }

    // MARK: Delete

    func testDeleteExpectsNoContent() async throws {
        let (api, _, auth) = try await client()
        stub.reply(.response(StubURLProtocol.Response(status: 204, headers: [:], body: Data())))
        try await api.deleteDownload(id: "d1", auth: auth)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, "/api/v2/downloads/d1")
        XCTAssertEqual(request.header("x-silo-device-id"), device)

        stub.reset()
        stub.reply(503, problem(503, "service_unavailable"))
        let outcome = await failure { try await api.deleteDownload(id: "d1", auth: auth) }
        XCTAssertEqual(outcome, .notApplied)
    }

    // MARK: Store

    func testRecordKeepsItsPendingEventAndStoreKeepsPendingDeletes() throws {
        let event = DownloadStatusEvent(status: .completed, updatedAt: Date(timeIntervalSince1970: 1_790_000_000.123),
            revision: 5)
        var file = DownloadStoreFile.empty
        let entries = try HTTPClient.makeJSONDecoder().decode([APIv2DownloadEntry].self,
            from: Data("[\(entry("d1", file: "abc"))]".utf8))
        let split = DownloadManager.partitionUnknownRows(entries, legacyRowsPending: false)
        XCTAssertEqual(split.imported.first?.mediaFileId, "abc")
        file.pendingServerDeletes = ["d9"]

        let decoded = try JSONDecoder().decode(DownloadStoreFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(decoded.pendingServerDeletes, ["d9"])

        let recordJSON = #"{"id":"d1","contentId":"movie-1","mediaFileId":"abc","format":"original","serverStatus":"ready","localStatus":"downloading","fileSize":1,"bytesDownloaded":0,"subtitleFilenames":{},"registeredAt":0,"retryCount":0}"#
        var record = try JSONDecoder().decode(DownloadRecord.self, from: Data(recordJSON.utf8))
        XCTAssertNil(record.pendingStatusEvent)
        record.pendingStatusEvent = event
        let roundTripped = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(roundTripped.pendingStatusEvent, event)
        XCTAssertEqual(roundTripped.mediaFileId, "abc")
    }
}
