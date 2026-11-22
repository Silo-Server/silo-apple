#if os(iOS) || os(tvOS)
import Foundation

enum DiagnosticsFeatureState: Equatable {
    case loading
    case available
    case disabledByServer
    case storageUnavailable
    case offline
    case permanentlyHidden

    var title: LocalizedStringResource {
        switch self {
        case .loading:
            return .diagnosticsAvailabilityChecking
        case .available:
            return .diagnosticsAvailabilityAvailable
        case .disabledByServer:
            return .diagnosticsAvailabilityDisabled
        case .storageUnavailable:
            return .diagnosticsAvailabilityStorageUnavailable
        case .offline:
            return .diagnosticsAvailabilityOffline
        case .permanentlyHidden:
            return .diagnosticsAvailabilityIneligible
        }
    }

    var isUploadAvailable: Bool {
        self == .available
    }
}
#endif
