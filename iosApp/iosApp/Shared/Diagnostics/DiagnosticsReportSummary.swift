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
    let destinationServerName: LocalizedStringResource

    var id: UUID { reportID }

    var typeTitle: LocalizedStringResource {
        switch type {
        case .crash, .nativeCrash:
            return .diagnosticsReportTypeCrash
        case .hang, .anr:
            return .diagnosticsSummaryTypeNotResponding
        case .abnormalExit:
            return .diagnosticsSummaryTypeUncleanShutdown
        case .manual:
            return .diagnosticsSummaryTypeManual
        }
    }

    /// The log categories by their identifiers, which stay as written.
    var categoriesDescription: LocalizedStringResource {
        guard !categories.isEmpty else {
            return .diagnosticsSummaryBasicLogs
        }
        return .verbatim(categories.map(\.rawValue).joined(separator: ", "))
    }
}

extension ReportType {
    /// The report's title in Settings lists and report details.
    var listTitle: LocalizedStringResource {
        switch self {
        case .crash, .nativeCrash:
            return .diagnosticsReportTypeCrash
        case .hang, .anr:
            return .diagnosticsReportTypeNotResponding
        case .abnormalExit:
            return .diagnosticsReportTypeUncleanShutdown
        case .manual:
            return .diagnosticsReportTypeManual
        }
    }
}
#endif
