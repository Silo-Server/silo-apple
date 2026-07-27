#if os(tvOS)
import SwiftUI

struct TVDiagnosticsReportSummaryCard: View {
    let report: PendingReport
    let model: DiagnosticsViewModel

    @State private var summary: DiagnosticsReportSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary {
                Text(summary.typeTitle)
                    .font(.system(size: 28, weight: .semibold))
                if let crashSummary = summary.crashSummary {
                    Text(crashSummary)
                        .font(.system(size: 21))
                }
                Text("Device: \(summary.deviceIdentity)")
                Text("Logs: \(summary.lineCount) lines · \(summary.categoriesDescription)")
                Text("Destination: \(summary.destinationServerName)")
                Text("Expires \(summary.expiresAt, format: .relative(presentation: .named))")
            } else {
                ProgressView("Building report summary…")
            }
        }
        .font(.system(size: 20))
        .foregroundStyle(Color.continuumOnSurface)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.continuumChromeRestingFill, in: .rect(cornerRadius: 14))
        .task {
            summary = await model.summary(for: report)
        }
    }
}
#endif
