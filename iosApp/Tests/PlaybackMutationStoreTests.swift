import Foundation
import XCTest
@testable import Silo

final class PlaybackMutationStoreTests: XCTestCase {
    private func fixture(installation: String? = nil) async throws -> (PlaybackMutationStore, PlaybackMutationAuthority, URL, TokenStore) {
        let name = "PlaybackMutationStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://playback.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try PlaybackMutationAuthority(auth: XCTUnwrap(captured), installationID: installation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let url = root.appendingPathComponent("sessions.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: name) }
        return (PlaybackMutationStore(url: url), authority, url, tokens)
    }

    func testBackwardSampleAndUncertainRetryPreserveExactSequenceAndBody() async throws {
        let (store, authority, _, _) = try await fixture()
        let session = try await store.register(sessionID: "session", authority: authority)
        let first = try await store.prepareProgress(session.id, authority: authority, position: 120, isPaused: false)
        let retry = try await store.prepareProgress(session.id, authority: authority, position: 30, isPaused: true)
        XCTAssertEqual(first, retry)
        let receipt = try JSONDecoder().decode(PlaybackSequencedProgressReceipt.self,
            from: Data(#"{"outcome":"replayed","accepted":{"sequence":1,"position":120,"is_paused":false}}"#.utf8))
        try await store.acknowledgeProgress(session.id, authority: authority, sent: first, receipt: receipt)
        let backward = try await store.prepareProgress(session.id, authority: authority, position: 30, isPaused: true)
        XCTAssertEqual(backward.sequence, 2)
        XCTAssertEqual(backward.position, 30)
    }

    func testStopSurvivesRestartAndLateDrainingCannotReopenTerminal() async throws {
        let (store, authority, url, _) = try await fixture(installation: "verified-installation")
        let session = try await store.register(sessionID: "session", authority: authority)
        let stop = try await store.prepareStop(session.id, authority: authority, position: 3, isPaused: true)
        let restarted = PlaybackMutationStore(url: url)
        let retried = try await restarted.prepareStop(session.id, authority: authority, position: 99, isPaused: false)
        XCTAssertEqual(stop, retried)
        let pending = try await restarted.pendingStops(authority: authority, afterRestart: true)
        XCTAssertEqual(pending.first?.stop, stop)
        func receipt(_ outcome: String) throws -> PlaybackSequencedStopReceipt {
            try JSONDecoder().decode(PlaybackSequencedStopReceipt.self,
                from: Data("{\"outcome\":\"\(outcome)\",\"stop_id\":\"\(stop.stopID.uuidString.lowercased())\"}".utf8))
        }
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop, receipt: receipt("draining"))
        let draining = try await restarted.session(session.id, authority: authority)
        XCTAssertEqual(draining.stopState, .draining)
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop, receipt: receipt("stopped"))
        try await restarted.acknowledgeStop(session.id, authority: authority, sent: stop, receipt: receipt("draining"))
        let terminal = try await restarted.session(session.id, authority: authority)
        XCTAssertEqual(terminal.stopState, .terminal)
    }

    func testUnknownInstallationAndReloginNeverPromotePendingIntent() async throws {
        let (store, authority, _, tokens) = try await fixture()
        let session = try await store.register(sessionID: "session", authority: authority)
        _ = try await store.prepareStop(session.id, authority: authority, position: nil, isPaused: true)
        let restarted = try await store.pendingStops(authority: authority, afterRestart: true)
        XCTAssertTrue(restarted.isEmpty)
        try await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let relogin = try PlaybackMutationAuthority(auth: XCTUnwrap(captured), installationID: nil)
        do { _ = try await store.session(session.id, authority: relogin); XCTFail() } catch {}
    }

    func testStopOmissionAndStrictAcceptedSampleWire() throws {
        let stop = PlaybackSequencedStop(stopID: UUID(), sample: nil)
        let data = try JSONEncoder().encode(stop)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["stop_id"])
        XCTAssertEqual(body["stop_id"] as? String, stop.stopID.uuidString.lowercased())
        for wire in [#"{"sequence":0,"position":0,"is_paused":false}"#,
                     #"{"sequence":1,"position":-1,"is_paused":false}"#,
                     #"{"sequence":1,"position":0}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(PlaybackSequencedSample.self, from: Data(wire.utf8)))
        }
    }

    func testWriteFailureDoesNotAllocateOrConsumeIntent() async throws {
        let (store, authority, url, _) = try await fixture()
        let session = try await store.register(sessionID: "session", authority: authority)
        let failed = PlaybackMutationStore(url: url) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        do { _ = try await failed.prepareProgress(session.id, authority: authority, position: 1, isPaused: false); XCTFail() } catch {}
        do { _ = try await failed.prepareStop(session.id, authority: authority, position: 2, isPaused: true); XCTFail() } catch {}
        let unchanged = try await store.session(session.id, authority: authority)
        XCTAssertEqual(unchanged.allocatedSequence, 0)
        XCTAssertNil(unchanged.pendingProgress)
        XCTAssertNil(unchanged.stop)
    }
}
