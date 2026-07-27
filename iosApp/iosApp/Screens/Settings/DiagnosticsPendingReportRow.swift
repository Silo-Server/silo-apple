#if os(iOS)
import SwiftUI

struct DiagnosticsPendingReportRow: View {
    let report: PendingReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(typeTitle)
                .foregroundStyle(Color.continuumOnSurface)

            Text(report.binding.capturedAtDate, format: .dateTime.month().day().hour().minute())
                .font(.footnote)
                .foregroundStyle(Color.continuumSecondaryText)

            Text("Expires \(expiryDate, format: .relative(presentation: .named))")
                .font(.footnote)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var expiryDate: Date {
        report.binding.capturedAtDate.addingTimeInterval(PendingReportStore.expiryInterval)
    }

    private var typeTitle: String {
        switch report.binding.type {
        case .crash, .nativeCrash:
            return "Crash"
        case .hang, .anr:
            return "Not Responding"
        case .abnormalExit:
            return "Unclean Shutdown"
        case .manual:
            return "Manual Report"
        }
    }
}
#endif
