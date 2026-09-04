#if os(iOS) || os(tvOS)
import AVFoundation
import Foundation

// Diagnostics-scoped capability probe feeding device.json snapshots.
// Deliberately named apart from the playback-protocol capability reporter
// (ApplePlaybackV3Capabilities); both use the same live AVPlayer output facts,
// while this payload also records diagnostic-only device sections.
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
        displayCapabilities: ApplePlaybackDisplayCapabilities = .probe(),
        videoCapabilityMode requestedMode: AppleDecodeCapabilities.StreamingVideoCapabilityMode? = nil
    ) -> Snapshot {
        let videoCapabilityMode = requestedMode ?? AppleDecodeCapabilities.streamingVideoCapabilityMode
        return Snapshot(
            display: displaySnapshot(displayCapabilities),
            videoCodecs: videoCodecSnapshot(
                displayCapabilities,
                videoCapabilityMode: videoCapabilityMode
            ),
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
            "hdr_output_eligible": .bool(capabilities.hdrPlaybackEligible),
            "hdr_types": .array(hdrTypes),
            "wide_gamut": .string("not_collected"),
            "max_resolution": capabilities.maxResolution.map { .string($0.rawValue) } ?? .string("unknown"),
            "supports_ten_bit": .bool(capabilities.supportsTenBit),
        ])
    }

    private static func videoCodecSnapshot(
        _ capabilities: ApplePlaybackDisplayCapabilities,
        videoCapabilityMode: AppleDecodeCapabilities.StreamingVideoCapabilityMode
    ) -> DiagnosticsJSONValue {
        // Which codecs is the shared client answer; the rest of each entry is
        // this probe's own. Declared evidence intentionally carries no
        // per-codec performance or HDR prediction: the display section still
        // records panel facts, while Aether probes the exact source at load.
        let codecs = AppleDecodeCapabilities.streamingVideoCodecs(
            for: videoCapabilityMode
        ).map(diagnosticsMIME(for:))
        let maxResolution: DiagnosticsJSONValue
        let hdr: DiagnosticsJSONValue
        if videoCapabilityMode == .aetherDeclared {
            maxResolution = .string("not_collected")
            hdr = .string("not_collected")
        } else {
            #if targetEnvironment(simulator)
            maxResolution = .string("1080p")
            hdr = .bool(false)
            #else
            maxResolution = .string(capabilities.maxResolution?.rawValue ?? "unknown")
            hdr = .bool(
                capabilities.supportsHDR10
                    || capabilities.supportsHLG
                    || capabilities.supportsDolbyVision
            )
            #endif
        }

        return .array(codecs.map { codec in
            .object([
                "mime": .string(codec),
                "hw": .string("unknown"),
                "profiles": .string("not_collected"),
                "max": maxResolution,
                "hdr": hdr,
            ])
        })
    }

    /// device.json reports codecs as MIME types (the schema is shared with
    /// the Android client, which gets them from MediaCodec).
    private static func diagnosticsMIME(for codec: String) -> String {
        switch codec {
        case "h264": return "video/avc"
        case "hevc": return "video/hevc"
        default: return "video/\(codec)"
        }
    }

    private static func hashedRouteUID(_ uid: String) -> String {
        guard !uid.isEmpty else {
            return "unknown"
        }
        return DiagnosticsSHA256.shortHex(data: Data(uid.utf8), count: 16)
    }
}
#endif
