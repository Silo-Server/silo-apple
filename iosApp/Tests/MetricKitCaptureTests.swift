import XCTest
@testable import Silo

final class MetricKitCaptureTests: XCTestCase {
    func testFixtureFingerprintDedupeUsesCanonicalDiagnosticJSON() throws {
        let store = try makeStore()
        let context = DiagnosticsCaptureContext(
            binding: DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42"),
            profileID: "profile-a",
            consentMode: .prompt,
            noticeVersion: 1,
            appVersion: "1.0.0",
            appBuild: "1",
            platform: .ios,
            osVersion: "26.0"
        )
        let periodStart = Date(timeIntervalSince1970: 10)
        let periodEnd = Date(timeIntervalSince1970: 20)

        let first = try XCTUnwrap(MetricKitCapture.captureFixtureDiagnostic(
            rawJSON: Data(Self.fixtureA.utf8),
            type: .hang,
            periodStart: periodStart,
            periodEnd: periodEnd,
            context: context,
            store: store,
            deviceSnapshotBuilder: makeDeviceSnapshotBuilder()
        ))
        let second = try MetricKitCapture.captureFixtureDiagnostic(
            rawJSON: Data(Self.fixtureB.utf8),
            type: .hang,
            periodStart: periodStart,
            periodEnd: periodEnd,
            context: context,
            store: store,
            deviceSnapshotBuilder: makeDeviceSnapshotBuilder()
        )

        XCTAssertNil(second)
        XCTAssertEqual(store.listReports(for: context.binding).map(\.id), [first.id])
        XCTAssertEqual(first.manifest.crash?.occurredAtStart, DiagnosticsTimestamp.string(from: periodStart))
        XCTAssertEqual(first.manifest.crash?.occurredAtEnd, DiagnosticsTimestamp.string(from: periodEnd))
        XCTAssertNil(first.manifest.crash?.thread)
        XCTAssertNil(first.manifest.crash?.foreground)
        XCTAssertTrue(first.manifest.crash?.summary.contains("Silo") == true)
    }

    /// Repeats of one crash share an issue fingerprint even though each
    /// payload differs in per-event fields such as the pid and addresses.
    func testIssueFingerprintIgnoresPerEventFieldsButNotTheFailure() {
        func payload(pid: Int, address: Int, signal: Int, offset: Int = 4096) -> Data {
            Data("""
            {
              "diagnosticMetaData": { "appBuildVersion": "812", "signal": \(signal), "exceptionType": 1, "pid": \(pid) },
              "callStackTree": {
                "callStacks": [
                  { "threadAttributed": false, "callStackRootFrames": [ { "binaryName": "Other", "offsetIntoBinaryTextSegment": 1 } ] },
                  { "threadAttributed": true, "callStackRootFrames": [
                    { "binaryName": "Silo", "offsetIntoBinaryTextSegment": \(offset), "address": \(address),
                      "subFrames": [ { "binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 8192 } ] }
                  ] }
                ]
              }
            }
            """.utf8)
        }
        let first = MetricKitDiagnosticParser.issueFingerprint(for: payload(pid: 10, address: 111, signal: 11), type: .crash)
        let repeatEvent = MetricKitDiagnosticParser.issueFingerprint(for: payload(pid: 20, address: 222, signal: 11), type: .crash)
        XCTAssertEqual(first, repeatEvent)
        XCTAssertNotEqual(
            MetricKitDiagnosticParser.fingerprint(for: payload(pid: 10, address: 111, signal: 11)),
            MetricKitDiagnosticParser.fingerprint(for: payload(pid: 20, address: 222, signal: 11))
        )

        XCTAssertNotEqual(first, MetricKitDiagnosticParser.issueFingerprint(for: payload(pid: 10, address: 111, signal: 6), type: .crash))
        XCTAssertNotEqual(first, MetricKitDiagnosticParser.issueFingerprint(
            for: payload(pid: 10, address: 111, signal: 11, offset: 5000),
            type: .crash
        ))
        XCTAssertNotEqual(first, MetricKitDiagnosticParser.issueFingerprint(for: payload(pid: 10, address: 111, signal: 11), type: .hang))
    }

    /// MetricKit nests callers under `subFrames`, so a crash chain runs from
    /// the crash site at the root out to `start`. Builds such a chain from
    /// `frames`, crash site first.
    private func crashPayload(_ frames: [(String, Int)], exceptionName: String? = nil) throws -> Data {
        var chain: [String: Any]?
        for (binary, offset) in frames.reversed() {
            var frame: [String: Any] = ["binaryName": binary, "offsetIntoBinaryTextSegment": offset]
            frame["subFrames"] = chain.map { [$0] }
            chain = frame
        }
        var metadata: [String: Any] = ["appBuildVersion": "812", "exceptionType": 10, "signal": 6]
        metadata["objectiveCexceptionReason"] = exceptionName.map { ["exceptionName": $0, "className": "NSArray"] }
        return try JSONSerialization.data(withJSONObject: [
            "diagnosticMetaData": metadata,
            "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [chain!]]]],
        ])
    }

    private func issue(_ payload: Data, type: ReportType = .crash) -> String {
        MetricKitDiagnosticParser.issueFingerprint(for: payload, type: type, appBinaryName: "Silo")
    }

    /// An abort or uncaught exception starts with the same system frames for
    /// every crash, so the first app frame below them tells crashes apart,
    /// and the outer callers do not.
    func testIssueFingerprintKeysOnTheCrashSiteAndTheFirstAppFrame() throws {
        let abortFrames = (0..<8).map { ("libsystem_kernel.dylib", 100 + $0) }
        let outer = [("UIKitCore", 1), ("UIKitCore", 2), ("dyld", 7)]
        let crash = try crashPayload(abortFrames + [("Silo", 4096)] + outer)

        XCTAssertNotEqual(issue(crash), issue(try crashPayload(abortFrames + [("Silo", 5000)] + outer)))
        XCTAssertNotEqual(
            issue(crash),
            issue(try crashPayload([("libsystem_kernel.dylib", 999)] + abortFrames.dropFirst() + [("Silo", 4096)] + outer))
        )
        XCTAssertEqual(
            issue(crash),
            issue(try crashPayload(abortFrames + [("Silo", 4096), ("SwiftUI", 3), ("GraphicsServices", 4), ("dyld", 7)]))
        )
        XCTAssertNotEqual(
            issue(try crashPayload(abortFrames + outer, exceptionName: "NSRangeException")),
            issue(try crashPayload(abortFrames + outer, exceptionName: "NSInvalidArgumentException"))
        )
    }

    /// A sampled hang tree branches; the walk follows the busiest branch,
    /// whatever order MetricKit lists the branches in.
    func testIssueFingerprintFollowsTheBusiestBranchOfAHangTree() throws {
        func hang(_ branches: [(offset: Int, samples: Int)]) throws -> Data {
            let children = branches.map { branch -> [String: Any] in
                ["binaryName": "Silo", "offsetIntoBinaryTextSegment": branch.offset, "sampleCount": branch.samples]
            }
            let root: [String: Any] = [
                "binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 1,
                "sampleCount": 11, "subFrames": children,
            ]
            return try JSONSerialization.data(withJSONObject: [
                "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [root]]]],
            ])
        }
        let busyFirst = issue(try hang([(20, 9), (10, 2)]), type: .hang)
        XCTAssertEqual(busyFirst, issue(try hang([(10, 2), (20, 9)]), type: .hang))
        XCTAssertNotEqual(busyFirst, issue(try hang([(20, 2), (10, 9)]), type: .hang))
        XCTAssertEqual(
            issue(try hang([(20, 5), (10, 5)]), type: .hang),
            issue(try hang([(10, 5), (20, 5)]), type: .hang)
        )
    }

    private func makeStore() throws -> PendingReportStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricKitCaptureTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PendingReportStore(rootDirectory: directory)
    }

    private func makeDeviceSnapshotBuilder() -> DeviceSnapshotBuilder {
        DeviceSnapshotBuilder(
            identityProvider: {
                AppleDeviceIdentity(
                    id: "device-id",
                    name: "Unit Test iPhone",
                    platform: "iOS",
                    clientFamily: "mobile"
                )
            },
            playbackSnapshotProvider: {
                DiagnosticsCapabilityProbe.Snapshot(
                    display: .object(["mode": .string("not_collected")]),
                    videoCodecs: .string("not_collected"),
                    network: .object(["transport": .string("not_collected")])
                )
            },
            audioSnapshotProvider: {
                DiagnosticsCapabilityProbe.audioOutputSnapshot(outputs: [])
            },
            dateProvider: { Date(timeIntervalSince1970: 21) },
            hardwareModelProvider: { "iPhone17,2" },
            osVersionProvider: { "26.0" },
            formFactorProvider: { "phone" }
        )
    }

    private static let fixtureA = """
    {
      "callStackTree": {
        "callStackRootFrames": [
          {
            "binaryName": "Silo",
            "offsetIntoBinaryTextSegment": 4096,
            "subFrames": [
              { "binaryName": "MediaModule", "offsetIntoBinaryTextSegment": 8192 }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "1"
      }
    }
    """

    private static let fixtureB = """
    {
      "diagnosticMetaData": {
        "appBuildVersion": "1"
      },
      "callStackTree": {
        "callStackRootFrames": [
          {
            "subFrames": [
              { "offsetIntoBinaryTextSegment": 8192, "binaryName": "MediaModule" }
            ],
            "offsetIntoBinaryTextSegment": 4096,
            "binaryName": "Silo"
          }
        ]
      }
    }
    """
}
