import Foundation
import XCTest
@testable import Silo

/// Subtitle wire models and the v2 provider-search, stored-subtitle and
/// download calls: opaque string identity on the wire, exact statuses, the
/// profile header, and the send-once download outcomes.
final class APIv2SubtitleTests: XCTestCase {
    private var stub = APIv2TestStub()

    private static let downloadBody = SubtitleDownloadBody(
        from: SubtitleSearchResult(id: "os-123", provider: "opensubtitles", language: "en",
                                   releaseName: "Some.Movie", format: "srt", score: 87.5, hearingImpaired: false),
        mediaFileId: 42)

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client(profile: String = "profile-one") async throws -> (APIv2Client, TokenStore) {
        let name = "APIv2SubtitleTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://subtitles.example")
        await tokens.setProfileId(profile)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private static func problem(_ type: String, _ status: Int, _ detail: String) -> String {
        #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"T","status":\#(status),"detail":"\#(detail)","instance":"urn:silo:request:1"}"#
    }

    private static func downloadResponse(id: String) -> String {
        #"{"subtitle":{"id":"\#(id)","media_file_id":"42","provider":"opensubtitles","language":"en","format":"srt","release_name":"Some.Movie","score":87.5,"hearing_impaired":false,"created_at":"2026-01-02T03:04:05.678Z"}}"#
    }

    private func owner(_ tokens: TokenStore) async throws -> CapturedOrdinaryRequestAuth {
        let captured = await tokens.captureOrdinaryRequestAuth()
        return try XCTUnwrap(captured)
    }
    private func fixture(_ name: String) throws -> Data {
        try APIv2FixtureTestSupport.data(named: name, bundleClass: Self.self)
    }

    private func assertInvalidSubtitleResponse<T>(_ expression: @autoclosure () throws -> T,
                                                  _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            guard case APIv2Error.invalidSubtitleResponse = error else {
                return XCTFail("\(message): unexpected \(error)", file: file, line: line)
            }
        }
    }

    private func assertDecodingFails<T: Decodable>(_ type: T.Type, from data: Data, _ message: String,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(type, from: data), message, file: file, line: line) { error in
            XCTAssertTrue(error is DecodingError, "\(message): unexpected \(error)", file: file, line: line)
        }
    }

    func testCreateAndCancelPreserveOpaqueJobIdentifiers() async throws {
        let name = "SubtitleJobIdentityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://subtitles.example")
        let stub = APIv2TestStub()
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let body = try APIv2SubtitleCreateBody(TranslateSubtitleBody(mediaFileId: 42, kind: .translate,
            sourceIndex: 0, sourceLanguage: "en", targetLanguage: "fr", sessionId: nil, startPosition: 0))
        for id in ["opaque-job", "007", "9223372036854775808", "job/part?x#y%z", ""] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitle_ai_job_opaque_id")) as? [String: Any])
            var job = try XCTUnwrap(object["job"] as? [String: Any])
            job["id"] = id; job["kind"] = "translate"; job["source_index"] = 0
            object["job"] = job; object["live_delivery_attached"] = false
            stub.reply(202, String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
            let auth = try await api.captureRequestOwner()
            if id.isEmpty {
                // The job may exist even though its receipt is unusable.
                do { _ = try await api.createSubtitle(body, auth: auth); XCTFail("Accepted empty job ID") }
                catch SubtitleCreationError.outcomeUnknown { }
                let count = stub.requests.count
                do { try await api.cancelSubtitleJob(id: id); XCTFail("Dispatched empty job ID") }
                catch APIv2Error.invalidSubtitleResponse { }
                XCTAssertEqual(stub.requests.count, count)
            } else {
                let created = try await api.createSubtitle(body, auth: auth)
                XCTAssertEqual(created.job.id, id)
                stub.reply(204, "")
                try await api.cancelSubtitleJob(id: id)
                let request = try XCTUnwrap(stub.requests.last)
                let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                XCTAssertNil(components.query)
                XCTAssertNil(components.fragment)
                let segment = try XCTUnwrap(components.percentEncodedPath.split(separator: "/").dropLast().last)
                XCTAssertEqual(String(segment).removingPercentEncoding, id)
            }
        }
    }

    func testAIJobFixturePreservesOpaqueIdentityAndNullableResult() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: fixture("subtitle_ai_job_opaque_id"))
        XCTAssertEqual(wire.job.id, "9007199254740993")
        // The synthetic server fixture intentionally has an empty kind.
        // Preserve it on the wire, but refuse unsupported player semantics.
        assertInvalidSubtitleResponse(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id), "empty kind")
        let playable = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: fixture("subtitle_ai_job_opaque_id").replacingEmptyJobKind())
        let job = try SubtitleJob(v2: playable.job, expectedJobID: "9007199254740993")
        XCTAssertEqual(job.id, "9007199254740993")
        XCTAssertEqual(job.mediaFileId, 42)
        XCTAssertNil(job.resultSubtitleId)
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.errorMessage, "Subtitle processing failed.")
        XCTAssertEqual(job.updatedAt, "2026-01-02T03:04:05.678Z")
        assertInvalidSubtitleResponse(try SubtitleJob(v2: playable.job, expectedJobID: "9007199254740992"), "job id mismatch")
    }

    /// Result IDs stay opaque; only an empty one breaks the contract. The
    /// file ID must be a string holding a positive integer.
    func testAIJobResultIDStaysOpaque() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitle_ai_job_opaque_id")) as? [String: Any])
        var row = try XCTUnwrap(object["job"] as? [String: Any])
        row["kind"] = "translate"
        for raw in ["9007199254740993", "9223372036854775808", "07", "opaque", ""] {
            row["result_subtitle_id"] = raw
            object["job"] = row
            let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
                from: JSONSerialization.data(withJSONObject: object))
            if raw.isEmpty {
                assertInvalidSubtitleResponse(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id), "empty result id")
            } else {
                XCTAssertEqual(try SubtitleJob(v2: wire.job, expectedJobID: wire.job.id).resultSubtitleId, raw)
            }
        }
        row["result_subtitle_id"] = NSNull()
        row["status"] = "queued"
        object["job"] = row
        let pending = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleJobEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try SubtitleJob(v2: pending.job, expectedJobID: pending.job.id).status, .pending,
                       "an unknown status must not stop the poller")
        row["media_file_id"] = 42
        object["job"] = row
        assertDecodingFails(APIv2SubtitleJobEnvelope.self, from: try JSONSerialization.data(withJSONObject: object),
                            "a numeric media_file_id is not the wire contract")
    }

    func testAIQuotaReadsTheV2PathAndRequiresEveryField() async throws {
        let (api, _) = try await client()
        stub.reply(200, String(decoding: try fixture("subtitle_ai_quota"), as: UTF8.self))
        let quota = try await api.subtitleAIQuota()
        XCTAssertEqual(quota, SubtitleAIQuota(limited: true, limit: 5, used: 2, remaining: 3, period: "daily"))
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/subtitles/ai/quota")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")

        // The v1 server left the counters out when unmetered; v2 always sends them.
        stub.reply(200, #"{"limited":false}"#)
        do { _ = try await api.subtitleAIQuota(); XCTFail("Decoded a quota without its counters") }
        catch is DecodingError { }
    }

    func testAIStatusIsAvailableOnlyWhenAllowedAndAvailable() async throws {
        let (api, _) = try await client()
        func body(enabled: Bool, transcribe: Bool, state: String, allowed: Bool) -> String {
            #"{"enabled":\#(enabled),"transcribe_enabled":\#(transcribe),"revision":"r","state":"\#(state)","allowed":\#(allowed)}"#
        }
        let cases: [(String, SubtitleAIStatus)] = [
            (body(enabled: true, transcribe: true, state: "available", allowed: true),
             SubtitleAIStatus(enabled: true, transcribeEnabled: true)),
            (body(enabled: false, transcribe: true, state: "available", allowed: true),
             SubtitleAIStatus(enabled: false, transcribeEnabled: true)),
            (body(enabled: true, transcribe: true, state: "available", allowed: false),
             SubtitleAIStatus(enabled: false, transcribeEnabled: false)),
            (body(enabled: true, transcribe: true, state: "disabled", allowed: true),
             SubtitleAIStatus(enabled: false, transcribeEnabled: false)),
            (body(enabled: true, transcribe: true, state: "future_state", allowed: true),
             SubtitleAIStatus(enabled: false, transcribeEnabled: false)),
        ]
        for (json, expected) in cases {
            stub.reply(200, json)
            let status = try await api.subtitleAIStatus()
            XCTAssertEqual(status, expected, json)
        }
        XCTAssertEqual(Set(stub.requestedPaths), ["/api/v2/subtitles/ai/status"])
        XCTAssertEqual(stub.requests.first?.header("X-Profile-Id"), "profile-one")

        // The contract requires `allowed` and `state`; the v1 shape is not an answer.
        stub.reply(200, #"{"enabled":true,"transcribe_enabled":true}"#)
        do { _ = try await api.subtitleAIStatus(); XCTFail("Decoded a status without allowed/state") }
        catch is DecodingError { }
    }

    /// A failed probe is not an answer: the capability keeps its last value.
    @MainActor
    func testAICapabilitiesKeepTheSubtitleStatusWhenTheProbeFails() async throws {
        let (api, _) = try await client()
        let capabilities = AICapabilities(api: SiloAI(v2: api))
        stub.reply(path: "/api/v2/subtitles/ai/status", 200,
                   #"{"enabled":true,"transcribe_enabled":false,"revision":"r","state":"available","allowed":true}"#)
        await capabilities.refresh()
        XCTAssertTrue(capabilities.subtitleEnabled)
        stub.reply(path: "/api/v2/subtitles/ai/status", 503, Self.problem("service_unavailable", 503, "Down"))
        await capabilities.refresh()
        XCTAssertTrue(capabilities.subtitleEnabled)
        XCTAssertFalse(capabilities.transcribeEnabled)
    }

    // MARK: Subtitle AI jobs

    private static func aiJob(id: String = "77", kind: String = "translate", sourceIndex: Int = 0,
                              file: String = "42", status: String = "running") -> String {
        #"{"id":"\#(id)","media_file_id":"\#(file)","kind":"\#(kind)","source_index":\#(sourceIndex),"source_language":"en","target_language":"fr","engine":"llm","model":"m","status":"\#(status)","progress":0.5,"progress_message":"","result_subtitle_id":null,"created_at":"2026-01-02T03:04:05.678Z","updated_at":"2026-01-02T03:04:05.678Z"}"#
    }

    private static func receipt(_ job: String = aiJob(), attached: Bool = false) -> String {
        #"{"job":\#(job),"live_delivery_attached":\#(attached)}"#
    }

    private static func translate(to target: String = "fr", sessionId: String? = nil) -> TranslateSubtitleBody {
        TranslateSubtitleBody(mediaFileId: 42, kind: .translate, sourceIndex: 0, sourceLanguage: "en",
                              targetLanguage: target, sessionId: sessionId, startPosition: 12.5)
    }

    private func postCount() -> Int { stub.requests.filter { $0.method == "POST" }.count }

    func testCreatePostsTheContractBody() async throws {
        let (api, tokens) = try await client()
        let ai = SiloAI(v2: api)
        let auth = try await owner(tokens)
        stub.reply(202, Self.receipt())
        let created = try await ai.translateSubtitle(Self.translate(), auth: auth)
        XCTAssertEqual(created.job.id, "77")
        XCTAssertEqual(created.job.mediaFileId, 42)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/subtitles/ai/translate")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["media_file_id", "kind", "source_index", "source_language",
                                        "target_language", "start_position"])
        XCTAssertEqual(body["media_file_id"] as? String, "42")
        XCTAssertEqual(body["kind"] as? String, "translate")
        XCTAssertEqual(body["start_position"] as? Double, 12.5)

        // Transcription sends both languages even when the player has none,
        // and a live session only when there is one.
        stub.reset()
        stub.reply(202, Self.receipt(Self.aiJob(kind: "transcribe", sourceIndex: -1), attached: true))
        let transcribe = TranslateSubtitleBody(mediaFileId: 42, kind: .transcribe, sourceIndex: -1, sourceLanguage: nil,
                                               targetLanguage: nil, sessionId: "session-1", startPosition: 0)
        let live = try await ai.translateSubtitle(transcribe, auth: auth)
        XCTAssertTrue(live.liveDeliveryAttached)
        let liveBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(stub.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(liveBody["source_language"] as? String, "")
        XCTAssertEqual(liveBody["target_language"] as? String, "")
        XCTAssertEqual(liveBody["session_id"] as? String, "session-1")
        XCTAssertEqual(liveBody["source_index"] as? Int, -1)
    }

    /// `createSubtitleAIJob` is `non_retryable`. A server answer or a request
    /// that never left releases the request; anything that may have started a
    /// job holds it until the user discards it. Nothing is ever resent.
    func testCreateHoldsOnlyAnUnknownOutcome() async throws {
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        let definite: [APIv2TestStub.Reply] = [
            .failure(URLError(.cannotConnectToHost)),
            .json(422, Self.problem("validation_failed", 422, "The subtitle request is not valid.")),
            .json(429, Self.problem("rate_limited", 429, "Transcription quota exhausted.")),
            .json(503, Self.problem("dependency_unavailable", 503, "AI subtitle processing is not configured")),
        ]
        for reply in definite {
            stub.reset()
            let ai = SiloAI(v2: api)
            stub.reply(reply)
            do { _ = try await ai.translateSubtitle(Self.translate(), auth: auth); XCTFail("Expected \(reply) to fail") }
            catch { XCTAssertFalse(SubtitleCreationError.isUncertain(error), "\(error)") }
            stub.reply(202, Self.receipt())
            _ = try await ai.translateSubtitle(Self.translate(), auth: auth)
            XCTAssertEqual(postCount(), 2, "a definite failure is released: \(reply)")
        }

        let uncertain: [APIv2TestStub.Reply] = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)),
            .json(202, #"{"job":"#),
            .json(200, Self.receipt()),
            .json(202, Self.receipt(Self.aiJob(file: "43"))),
        ]
        for reply in uncertain {
            stub.reset()
            let ai = SiloAI(v2: api)
            stub.reply(reply)
            do { _ = try await ai.translateSubtitle(Self.translate(), auth: auth); XCTFail("Expected \(reply) to fail") }
            catch { XCTAssertTrue(SubtitleCreationError.isUncertain(error), "\(error)") }

            // A new playhead does not make it a new request.
            let moved = TranslateSubtitleBody(mediaFileId: 42, kind: .translate, sourceIndex: 0, sourceLanguage: "en",
                                              targetLanguage: "fr", sessionId: "session-2", startPosition: 99)
            do { _ = try await ai.translateSubtitle(moved, auth: auth); XCTFail("Resent a held request") }
            catch SubtitleCreationError.unresolved { }
            XCTAssertEqual(postCount(), 1, "a held request is never resent: \(reply)")

            stub.reply(202, Self.receipt())
            _ = try await ai.translateSubtitle(Self.translate(to: "de"), auth: auth)
            XCTAssertEqual(postCount(), 2, "another target language is a different request")

            await ai.discardUnresolvedSubtitle(Self.translate(), auth: auth)
            _ = try await ai.translateSubtitle(Self.translate(), auth: auth)
            XCTAssertEqual(postCount(), 3, "a discarded hold can be sent again")
        }
    }

    func testCreateForAReplacedOwnerIsRefusedOrHeld() async throws {
        // Replaced before the call: refused, nothing sent, nothing held.
        let (api, tokens) = try await client()
        let ai = SiloAI(v2: api)
        let auth = try await owner(tokens)
        await tokens.setProfileId("profile-two")
        for _ in 0..<2 {
            do { _ = try await ai.translateSubtitle(Self.translate(), auth: auth); XCTFail("Sent for a replaced owner") }
            catch HTTPError.requestIdentityChanged { }
        }
        XCTAssertTrue(stub.requests.isEmpty)

        // Replaced while in flight: the server may have started the job.
        stub.reset()
        let (inFlight, inFlightTokens) = try await client()
        let inFlightAI = SiloAI(v2: inFlight)
        let inFlightOwner = try await owner(inFlightTokens)
        stub.reply(202, Self.receipt())
        stub.hold()
        let task = Task { try await inFlightAI.translateSubtitle(Self.translate(), auth: inFlightOwner) }
        await stub.waitUntilHeld()
        await inFlightTokens.setProfileToken("replacement")
        stub.release()
        do {
            _ = try await task.value
            XCTFail("A receipt for a replaced owner cannot publish")
        } catch {
            XCTAssertEqual(error as? SubtitleCreationError, .outcomeUnknown)
        }
        do { _ = try await inFlightAI.translateSubtitle(Self.translate(), auth: inFlightOwner); XCTFail("Resent") }
        catch SubtitleCreationError.unresolved { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testPollAndCancelRunForTheJobOwner() async throws {
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        stub.reply(200, #"{"job":\#(Self.aiJob(status: "completed"))}"#)
        let job = try await api.subtitleJob(id: "77", auth: auth)
        XCTAssertEqual(job.status, .completed)
        let poll = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(poll.method, "GET")
        XCTAssertEqual(poll.path, "/api/v2/subtitles/ai/jobs/77")
        XCTAssertEqual(poll.header("X-Profile-Id"), "profile-one")

        // A snapshot of another job is not this job's state.
        stub.reply(200, #"{"job":\#(Self.aiJob(id: "78"))}"#)
        do { _ = try await api.subtitleJob(id: "77", auth: auth); XCTFail("Accepted another job") }
        catch APIv2Error.invalidSubtitleResponse { }

        stub.reset()
        stub.reply(204, "")
        try await api.cancelSubtitleJob(id: "77", auth: auth)
        XCTAssertEqual(stub.requests.first?.method, "POST")
        XCTAssertEqual(stub.requests.first?.path, "/api/v2/subtitles/ai/jobs/77/cancel")

        // Neither runs for an owner that has been replaced.
        stub.reset()
        await tokens.setProfileId("profile-two")
        do { _ = try await api.subtitleJob(id: "77", auth: auth); XCTFail("Polled for a replaced owner") }
        catch HTTPError.requestIdentityChanged { }
        do { try await api.cancelSubtitleJob(id: "77", auth: auth); XCTFail("Cancelled for a replaced owner") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// The menu shows an unknown outcome as a failure with a way to let the
    /// held request go; a repeat tap is refused without sending.
    @MainActor
    func testControllerHoldsAnUnknownOutcomeUntilDiscarded() async throws {
        let (api, _) = try await client()
        stub.fail(.networkConnectionLost)
        let controller = SubtitleAIController(
            api: SiloAI(v2: api),
            mediaFileId: { 42 },
            currentTime: { 3 },
            handoffContext: { nil },
            registerAndSelectDescriptor: { _ in }
        )
        func settle() async {
            for _ in 0..<500 where controller.phase == .submitting { try? await Task.sleep(for: .milliseconds(10)) }
        }

        controller.transcribe(audioIndex: -1, translateTo: "fr")
        await settle()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.hasHeldRequest)
        XCTAssertEqual(controller.errorMessage, SubtitleCreationError.outcomeUnknown.errorDescription)

        controller.transcribe(audioIndex: -1, translateTo: "fr")
        await settle()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertTrue(controller.hasHeldRequest)
        XCTAssertEqual(controller.errorMessage, SubtitleCreationError.unresolved.errorDescription)
        XCTAssertEqual(postCount(), 1, "the held request was not sent again")

        controller.discardHeldRequest()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.hasHeldRequest)
        XCTAssertNil(controller.errorMessage)
    }

    /// When the poller gives up on a poll-only job, the job may still finish
    /// on the server; the menu says so instead of showing progress forever,
    /// and the preparing presentation ends.
    @MainActor
    func testControllerReportsAJobThePollerLostTrackOf() async throws {
        let (api, _) = try await client()
        stub.sequence([.json(202, Self.receipt(Self.aiJob(kind: "transcribe", sourceIndex: -1)))])
        stub.fail(.networkConnectionLost)
        let sink = LiveSink()
        let coordinator = LiveSubtitleCoordinator(controls: LiveControls(), sink: sink, clock: ManualSafetyClock())
        let controller = SubtitleAIController(
            api: SiloAI(v2: api),
            mediaFileId: { 42 },
            currentTime: { 0 },
            liveCoordinator: coordinator,
            handoffContext: { nil },
            registerAndSelectDescriptor: { _ in }
        )
        controller.transcribe(audioIndex: -1, translateTo: nil)
        for _ in 0..<1500 where controller.phase != .failed { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertFalse(controller.hasHeldRequest, "the job was accepted; nothing is held")
        XCTAssertEqual(stub.requests.filter { $0.method == "GET" }.count, AIJobPoller.maxConsecutiveFailures)
        XCTAssertEqual(postCount(), 1)
        XCTAssertEqual(coordinator.phase, .failed, "a poll-only presentation has nothing else to settle it")
        XCTAssertEqual(sink.restoreCount, 1)
    }

    /// A poller give-up leaves a streaming live track alone: the websocket's
    /// `completed` frame still hands off, selects the stored track and
    /// completes the job.
    @MainActor
    func testWebsocketCompletesAJobThePollerLostTrackOf() async throws {
        let live = try await liveJobThePollerGaveUpOn()
        XCTAssertEqual(live.controller.phase, .running)
        XCTAssertEqual(live.coordinator.phase, .streaming)
        XCTAssertEqual(live.sink.closedEarly, [])
        XCTAssertEqual(live.sink.restoreCount, 0)
        XCTAssertEqual(live.sink.failureNotices, [])

        live.controller.handle(.completed(.init(trackKey: "ai-77", subtitleId: 555, language: "es", label: "Spanish")))
        for _ in 0..<500 where live.selected.count == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(live.selected.count, 1, "the stored track was registered and selected")
        XCTAssertEqual(live.controller.phase, .completed)
        XCTAssertNil(live.controller.errorMessage)
        XCTAssertEqual(live.coordinator.phase, .completed)
        XCTAssertEqual(live.sink.closedAfterHandoff, ["ai-77"])
        XCTAssertEqual(live.sink.closedEarly, [])
        XCTAssertEqual(live.sink.restoreCount, 0)
        XCTAssertEqual(live.sink.failureNotices, [])
    }

    /// Once the poller gave up, losing the socket leaves nothing to settle
    /// the job, so it fails and the live track is closed.
    @MainActor
    func testSocketLossFailsAJobThePollerLostTrackOf() async throws {
        let live = try await liveJobThePollerGaveUpOn()
        live.controller.realtimeDidBecomeUnavailable()
        XCTAssertEqual(live.controller.phase, .failed)
        XCTAssertEqual(live.controller.errorMessage?.hasPrefix("Silo lost track of this subtitle job."), true)
        XCTAssertEqual(live.coordinator.phase, .failed)
        XCTAssertEqual(live.sink.closedEarly, ["ai-77"])
        XCTAssertEqual(live.sink.restoreCount, 1)
        XCTAssertEqual(live.selected.count, 0)
    }

    private struct LiveJob {
        let controller: SubtitleAIController
        let coordinator: LiveSubtitleCoordinator
        let sink: LiveSink
        let selected: SelectedDescriptors
    }

    /// Starts a live transcription whose websocket streams cues, then lets
    /// every job read fail until the poller gives up.
    @MainActor
    private func liveJobThePollerGaveUpOn() async throws -> LiveJob {
        let (api, _) = try await client()
        stub.sequence([.json(202, Self.receipt(Self.aiJob(kind: "transcribe", sourceIndex: -1), attached: true))])
        stub.fail(.networkConnectionLost)
        let sink = LiveSink()
        let selected = SelectedDescriptors()
        let coordinator = LiveSubtitleCoordinator(controls: LiveControls(), sink: sink, clock: ManualSafetyClock())
        let controller = SubtitleAIController(
            api: SiloAI(v2: api),
            mediaFileId: { 42 },
            currentTime: { 0 },
            sessionId: { "sess-1" },
            realtimeUnavailable: { false },
            liveCoordinator: coordinator,
            handoffContext: {
                SubtitleAIController.HandoffContext(
                    sessionId: "sess-1",
                    ordinals: DownloadedSubtitleOrdinals(published: [:], next: 3),
                    resolveURL: { URL(string: "https://subtitles.example\($0)") }
                )
            },
            registerAndSelectDescriptor: { _ in selected.count += 1 },
            downloadedSubtitlesFetch: { _ in
                [DownloadedSubtitle(id: "555", mediaFileId: 42, provider: "p", language: "es",
                                    format: "subrip", releaseName: "r")]
            }
        )
        sink.controller = controller

        controller.transcribe(audioIndex: -1, translateTo: nil)
        for _ in 0..<500 where controller.phase != .running { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .running)
        controller.handle(.started(.init(fileId: 42, jobId: nil, trackKey: "ai-77", language: "es",
                                         label: "Spanish", totalCues: 10)))
        controller.handle(.cues(.init(trackKey: "ai-77",
                                      cues: [PlaybackRealtimeSubtitleCue(start: 10, end: 12, text: "hi")],
                                      done: 1, total: 10)))
        XCTAssertEqual(coordinator.phase, .streaming)

        for _ in 0..<1500 where !controller.pollerLostTrackForTesting { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.pollerLostTrackForTesting)
        XCTAssertEqual(stub.requests.filter { $0.method == "GET" }.count, AIJobPoller.maxConsecutiveFailures)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(stub.requests.first?.body)) as? [String: Any])
        XCTAssertEqual(body["session_id"] as? String, "sess-1")
        return LiveJob(controller: controller, coordinator: coordinator, sink: sink, selected: selected)
    }

    @MainActor
    private final class SelectedDescriptors {
        var count = 0
    }

    @MainActor
    private final class LiveControls: LivePlaybackControls {
        var isPlaying = true
        func pause() { isPlaying = false }
        func play() { isPlaying = true }
    }

    /// Records what the coordinator did to the live track and routes the
    /// persisted handoff back to the controller, as the player's adapter does.
    @MainActor
    private final class LiveSink: LiveSubtitleSink {
        weak var controller: SubtitleAIController?
        var closedEarly: [String] = []
        var closedAfterHandoff: [String] = []
        var restoreCount = 0
        var failureNotices: [String] = []

        func installLiveTrack(trackKey: String, label: String?, language: String?) {}
        func feedCue(_ cue: PlaybackRealtimeSubtitleCue) {}
        func selectLive(trackKey: String) {}
        func closeLiveTrack(trackKey: String) { closedEarly.append(trackKey) }
        func closeLiveTrackAfterPersistedSelected(trackKey: String) { closedAfterHandoff.append(trackKey) }
        func restorePriorSelection(_ selection: Int64?) { restoreCount += 1 }
        func registerPersisted(subtitleId: Int) { controller?.completeLivePersistedHandoff(subtitleId: subtitleId) }
        func showPreparingNotice() {}
        func showFailureNotice(_ message: String) { failureNotices.append(message) }
    }

    /// Never fires the safety timeout, so the tests control the live phase.
    @MainActor
    private final class ManualSafetyClock: LiveSubtitleClock {
        private final class Handle: LiveSubtitleCancellable { func cancel() {} }
        func scheduleSafetyResume(after seconds: TimeInterval,
                                  _ action: @escaping @MainActor () -> Void) -> LiveSubtitleCancellable {
            Handle()
        }
    }

    // MARK: Stored subtitles

    func testStoredFixtureKeepsOpaqueIDAndRefusesDifferentFile() throws {
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self, from: fixture("subtitles_stored"))
        let subtitle = try XCTUnwrap(wire.subtitles.first)
        let player = try subtitle.playerValue(mediaFileID: 42)
        XCTAssertEqual(player.id, "7")
        XCTAssertEqual(player.mediaFileId, 42)
        XCTAssertEqual(player.streamURLExtension, ".vtt")
        assertInvalidSubtitleResponse(try subtitle.playerValue(mediaFileID: 43), "another file's subtitle")
    }

    /// IDs fail soft: opaque, leading-zero and oversized IDs all stay in the
    /// listing, in server order, because a row's position fixes its combined
    /// player index. Only a number where the contract says string fails.
    func testStoredListKeepsEveryOpaqueIDInServerOrder() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitles_stored")) as? [String: Any])
        let row = try XCTUnwrap((object["subtitles"] as? [[String: Any]])?.first)
        let ids = ["opaque-id", "7", "9223372036854775808", "07"]
        object["subtitles"] = ids.map { id -> [String: Any] in
            var other = row
            other["id"] = id
            return other
        }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try wire.playerValues(mediaFileID: 42).map(\.id), ids)

        var numeric = row
        numeric["id"] = 7
        object["subtitles"] = [numeric]
        assertDecodingFails(APIv2StoredSubtitles.self, from: try JSONSerialization.data(withJSONObject: object),
                            "a numeric id is not the wire contract")
    }

    /// Dropping a row would shift every later track's combined index, so a
    /// row for another file fails the whole listing.
    func testStoredListWithAnotherFilesRowIsRefused() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("subtitles_stored")) as? [String: Any])
        let row = try XCTUnwrap((object["subtitles"] as? [[String: Any]])?.first)
        var other = row
        other["id"] = "8"
        other["media_file_id"] = "43"
        object["subtitles"] = [row, other]
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2StoredSubtitles.self,
            from: JSONSerialization.data(withJSONObject: object))
        assertInvalidSubtitleResponse(try wire.playerValues(mediaFileID: 42), "a row for file 43")
    }

    func testStoredListReadsTheV2PathWithTheProfile() async throws {
        let (api, _) = try await client()
        stub.reply(200, String(decoding: try fixture("subtitles_stored"), as: UTF8.self))
        let rows = try await api.storedSubtitles(mediaFileID: 42)
        XCTAssertEqual(rows.map(\.id), ["7"])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/subtitles/42")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")

        stub.reset()
        do { _ = try await api.storedSubtitles(mediaFileID: 0); XCTFail("Listed file 0") }
        catch APIv2SubtitleRequestError.invalidMediaFile { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Provider status

    func testProviderStatusIsAvailableOnlyWhenAllowedAvailableAndEnabled() async throws {
        let (api, _) = try await client()
        let cases: [(String, Bool)] = [
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"available","allowed":true}"#, true),
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"available","allowed":false}"#, false),
            (#"{"schema_version":1,"enabled":false,"providers":[],"revision":"r","state":"not_configured","allowed":true}"#, false),
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"disabled","allowed":true}"#, false),
            (#"{"schema_version":1,"enabled":true,"providers":["opensubtitles"],"revision":"r","state":"future_state","allowed":true}"#, false),
        ]
        for (body, expected) in cases {
            stub.reply(200, body)
            let status = try await api.subtitleProviderStatus()
            XCTAssertEqual(status.isAvailable, expected, body)
        }
        XCTAssertEqual(Set(stub.requestedPaths), ["/api/v2/subtitles/providers/status"])

        // The contract requires `allowed`; the v1 shape is not an answer.
        stub.reply(200, #"{"schema_version":1,"enabled":true,"providers":[]}"#)
        do { _ = try await api.subtitleProviderStatus(); XCTFail("Decoded a status without allowed/state") }
        catch is DecodingError { }
    }

    /// A failed probe is not an answer: the store keeps its previous value
    /// and the next refresh asks again.
    @MainActor
    func testProviderStoreKeepsItsValueWhenTheProbeFails() async throws {
        let (api, _) = try await client()
        let store = SubtitleProvidersStore(api: SiloAI(v2: api))
        stub.reply(200, #"{"schema_version":1,"enabled":false,"providers":[],"revision":"r","state":"not_configured","allowed":true}"#)
        await store.refresh()
        XCTAssertFalse(store.isAvailable)
        stub.reply(503, Self.problem("service_unavailable", 503, "Down"))
        await store.refresh()
        XCTAssertFalse(store.isAvailable)
        stub.reply(200, #"{"schema_version":1,"enabled":true,"providers":["subdl"],"revision":"s","state":"available","allowed":true}"#)
        await store.refresh()
        XCTAssertTrue(store.isAvailable)
    }

    // MARK: Search and download

    func testSearchPostsTheV2BodyOnce() async throws {
        let (api, _) = try await client()
        stub.reply(200, String(decoding: try fixture("subtitles_search_partial"), as: UTF8.self))
        let response = try await api.searchSubtitles(SubtitleSearchBody(mediaFileId: 42, languages: ["en", "fr"]))
        XCTAssertEqual(response.results.map(\.id), ["opaque-result"])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/subtitles/search")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["media_file_id"] as? String, "42")
        XCTAssertEqual(body["languages"] as? [String], ["en", "fr"])
        XCTAssertEqual(body.count, 2)

        stub.reset()
        let tooMany = SubtitleSearchBody(mediaFileId: 42, languages: (0...100).map { "l\($0)" })
        do { _ = try await api.searchSubtitles(tooMany); XCTFail("Sent 101 languages") }
        catch APIv2SubtitleRequestError.tooManyLanguages { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testDownloadPostsTheContractBodyAndReturnsTheStoredRow() async throws {
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        stub.reply(200, Self.downloadResponse(id: "stored-9"))
        let row = try await api.downloadSubtitle(Self.downloadBody, auth: auth)
        XCTAssertEqual(row.id, "stored-9")
        XCTAssertEqual(row.mediaFileId, 42)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v2/subtitles/download")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["media_file_id", "provider", "subtitle_id", "language",
                                        "release_name", "score", "hearing_impaired"])
        XCTAssertEqual(body["media_file_id"] as? String, "42")
        XCTAssertEqual(body["subtitle_id"] as? String, "os-123")
    }

    /// `downloadSubtitle` is `non_retryable`: every failure leaves exactly one
    /// request, and only a refusal or an error answer is a definite failure.
    func testDownloadFailuresAreSentOnceAndSortedByOutcome() async throws {
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        let definite: [APIv2TestStub.Reply] = [
            .failure(URLError(.cannotConnectToHost)),
            .json(422, Self.problem("validation_failed", 422, "The provider result is not valid.")),
            .json(502, Self.problem("upstream_failed", 502, "The provider did not answer.")),
        ]
        let uncertain: [APIv2TestStub.Reply] = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)),
            .json(200, #"{"subtitle":"#),
            .json(201, Self.downloadResponse(id: "stored-9")),
        ]
        for (reply, expected) in definite.map({ ($0, false) }) + uncertain.map({ ($0, true) }) {
            stub.reset()
            stub.reply(reply)
            do {
                _ = try await api.downloadSubtitle(Self.downloadBody, auth: auth)
                XCTFail("Expected a failure for \(reply)")
            } catch {
                XCTAssertEqual(SubtitleDownloadOutcome.isUnconfirmed(error), expected, "\(error)")
            }
            XCTAssertEqual(stub.requests.count, 1, "download is never resent: \(reply)")
        }
    }

    func testDownloadForAReplacedOwnerIsRefusedOrUnconfirmed() async throws {
        // Replaced before the call: refused, nothing sent.
        let (api, tokens) = try await client()
        let auth = try await owner(tokens)
        await tokens.setProfileId("profile-two")
        do { _ = try await api.downloadSubtitle(Self.downloadBody, auth: auth); XCTFail("Sent for a replaced owner") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)

        // Replaced while in flight: the server may have stored it.
        stub.reset()
        let (inFlight, inFlightTokens) = try await client()
        let inFlightOwner = try await owner(inFlightTokens)
        stub.reply(200, Self.downloadResponse(id: "stored-9"))
        stub.hold()
        let task = Task { try await inFlight.downloadSubtitle(Self.downloadBody, auth: inFlightOwner) }
        await stub.waitUntilHeld()
        await inFlightTokens.setProfileToken("replacement")
        stub.release()
        do {
            _ = try await task.value
            XCTFail("A response for a replaced owner cannot publish")
        } catch {
            XCTAssertEqual(error as? APIv2SubtitleRequestError, .outcomeUnknownOwnerChanged)
            XCTAssertTrue(SubtitleDownloadOutcome.isUnconfirmed(error))
        }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testSearchUsesStringFileIDAndPreservesPartialResultWarning() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(APIv2SubtitleSearchBody(SubtitleSearchBody(mediaFileId: 42, languages: ["en"])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["media_file_id"] as? String, "42")
        XCTAssertEqual(object["languages"] as? [String], ["en"])
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSearchResponse.self,
            from: fixture("subtitles_search_partial")).playerValue
        XCTAssertEqual(response.results.first?.id, "opaque-result")
        XCTAssertNil(response.results.first?.uploadDate)
        XCTAssertEqual(response.warnings, ["One or more subtitle providers could not complete the search."])
        assertDecodingFails(APIv2SubtitleSearchResponse.self, from: Data(#"{"results":null,"warnings":[]}"#.utf8),
                            "results must be an array")
    }
}

private extension Data {
    func replacingEmptyJobKind() -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: #""kind": """#, with: #""kind": "translate""#).utf8)
    }
}
