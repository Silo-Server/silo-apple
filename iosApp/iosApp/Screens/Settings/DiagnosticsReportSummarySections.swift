#if os(iOS)
import SwiftUI

struct DiagnosticsReportSummarySections: View {
    let summary: DiagnosticsReportSummary

    var body: some View {
        Section {
            LabeledContent {
                Text(summary.typeTitle)
            } label: {
                Text(.diagnosticsSummaryType)
            }
            .accessibilityElement(children: .combine)
            LabeledContent {
                Text(summary.capturedAt, format: .dateTime.month().day().year().hour().minute())
            } label: {
                Text(.diagnosticsSummaryCaptured)
            }
            LabeledContent {
                Text(summary.expiresAt, format: .dateTime.month().day().year().hour().minute())
            } label: {
                Text(.diagnosticsReportExpires)
            }
            if let crashSummary = summary.crashSummary {
                // The report's own crash text, sent as written.
                Text(verbatim: crashSummary)
                    .textSelection(.enabled)
            }
        } header: {
            Text(.diagnosticsSummaryIncident)
        }

        Section {
            LabeledContent {
                Text(verbatim: summary.deviceIdentity)
            } label: {
                Text(.diagnosticsSummaryDevice)
            }
            .accessibilityElement(children: .combine)
            LabeledContent {
                Text(summary.categoriesDescription)
            } label: {
                Text(.diagnosticsSummaryLogCategories)
            }
            .accessibilityElement(children: .combine)
            LabeledContent {
                Text(verbatim: "\(summary.lineCount)")
            } label: {
                Text(.diagnosticsSummaryLogLines)
            }
            .accessibilityElement(children: .combine)
            LabeledContent {
                Text(summary.destinationServerName)
            } label: {
                Text(.diagnosticsRowDestination)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text(.diagnosticsSummaryContents)
        }
    }
}
#endif
