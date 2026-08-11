#if os(iOS)
import SwiftUI

struct DiagnosticsPromptSheet: View {
    let prompt: DiagnosticsPrompt
    @Bindable var model: DiagnosticsViewModel

    @State private var showAlwaysConfirmation = false

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

                    if model.allowsAlwaysSend {
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
                            Text("This report and future crash reports for this server account will be sent automatically.")
                        }
                    }

                    Button("Don't Send", role: .cancel, action: model.declinePrompt)
                        .disabled(model.isWorking)
                }

                if model.isWorking {
                    ProgressView("Sending diagnostics…")
                }
            }
            .continuumGroupedListStyle()
            .navigationTitle(prompt.title)
        }
    }
}
#endif
