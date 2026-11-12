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
                    NavigationLink {
                        DiagnosticsPromptReviewView(prompt: prompt, model: model)
                    } label: {
                        Text(.diagnosticsPromptViewReport)
                    }

                    Button(.diagnosticsConsentConfirm, systemImage: "paperplane.fill") {
                        Task { await model.sendPrompt(always: false) }
                    }
                    .disabled(model.isWorking)

                    // Inside the condition, so its confirmation closes and
                    // resets when Always Send stops being offered.
                    if model.allowsAlwaysSend {
                        DiagnosticsAlwaysSendButton(
                            model: model,
                            message: .diagnosticsAlwaysSendPromptMessageOne
                        )
                    }

                    Button(.diagnosticsPromptDontSendButton, role: .cancel, action: model.declinePrompt)
                        .disabled(model.isWorking)
                }

                if model.isWorking {
                    ProgressView {
                        Text(.diagnosticsPromptSending)
                    }
                }
            }
            .siloGroupedListStyle()
            .navigationTitle(Text(prompt.title))
        }
    }
}

/// "Always Send" and its confirmation, shared by the prompt sheet and its
/// report review.
struct DiagnosticsAlwaysSendButton: View {
    let model: DiagnosticsViewModel
    let message: LocalizedStringResource

    @State private var isConfirming = false

    var body: some View {
        Button(.diagnosticsAlwaysSendConfirm, systemImage: "checkmark.shield.fill") {
            isConfirming = true
        }
        .disabled(model.isWorking)
        .confirmationDialog(
            Text(.diagnosticsAlwaysSendConfirmTitle),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(.diagnosticsAlwaysSendConfirm) {
                Task { await model.sendPrompt(always: true) }
            }
            Button(.commonCancel, role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
#endif
