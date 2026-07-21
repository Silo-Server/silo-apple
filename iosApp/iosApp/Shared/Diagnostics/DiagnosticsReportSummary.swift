#if os(iOS) || os(tvOS)
import Foundation

struct DiagnosticsReportSummary: Identifiable, Equatable {
    let reportID: UUID
    let type: ReportType
    let capturedAt: Date
    let expiresAt: Date
    let crashSummary: String?
    let deviceIdentity: String
    let categories: [DiagnosticsLogCategory]
    let lineCount: Int
    let destinationServerName: String

    var id: UUID { reportID }

    var typeTitle: String {
        switch type {
        case .crash, .nativeCrash:
            return "Crash"
        case .hang, .anr:
            return "Not responding"
        case .abnormalExit:
            return "Unclean shutdown"
        case .manual:
            return "Manual report"
        }
    }

    var categoriesDescription: String {
        guard !categories.isEmpty else {
            return "Basic diagnostic logs"
        }
        return categories.map(\.rawValue).joined(separator: ", ")
    }
}
#endif
