#if os(iOS)
import SwiftUI

struct DiagnosticsPromptReviewView: View {
    let prompt: DiagnosticsPrompt
    let model: DiagnosticsViewModel

    var body: some View {
        List {
            ForEach(prompt.reports) { report in
                DiagnosticsPromptReportSummaryView(report: report, model: model)
            }

            Section {
                Button("Send", systemImage: "paperplane.fill") {
                    Task { await model.sendPrompt(always: false) }
                }
                .disabled(model.isWorking)

                DiagnosticsAlwaysSendButton(
                    model: model,
                    message: "These reports and future crash reports for this server account will be sent automatically."
                )

                Button("Don't Send", role: .cancel, action: model.declinePrompt)
                    .disabled(model.isWorking)
            }
        }
        .siloGroupedListStyle()
        .navigationTitle("Report Summary")
    }
}
#endif
