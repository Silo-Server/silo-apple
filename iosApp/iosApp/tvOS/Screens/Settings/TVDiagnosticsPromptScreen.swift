#if os(tvOS)
import SwiftUI

struct TVDiagnosticsPromptScreen: View {
    let prompt: DiagnosticsPrompt
    @Bindable var model: DiagnosticsViewModel

    @State private var isReviewing = false
    @State private var showAlwaysConfirmation = false
    @FocusState private var focusedAction: Action?

    var body: some View {
        ZStack {
            SettingsBackdrop()

            VStack(alignment: .leading, spacing: 28) {
                Text(isReviewing ? "Report Summary" : prompt.title)
                    .font(.system(size: 48, weight: .bold))

                if isReviewing {
                    reviewContent
                } else {
                    Text(prompt.message)
                        .font(.system(size: 26))
                        .foregroundStyle(Color.continuumSecondaryText)
                        .frame(maxWidth: 1050, alignment: .leading)
                    if model.selectedDestination == .hosted {
                        Text(model.hostedPrivacyDisclosure)
                            .font(.body)
                            .foregroundStyle(Color.continuumSecondaryText.opacity(0.82))
                            .frame(maxWidth: 1050, alignment: .leading)
                    }
                }

                Spacer(minLength: 20)

                actionButtons
            }
            .padding(80)
            .disabled(showAlwaysConfirmation || model.isWorking)

            if showAlwaysConfirmation {
                TVSettingsConfirmationOverlay(
                    title: "Always Send Crash Reports?",
                    message: "These reports and future crash reports for this server account will be sent automatically.",
                    confirmTitle: "Always Send",
                    cancel: cancelAlwaysConfirmation,
                    confirm: confirmAlwaysSend
                )
                .zIndex(1)
            }
        }
        .focusSection()
        .defaultFocus($focusedAction, .dontSend, priority: .userInitiated)
        .onAppear { focusedAction = .dontSend }
        .onExitCommand(perform: handleExit)
    }

    private var reviewContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(prompt.reports) { report in
                    TVDiagnosticsReportSummaryCard(report: report, model: model)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 560)
    }

    private var actionButtons: some View {
        HStack(spacing: 18) {
            Button("Don't Send", action: model.declinePrompt)
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedAction, equals: .dontSend)

            Button(isReviewing ? "Back" : "View Report") {
                isReviewing.toggle()
                focusedAction = .dontSend
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($focusedAction, equals: .review)

            Button("Send") {
                Task { await model.sendPrompt(always: false) }
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($focusedAction, equals: .send)

            if model.allowsAlwaysSend {
                Button("Always Send") {
                    showAlwaysConfirmation = true
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedAction, equals: .always)
            }
        }
    }

    private func handleExit() {
        if isReviewing {
            isReviewing = false
            focusedAction = .dontSend
        } else {
            model.declinePrompt()
        }
    }

    private func cancelAlwaysConfirmation() {
        showAlwaysConfirmation = false
        Task { @MainActor in
            await Task.yield()
            focusedAction = .dontSend
        }
    }

    private func confirmAlwaysSend() {
        showAlwaysConfirmation = false
        Task { await model.sendPrompt(always: true) }
    }

    private enum Action: Hashable {
        case dontSend
        case review
        case send
        case always
    }
}
#endif
