#if os(iOS)
import SwiftUI

struct DiagnosticsPromptSheet: View {
    let prompt: DiagnosticsPrompt
    let model: DiagnosticsViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(prompt.message)

                    if model.selectedDestination == .hosted {
                        Text(model.hostedPrivacyDisclosure)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink("View Report") {
                        DiagnosticsPromptReviewView(prompt: prompt, model: model)
                    }

                    Button("Send", systemImage: "paperplane.fill") {
                        Task { await model.sendPrompt(always: false) }
                    }
                    .disabled(model.isWorking)

                    // Inside the condition, so its confirmation closes and
                    // resets when Always Send stops being offered.
                    if model.allowsAlwaysSend {
                        DiagnosticsAlwaysSendButton(
                            model: model,
                            message: "This report and future crash reports for this server account will be sent automatically."
                        )
                    }

                    Button("Don't Send", role: .cancel, action: model.declinePrompt)
                        .disabled(model.isWorking)
                }

                if model.isWorking {
                    ProgressView("Sending diagnostics…")
                }
            }
            .siloGroupedListStyle()
            .navigationTitle(prompt.title)
        }
    }
}

/// "Always Send" and its confirmation, shared by the prompt sheet and its
/// report review.
struct DiagnosticsAlwaysSendButton: View {
    let model: DiagnosticsViewModel
    let message: String

    @State private var isConfirming = false

    var body: some View {
        Button("Always Send", systemImage: "checkmark.shield.fill") {
            isConfirming = true
        }
        .disabled(model.isWorking)
        .confirmationDialog(
            "Always Send Crash Reports?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Always Send") {
                Task { await model.sendPrompt(always: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
#endif
