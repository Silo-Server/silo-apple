import XCTest
@testable import Silo

final class DiagnosticsContractTests: XCTestCase {
    private enum InvalidExpectation {
        case decode
        case validate
    }

    private let validManifestFixtures = [
        "android-manual-no-profile.json",
        "android-manual.json",
        "android-tv-crash-ueh.json",
        "ios-hang-metrickit.json",
        "tvos-abnormal-exit.json",
    ]
    private let validDeviceFixture = "device.json"
    private let validLogLineFixture = "loglines.jsonl"
    private let invalidExpectations: [String: InvalidExpectation] = [
        "archive-entry-outside-allowlist.json": .validate,
        "bad-schema-version.json": .validate,
        "missing-consent.json": .decode,
        "platform-macos-reserved.json": .decode,
        "stack-excerpt-over-8kib.json": .validate,
        "unknown-report-type.json": .decode,
    ]

    func testValidFixturesDecodeAndValidate() throws {
        for fixture in validManifestFixtures {
            let url = try fixtureURL(fixture, sourceSubdirectory: "fixtures/valid")
            let manifest = try DiagnosticsJSONCoding.makeDecoder().decode(DiagnosticsManifest.self, from: Data(contentsOf: url))
            try manifest.validate()
        }

        let deviceURL = try fixtureURL(validDeviceFixture, sourceSubdirectory: "fixtures/valid")
        let payload = try DiagnosticsJSONCoding.makeDecoder().decode(DeviceSnapshotPayload.self, from: Data(contentsOf: deviceURL))
        try payload.validate()

        let logLineURL = try fixtureURL(validLogLineFixture, sourceSubdirectory: "fixtures/valid")
        try validateJSONLFixture(logLineURL)
    }

    func testDiagnosticsAPIDecodesWithHTTPClientSnakeCaseStrategy() throws {
        let decoder = HTTPClient.makeJSONDecoder()

        let status = try decoder.decode(DiagnosticsStatusResponse.self, from: Data("""
        {
          "status": "available",
          "server_instance_id": "srv_123",
          "accepted_schema_versions": [1],
          "max_bundle_bytes": 1048576,
          "max_manifest_bytes": 65536,
          "retention_days": 30,
          "consent_notice_version": 2
        }
        """.utf8))

        XCTAssertEqual(status.status, .available)
        XCTAssertEqual(status.serverInstanceID, "srv_123")
        XCTAssertEqual(status.acceptedSchemaVersions, [1])
        XCTAssertEqual(status.maxBundleBytes, 1_048_576)
        XCTAssertEqual(status.maxManifestBytes, 65_536)
        XCTAssertEqual(status.retentionDays, 30)
        XCTAssertEqual(status.consentNoticeVersion, 2)

        let upload = try decoder.decode(DiagnosticsUploadResponse.self, from: Data("""
        {
          "report_id": "diag_123",
          "short_id": "ABC123"
        }
        """.utf8))

        XCTAssertEqual(upload.reportID, "diag_123")
        XCTAssertEqual(upload.shortID, "ABC123")
    }

    func testInvalidFixturesFailAtExpectedStage() throws {
        for (fileName, expectation) in invalidExpectations {
            let url = try fixtureURL(fileName, sourceSubdirectory: "fixtures/invalid")
            let data = try Data(contentsOf: url)
            switch expectation {
            case .decode:
                XCTAssertThrowsError(
                    try DiagnosticsJSONCoding.makeDecoder().decode(DiagnosticsManifest.self, from: data),
                    fileName
                )
            case .validate:
                let manifest = try DiagnosticsJSONCoding.makeDecoder().decode(DiagnosticsManifest.self, from: data)
                XCTAssertThrowsError(try manifest.validate(), fileName)
            }
        }
    }

    private func validateJSONLFixture(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertFalse(lines.isEmpty, url.lastPathComponent)
        for line in lines {
            let payload = Data(line.utf8)
            let decoded = try DiagnosticsJSONCoding.makeDecoder().decode(DiagnosticsLogLine.self, from: payload)
            try decoded.validate()
        }
    }

    private func fixtureURL(_ fileName: String, sourceSubdirectory: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        if let flattened = bundle.url(forResource: baseName, withExtension: ext) {
            return flattened
        }

        let candidates = [
            bundle.resourceURL?
                .appendingPathComponent("DiagnosticsContract")
                .appendingPathComponent(sourceSubdirectory)
                .appendingPathComponent(fileName),
            bundle.resourceURL?
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("DiagnosticsContract")
                .appendingPathComponent(sourceSubdirectory)
                .appendingPathComponent(fileName),
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw NSError(
            domain: "DiagnosticsContractTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Diagnostics contract fixture missing from test bundle: \(fileName)"]
        )
    }
}
