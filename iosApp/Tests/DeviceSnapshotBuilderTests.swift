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

    func testSnapshotOmitsDeviceNameAndStableDeviceID() throws {
        let snapshot = makeBuilder(
            audio: DiagnosticsCapabilityProbe.audioOutputSnapshot(outputs: [])
        ).build(provenance: .preFailure)
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(snapshot)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("Unit Test iPhone"))
        XCTAssertFalse(encoded.contains("device-id"))
        XCTAssertFalse(encoded.contains(#""device""#))
        XCTAssertFalse(encoded.contains(#""device_id""#))
    }

    func testCapabilityProbeRecordsCurrentHDRPlaybackModes() {
        let snapshot = DiagnosticsCapabilityProbe.snapshot(
            displayCapabilities: ApplePlaybackDisplayCapabilities(
                hdrPlaybackEligible: true,
                supportsDolbyVision: true,
                supportsHDR10: true,
                supportsHLG: false,
                supportsAtmos: false,
                maxResolution: nil,
                supportsTenBit: true
            )
        )

        guard case .object(let display) = snapshot.display else {
            return XCTFail("display snapshot was not an object")
        }
        XCTAssertEqual(display["hdr_output_eligible"], .bool(true))
        XCTAssertEqual(display["hdr_types"], .array([.string("HDR10"), .string("DV")]))
        XCTAssertEqual(display["supports_ten_bit"], .bool(true))
    }

    func testDeclaredEngineDiagnosticsDoNotInventPerCodecDisplayFacts() {
        let snapshot = DiagnosticsCapabilityProbe.snapshot(
            displayCapabilities: ApplePlaybackDisplayCapabilities(
                hdrPlaybackEligible: true,
                supportsDolbyVision: true,
                supportsHDR10: true,
                supportsHLG: true,
                supportsAtmos: false,
                maxResolution: .uhd4K,
                supportsTenBit: true
            ),
            videoCapabilityMode: .aetherDeclared
        )

        guard case .array(let codecs) = snapshot.videoCodecs else {
            return XCTFail("video codec diagnostics were not an array")
        }
        XCTAssertEqual(codecs.count, AppleDecodeCapabilities.aetherOriginalHTTPVideoCodecs.count)
        for codec in codecs {
            guard case .object(let fields) = codec else {
                return XCTFail("video codec diagnostic was not an object")
            }
            XCTAssertEqual(fields["max"], .string("not_collected"))
            XCTAssertEqual(fields["hdr"], .string("not_collected"))
        }
    }

    private func makeBuilder(
        audio: DiagnosticsCapabilityProbe.AudioOutputSnapshot,
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> DeviceSnapshotBuilder {
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
