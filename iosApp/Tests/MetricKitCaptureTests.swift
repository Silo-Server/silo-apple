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
