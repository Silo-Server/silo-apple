#if os(iOS) || os(tvOS)
import Foundation

enum DiagnosticsFeatureState: Equatable {
    case loading
    case available
    case disabledByServer
    case storageUnavailable
    case offline
    case permanentlyHidden

    var title: String {
        switch self {
        case .loading:
            return "Checking availability…"
        case .available:
            return "Available"
        case .disabledByServer:
            return "Disabled by server"
        case .storageUnavailable:
            return "Storage unavailable"
        case .offline:
            return "Offline"
        case .permanentlyHidden:
            return "Unavailable"
        }
    }

    var isUploadAvailable: Bool {
        self == .available
    }
}
#endif
