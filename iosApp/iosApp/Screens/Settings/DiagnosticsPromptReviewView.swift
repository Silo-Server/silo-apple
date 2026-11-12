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
                Button(.diagnosticsConsentConfirm, systemImage: "paperplane.fill") {
                    Task { await model.sendPrompt(always: false) }
                }
                .disabled(model.isWorking)

                DiagnosticsAlwaysSendButton(
                    model: model,
                    message: .diagnosticsAlwaysSendPromptMessageMany
                )

                Button(.diagnosticsPromptDontSendButton, role: .cancel, action: model.declinePrompt)
                    .disabled(model.isWorking)
            }
        }
        .siloGroupedListStyle()
        .navigationTitle(Text(.diagnosticsSummaryTitle))
    }
}
#endif
