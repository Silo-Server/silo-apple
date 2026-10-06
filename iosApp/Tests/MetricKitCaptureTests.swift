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

    func testCrashExcerptUsesThreadAttributedStack() {
        let crash = crashInfo(Self.backgroundThreadCrash, type: .crash)

        XCTAssertEqual(crash.stackExcerpt, "Silo 100\nSilo 200\nUIKitCore 300")
        XCTAssertEqual(crash.summary, "Crash reported by MetricKit: Silo 100")
    }

    func testExcerptFallsBackToFirstStackWhenNoThreadIsAttributed() {
        let crash = crashInfo(Self.unattributedHang, type: .hang)

        XCTAssertEqual(crash.stackExcerpt, "Silo 10\nSilo 20")
        XCTAssertFalse(crash.stackExcerpt?.contains("CoreFoundation") ?? false)
        XCTAssertEqual(crash.summary, "Main thread hang reported by MetricKit: Silo 10")
    }

    func testExcerptCapsAttributedStackAtTwelveFramesInOrder() throws {
        // Build a 15-deep subFrames chain, Silo 1 (top) through Silo 15.
        var frame: [String: Any] = ["binaryName": "Silo", "offsetIntoBinaryTextSegment": 15]
        for offset in stride(from: 14, through: 1, by: -1) {
            frame = ["binaryName": "Silo", "offsetIntoBinaryTextSegment": offset, "subFrames": [frame]]
        }
        let idleFrame: [String: Any] = ["binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 1000]
        let payload: [String: Any] = [
            "callStackTree": [
                "callStackPerThread": true,
                "callStacks": [
                    ["threadAttributed": false, "callStackRootFrames": [idleFrame]],
                    ["threadAttributed": true, "callStackRootFrames": [frame]],
                ],
            ],
        ]
        let rawJSON = try JSONSerialization.data(withJSONObject: payload)

        let crash = MetricKitDiagnosticParser.crashInfo(
            rawJSON: rawJSON,
            type: .crash,
            periodStart: Date(timeIntervalSince1970: 10),
            periodEnd: Date(timeIntervalSince1970: 20)
        )

        let lines = try XCTUnwrap(crash.stackExcerpt).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, (1...12).map { "Silo \($0)" })
    }

    func testAttributedStackWithoutFramesDoesNotBorrowAnotherThread() {
        // MetricKit has been seen to attribute a thread with an empty
        // callStackRootFrames. Another thread's frames would be misleading.
        let json = """
        {"callStackTree": {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [
            {"binaryName": "libsystem_kernel.dylib", "offsetIntoBinaryTextSegment": 1000}]},
          {"threadAttributed": true, "callStackRootFrames": []}
        ]}}
        """
        let crash = crashInfo(json, type: .crash)

        XCTAssertNil(crash.stackExcerpt)
        XCTAssertEqual(crash.summary, "Crash reported by MetricKit")
    }

    private func crashInfo(_ json: String, type: ReportType) -> DiagnosticsCrashInfo {
        MetricKitDiagnosticParser.crashInfo(
            rawJSON: Data(json.utf8),
            type: type,
            periodStart: Date(timeIntervalSince1970: 10),
            periodEnd: Date(timeIntervalSince1970: 20)
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

    /// A background-thread crash: thread 0 is idle in the kernel, and the
    /// crashed thread comes second.
    private static let backgroundThreadCrash = """
    {
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              {
                "binaryName": "libsystem_kernel.dylib",
                "offsetIntoBinaryTextSegment": 1000,
                "subFrames": [
                  { "binaryName": "libsystem_pthread.dylib", "offsetIntoBinaryTextSegment": 2000 }
                ]
              }
            ]
          },
          {
            "threadAttributed": true,
            "callStackRootFrames": [
              {
                "binaryName": "Silo",
                "offsetIntoBinaryTextSegment": 100,
                "subFrames": [
                  {
                    "binaryName": "Silo",
                    "offsetIntoBinaryTextSegment": 200,
                    "subFrames": [
                      { "binaryName": "UIKitCore", "offsetIntoBinaryTextSegment": 300 }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "1"
      }
    }
    """

    /// Neither stack is attributed: the first says false, the second omits the key.
    private static let unattributedHang = """
    {
      "callStackTree": {
        "callStackPerThread": true,
        "callStacks": [
          {
            "threadAttributed": false,
            "callStackRootFrames": [
              {
                "binaryName": "Silo",
                "offsetIntoBinaryTextSegment": 10,
                "subFrames": [
                  { "binaryName": "Silo", "offsetIntoBinaryTextSegment": 20 }
                ]
              }
            ]
          },
          {
            "callStackRootFrames": [
              {
                "binaryName": "CoreFoundation",
                "offsetIntoBinaryTextSegment": 30,
                "subFrames": [
                  { "binaryName": "CoreFoundation", "offsetIntoBinaryTextSegment": 40 }
                ]
              }
            ]
          }
        ]
      },
      "diagnosticMetaData": {
        "appBuildVersion": "1"
      }
    }
    """
}
