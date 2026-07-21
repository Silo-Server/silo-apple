#if os(iOS)
import SwiftUI

struct DiagnosticsPromptReviewView: View {
    let prompt: DiagnosticsPrompt
    @Bindable var model: DiagnosticsViewModel

    @State private var showAlwaysConfirmation = false

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

                Button("Always Send", systemImage: "checkmark.shield.fill") {
                    showAlwaysConfirmation = true
                }
                .disabled(model.isWorking)
                .confirmationDialog(
                    "Always Send Crash Reports?",
                    isPresented: $showAlwaysConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Always Send") {
                        Task { await model.sendPrompt(always: true) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("These reports and future crash reports for this server account will be sent automatically.")
                }

                Button("Don't Send", role: .cancel, action: model.declinePrompt)
            }
        }
        .continuumGroupedListStyle()
        .navigationTitle("Report Summary")
    }
}
#endif
