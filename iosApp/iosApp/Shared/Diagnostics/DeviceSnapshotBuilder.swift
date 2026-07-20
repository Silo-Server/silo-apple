#if os(iOS) || os(tvOS)
import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct DeviceSnapshotBuilder {
    var identityProvider: () -> AppleDeviceIdentity = { AppleDeviceIdentity.current }
    var playbackSnapshotProvider: () -> DiagnosticsCapabilityProbe.Snapshot = {
        DiagnosticsCapabilityProbe.snapshot()
    }
    var audioSnapshotProvider: () -> DiagnosticsCapabilityProbe.AudioOutputSnapshot = {
        DiagnosticsCapabilityProbe.audioOutputSnapshot()
    }
    var dateProvider: () -> Date = { Date() }
    var hardwareModelProvider: () -> String = { DeviceSnapshotBuilder.hardwareModel() }
    var osVersionProvider: () -> String = { DeviceSnapshotBuilder.osVersion() }
    var formFactorProvider: () -> String = { DeviceSnapshotBuilder.formFactor() }

    static let live = DeviceSnapshotBuilder()

    func build(provenance: Provenance) -> DeviceSnapshotPayload {
        let identity = identityProvider()
        let playback = playbackSnapshotProvider()
        let audio = audioSnapshotProvider()

        return DeviceSnapshotPayload(
            capturedAt: DiagnosticsTimestamp.string(from: dateProvider()),
            provenance: provenance,
            identity: .object([
                "manufacturer": .string("Apple"),
                "model": .string(hardwareModelProvider()),
                "device": .string(identity.name),
                "form_factor": .string(formFactorProvider()),
                "device_id": .string(identity.id),
                "platform": .string(identity.platform),
            ]),
            display: playback.display,
            audio: audio.jsonValue,
            videoCodecs: playback.videoCodecs,
            network: playback.network
        )
    }

    func deviceSummary(from snapshot: DeviceSnapshotPayload) -> DiagnosticsManifest.DeviceSummary {
        DiagnosticsManifest.DeviceSummary(
            manufacturer: snapshot.identity.stringValue(for: "manufacturer") ?? "Apple",
            model: snapshot.identity.stringValue(for: "model") ?? hardwareModelProvider(),
            os: osVersionProvider(),
            formFactor: snapshot.identity.stringValue(for: "form_factor") ?? formFactorProvider()
        )
    }

    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, child in
            guard let value = child.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        if !identifier.isEmpty {
            return identifier
        }
        #if os(tvOS)
        return "Apple TV"
        #else
        return "Apple Device"
        #endif
    }

    private static func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private static func formFactor() -> String {
        #if os(tvOS)
        return "tv"
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "phone"
        case .pad:
            return "tablet"
        default:
            return "mobile"
        }
        #else
        return "not_collected"
        #endif
    }
}

private extension DiagnosticsJSONValue {
    func stringValue(for key: String) -> String? {
        guard case .object(let object) = self,
              case .string(let value)? = object[key] else {
            return nil
        }
        return value
    }
}
#endif
