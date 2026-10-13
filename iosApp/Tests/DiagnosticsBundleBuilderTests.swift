import XCTest
@testable import Silo

final class DiagnosticsBundleBuilderTests: XCTestCase {
    func testExactTokenScrubReplacesLiveTokensInTextualData() throws {
        let data = Data("access=access-token-123 profile=profile-token-456 access-token-123".utf8)

        let scrubbed = DiagnosticsBundleBuilder.scrubExactTokenMatches(
            in: data,
            tokens: ["access-token-123", "profile-token-456", "access-token-123"]
        )
        let rendered = try XCTUnwrap(String(bytes: scrubbed, encoding: .utf8))

        XCTAssertFalse(rendered.contains("access-token-123"))
        XCTAssertFalse(rendered.contains("profile-token-456"))
        XCTAssertEqual(
            rendered,
            "access=[redacted_token] profile=[redacted_token] [redacted_token]"
        )
    }

    func testExactTokenScrubFailsClosedForNonUTF8Data() {
        let data = Data([0xff, 0xfe, 0xfd, 0x00])

        let scrubbed = DiagnosticsBundleBuilder.scrubExactTokenMatches(
            in: data,
            tokens: ["token"]
        )

        XCTAssertEqual(
            String(data: scrubbed, encoding: .utf8),
            "[redaction_failed: non-utf8 content dropped]"
        )
        XCTAssertNotEqual(scrubbed, data)
    }

    /// Hosted MetricKit payloads keep the fields a reader uses to symbolicate
    /// and classify the failure; anything else, including fields Apple adds
    /// later, is dropped rather than passed through.
    func testHostedMetricKitKeepsOnlyAllowListedFields() throws {
        let binaryUUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let raw = try JSONSerialization.data(withJSONObject: [
            "version": "1.0.0",
            "futureTopLevelField": "unknown",
            "callStackTree": [
                "callStackPerThread": true,
                "callStacks": [[
                    "threadAttributed": true,
                    "callStackRootFrames": [[
                        "binaryUUID": binaryUUID,
                        "binaryName": "Silo",
                        "offsetIntoBinaryTextSegment": 4096,
                        "sampleCount": 1,
                        "address": 4_294_971_392,
                        "futureFrameField": "unknown",
                        "subFrames": [[
                            "binaryUUID": binaryUUID,
                            "binaryName": "Silo",
                            "offsetIntoBinaryTextSegment": 8192,
                        ]],
                    ]],
                ]],
            ],
            "diagnosticMetaData": [
                "appBuildVersion": "812",
                "appVersion": "1.4.0",
                "osVersion": "iPhone OS 27.0 (24A434)",
                "deviceType": "iPhone18,2",
                "platformArchitecture": "arm64e",
                "regionFormat": "US",
                "pid": 4321,
                "bundleIdentifier": "org.siloserver.silo",
                "virtualMemoryRegionInfo": "0 is not in any region",
                "exceptionType": 1,
                "exceptionCode": 0,
                "signal": 11,
                "terminationReason": "Namespace SIGNAL, Code 11",
                "hangDuration": "3 sec",
                "objectiveCexceptionReason": [
                    "exceptionName": "NSRangeException",
                    "className": "NSArray",
                    "composedMessage": "index 5 beyond bounds",
                    "formatString": "index %ld beyond bounds",
                    "arguments": ["5"],
                ],
            ],
        ])

        let sanitized = try DiagnosticsBundleBuilder.sanitizeHostedMetricKitJSON(raw)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["version", "callStackTree", "diagnosticMetaData"])
        let metadata = try XCTUnwrap(object["diagnosticMetaData"] as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), [
            "appBuildVersion", "appVersion", "osVersion", "deviceType", "platformArchitecture",
            "exceptionType", "exceptionCode", "signal", "terminationReason", "hangDuration",
            "objectiveCexceptionReason",
        ])
        let reason = try XCTUnwrap(metadata["objectiveCexceptionReason"] as? [String: Any])
        XCTAssertEqual(Set(reason.keys), ["exceptionName", "className", "composedMessage"])

        let tree = try XCTUnwrap(object["callStackTree"] as? [String: Any])
        let stack = try XCTUnwrap((tree["callStacks"] as? [[String: Any]])?.first)
        let frame = try XCTUnwrap((stack["callStackRootFrames"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(frame.keys), [
            "binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "sampleCount", "subFrames",
        ])
        XCTAssertEqual(frame["binaryUUID"] as? String, binaryUUID)
        XCTAssertEqual(frame["offsetIntoBinaryTextSegment"] as? Int, 4096)
        let subFrame = try XCTUnwrap((frame["subFrames"] as? [[String: Any]])?.first)
        XCTAssertEqual(subFrame["offsetIntoBinaryTextSegment"] as? Int, 8192)
    }
    /// OS-composed exception text can quote a server URL, a LAN address, or
    /// an account email. Hosted archives redact them like any log line.
    func testHostedMetricKitFreeTextIsRedacted() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "diagnosticMetaData": [
                "terminationReason": "Namespace SIGNAL, Code 6 while loading https://media.example.com/api/v2/items",
                "objectiveCexceptionReason": [
                    "exceptionName": "NSInvalidArgumentException",
                    "className": "NSURL",
                    "composedMessage": "bad response from http://192.168.1.20:8096/x for person@example.org",
                ],
            ],
        ])

        let sanitized = try DiagnosticsBundleBuilder.sanitizeHostedMetricKitJSON(raw)
        let text = try XCTUnwrap(String(data: sanitized, encoding: .utf8))
        for secret in ["192.168.1.20", "8096", "media.example.com", "person@example.org"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let metadata = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: sanitized) as? [String: Any])?["diagnosticMetaData"] as? [String: Any]
        )
        let reason = try XCTUnwrap(metadata["objectiveCexceptionReason"] as? [String: Any])
        XCTAssertEqual(reason["exceptionName"] as? String, "NSInvalidArgumentException")
        XCTAssertTrue((reason["composedMessage"] as? String)?.hasPrefix("bad response from ") == true)
        XCTAssertTrue((metadata["terminationReason"] as? String)?.hasPrefix("Namespace SIGNAL, Code 6") == true)
    }
}
