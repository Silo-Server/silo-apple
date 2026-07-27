#if os(iOS)
import SwiftUI

struct DiagnosticsReportSummarySections: View {
    let summary: DiagnosticsReportSummary

    var body: some View {
        Section("Incident") {
            LabeledContent("Type", value: summary.typeTitle)
            LabeledContent("Captured") {
                Text(summary.capturedAt, format: .dateTime.month().day().year().hour().minute())
            }
            LabeledContent("Expires") {
                Text(summary.expiresAt, format: .dateTime.month().day().year().hour().minute())
            }
            if let crashSummary = summary.crashSummary {
                Text(crashSummary)
                    .textSelection(.enabled)
            }
        }

        Section("Contents") {
            LabeledContent("Device", value: summary.deviceIdentity)
            LabeledContent("Log Categories", value: summary.categoriesDescription)
            LabeledContent("Log Lines", value: "\(summary.lineCount)")
            LabeledContent("Destination", value: summary.destinationServerName)
        }
    }
}
#endif
