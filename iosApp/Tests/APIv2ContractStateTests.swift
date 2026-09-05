import Foundation
import XCTest
@testable import Silo

/// The v2 contract verdict in `ConnectionMonitor` is scoped to one server.
/// A probe of a setup candidate, or one that outlives a server switch, must
/// never gate the session that is actually active.
@MainActor
final class APIv2ContractStateTests: XCTestCase {
    private var monitor: ConnectionMonitor { ConnectionMonitor.shared }
    private var activeServerId: String?

    override func setUp() async throws {
        try await super.setUp()
        let previousProvider = monitor.activeServerIdProvider
        addTeardownBlock { @MainActor [monitor] in
            monitor.activeServerIdProvider = previousProvider
            monitor.onContractRecheckNeeded = nil
            monitor.resetContractStatus()
            // Leave the shared monitor reachable for whatever runs next.
            monitor.noteServerResponded()
        }
        monitor.onContractRecheckNeeded = nil
        monitor.resetContractStatus()
        monitor.activeServerIdProvider = { [unowned self] in self.activeServerId }
    }

    func testVerdictForNonActiveServerLeavesActiveVerdictUnchanged() {
        activeServerId = "active"
        monitor.noteContractProbe(.v2(.fixture), serverId: "active")
        XCTAssertEqual(monitor.contractStatus, .v2)

        // A v1-only candidate probed during setup, while "active" stays active.
        monitor.noteContractProbe(.updateServer, serverId: "candidate")

        XCTAssertEqual(monitor.contractStatus, .v2)
        XCTAssertEqual(monitor.contractServerId, "active")
        XCTAssertFalse(monitor.isServerUpdateRequired)
    }

    func testVerdictForActiveServerRecords() {
        activeServerId = "active"
        monitor.noteContractProbe(.updateServer, serverId: "active")

        XCTAssertEqual(monitor.contractStatus, .updateRequired)
        XCTAssertEqual(monitor.contractServerId, "active")
        XCTAssertTrue(monitor.isServerUpdateRequired)
    }

    func testStaleVerdictAfterSwitchIsDropped() {
        activeServerId = "old"
        monitor.noteContractProbe(.v2(.fixture), serverId: "old")

        // The user switches while a probe of "old" is still in flight; its
        // late verdict names "old" and must not describe "new".
        activeServerId = "new"
        monitor.noteContractProbe(.updateServer, serverId: "old")

        XCTAssertNotEqual(monitor.contractServerId, "new")
        XCTAssertFalse(monitor.isServerUpdateRequired)

        // The new server's own probe records normally.
        monitor.noteContractProbe(.updateServer, serverId: "new")
        XCTAssertEqual(monitor.contractServerId, "new")
        XCTAssertTrue(monitor.isServerUpdateRequired)
    }

    func testSwitchingAwayHidesVerdictWithoutReset() {
        activeServerId = "old"
        monitor.noteContractProbe(.updateServer, serverId: "old")
        XCTAssertTrue(monitor.isServerUpdateRequired)

        activeServerId = "new"
        XCTAssertFalse(
            monitor.isServerUpdateRequired,
            "a verdict recorded for a server that is no longer active must not gate the new one"
        )
    }

    func testResetClearsVerdictAndServer() {
        activeServerId = "active"
        monitor.noteContractProbe(.updateServer, serverId: "active")
        XCTAssertTrue(monitor.isServerUpdateRequired)

        monitor.resetContractStatus()

        XCTAssertEqual(monitor.contractStatus, .unknown)
        XCTAssertNil(monitor.contractServerId)
        XCTAssertFalse(monitor.isServerUpdateRequired)
    }

    func testFailureAfterSwitchDoesNotReviveOldVerdict() {
        activeServerId = "old"
        monitor.noteContractProbe(.updateServer, serverId: "old")

        activeServerId = "new"
        monitor.noteContractProbe(.failure(.timeout), serverId: "new")

        XCTAssertEqual(monitor.contractServerId, "new")
        XCTAssertEqual(monitor.contractStatus, .unknown, "a timeout for the new server is not contract evidence")
        XCTAssertFalse(monitor.isServerUpdateRequired)
    }

    func testV2VerdictAfterUpdateRequiredClearsForSameServer() {
        activeServerId = "active"
        monitor.noteContractProbe(.updateServer, serverId: "active")
        XCTAssertTrue(monitor.isServerUpdateRequired)

        monitor.noteContractProbe(.v2(.fixture), serverId: "active")

        XCTAssertEqual(monitor.contractStatus, .v2)
        XCTAssertEqual(monitor.contractServerId, "active")
        XCTAssertFalse(monitor.isServerUpdateRequired, "an upgraded server clears the sticky verdict")
    }

    func testRecheckHookFiresOnceOnRecoveryWhileUpdateRequired() {
        var fired = 0
        monitor.onContractRecheckNeeded = { fired += 1 }
        activeServerId = "active"
        monitor.noteContractProbe(.updateServer, serverId: "active")

        // Steady-state responses and the first reachable step are not edges.
        monitor.noteServerResponded()
        XCTAssertEqual(fired, 0)

        monitor.noteServerUnreachable()
        XCTAssertEqual(fired, 0, "going down is not a recovery")
        monitor.noteServerResponded()
        XCTAssertEqual(fired, 1, "unreachable -> reachable while update-required requests a re-probe")
        monitor.noteServerResponded()
        XCTAssertEqual(fired, 1, "the hook fires on the edge, not on every response")

        // The verdict itself is untouched by the edge; only a probe changes it.
        XCTAssertTrue(monitor.isServerUpdateRequired)
    }

    func testRecheckHookStaysQuietWithoutUpdateRequired() {
        var fired = 0
        monitor.onContractRecheckNeeded = { fired += 1 }
        activeServerId = "active"
        monitor.noteContractProbe(.v2(.fixture), serverId: "active")

        monitor.noteServerUnreachable()
        monitor.noteServerResponded()
        XCTAssertEqual(fired, 0, "a v2 server recovering needs no re-probe")

        // A verdict that belongs to a server that is no longer active is not
        // update-required for the active one, so recovery must not fire.
        monitor.noteContractProbe(.updateServer, serverId: "active")
        activeServerId = "other"
        monitor.noteServerUnreachable()
        monitor.noteServerResponded()
        XCTAssertEqual(fired, 0, "a stale verdict for another server never triggers a re-probe")
    }
}

private extension APIv2SystemInfo {
    static let fixture = APIv2SystemInfo(
        serverVersion: "2.0.0",
        apiMajor: 2,
        contractDigest: "test",
        links: APIv2SystemInfoLinks(openapi: "/api/v2/openapi.json", capabilities: "/api/v2/capabilities")
    )
}
