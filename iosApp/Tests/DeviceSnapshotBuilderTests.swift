import XCTest
@testable import Silo

final class DeviceSnapshotBuilderTests: XCTestCase {
    func testRouteUIDsAreHashedStablyAndRawUIDsAreNotEncoded() throws {
        let rawUID = "raw-hdmi-route-uid"
        let expectedHash = DiagnosticsSHA256.shortHex(data: Data(rawUID.utf8), count: 16)
        let audio = DiagnosticsCapabilityProbe.audioOutputSnapshot(outputs: [
            DiagnosticsCapabilityProbe.AudioRouteOutput(
                portType: "HDMI",
                rawUID: rawUID,
                portName: "Receiver",
                channels: 8
            ),
        ])
        let builder = makeBuilder(audio: audio)

        let snapshot = builder.build(provenance: .postRestart)
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(snapshot)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(encoded.contains(expectedHash))
        XCTAssertFalse(encoded.contains(rawUID))
        XCTAssertFalse(encoded.contains("Receiver"))
        XCTAssertTrue(encoded.contains(#""passthrough":"unknown""#))
    }

    func testSnapshotCarriesCapturedAtProvenanceAndNotCollectedFields() throws {
        let capturedAt = Date(timeIntervalSince1970: 123)
        let builder = makeBuilder(
            audio: DiagnosticsCapabilityProbe.audioOutputSnapshot(outputs: []),
            date: capturedAt
        )

        let snapshot = builder.build(provenance: .preFailure)

        XCTAssertEqual(snapshot.capturedAt, DiagnosticsTimestamp.string(from: capturedAt))
        XCTAssertEqual(snapshot.provenance, .preFailure)
        XCTAssertEqual(snapshot.network, .object(["transport": .string("not_collected")]))
        try snapshot.validate()
    }

    private func makeBuilder(
        audio: DiagnosticsCapabilityProbe.AudioOutputSnapshot,
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> DeviceSnapshotBuilder {
        DeviceSnapshotBuilder(
            identityProvider: {
                AppleDeviceIdentity(id: "device-id", name: "Unit Test iPhone", platform: "iOS")
            },
            playbackSnapshotProvider: {
                DiagnosticsCapabilityProbe.Snapshot(
                    display: .object([
                        "mode": .string("not_collected"),
                        "hdr_types": .array([]),
                    ]),
                    videoCodecs: .string("not_collected"),
                    network: .object(["transport": .string("not_collected")])
                )
            },
            audioSnapshotProvider: { audio },
            dateProvider: { date },
            hardwareModelProvider: { "iPhone17,2" },
            osVersionProvider: { "26.0" },
            formFactorProvider: { "phone" }
        )
    }
}
