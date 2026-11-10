#if os(tvOS)
import Foundation

struct TVControlStandbyState: Equatable {
    var controllerName: String?
    var serverName: String?
    /// Other controllers also waiting, besides `controllerName`.
    var otherControllerCount = 0

    /// The waiting controller's name, "iPhone" when it sent none.
    var displayName: String {
        controllerName.flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
    }

    /// The standby heading: "Ready for <name>", counting other waiting
    /// controllers.
    var heading: LocalizedStringResource {
        otherControllerCount > 0
            ? .castStandbyReadyForOthers(otherControllerCount, displayName)
            : .castStandbyReadyFor(displayName)
    }

    /// English label the standby tests check; the screen shows `heading`.
    var controllerLabel: String {
        let name = displayName
        switch otherControllerCount {
        case ...0: return name
        case 1: return "\(name) and 1 other device"
        default: return "\(name) and \(otherControllerCount) other devices"
        }
    }
}
#endif
