#if os(iOS)
import SwiftUI

struct DiagnosticsReportDetailView: View {
    let report: PendingReport
    @Bindable var model: DiagnosticsViewModel

    @State private var summary: DiagnosticsReportSummary?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let summary {
                DiagnosticsReportSummarySections(summary: summary)
            } else {
                ProgressView("Building report summary…")
            }

            Section {
                Button("Send Report", systemImage: "paperplane.fill") {
                    Task {
                        await model.send(report)
                        dismiss()
                    }
                }
                .disabled(!model.featureState.isUploadAvailable || model.isWorking)

                Button("Delete Report", systemImage: "trash", role: .destructive) {
                    Task {
                        await model.delete(report)
                        dismiss()
                    }
                }
                .disabled(model.isWorking)
            }
        }
        .continuumGroupedListStyle()
        .navigationTitle("Report Details")
        .task {
            summary = await model.summary(for: report)
        }
    }
}
#endif
