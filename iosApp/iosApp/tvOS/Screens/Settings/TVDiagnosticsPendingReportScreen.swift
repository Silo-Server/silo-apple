#if os(tvOS)
import SwiftUI

struct TVDiagnosticsPendingReportScreen: View {
    let report: PendingReport
    @Bindable var model: DiagnosticsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var summary: DiagnosticsReportSummary?
    @State private var showDeleteConfirmation = false
    @FocusState private var focusedAction: Action?

    var body: some View {
        ZStack {
            SettingsBackdrop()

            VStack(alignment: .leading, spacing: 28) {
                Text("Report Details")
                    .font(.system(size: 48, weight: .bold))

                if let summary {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(summary.typeTitle)
                            .font(.system(size: 32, weight: .semibold))
                        if let crashSummary = summary.crashSummary {
                            Text(crashSummary)
                        }
                        Text("Device: \(summary.deviceIdentity)")
                        Text("Logs: \(summary.lineCount) lines · \(summary.categoriesDescription)")
                        Text("Destination: \(summary.destinationServerName)")
                        Text("Expires \(summary.expiresAt, format: .relative(presentation: .named))")
                    }
                    .font(.system(size: 23))
                    .foregroundStyle(Color.siloSecondaryText)
                } else {
                    ProgressView("Building report summary…")
                }

                Spacer()

                HStack(spacing: 18) {
                    Button("Cancel", action: dismiss.callAsFunction)
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .focused($focusedAction, equals: .cancel)

                    Button("Send Report") {
                        Task {
                            await model.send(report)
                            dismiss()
                        }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .disabled(!model.featureState.isUploadAvailable || model.isWorking)
                    .focused($focusedAction, equals: .send)

                    Button("Delete Report") { showDeleteConfirmation = true }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                        .disabled(model.isWorking)
                        .focused($focusedAction, equals: .delete)
                }
            }
            .padding(80)
            .disabled(showDeleteConfirmation)

            if showDeleteConfirmation {
                TVSettingsConfirmationOverlay(
                    title: "Delete Report?",
                    message: "This pending diagnostics report cannot be recovered.",
                    confirmTitle: "Delete",
                    cancel: cancelDelete,
                    confirm: deleteReport
                )
                .zIndex(1)
            }
        }
        .focusSection()
        .defaultFocus($focusedAction, .cancel, priority: .userInitiated)
        .onAppear { focusedAction = .cancel }
        .onExitCommand(perform: dismiss.callAsFunction)
        .task { summary = await model.summary(for: report) }
    }

    private func cancelDelete() {
        showDeleteConfirmation = false
        Task { @MainActor in
            await Task.yield()
            focusedAction = .cancel
        }
    }

    private func deleteReport() {
        showDeleteConfirmation = false
        Task {
            await model.delete(report)
            dismiss()
        }
    }

    private enum Action: Hashable {
        case cancel
        case send
        case delete
    }
}
#endif
