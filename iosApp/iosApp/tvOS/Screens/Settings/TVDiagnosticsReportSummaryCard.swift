#if os(tvOS)
import SwiftUI

struct TVDiagnosticsReportSummaryCard: View {
    let report: PendingReport
    let model: DiagnosticsViewModel

    @State private var summary: DiagnosticsReportSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary {
                TVDiagnosticsSummaryLines(
                    summary: summary,
                    spacing: 10,
                    titleSize: 28,
                    crashSummarySize: 21
                )
            } else {
                ProgressView("Building report summary…")
            }
        }
        .font(.system(size: 20))
        .foregroundStyle(Color.siloOnSurface)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siloChromeRestingFill, in: .rect(cornerRadius: 14))
        .task {
            summary = await model.summary(for: report)
        }
    }
}

/// Report type, crash summary, device, logs, destination, and expiry, shared
/// by the Settings card and the report details screen.
struct TVDiagnosticsSummaryLines: View {
    let summary: DiagnosticsReportSummary
    let spacing: CGFloat
    let titleSize: CGFloat
    /// Nil inherits the surrounding font.
    var crashSummarySize: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(summary.typeTitle)
                .font(.system(size: titleSize, weight: .semibold))
            if let crashSummary = summary.crashSummary {
                Text(crashSummary)
                    .font(crashSummarySize.map { Font.system(size: $0) })
            }
            Text("Device: \(summary.deviceIdentity)")
            Text("Logs: \(summary.lineCount) lines · \(summary.categoriesDescription)")
            Text("Destination: \(summary.destinationServerName)")
            Text("Expires \(summary.expiresAt, format: .relative(presentation: .named))")
        }
    }
}
#endif
