#if os(iOS) || os(tvOS)
import AVFoundation
import Foundation

// Diagnostics-scoped capability probe feeding device.json snapshots.
// Deliberately named apart from the playback-protocol capability reporter
// (ApplePlaybackV3Capabilities, in flight on another branch); once that
// lands, DeviceSnapshotBuilder's providers can delegate to its
// outputSnapshot() internals instead of probing here.
enum DiagnosticsCapabilityProbe {
    struct Snapshot: Equatable {
        let display: DiagnosticsJSONValue
        let videoCodecs: DiagnosticsJSONValue
        let network: DiagnosticsJSONValue
    }

    struct AudioRouteOutput: Equatable {
        let portType: String
        let rawUID: String
        let portName: String?
        let channels: Int?
    }

    struct AudioOutputSnapshot: Equatable {
        let outputs: [DiagnosticsJSONValue]
        let passthrough: DiagnosticsJSONValue
        let suppressions: DiagnosticsJSONValue

        var jsonValue: DiagnosticsJSONValue {
            .object([
                "outputs": .array(outputs),
                "passthrough": passthrough,
                "suppressions": suppressions,
            ])
        }
    }

    static func snapshot(
        displayCapabilities: ApplePlaybackDisplayCapabilities = .probe()
    ) -> Snapshot {
        Snapshot(
            display: displaySnapshot(displayCapabilities),
            videoCodecs: videoCodecSnapshot(displayCapabilities),
            network: .object(["transport": .string("not_collected")])
        )
    }

    internal static func audioOutputSnapshot() -> AudioOutputSnapshot {
        #if !os(macOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
            AudioRouteOutput(
                portType: $0.portType.rawValue,
                rawUID: $0.uid,
                portName: $0.portName,
                channels: $0.channels?.count
            )
        }
        return audioOutputSnapshot(outputs: outputs)
        #else
        return AudioOutputSnapshot(outputs: [], passthrough: .string("not_collected"), suppressions: .string("not_collected"))
        #endif
    }

    internal static func audioOutputSnapshot(outputs: [AudioRouteOutput]) -> AudioOutputSnapshot {
        AudioOutputSnapshot(
            outputs: outputs.map { output in
                var payload: [String: DiagnosticsJSONValue] = [
                    "type": .string(output.portType),
                    "uid_hash": .string(hashedRouteUID(output.rawUID)),
                ]
                if let channels = output.channels {
                    payload["channels"] = .int(channels)
                }
                return .object(payload)
            },
            passthrough: .string("unknown"),
            suppressions: .string("not_collected")
        )
    }

    private static func displaySnapshot(_ capabilities: ApplePlaybackDisplayCapabilities) -> DiagnosticsJSONValue {
        var hdrTypes: [DiagnosticsJSONValue] = []
        if capabilities.supportsHDR10 { hdrTypes.append(.string("HDR10")) }
        if capabilities.supportsHLG { hdrTypes.append(.string("HLG")) }
        if capabilities.supportsDolbyVision { hdrTypes.append(.string("DV")) }

        return .object([
            "mode": .string("not_collected"),
            "modes_supported": .string("not_collected"),
            "hdr_types": .array(hdrTypes),
            "wide_gamut": .string("not_collected"),
            "max_resolution": capabilities.maxResolution.map { .string($0.rawValue) } ?? .string("unknown"),
            "supports_ten_bit": .bool(capabilities.supportsTenBit),
        ])
    }

    private static func videoCodecSnapshot(_ capabilities: ApplePlaybackDisplayCapabilities) -> DiagnosticsJSONValue {
        #if targetEnvironment(simulator)
        let codecs = ["video/avc"]
        let maxResolution = "1080p"
        let hdr = false
        #else
        let codecs = ["video/avc", "video/hevc"]
        let maxResolution = capabilities.maxResolution?.rawValue ?? "unknown"
        let hdr = capabilities.supportsHDR10 || capabilities.supportsHLG || capabilities.supportsDolbyVision
        #endif

        return .array(codecs.map { codec in
            .object([
                "mime": .string(codec),
                "hw": .string("unknown"),
                "profiles": .string("not_collected"),
                "max": .string(maxResolution),
                "hdr": .bool(hdr),
            ])
        })
    }

    private static func hashedRouteUID(_ uid: String) -> String {
        guard !uid.isEmpty else {
            return "unknown"
        }
        return DiagnosticsSHA256.shortHex(data: Data(uid.utf8), count: 16)
    }
}
#endif
