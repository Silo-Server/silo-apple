#if os(iOS) || os(tvOS)
import Foundation

struct DeviceSnapshotPayload: Codable, Equatable {
    let capturedAt: String
    let provenance: Provenance
    let identity: DiagnosticsJSONValue
    let display: DiagnosticsJSONValue
    let audio: DiagnosticsJSONValue
    let videoCodecs: DiagnosticsJSONValue
    let network: DiagnosticsJSONValue

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case provenance
        case identity
        case display
        case audio
        case videoCodecs = "video_codecs"
        case network
    }

    func validate() throws {
        guard !capturedAt.isEmpty else {
            throw DiagnosticsValidationError.invalidField("device.captured_at")
        }
        guard provenance == .preFailure || provenance == .postRestart else {
            throw DiagnosticsValidationError.invalidField("device.provenance")
        }
        guard identity.isDiagnosticsTriStateObject else {
            throw DiagnosticsValidationError.invalidField("device.identity")
        }
        guard display.isDiagnosticsTriStateObject else {
            throw DiagnosticsValidationError.invalidField("device.display")
        }
        guard audio.isDiagnosticsTriStateObject else {
            throw DiagnosticsValidationError.invalidField("device.audio")
        }
        guard videoCodecs.isDiagnosticsArrayOrSentinel else {
            throw DiagnosticsValidationError.invalidField("device.video_codecs")
        }
        guard network.isDiagnosticsTriStateObject else {
            throw DiagnosticsValidationError.invalidField("device.network")
        }
    }
}

private extension DiagnosticsJSONValue {
    var isDiagnosticsTriStateObject: Bool {
        if case .object = self {
            return true
        }
        return isDiagnosticsSentinel
    }

    var isDiagnosticsArrayOrSentinel: Bool {
        if case .array = self {
            return true
        }
        return isDiagnosticsSentinel
    }

    var isDiagnosticsSentinel: Bool {
        guard case .string(let value) = self else {
            return false
        }
        return value == "unknown" || value == "not_collected"
    }
}
#endif
