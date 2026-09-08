import Foundation
import XCTest
@testable import Silo

@MainActor
final class APIv2PlaybackTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
    }

    func testFrozenWireFixturesKeepStringIDsAndNumericTracks() throws {
        let data = try fixtureData("playback_start_opaque_ids")
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: data)
        XCTAssertEqual(wire.playbackPlan?.effectiveMediaFileId, "42")
        XCTAssertEqual(wire.playbackPlan?.source.mediaFileId, "42")
        XCTAssertEqual(wire.playbackPlan?.selectedTracks.audio?.index, 0)
        let projected = try wire.legacy()
        XCTAssertEqual(projected.playbackPlan?.effectiveMediaFileId, 42)
        XCTAssertEqual(projected.playbackPlan?.stream.url, wire.playbackPlan?.stream.url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var plan = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        plan["effective_media_file_id"] = 42
        object["playback_plan"] = plan
        XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self,
            from: JSONSerialization.data(withJSONObject: object)))
        plan["effective_media_file_id"] = "opaque-future-file"
        object["playback_plan"] = plan
        let future = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try future.legacy())
        for name in ["playback_progress_applied", "playback_progress_stale"] {
            let receipt = try JSONDecoder().decode(PlaybackSequencedProgressReceipt.self, from: fixtureData(name))
            XCTAssertEqual(receipt.accepted?.sequence, 42)
        }
        for name in ["playback_stop_completed", "playback_stop_draining"] {
            let receipt = try JSONDecoder().decode(PlaybackSequencedStopReceipt.self, from: fixtureData(name))
            XCTAssertNotNil(receipt.historyId)
        }
        let available = try capability()
        XCTAssertFalse(try available.requireAvailable().isEmpty)
        let unavailable = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackCapabilities.self,
            from: fixtureData("playback_capability_unconfigured"))
        XCTAssertThrowsError(try unavailable.requireAvailable())
        for name in ["playback_installation_changed", "playback_invalid_protocol"] {
            let problem = try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: fixtureData(name))
            XCTAssertTrue([409, 422].contains(problem.status))
        }
    }

    private func capability() throws -> APIv2PlaybackCapabilities {
        try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackCapabilities.self,
            from: fixtureData("playback_capability_available"))
    }

    private func request(attempt: String = "apple:stable-attempt", authorizedOrigins: Bool = false) -> PlaybackV3StartRequest {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        return PlaybackV3StartRequest(protocolVersion: 3, clientFeatures: ApplePlaybackV3Capabilities.startFeatures(authorizedMediaOrigins: authorizedOrigins),
            fileId: 42, profileId: "profile", playbackAttemptId: attempt, qualityPreference: "auto",
            subtitleFidelityPreference: "preserve", progressPersistence: nil, startPosition: 12.5,
            audioTrackId: "file:42:audio:0", audioTrackIndex: 0, subtitleTrackId: nil, subtitleTrackIndex: nil,
            metered: false, bandwidthEstimateKbps: nil, bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context)
    }

    private func fixture(failWrites: Bool = false, observeJournal: (@Sendable (Data) -> Void)? = nil) async throws -> (PlaybackMutationCoordinator, TokenStore, CapturedDurableAccountAuth, SiloAPI, PlaybackMutationStore) {
        let name = "APIv2PlaybackTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let auth = try XCTUnwrap(captured)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [V2PlaybackProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens,
            v2: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let store = PlaybackMutationStore(url: root.appendingPathComponent("sessions.json"), write: { data, url in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
            observeJournal?(data)
        })
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"),
            decision: try fixtureData("playback_start_opaque_ids"))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: name)
            V2PlaybackProtocol.reset()
        }
        return (PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: []), tokens, auth, api, store)
    }

    private func boundContract(attempt: String = "audio:bound", digest: String = String(repeating: "a", count: 64)) throws -> (APIv2PlaybackCapabilities, APIv2ProgressTimeline, PlaybackV3StartRequest) {
        var caps = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData("playback_capability_available")) as? [String: Any])
        caps["features"] = (caps["features"] as? [String] ?? []) + [APIv2PlaybackManifest.feature]
        let capData = try JSONSerialization.data(withJSONObject: caps)
        let capability = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackCapabilities.self, from: capData)
        let binding = APIv2ProgressTimeline(timelineId: digest,
            mediaItemId: "book", fileId: "42", partOffsetSeconds: 60, partDurationSeconds: 30, durationSeconds: 90)
        var decision = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData("playback_start_opaque_ids")) as? [String: Any])
        decision["server_features"] = (decision["server_features"] as? [String] ?? []) + [APIv2PlaybackManifest.feature]
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        decision["progress_timeline"] = try JSONSerialization.jsonObject(with: encoder.encode(binding))
        V2PlaybackProtocol.configure(capability: capData, decision: try JSONSerialization.data(withJSONObject: decision))
        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        let start = PlaybackV3StartRequest(protocolVersion: 3,
            clientFeatures: ApplePlaybackV3Capabilities.audiobookFeatures + [APIv2PlaybackManifest.feature],
            fileId: 42, profileId: "profile", playbackAttemptId: attempt, qualityPreference: "auto",
            subtitleFidelityPreference: "preserve", progressPersistence: "client_bound", startPosition: 12,
            audioTrackId: nil, audioTrackIndex: nil, subtitleTrackId: nil, subtitleTrackIndex: nil,
            metered: false, bandwidthEstimateKbps: nil, bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context, timelineId: binding.timelineId)
        return (capability, binding, start)
    }

    private func timelineRefusal(retryable: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocol_version": 3,
            "server_features": [PlaybackProtocolV3.planFeature, PlaybackSequencedContract.feature],
            "outcome": "adaptation_unavailable", "terminal": ["reason": "client_timeline_changed",
                "message": "Timeline changed. Start a new playback request.", "retryable": retryable]])
    }

    func testMalformedTimelineTerminalCannotSettleOriginalAttempt() async throws {
        let (owner, _, auth, _, store) = try await fixture()
        let (capability, binding, start) = try boundContract()
        // A retryable mismatch is not the accepted retained refusal contract.
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"),
            decision: try timelineRefusal(retryable: true))
        do { _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding); XCTFail() } catch {}
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability.requireAvailable())
        let pending = try await store.pendingStarts(authority: authority)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotNil(pending.first?.response)
    }

    func testLostTimelineRefusalSettlesOnlyExactReplayThenAllowsNewExplicitManifest() async throws {
        let (owner, _, auth, _, store) = try await fixture()
        let (capability, binding, start) = try boundContract()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: try timelineRefusal())
        V2PlaybackProtocol.startFails(true)
        do { _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding); XCTFail() } catch {}
        V2PlaybackProtocol.startFails(false)
        let (_, nextBinding, next) = try boundContract(attempt: "audio:new-explicit", digest: String(repeating: "b", count: 64))
        do { _ = try await owner.startV2(request: next, auth: auth, capability: capability, progressTimeline: nextBinding); XCTFail() } catch {}
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: try timelineRefusal())
        await owner.retryPendingStops()
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability.requireAvailable())
        let pending = try await store.pendingStarts(authority: authority)
        XCTAssertTrue(pending.isEmpty)
        let replay = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
        XCTAssertEqual(replay.count, 2)
        XCTAssertEqual(replay[0].1, replay[1].1)
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod != "DELETE" && $0.0.url?.path.contains("/timelines/") != true })
        // Only this explicit caller obtains a new snapshot and creates a new attempt.
        _ = try boundContract(attempt: "audio:new-explicit", digest: String(repeating: "b", count: 64))
        let manifest = try await owner.discoverTimeline(fileID: 42, itemID: "book", auth: auth, capability: capability)
        XCTAssertEqual(manifest.timelineId, nextBinding.timelineId)
        let response = try await owner.startV2(request: next, auth: auth, capability: capability, progressTimeline: nextBinding)
        XCTAssertNotNil(response.sessionId ?? response.playbackPlan?.sessionId)
    }

    func testInterim409And503RemainUncertainWithoutFreshAttemptDispatch() async throws {
        let (owner, _, auth, _, store) = try await fixture()
        let (capability, binding, start) = try boundContract()
        for status in [409, 503] {
            var problem = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData("playback_installation_changed")) as? [String: Any])
            problem["status"] = status
            problem["code"] = "timeline_changed"
            V2PlaybackProtocol.rejectStart(try JSONSerialization.data(withJSONObject: problem), status: status)
            do { _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding); XCTFail() } catch {}
        }
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability.requireAvailable())
        let pending = try await store.pendingStarts(authority: authority)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.response)
        let (_, nextBinding, next) = try boundContract(attempt: "audio:must-not-dispatch")
        do { _ = try await owner.startV2(request: next, auth: auth, capability: capability, progressTimeline: nextBinding); XCTFail() } catch {}
        let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].1, starts[1].1)
    }

    func testBoundDiscoveryUsesInstallationAndCapturedProfile() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let (capability, binding, _) = try boundContract()
        let result = try await owner.discoverTimeline(fileID: 42, itemID: "book", auth: auth, capability: capability)
        XCTAssertEqual(result.timelineId, binding.timelineId)
        XCTAssertEqual(result.parts.map(\.fileId), [43.description, 42.description])
        let read = try XCTUnwrap(V2PlaybackProtocol.requests().first { $0.0.url?.path.contains("/timelines/") == true })
        XCTAssertEqual(read.0.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(read.0.url), resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "installation_id", value: try capability.requireAvailable())])
        XCTAssertEqual(read.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
    }

    func testBoundStartPersistsExactDigestAndStopMustTerminalizeBeforeNextAttempt() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let (capability, binding, start) = try boundContract()
        let response = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding)
        XCTAssertEqual(response.progressTimeline, binding)
        let id = try XCTUnwrap(response.sessionId ?? response.playbackPlan?.sessionId)
        V2PlaybackProtocol.stopStatus(202)
        let stopped = try await owner.stop(sessionID: id, position: nil, isPaused: true)
        XCTAssertFalse(stopped)
        do {
            _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding)
            XCTFail("Draining part must hold successor")
        } catch {}
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }.count, 1)
        V2PlaybackProtocol.stopStatus(200)
        let terminal = try await owner.stop(sessionID: id, position: 29, isPaused: false)
        XCTAssertTrue(terminal)
        let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: starts[0].1) as? [String: Any])
        XCTAssertEqual(body["progress_persistence"] as? String, "client_bound")
        XCTAssertEqual(body["timeline_id"] as? String, binding.timelineId)
        XCTAssertEqual(body["start_position"] as? Double, 12)
        let stops = V2PlaybackProtocol.requests().filter { $0.0.httpMethod == "DELETE" }
        XCTAssertEqual(stops[0].1, stops[1].1)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: stops[0].1) as? [String: Any])?["timeline_id"] as? String, binding.timelineId)
        XCTAssertFalse(V2PlaybackProtocol.requests().contains { $0.0.url?.path.contains("/api/v1") == true })
    }

    func testRestoredBoundSessionRequiresExplicitStopAndLiveOwnerIsNotRetired() async throws {
        let (owner, tokens, auth, api, store) = try await fixture()
        let (capability, binding, start) = try boundContract()
        _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding)
        await owner.restorePending()
        await owner.retryPendingStops()
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod != "DELETE" })
        let restored = PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: [])
        await restored.restorePending()
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod != "DELETE" })
        await restored.retryPendingStops()
        let stop = try XCTUnwrap(V2PlaybackProtocol.requests().first { $0.0.httpMethod == "DELETE" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stop.1) as? [String: Any])
        XCTAssertEqual(body["timeline_id"] as? String, binding.timelineId)
        XCTAssertNil(body["position"])
    }

    func testBoundStartMismatchRetainsExactUncertainIntentWithoutNewDispatch() async throws {
        let (owner, _, auth, _, store) = try await fixture()
        let (capability, binding, start) = try boundContract()
        let wrong = APIv2ProgressTimeline(timelineId: binding.timelineId, mediaItemId: "book", fileId: "42",
            partOffsetSeconds: 0, partDurationSeconds: 30, durationSeconds: 90)
        do { _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: wrong); XCTFail() } catch {}
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability.requireAvailable())
        let pending = try await store.pendingStarts(authority: authority)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.progressTimeline, wrong)
        do { _ = try await owner.startV2(request: start, auth: auth, capability: capability, progressTimeline: binding); XCTFail() } catch {}
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }.count, 1)
    }

    func testUncertainStartRestartBlocksNewAttemptAndExplicitRetryStopsWithoutAutoplay() async throws {
        let (owner, tokens, auth, api, store) = try await fixture()
        V2PlaybackProtocol.startFails(true)
        do { _ = try await owner.startV2(request: request(), auth: auth, capability: capability()); XCTFail() } catch {}
        do { try await owner.requireResolvedStartBeforeLegacy(auth: auth); XCTFail() }
        catch PlaybackSequencedError.pendingStart {} catch { XCTFail("\(error)") }
        let restarted = PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: [])
        await restarted.restorePending()
        do { _ = try await restarted.startV2(request: request(attempt: "different"), auth: auth, capability: capability()); XCTFail() }
        catch PlaybackSequencedError.pendingStart {} catch { XCTFail("\(error)") }
        V2PlaybackProtocol.startFails(false)
        V2PlaybackProtocol.stopStatus(202)
        await restarted.retryPendingStops()
        V2PlaybackProtocol.stopStatus(200)
        await restarted.retryPendingStops()
        let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path == "/api/v2/playback/start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].1, starts[1].1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: starts[0].1) as? [String: Any])
        XCTAssertEqual(body["file_id"] as? String, "42")
        XCTAssertEqual(body["audio_track_index"] as? Int, 0)
        XCTAssertEqual(body["installation_id"] as? String, try capability().requireAvailable())
        let stops = V2PlaybackProtocol.requests().filter { $0.0.httpMethod == "DELETE" }
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops.first?.1, stops.last?.1)
        let stop = try XCTUnwrap(JSONSerialization.jsonObject(with: stops[0].1) as? [String: Any])
        XCTAssertEqual(Set(stop.keys), ["stop_id", "installation_id"])
        XCTAssertEqual(starts[0].0.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
    }

    func testExplicitRetryCannotRetireAnInFlightPlayerStart() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let dispatched = expectation(description: "Start dispatched")
        let release = DispatchSemaphore(value: 0)
        V2PlaybackProtocol.beforeNextStart {
            dispatched.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        let capability = try capability()
        let request = request()
        let starting = Task { try await owner.startV2(request: request, auth: auth, capability: capability) }
        await fulfillment(of: [dispatched], timeout: 2)
        await owner.retryPendingStops()
        release.signal()
        _ = try await starting.value
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url?.path == "/api/v2/playback/start" }.count, 1)
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod != "DELETE" })
    }

    func testStaleRestoreSnapshotCannotRetireCompletedPlayerStart() async throws {
        let (_, tokens, auth, api, store) = try await fixture()
        let snapshotRead = expectation(description: "Unfinished snapshot read")
        let barrier = PlaybackRestoreBarrier()
        let owner = PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: [],
            pendingStarts: { authority in
                let snapshot = try await store.pendingStarts(authority: authority)
                snapshotRead.fulfill()
                await barrier.wait()
                return snapshot
            })
        V2PlaybackProtocol.startFails(true)
        do { _ = try await owner.startV2(request: request(), auth: auth, capability: capability()); XCTFail() } catch {}
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability().requireAvailable())
        let pending = try await store.pendingStarts(authority: authority)
        let id = try XCTUnwrap(pending.first?.id)
        let restoring = Task { await owner.restorePending() }
        await fulfillment(of: [snapshotRead], timeout: 2)
        V2PlaybackProtocol.startFails(false)
        _ = try await owner.startV2(request: request(), auth: auth, capability: capability())
        await barrier.release()
        await restoring.value
        XCTAssertFalse(PlaybackStopNotices.shared.pending.contains(id))
        let before = V2PlaybackProtocol.requests().count
        await owner.retryPendingStops()
        XCTAssertEqual(V2PlaybackProtocol.requests().count, before)
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod != "DELETE" })
    }

    func testStartPersistenceFailureSendsNoMutation() async throws {
        let (owner, _, auth, _, _) = try await fixture(failWrites: true)
        do { _ = try await owner.startV2(request: request(), auth: auth, capability: capability()); XCTFail() } catch {}
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod == "GET" })
    }

    func testValidationAfterUncertainDispatchRetainsAttemptUntilReplay() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        V2PlaybackProtocol.startFails(true)
        do { _ = try await owner.startV2(request: request(), auth: auth, capability: capability()); XCTFail() } catch {}
        V2PlaybackProtocol.startFails(false)
        V2PlaybackProtocol.rejectStart(try fixtureData("playback_invalid_protocol"))
        do { _ = try await owner.startV2(request: request(), auth: auth, capability: capability()); XCTFail() }
        catch APIv2Error.problem(let problem) { XCTAssertEqual(problem.status, 422) }
        catch { XCTFail("\(error)") }
        do { try await owner.requireResolvedStartBeforeLegacy(auth: auth); XCTFail() }
        catch PlaybackSequencedError.pendingStart {} catch { XCTFail("\(error)") }
        do { _ = try await owner.startV2(request: request(attempt: "different"), auth: auth, capability: capability()); XCTFail() }
        catch PlaybackSequencedError.pendingStart {} catch { XCTFail("\(error)") }
        V2PlaybackProtocol.rejectStart(nil)
        await owner.retryPendingStops()
        let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path == "/api/v2/playback/start" }
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(starts[0].1, starts[1].1)
        XCTAssertEqual(starts[1].1, starts[2].1)
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.httpMethod == "DELETE" }.count, 1)
        try await owner.requireResolvedStartBeforeLegacy(auth: auth)
    }

    func testUnconfiguredPlaybackStopsBeforeAnyStartTransport() async throws {
        let (owner, _, _, _, _) = try await fixture()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_unconfigured"),
            decision: try fixtureData("playback_start_opaque_ids"))
        do { _ = try await owner.captureStartAuth(); XCTFail("Unconfigured playback must not start") }
        catch let failure as PlaybackV3TerminalFailure {
            XCTAssertEqual(failure.reason, "playback_not_configured")
            XCTAssertTrue(failure.message.contains("not configured"))
        }
        XCTAssertTrue(V2PlaybackProtocol.requests().allSatisfy { $0.0.httpMethod == "GET" && $0.0.url!.path.hasPrefix("/api/v2/") })
    }

    func testTemporaryAuthCannotFabricateDurableV2Owner() async throws {
        let (owner, tokens, _, _, _) = try await fixture()
        await tokens.beginTemporaryScope(TemporaryAuthScope(serverId: "server", serverURL: "https://playback.example",
            accessToken: "temporary", refreshToken: "temporary-refresh", profileId: "profile", profileToken: "proof",
            controllerDeviceId: "controller", expiresAt: Date().addingTimeInterval(60)))
        do { _ = try await owner.captureStartAuth(); XCTFail() }
        catch PlaybackSequencedError.authorityChanged {} catch { XCTFail("\(error)") }
        XCTAssertFalse(V2PlaybackProtocol.requests().contains { $0.0.httpMethod == "POST" })
    }

    func testControlTicketBindsExactSessionInstallationAndCapturedAuthority() async throws {
        let (owner, tokens, auth, _, _) = try await fixture()
        let response = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let id = try XCTUnwrap(response.sessionId)
        let binding = try await owner.controlBinding(sessionID: id)
        let socket = try await owner.controlRequest(binding)
        XCTAssertEqual(socket.url?.absoluteString, "wss://playback.example/api/v2/playback/sessions/\(id)/control/ws")
        XCTAssertNil(socket.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(socket.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "silo.playback-control.v2, silo.ticket.single-use-proof")
        let sent = try XCTUnwrap(V2PlaybackProtocol.requests().last { $0.0.url!.path.hasSuffix("/ws-ticket") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.1) as? [String: String])
        XCTAssertEqual(body, ["installation_id": try capability().requireAvailable()])
        XCTAssertEqual(sent.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
        _ = await tokens.setProfileToken("different-proof")
        do { _ = try await owner.controlRequest(binding); XCTFail("Changed PIN authority must fence control") } catch {}
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url!.path.hasSuffix("/ws-ticket") }.count, 1)
    }

    func testSuspendedControlHandlerCannotSendResultAfterAuthorityChanges() async throws {
        for handlerRejects in [false, true] {
            let (owner, tokens, auth, _, _) = try await fixture()
            let response = try await owner.startV2(request: request(), auth: auth, capability: capability())
            let binding = try await owner.controlBinding(sessionID: XCTUnwrap(response.sessionId))
            let command = try JSONDecoder().decode(PlaybackRealtimeCommandEnvelope.self, from: Data(
                "{\"type\":\"command\",\"command_id\":\"one\",\"session_id\":\"\(binding.sessionID)\",\"name\":\"pause\"}".utf8))
            let entered = expectation(description: "handler suspended")
            var continuation: CheckedContinuation<Void, Never>?
            var frames: [PlaybackRealtimeResultEnvelope] = []
            let task = Task {
                try await PlaybackRealtimeClient.executeCommand(command, handler: { _ in
                    await withCheckedContinuation { continuation = $0; entered.fulfill() }
                    if handlerRejects { throw PlaybackRealtimeCommandExecutionError.commandFailed }
                }, validate: { try await owner.validateControlBinding(binding) },
                    sendResult: { frames.append($0) })
            }
            await fulfillment(of: [entered], timeout: 2)
            await tokens.setProfileId("another-profile")
            continuation?.resume()
            do { try await task.value; XCTFail("Owner rejection must propagate") } catch {}
            XCTAssertTrue(frames.isEmpty, "No completed or rejected result may leave the stale socket")
        }
    }

    private func headerMediaDecision(proxy: Bool = true, planID: String? = nil) throws -> (Data, String, String) {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData("playback_start_opaque_ids")) as? [String: Any])
        var plan = try XCTUnwrap(value["playback_plan"] as? [String: Any])
        let session = try XCTUnwrap(value["session_id"] as? String)
        var stream = try XCTUnwrap(plan["stream"] as? [String: Any])
        let raw = proxy ? "https://proxy.example/stream/v3/\(session)" : "/api/v2/stream/\(session)"
        stream["url"] = raw
        stream["headers"] = ["X-Profile-Id": "profile"]
        plan["stream"] = stream
        if let planID { plan["plan_id"] = planID }
        value["playback_plan"] = plan
        return (try JSONSerialization.data(withJSONObject: value), session, raw)
    }

    func testOriginalHeaderAuthIsEphemeralAndCannotBeRestoredOrRotated() async throws {
        for proxy in [false, true] {
            let writes = AuxiliaryJournalCapture()
            let (owner, tokens, auth, api, store) = try await fixture(observeJournal: writes.append)
            let (decision, id, raw) = try headerMediaDecision(proxy: proxy)
            V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
            _ = try await owner.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability())
            async let first = owner.streamRequest(sessionID: id, rawURL: raw,
                additionalHeaders: ["Authorization": "must-not-use", "X-Profile-Id": "wrong"],
                requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: proxy)
            async let second = owner.streamRequest(sessionID: id, rawURL: raw,
                additionalHeaders: [:], requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: proxy)
            let (media, concurrent) = try await (first, second)
            XCTAssertTrue(media.proxyAuxiliaryScope === concurrent.proxyAuxiliaryScope)
            XCTAssertEqual(media.headers, ["Authorization": "Bearer access", "X-Profile-Id": "profile"])
            XCTAssertNotNil(media.proxyAuxiliaryScope)
            XCTAssertFalse(writes.data.contains { String(decoding: $0, as: UTF8.self).contains("Bearer ") })
            let files = try writes.data.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            XCTAssertFalse(files.isEmpty)
            let journal = try JSONDecoder().decode(AuxiliaryJournalSnapshot.self, from: XCTUnwrap(writes.data.last))
            XCTAssertEqual(journal.starts?.values.first?.response, decision, "Retain exact server response bytes with selector only")
            let restarted = PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: [])
            await restarted.restorePending()
            do {
                _ = try await restarted.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                    requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: proxy)
                XCTFail("Persisted response cannot recreate original ephemeral credentials")
            } catch {}
            _ = await tokens.saveTokens(accessToken: "replacement", refreshToken: "replacement-refresh")
            do {
                _ = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                    requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: proxy)
                XCTFail("Old plan must not adopt rotated token")
            } catch {}
            media.proxyAuxiliaryScope?.invalidate()
        }
    }

    func testBridgeLostStartCannotAdoptReplacementTokenOrProof() async throws {
        for proof in [false, true] {
            V2PlaybackProtocol.reset()
            let (owner, tokens, auth, _, store) = try await fixture()
            let (decision, id, raw) = try headerMediaDecision()
            V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
            let refresh = await tokens.captureRefreshCredential(expected: auth.request.account)
            let capturedRefresh = try XCTUnwrap(refresh)
            V2PlaybackProtocol.loseNextStart {
                if proof { _ = await tokens.setProfileToken("replacement-proof") }
                else { _ = await tokens.saveRefreshedTokens("replacement", "replacement-refresh", replacing: capturedRefresh) }
            }
            do {
                _ = try await PlaybackSessionBridge.startV2WithNetworkRetry(coordinator: owner,
                    request: request(authorizedOrigins: true), auth: auth, capability: capability())
                XCTFail("Lost response retry adopted replacement authority")
            } catch {}
            do {
                _ = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                    requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
                XCTFail("Uncertain attempt gained usable media authority")
            } catch {}
            let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
            XCTAssertEqual(starts.count, 1, "Changed authority must not dispatch playback retry")
            let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability().requireAvailable())
            let pending = try await store.pendingStarts(authority: authority)
            XCTAssertEqual(pending.first?.body, starts.first?.1)
            XCTAssertNil(pending.first?.response)
            // Explicit recovery still resolves and retires the allocation.
            await owner.restorePending()
            await owner.retryPendingStops()
            let recovered = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
            XCTAssertEqual(recovered.count, 2)
            XCTAssertEqual(recovered.last?.1, starts.first?.1)
            XCTAssertTrue(V2PlaybackProtocol.requests().contains { $0.0.httpMethod == "DELETE" })
        }
    }

    func testResponseLessRestoreCannotRecreateOriginalMediaAuthority() async throws {
        let (owner, tokens, auth, api, store) = try await fixture()
        let (decision, id, raw) = try headerMediaDecision()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
        V2PlaybackProtocol.startFails(true)
        do { _ = try await owner.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability()); XCTFail() } catch {}
        let original = try XCTUnwrap(V2PlaybackProtocol.requests().first { $0.0.url?.path.hasSuffix("/start") == true })
        V2PlaybackProtocol.startFails(false)
        let restored = PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: [])
        await restored.restorePending()
        do { _ = try await restored.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability()); XCTFail("Restored intent adopted process credentials") } catch {}
        do {
            _ = try await restored.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
            XCTFail("Restored response-less intent gained media scope")
        } catch {}
        let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.last?.1, original.1)
        XCTAssertTrue(V2PlaybackProtocol.requests().contains { $0.0.httpMethod == "DELETE" }, "Resolved allocation must still retire")
    }

    func testBridgeLostStartWithUnchangedAuthorityRetainsExactAttempt() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let (decision, id, raw) = try headerMediaDecision()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
        V2PlaybackProtocol.loseNextStart {}
        _ = try await PlaybackSessionBridge.startV2WithNetworkRetry(coordinator: owner,
            request: request(authorizedOrigins: true), auth: auth, capability: capability())
        let starts = V2PlaybackProtocol.requests().filter { $0.0.url?.path.hasSuffix("/start") == true }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.first?.1, starts.last?.1)
        let media = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
            requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
        XCTAssertEqual(media.headers["Authorization"], "Bearer access")
        media.proxyAuxiliaryScope?.invalidate()
    }

    func testAPIOnlyAttemptCannotBePromotedByMediaCaller() async throws {
        for proxy in [false, true] {
            let (owner, _, auth, _, _) = try await fixture()
            let (decision, id, raw) = try headerMediaDecision(proxy: proxy)
            V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
            _ = try await owner.startV2(request: request(), auth: auth, capability: capability())
            do {
                _ = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                    requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
                XCTFail("Media caller cannot add origin negotiation to the original attempt")
            } catch {}
            if !proxy {
                let media = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                    requiresHeaderAuthenticatedMedia: true)
                XCTAssertEqual(media.headers["X-Profile-Id"], "profile")
                XCTAssertEqual(media.url.host, "playback.example")
                media.proxyAuxiliaryScope?.invalidate()
            }
        }
    }

    func testMismatchedPublishedProfileSelectorCannotAdoptMediaAuthority() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let (decision, id, raw) = try headerMediaDecision()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: decision) as? [String: Any])
        var plan = try XCTUnwrap(value["playback_plan"] as? [String: Any])
        var stream = try XCTUnwrap(plan["stream"] as? [String: Any])
        stream["headers"] = ["x-profile-id": "another-profile"]
        plan["stream"] = stream
        value["playback_plan"] = plan
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"),
            decision: try JSONSerialization.data(withJSONObject: value))
        do {
            _ = try await owner.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability())
            XCTFail("Published selector cannot override captured recipe authority")
        } catch {}
        do {
            _ = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
            XCTFail("Rejected selector must not leave usable media authority")
        } catch {}
    }

    func testActualReplanAndStopInvalidateOldMediaScope() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let (decision, id, raw) = try headerMediaDecision()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
        _ = try await owner.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability())
        let first = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
            requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
        let (next, _, _) = try headerMediaDecision(planID: "replacement-plan")
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: next)
        _ = try await owner.replan(sessionID: id, request: replanRequest())
        do { try await first.proxyAuxiliaryScope?.requireCurrent(); XCTFail("Old plan remains active") } catch {}
        let second = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
            requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
        XCTAssertEqual(second.proxyAuxiliaryScope?.planID, "replacement-plan")
        _ = try await owner.stop(sessionID: id, position: nil, isPaused: true)
        do { try await second.proxyAuxiliaryScope?.requireCurrent(); XCTFail("Stopped plan remains active") } catch {}
    }

    func testConcurrentStopCannotBeUndoneByLateReplanAdoption() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let (decision, id, raw) = try headerMediaDecision()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
        _ = try await owner.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability())
        let media = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
            requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
        let received = expectation(description: "replan response held")
        let gate = PlaybackRestoreBarrier()
        V2PlaybackProtocol.afterNextResponse { received.fulfill(); await gate.wait() }
        let request = try replanRequest()
        let replanning = Task { try await owner.replan(sessionID: id, request: request) }
        await fulfillment(of: [received], timeout: 2)
        _ = try await owner.stop(sessionID: id, position: nil, isPaused: true)
        await gate.release()
        do { _ = try await replanning.value; XCTFail("Late replan adopted after stop") } catch {}
        do { try await media.proxyAuxiliaryScope?.requireCurrent(); XCTFail("Stopped scope remains valid") } catch {}
        do {
            _ = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
            XCTFail("Stopped session regained media authority")
        } catch {}
    }

    func testIdentitySwitchBeforeStartResponseCannotAdoptHeaderMedia() async throws {
        let (owner, tokens, auth, _, _) = try await fixture()
        let (decision, id, raw) = try headerMediaDecision()
        V2PlaybackProtocol.configure(capability: try fixtureData("playback_capability_available"), decision: decision)
        V2PlaybackProtocol.afterNextResponse { await tokens.setProfileId("replacement") }
        do { _ = try await owner.startV2(request: request(authorizedOrigins: true), auth: auth, capability: capability()); XCTFail() } catch {}
        do {
            _ = try await owner.streamRequest(sessionID: id, rawURL: raw, additionalHeaders: [:],
                requiresHeaderAuthenticatedMedia: true, allowsAuthorizedMediaOrigins: true)
            XCTFail("Foreign response adopted")
        } catch {}
    }

    func testMediaResolutionUsesSessionAuthorityAndRejectsAccountSwitch() async throws {
        let (owner, tokens, auth, _, _) = try await fixture()
        let response = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let id = try XCTUnwrap(response.sessionId)
        let raw = "/api/v2/stream/\(id)?st=opaque-proof"
        let media = try await owner.streamRequest(sessionID: id, rawURL: raw,
            additionalHeaders: [:], requiresHeaderAuthenticatedMedia: true)
        XCTAssertEqual(media.url.host, "playback.example")
        try await tokens.installAccountSession(accessToken: "other", refreshToken: "other", accountID: "2")
        await tokens.setProfileId("profile")
        do {
            _ = try await owner.streamRequest(sessionID: id, rawURL: raw,
                additionalHeaders: [:], requiresHeaderAuthenticatedMedia: true)
            XCTFail("A later account must not resolve the previous session's stream")
        } catch PlaybackSequencedError.authorityChanged {} catch { XCTFail("\(error)") }
    }

    func testRejectedControlTicketDoesNotRefreshReplayOrUseV1() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let response = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let binding = try await owner.controlBinding(sessionID: XCTUnwrap(response.sessionId))
        V2PlaybackProtocol.controlStatus(401)
        do { _ = try await owner.controlRequest(binding); XCTFail() } catch {}
        let requests = V2PlaybackProtocol.requests()
        XCTAssertEqual(requests.filter { $0.0.url!.path.hasSuffix("/ws-ticket") }.count, 1)
        XCTAssertFalse(requests.contains { $0.0.url!.path.contains("/api/v1/") || $0.0.url!.path.hasSuffix("/auth/refresh") })
    }

    func testControlTicketRejectsProtocolInjectionAndForeignAuthorityURL() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        for ticket in ["bad,header", "bad\r\nheader", ""] {
            XCTAssertThrowsError(try APIv2PlaybackControlTicket(ticket: ticket, expiresIn: 30,
                maxConnectionSeconds: 60, protocol: "silo.playback-control.v2").request(serverURL: "https://playback.example", sessionID: id))
        }
        let ticket = APIv2PlaybackControlTicket(ticket: "proof", expiresIn: 30, maxConnectionSeconds: 60, protocol: "silo.playback-control.v2")
        XCTAssertThrowsError(try ticket.request(serverURL: "https://user@playback.example", sessionID: id))
        XCTAssertThrowsError(try ticket.request(serverURL: "https://playback.example", sessionID: "../other"))
        XCTAssertEqual(try ticket.request(serverURL: "https://playback.example/base/", sessionID: id).url?.path,
            "/base/api/v2/playback/sessions/\(id)/control/ws")
    }

    private func replanRequest(id: String = "apple-replan:one", operation: String = "seek_reanchor") throws -> PlaybackV3ReplanRequest {
        let start = request()
        let decision = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: fixtureData("playback_start_opaque_ids"))
        let plan = try XCTUnwrap(decision.playbackPlan)
        return PlaybackV3ReplanRequest(protocolVersion: 3, clientFeatures: [], operation: operation,
            playbackAttemptId: start.playbackAttemptId, replanRequestId: id,
            failedPlanId: plan.planId, planAttemptId: "apple-plan:one", planAttemptKey: plan.planAttemptKey,
            attemptedPlanKeys: [plan.planAttemptKey], attemptCount: 1, qualityPreference: "auto", positionSeconds: 120,
            metered: false, bandwidthEstimateKbps: nil, bandwidthCapKbps: nil, selectedTracks: plan.selectedTracks,
            failure: nil, localMutations: [], clientCapabilities: start.clientCapabilities,
            clientPlaybackContext: start.clientPlaybackContext)
    }

    func testReplanUsesV2AndPreservesServerPlanAndClientAttemptIdentities() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let started = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let id = try XCTUnwrap(started.sessionId)
        let input = try replanRequest()
        _ = try await owner.replan(sessionID: id, request: input)
        let sent = try XCTUnwrap(V2PlaybackProtocol.requests().last { $0.0.url!.path.hasSuffix("/replan") })
        XCTAssertEqual(sent.0.url!.path, "/api/v2/playback/\(id)/replan")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.1) as? [String: Any])
        XCTAssertEqual(body["installation_id"] as? String, try capability().requireAvailable())
        XCTAssertEqual(body["replan_request_id"] as? String, input.replanRequestId)
        XCTAssertEqual(body["playback_attempt_id"] as? String, input.playbackAttemptId)
        XCTAssertEqual(body["plan_attempt_key"] as? String, input.planAttemptKey)
        do { _ = try await owner.replan(sessionID: id, request: replanRequest(operation: "quality_change")); XCTFail() }
        catch let failure as PlaybackV3TerminalFailure { XCTAssertEqual(failure.reason, "capability_unsupported") }
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url!.path.hasSuffix("/replan") }.count, 1)
    }

    func testUncertainReplanCannotReplayOrRebaseAfterCoordinatorRestart() async throws {
        let (owner, tokens, auth, api, store) = try await fixture()
        let started = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let id = try XCTUnwrap(started.sessionId)
        V2PlaybackProtocol.failProgress(true)
        do { _ = try await owner.replan(sessionID: id, request: replanRequest()); XCTFail() } catch {}
        V2PlaybackProtocol.failProgress(false)
        let restarted = PlaybackMutationCoordinator(api: api, tokens: tokens, store: store, retryDelays: [])
        try await restarted.register(sessionID: id, features: [PlaybackSequencedContract.feature], auth: auth,
            installationID: capability().requireAvailable(), attemptID: request().playbackAttemptId)
        do { _ = try await restarted.replan(sessionID: id, request: replanRequest(id: "apple-replan:different")); XCTFail() }
        catch let failure as PlaybackV3TerminalFailure { XCTAssertEqual(failure.reason, "replan_pending") }
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url!.path.hasSuffix("/replan") }.count, 1)
    }

    func testRouteEventIsOneV2DispatchWithMatchingReceipt() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let started = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let event = PlaybackV3RouteEvent(protocolVersion: 3, playbackAttemptId: request().playbackAttemptId,
            sessionId: started.sessionId, planId: nil, planAttemptId: nil, planAttemptKey: nil, event: "first_frame",
            failureClassification: nil, fallbackReason: nil, appliedQuirkIds: [], quirkRegistryRevision: nil,
            outputContextId: nil, diagnostics: [:])
        try await owner.reportRouteEvent(event)
        let sent = try XCTUnwrap(V2PlaybackProtocol.requests().last { $0.0.url!.path.hasSuffix("/route-events") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.1) as? [String: Any])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body["event_id"] as? String)))
        XCTAssertEqual(body["installation_id"] as? String, try capability().requireAvailable())
        V2PlaybackProtocol.failProgress(true)
        do { try await owner.reportRouteEvent(event); XCTFail() } catch {}
        XCTAssertEqual(V2PlaybackProtocol.requests().filter { $0.0.url!.path.hasSuffix("/route-events") }.count, 2)
        XCTAssertFalse(V2PlaybackProtocol.requests().contains { $0.0.url!.path.contains("/api/v1/") })
    }

    func testWatchStateProjectionKeepsStringIDsDurationAndMarkers() async throws {
        let (_, _, auth, api, _) = try await fixture()
        let watch = try await api.v2.watchDetail(id: "movie:fixture", imageSize: "small", auth: auth.request)
        XCTAssertEqual(watch.versions.first?.fileId, 42)
        XCTAssertEqual(watch.versions.first?.duration, 10200)
        XCTAssertEqual(watch.versions.first?.intro?.end, 90)
        XCTAssertEqual(watch.credits?.start, 10000)
        XCTAssertEqual(watch.userData?.lastFileId, 42)
        let sent = try XCTUnwrap(V2PlaybackProtocol.requests().last)
        XCTAssertEqual(sent.0.url?.path, "/api/v2/watch/movie:fixture")
        XCTAssertEqual(sent.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile")
    }

    func testV2ProgressCarriesInstallationAndRetainsExactUncertainSample() async throws {
        let (owner, _, auth, _, _) = try await fixture()
        let response = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let id = try XCTUnwrap(response.sessionId)
        V2PlaybackProtocol.failProgress(true)
        do { try await owner.report(sessionID: id, position: 120, isPaused: false); XCTFail() } catch {}
        V2PlaybackProtocol.failProgress(false)
        try await owner.report(sessionID: id, position: 30, isPaused: true)
        try await owner.report(sessionID: id, position: 30, isPaused: true)
        let progress = V2PlaybackProtocol.requests().filter { $0.0.url!.path.hasSuffix("/progress") }
        XCTAssertEqual(progress.count, 3)
        XCTAssertEqual(progress[0].1, progress[1].1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: progress[2].1) as? [String: Any])
        XCTAssertEqual(body["sequence"] as? Int, 2)
        XCTAssertEqual(body["position"] as? Double, 30)
        XCTAssertEqual(body["installation_id"] as? String, try capability().requireAvailable())
    }

    func testInstallationAndEpochChangesCannotDispatchPendingMutations() async throws {
        let (owner, tokens, auth, _, _) = try await fixture()
        let response = try await owner.startV2(request: request(), auth: auth, capability: capability())
        let id = try XCTUnwrap(response.sessionId)
        V2PlaybackProtocol.changeInstallation()
        do { try await owner.report(sessionID: id, position: 1, isPaused: false); XCTFail() } catch {}
        XCTAssertFalse(V2PlaybackProtocol.requests().contains { $0.0.url?.path.hasSuffix("/progress") == true })
        try await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let stopped = try await owner.stop(sessionID: id, position: 2, isPaused: true)
        XCTAssertFalse(stopped)
        XCTAssertFalse(V2PlaybackProtocol.requests().contains { $0.0.httpMethod == "DELETE" })
    }
}

private final class V2PlaybackProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseHook: (@Sendable () async -> Void)?
    static func afterNextResponse(_ hook: @escaping @Sendable () async -> Void) { lock.withLock { responseHook = hook } }
    nonisolated(unsafe) private static var capability = Data()
    nonisolated(unsafe) private static var decision = Data()
    nonisolated(unsafe) private static var startHook: (@Sendable () -> Void)?
    static func beforeNextStart(_ hook: @escaping @Sendable () -> Void) { lock.withLock { startHook = hook } }
    nonisolated(unsafe) private static var lostStartHook: (@Sendable () async -> Void)?
    static func loseNextStart(_ hook: @escaping @Sendable () async -> Void) { lock.withLock { lostStartHook = hook } }
    nonisolated(unsafe) private static var failStart = false
    nonisolated(unsafe) private static var rejection: Data?
    nonisolated(unsafe) private static var rejectionCode = 422
    nonisolated(unsafe) private static var progressFailure = false
    nonisolated(unsafe) private static var stopCode = 200
    nonisolated(unsafe) private static var controlCode = 200
    static func controlStatus(_ value: Int) { lock.withLock { controlCode = value } }
    nonisolated(unsafe) private static var captured: [(URLRequest, Data)] = []
    static func configure(capability: Data, decision: Data) { lock.withLock { Self.capability = capability; Self.decision = decision } }
    static func rejectStart(_ value: Data?, status: Int = 422) { lock.withLock { rejection = value; rejectionCode = status } }
    static func failProgress(_ value: Bool) { lock.withLock { progressFailure = value } }
    static func startFails(_ value: Bool) { lock.withLock { failStart = value } }
    static func stopStatus(_ value: Int) { lock.withLock { stopCode = value } }
    static func requests() -> [(URLRequest, Data)] { lock.withLock { captured } }
    static func reset() { lock.withLock { captured = []; lostStartHook = nil; startHook = nil; responseHook = nil; failStart = false; stopCode = 200; controlCode = 200; rejection = nil; rejectionCode = 422; progressFailure = false } }
    static func changeInstallation() { lock.withLock {
        var value = try! JSONSerialization.jsonObject(with: capability) as! [String: Any]
        value["installation_id"] = "different-installation"
        capability = try! JSONSerialization.data(withJSONObject: value)
    } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let state = Self.lock.withLock { Self.captured.append((request, body)); return (Self.capability, Self.decision, Self.failStart, Self.stopCode, Self.rejection, Self.progressFailure, Self.rejectionCode) }
        var status = 200
        let output: Data
        if request.url!.path.hasPrefix("/api/v2/watch/") {
            output = Data(#"{"content_id":"movie:fixture","type":"movie","title":"Fixture","versions":[{"file_id":"42","resolution":"1080p","codec_video":"h264","codec_audio":"aac","hdr":false,"container":"mkv","file_size":1024,"duration_seconds":10200,"bitrate":8000000,"added_at":"2026-01-02T03:04:05.000Z","intro":{"start_seconds":0,"end_seconds":90}}],"subtitles":[],"credits":{"start_seconds":10000,"end_seconds":10200},"user_data":{"position_seconds":1325.5,"duration_seconds":10200,"watched_count":0,"unplayed_count":0,"in_progress_count":1,"played":false,"last_file_id":"42"}}"#.utf8)
        } else if request.url!.path.hasSuffix("/control/capabilities") {
            output = Data(#"{"available":true,"protocol":"silo.playback-control.v2","owner_lease_admission":true}"#.utf8)
        } else if request.url!.path.hasSuffix("/ws-ticket") {
            status = Self.lock.withLock { Self.controlCode }
            output = Data(#"{"ticket":"single-use-proof","expires_in":30,"max_connection_seconds":14400,"protocol":"silo.playback-control.v2"}"#.utf8)
        } else if request.url!.path.hasSuffix("/replan") {
            if state.5 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            output = state.1
        } else if request.url!.path.hasSuffix("/route-events") {
            if state.5 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            let input = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            status = 202
            output = try! JSONSerialization.data(withJSONObject: ["event_id": input["event_id"]!, "outcome": "accepted"])
        } else if request.url!.path.contains("/timelines/") {
            let caps = try! JSONSerialization.jsonObject(with: state.0) as! [String: Any]
            let decision = (try? JSONSerialization.jsonObject(with: state.1)) as? [String: Any]
            let digest = (decision?["progress_timeline"] as? [String: Any])?["timeline_id"] as? String ?? String(repeating: "a", count: 64)
            output = try! JSONSerialization.data(withJSONObject: ["installation_id": caps["installation_id"]!,
                "timeline_id": digest, "media_item_id": "book", "edition_id": "edition",
                "duration_seconds": 90, "parts": [["file_id": "43", "offset_seconds": 0, "duration_seconds": 60],
                    ["file_id": "42", "offset_seconds": 60, "duration_seconds": 30]]])
        } else if request.url!.path.hasSuffix("/capabilities") { output = state.0 }
        else if request.url!.path.hasSuffix("/start") {
            let hook = Self.lock.withLock { let hook = Self.startHook; Self.startHook = nil; return hook }
            hook?()
            if let lost = Self.lock.withLock({ let hook = Self.lostStartHook; Self.lostStartHook = nil; return hook }) {
                Task { await lost(); client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
                return
            }
            if state.2 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            status = state.4 == nil ? 201 : state.6; output = state.4 ?? state.1
        } else {
            if state.5 && request.httpMethod == "POST" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            let input = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if request.httpMethod == "DELETE" {
                status = state.3
                output = try! JSONSerialization.data(withJSONObject: ["outcome": status == 202 ? "draining" : "stopped", "stop_id": input["stop_id"] ?? ""])
            } else { output = try! JSONSerialization.data(withJSONObject: ["outcome": "applied", "accepted": input]) }
        }
        let hook = Self.lock.withLock { let hook = Self.responseHook; Self.responseHook = nil; return hook }
        let responseStatus = status
        Task {
            await hook?()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: responseStatus,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: output)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private actor PlaybackRestoreBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class AuxiliaryJournalCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    var data: [Data] { lock.withLock { values } }
    func append(_ data: Data) { lock.withLock { values.append(data) } }
}

private struct AuxiliaryJournalSnapshot: Decodable {
    let starts: [UUID: StoredPlaybackStart]?
}
