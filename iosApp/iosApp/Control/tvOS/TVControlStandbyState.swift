#if os(tvOS)
import Foundation

struct TVControlStandbyState: Equatable {
    var controllerName: String?
    var serverName: String?
    /// Other controllers also waiting, besides `controllerName`.
    var otherControllerCount = 0

    var controllerLabel: String {
        let name = controllerName.flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
        switch otherControllerCount {
        case ...0: return name
        case 1: return "\(name) and 1 other device"
        default: return "\(name) and \(otherControllerCount) other devices"
        }
    }
}
#endif
