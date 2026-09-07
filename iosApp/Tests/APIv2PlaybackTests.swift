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

    private func request(attempt: String = "apple:stable-attempt") -> PlaybackV3StartRequest {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        return PlaybackV3StartRequest(protocolVersion: 3, clientFeatures: ApplePlaybackV3Capabilities.features,
            fileId: 42, profileId: "profile", playbackAttemptId: attempt, qualityPreference: "auto",
            subtitleFidelityPreference: "preserve", progressPersistence: nil, startPosition: 12.5,
            audioTrackId: "file:42:audio:0", audioTrackIndex: 0, subtitleTrackId: nil, subtitleTrackIndex: nil,
            metered: false, bandwidthEstimateKbps: nil, bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities, clientPlaybackContext: snapshot.context)
    }

    private func fixture(failWrites: Bool = false) async throws -> (PlaybackMutationCoordinator, TokenStore, CapturedDurableAccountAuth, SiloAPI, PlaybackMutationStore) {
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
    nonisolated(unsafe) private static var capability = Data()
    nonisolated(unsafe) private static var decision = Data()
    nonisolated(unsafe) private static var startHook: (@Sendable () -> Void)?
    static func beforeNextStart(_ hook: @escaping @Sendable () -> Void) { lock.withLock { startHook = hook } }
    nonisolated(unsafe) private static var failStart = false
    nonisolated(unsafe) private static var rejection: Data?
    nonisolated(unsafe) private static var progressFailure = false
    nonisolated(unsafe) private static var stopCode = 200
    nonisolated(unsafe) private static var captured: [(URLRequest, Data)] = []
    static func configure(capability: Data, decision: Data) { lock.withLock { Self.capability = capability; Self.decision = decision } }
    static func rejectStart(_ value: Data?) { lock.withLock { rejection = value } }
    static func failProgress(_ value: Bool) { lock.withLock { progressFailure = value } }
    static func startFails(_ value: Bool) { lock.withLock { failStart = value } }
    static func stopStatus(_ value: Int) { lock.withLock { stopCode = value } }
    static func requests() -> [(URLRequest, Data)] { lock.withLock { captured } }
    static func reset() { lock.withLock { captured = []; startHook = nil; failStart = false; stopCode = 200; rejection = nil; progressFailure = false } }
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
        let state = Self.lock.withLock { Self.captured.append((request, body)); return (Self.capability, Self.decision, Self.failStart, Self.stopCode, Self.rejection, Self.progressFailure) }
        var status = 200
        let output: Data
        if request.url!.path.hasSuffix("/capabilities") { output = state.0 }
        else if request.url!.path.hasSuffix("/start") {
            let hook = Self.lock.withLock { let hook = Self.startHook; Self.startHook = nil; return hook }
            hook?()
            if state.2 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            status = state.4 == nil ? 201 : 422; output = state.4 ?? state.1
        } else {
            if state.5 && request.httpMethod == "POST" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            let input = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if request.httpMethod == "DELETE" {
                status = state.3
                output = try! JSONSerialization.data(withJSONObject: ["outcome": status == 202 ? "draining" : "stopped", "stop_id": input["stop_id"] ?? ""])
            } else { output = try! JSONSerialization.data(withJSONObject: ["outcome": "applied", "accepted": input]) }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: output)
        client?.urlProtocolDidFinishLoading(self)
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
