import XCTest
@testable import Silo

/// Which unclean previous runs become an abnormal-exit report. A reboot, an
/// app update, or a debugger session ends a run without saying anything about
/// Silo's stability, so those leftovers are dropped on the next launch.
final class ExitSentinelLeftoverPolicyTests: XCTestCase {
    private let environment = ExitSentinelEnvironment(
        bootTime: 1_790_000_000,
        appVersion: "1.4.0",
        appBuild: "812",
        debuggerAttached: false
    )

    private func marker(environment: ExitSentinelEnvironment?) -> ExitSentinelMarker {
        ExitSentinelMarker(
            runID: "previous-run",
            startedAt: "2026-10-04T10:00:00.000Z",
            binding: DiagnosticsBinding(serverInstanceID: "srv", accountUserID: "acct"),
            profileID: "prof",
            environment: environment
        )
    }

    func testSameBootAndBuildIsReported() {
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: environment), .report)
    }

    func testRebootIsDropped() {
        var current = environment
        current.bootTime = environment.bootTime! + 3_600
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: current), .dropRebooted)
    }

    func testSmallBootTimeDriftFromClockCorrectionIsStillTheSameBoot() {
        var current = environment
        current.bootTime = environment.bootTime! + 2.5
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: current), .report)
    }

    func testUnknownBootTimeDoesNotDropTheReport() {
        var armed = environment
        armed.bootTime = nil
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: armed), current: environment), .report)

        var current = environment
        current.bootTime = nil
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: current), .report)
    }

    func testBuildOrVersionChangeIsDropped() {
        var newBuild = environment
        newBuild.appBuild = "813"
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: newBuild), .dropBuildChanged)

        var newVersion = environment
        newVersion.appVersion = "1.5.0"
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: newVersion), .dropBuildChanged)
    }

    func testDebuggerOnEitherRunIsDropped() {
        var debugged = environment
        debugged.debuggerAttached = true
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: debugged), current: environment), .dropDebuggerAttached)
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: environment), current: debugged), .dropDebuggerAttached)
    }

    /// A marker without build fields was written by a build that predates
    /// them, so the running build is necessarily different.
    func testLegacyMarkerWithoutEnvironmentIsTreatedAsBuildChange() throws {
        let legacy = try DiagnosticsJSONCoding.makeDecoder().decode(
            ExitSentinelMarker.self,
            from: Data(#"{"run_id":"old-run","started_at":"2026-07-20T10:00:00Z"}"#.utf8)
        )
        XCTAssertNil(legacy.appBuild)
        XCTAssertNil(legacy.bootTime)
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(legacy, current: environment), .dropBuildChanged)
    }

    func testMarkerRoundTripsEnvironmentAndRebindKeepsIt() throws {
        let original = marker(environment: environment)
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(original)
        let decoded = try DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.bootTime, environment.bootTime)
        XCTAssertEqual(decoded.appBuild, "812")

        let rebound = original.rebound(
            startedAt: "2026-10-04T11:00:00.000Z",
            binding: DiagnosticsBinding(serverInstanceID: "srv-b", accountUserID: "acct-b"),
            profileID: nil
        )
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(rebound, current: environment), .report)
    }

    /// `kern.boottime` shifts when the wall clock is stepped, for example by
    /// NTP after a long sleep. The boot session UUID does not, so a crash in
    /// the same boot is still reported.
    func testSameBootSessionIsReportedDespiteABootTimeJump() {
        var armed = environment
        armed.bootSessionUUID = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"
        var current = armed
        current.bootTime = armed.bootTime! + 3_600
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: armed), current: current), .report)

        current = armed
        current.bootSessionUUID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(marker(environment: armed), current: current), .dropRebooted)
    }

    /// A marker armed before the UUID was recorded falls back to boot time.
    func testMarkerWithoutBootSessionFallsBackToBootTime() throws {
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(marker(environment: environment))
        let decoded = try DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: data)
        XCTAssertNil(decoded.bootSessionUUID)

        var current = environment
        current.bootSessionUUID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(decoded, current: current), .report)
        current.bootTime = environment.bootTime! + 3_600
        XCTAssertEqual(ExitSentinelLeftoverPolicy.decide(decoded, current: current), .dropRebooted)
    }

    func testCurrentEnvironmentReadsBootSessionFromTheKernel() throws {
        let uuid = try XCTUnwrap(ExitSentinelEnvironment.systemBootSessionUUID())
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertEqual(ExitSentinelEnvironment.systemBootSessionUUID(), uuid)
    }

    // MARK: - Store promotion

    private func makeStore() -> ExitSentinelMarkerStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExitSentinelLeftoverPolicyTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ExitSentinelMarkerStore(currentURL: directory.appendingPathComponent("exit-sentinel.json"))
    }

    func testRejectedPreviousRunIsRemovedInsteadOfPromoted() {
        let store = makeStore()
        store.writeCurrent(marker(environment: environment))

        XCTAssertNil(store.preserveLeftoverFromCurrentSlot(currentRunID: "this-run") { _ in false })
        XCTAssertNil(store.readLeftover())
        XCTAssertNil(store.readCurrent())
    }

    /// A crash promoted on an earlier launch is still waiting for capture; a
    /// reboot since then must not discard it.
    func testPromotedLeftoverIsNotJudgedAgain() {
        let store = makeStore()
        let crashed = marker(environment: environment)
        store.writeCurrent(crashed)
        XCTAssertEqual(store.preserveLeftoverFromCurrentSlot(currentRunID: "relaunch") { _ in true }, crashed)
        store.writeCurrent(ExitSentinelMarker(runID: "relaunch", startedAt: "2026-10-04T11:00:00.000Z"))
        store.clearCurrent()

        XCTAssertEqual(store.preserveLeftoverFromCurrentSlot(currentRunID: "after-reboot") { _ in false }, crashed)
        XCTAssertEqual(store.readLeftover(), crashed)
    }

    func testDebuggerAttachingLaterIsRecordedOnTheRunsMarker() {
        let store = makeStore()
        store.writeCurrent(marker(environment: environment))

        store.markCurrentRunDebuggerAttached(runID: "another-run")
        XCTAssertEqual(store.readCurrent()?.debuggerAttached, false)

        store.markCurrentRunDebuggerAttached(runID: "previous-run")
        XCTAssertEqual(store.readCurrent()?.debuggerAttached, true)
    }

    func testCurrentEnvironmentReadsBootTimeFromTheKernel() throws {
        let bootTime = try XCTUnwrap(ExitSentinelEnvironment.systemBootTime())
        XCTAssertLessThan(bootTime, Date().timeIntervalSince1970)
        XCTAssertGreaterThan(bootTime, 1_000_000_000)
    }
}
