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
                ProgressView {
                    Text(.diagnosticsSummaryBuilding)
                }
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
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(summary.typeTitle)
                .font(.system(size: titleSize, weight: .semibold))
            if let crashSummary = summary.crashSummary {
                // The report's own crash text, sent as written.
                Text(verbatim: crashSummary)
                    .font(crashSummarySize.map { Font.system(size: $0) })
            }
            Text(.diagnosticsSummaryDeviceLine(summary.deviceIdentity))
            // Digits as before: a catalog number would group them ("1,234").
            Text(.diagnosticsSummaryLogsLine(
                "\(summary.lineCount)",
                AppLanguage.string(summary.categoriesDescription, locale: locale)
            ))
            Text(.diagnosticsSummaryDestinationLine(
                AppLanguage.string(summary.destinationServerName, locale: locale)
            ))
            Text(.diagnosticsReportExpiresRelative(
                summary.expiresAt.formatted(.relative(presentation: .named).locale(locale))
            ))
        }
    }
}
#endif
