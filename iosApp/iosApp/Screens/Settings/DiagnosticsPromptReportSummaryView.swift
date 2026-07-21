#if os(iOS)
import SwiftUI

struct DiagnosticsPromptReportSummaryView: View {
    let report: PendingReport
    let model: DiagnosticsViewModel

    @State private var summary: DiagnosticsReportSummary?

    var body: some View {
        Group {
            if let summary {
                DiagnosticsReportSummarySections(summary: summary)
            } else {
                Section {
                    ProgressView("Building report summary…")
                }
            }
        }
        .task {
            summary = await model.summary(for: report)
        }
    }
}
#endif
