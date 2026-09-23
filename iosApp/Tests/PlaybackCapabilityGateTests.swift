import Foundation
import XCTest
@testable import Silo

/// `PlaybackV3CapabilityGate` over `GET /api/v2/playback/capabilities`: the
/// contract it requires, what it caches, and the one refresh a start gets
/// when the server's playback installation changed.
final class PlaybackCapabilityGateTests: XCTestCase {
    private typealias Support = APIv2FixtureTestSupport

    private let installationA = "11111111-1111-4111-8111-111111111111"
    private let installationB = "22222222-2222-4222-8222-222222222222"
    private let path = "/api/v2/playback/capabilities"

    /// The vendored fixture plus the header-authenticated media feature the
    /// server always advertises (`ServerFeaturesV3`), with `installation`.
    private func available(installation: String? = nil, dropping feature: String? = nil) throws -> String {
        let data = try Support.mutatedBody(named: "playback_capability_available", bundleClass: Self.self) {
            var features = $0["features"] as? [String] ?? []
            features.append(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
            $0["features"] = features.filter { $0 != feature }
            if let installation { $0["installation_id"] = installation }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func fixtureString(_ name: String) throws -> String {
        String(decoding: try Support.data(named: name, bundleClass: Self.self), as: UTF8.self)
    }

    private func makeGate(
        fetch: (@Sendable (CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackCapabilities)? = nil
    ) async throws -> (PlaybackV3CapabilityGate, APIv2TestStub) {
        let name = "PlaybackCapabilityGateTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        await tokens.setProfileId("profile-one")
        let stub = APIv2TestStub()
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let gate = PlaybackV3CapabilityGate(tokenStore: tokens, fetch: fetch ?? { try await api.playbackCapabilities(auth: $0) })
        return (gate, stub)
    }

    private func assertTerminal(_ reason: String, _ operation: () async throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("expected terminal \(reason)", file: file, line: line)
        } catch let failure as PlaybackV3TerminalFailure {
            XCTAssertEqual(failure.reason, reason, file: file, line: line)
            XCTAssertFalse(failure.retryable, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Contract

    func testAvailableCapabilityYieldsItsInstallationOnlyWithTheWholeContract() async throws {
        let decoder = Support.decoder
        let full = try decoder.decode(APIv2PlaybackCapabilities.self, from: Data(try available().utf8))
        XCTAssertEqual(try full.requireAvailable(), installationA)

        for feature in [PlaybackProtocolV3.planFeature, PlaybackProtocolV3.neutralContractFeature,
                        PlaybackProtocolV3.headerAuthenticatedMediaFeature, PlaybackSequencedContract.feature] {
            let partial = try decoder.decode(APIv2PlaybackCapabilities.self,
                from: Data(try available(dropping: feature).utf8))
            await assertTerminal("server_upgrade_required") { _ = try partial.requireAvailable() }
        }

        let unconfigured = try Support.decode(APIv2PlaybackCapabilities.self,
            named: "playback_capability_unconfigured", bundleClass: Self.self)
        await assertTerminal("playback_not_configured") { _ = try unconfigured.requireAvailable() }

        let anonymous = try decoder.decode(APIv2PlaybackCapabilities.self, from: Support.mutatedBody(
            named: "playback_capability_available", bundleClass: Self.self) {
                $0["features"] = ($0["features"] as? [String] ?? []) + [PlaybackProtocolV3.headerAuthenticatedMediaFeature]
                $0.removeValue(forKey: "installation_id")
            })
        await assertTerminal("playback_not_configured") { _ = try anonymous.requireAvailable() }
    }

    // MARK: Caching

    func testGateCachesOnlyAnAvailableCapability() async throws {
        let (gate, stub) = try await makeGate()
        stub.sequence([.json(200, try fixtureString("playback_capability_unconfigured")),
                       .json(200, try available())])

        await assertTerminal("playback_not_configured") { try await gate.requireNeutralProtocolV3() }
        let first = try await gate.requireNeutralProtocolV3()
        let second = try await gate.requireNeutralProtocolV3()

        XCTAssertEqual(first.installationID, installationA)
        XCTAssertEqual(second, first)
        XCTAssertEqual(stub.requestedPaths, [path, path], "a refusal is re-probed; availability is not")
        XCTAssertEqual(stub.methods, ["GET", "GET"])
        XCTAssertEqual(stub.requests.last?.headers["x-profile-id"], "profile-one")
    }

    func testGateMapsServerRefusalsToTerminalFailures() async throws {
        let (gate, stub) = try await makeGate()
        stub.sequence([
            .json(409, #"{"type":"https://siloserver.org/docs/api/v2/problems/capability_not_configured","title":"Conflict","status":409,"detail":"Playback installation identity is not configured"}"#),
            .text(404, "404 page not found\n", contentType: "text/plain; charset=utf-8"),
        ])

        await assertTerminal("playback_not_configured") { try await gate.requireNeutralProtocolV3() }
        do {
            try await gate.requireNeutralProtocolV3()
            XCTFail("a v1-only server cannot start v2 playback")
        } catch let failure as PlaybackV3TerminalFailure {
            XCTAssertEqual(failure.reason, "server_upgrade_required")
            XCTAssertEqual(failure.message, UpdateRequirement.serverMessage)
        }
    }

    // MARK: installation_changed

    func testInstallationChangedRefetchesAndRunsTheStartOnceMore() async throws {
        let (gate, stub) = try await makeGate()
        stub.sequence([.json(200, try available(installation: installationA)),
                       .json(200, try available(installation: installationB))])
        let changed = try Support.decode(APIv2Problem.self, named: "playback_installation_changed", bundleClass: Self.self)

        var attempts: [String] = []
        let started = try await gate.withInstallationRefresh { capability -> String in
            attempts.append(capability.installationID)
            if attempts.count == 1 { throw APIv2Error.problem(changed) }
            return capability.installationID
        }

        XCTAssertEqual(attempts, [installationA, installationB])
        XCTAssertEqual(started, installationB)
        XCTAssertEqual(stub.requestedPaths, [path, path])
        let cached = try await gate.requireNeutralProtocolV3()
        XCTAssertEqual(cached.installationID, installationB, "the refreshed capability replaces the stale one")
        XCTAssertEqual(stub.requestedPaths.count, 2)
    }

    func testOtherStartFailuresNeitherRefetchNorRetry() async throws {
        let (gate, stub) = try await makeGate()
        stub.reply(200, try available())
        let conflict = APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/progress_conflict",
            title: "Conflict", status: 409, detail: "", instance: nil, errors: nil)

        for failure in [APIv2Error.problem(conflict), APIv2Error.httpStatus(500)] {
            var calls = 0
            do {
                _ = try await gate.withInstallationRefresh { _ -> Void in
                    calls += 1
                    throw failure
                }
                XCTFail("the start failure must surface")
            } catch APIv2Error.problem, APIv2Error.httpStatus {}
            XCTAssertEqual(calls, 1)
        }
        XCTAssertEqual(stub.requestedPaths, [path], "the cached capability serves both starts")
    }

    /// The re-probe runs in an unstructured task, so a caller cancelled while
    /// it is in flight (player dismissed, autoplay start timeout) must not run
    /// the start again and allocate a session nobody owns.
    func testCancellationDuringTheRefreshSkipsTheSecondStart() async throws {
        let first = try Support.decoder.decode(APIv2PlaybackCapabilities.self,
            from: Data(try available(installation: installationA).utf8))
        let refreshed = try Support.decoder.decode(APIv2PlaybackCapabilities.self,
            from: Data(try available(installation: installationB).utf8))
        let changed = try Support.decode(APIv2Problem.self, named: "playback_installation_changed", bundleClass: Self.self)
        let counts = RefreshCounts()
        let (reprobeStarted, reprobeStartedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (gate, _) = try await makeGate { _ in
            guard await counts.nextFetch() > 1 else { return first }
            reprobeStartedSignal.yield()
            for await _ in release { break }
            return refreshed
        }

        let start = Task {
            try await gate.withInstallationRefresh { capability -> String in
                if await counts.nextStart() == 1 { throw APIv2Error.problem(changed) }
                return capability.installationID
            }
        }
        var started = reprobeStarted.makeAsyncIterator()
        _ = await started.next()
        start.cancel()
        releaseSignal.yield()
        releaseSignal.finish()

        do {
            let installation = try await start.value
            XCTFail("a cancelled caller must not start again, got \(installation)")
        } catch is CancellationError {}
        let starts = await counts.starts
        let fetches = await counts.fetches
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(fetches, 2)
    }

    /// A second refusal after the refresh surfaces instead of looping.
    func testInstallationChangedTwiceSurfacesTheSecondRefusal() async throws {
        let (gate, stub) = try await makeGate()
        stub.reply(200, try available())
        let changed = try Support.decode(APIv2Problem.self, named: "playback_installation_changed", bundleClass: Self.self)

        var calls = 0
        do {
            _ = try await gate.withInstallationRefresh { _ -> Void in
                calls += 1
                throw APIv2Error.problem(changed)
            }
            XCTFail("the second refusal must surface")
        } catch let error where PlaybackV3CapabilityGate.isInstallationChanged(error) {}
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(stub.requestedPaths, [path, path])
    }
}

private actor RefreshCounts {
    private(set) var fetches = 0
    private(set) var starts = 0

    func nextFetch() -> Int {
        fetches += 1
        return fetches
    }

    func nextStart() -> Int {
        starts += 1
        return starts
    }
}
