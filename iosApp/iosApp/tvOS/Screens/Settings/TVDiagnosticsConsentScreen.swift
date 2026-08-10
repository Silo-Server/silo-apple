#if os(tvOS)
import SwiftUI

struct TVDiagnosticsConsentScreen: View {
    @Bindable var model: DiagnosticsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var proposedMode: DiagnosticsConsentChoice?
    @FocusState private var focusedAction: Action?

    var body: some View {
        ZStack {
            SettingsBackdrop()

            VStack(alignment: .leading, spacing: 24) {
                Text("Crash Reports")
                    .font(.system(size: 48, weight: .bold))
                Text("Choose what Silo should do when a crash, hang, or unclean shutdown report is available.")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.continuumSecondaryText)

                Button("Cancel", action: dismiss.callAsFunction)
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focusedAction, equals: .cancel)

                Button("Ask") { select(.ask) }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focusedAction, equals: .ask)

                Button("Always") { proposedMode = .always }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focusedAction, equals: .always)

                Button("Never") { proposedMode = .never }
                    .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                    .focused($focusedAction, equals: .never)
            }
            .frame(maxWidth: 950, alignment: .leading)
            .disabled(proposedMode != nil)

            if proposedMode == .always {
                TVSettingsConfirmationOverlay(
                    title: "Always Send Crash Reports?",
                    message: "Any pending reports and future crash reports for this server account will be sent automatically.",
                    confirmTitle: "Always Send",
                    cancel: cancelConfirmation,
                    confirm: { confirm(.always) }
                )
                .zIndex(1)
            } else if proposedMode == .never {
                TVSettingsConfirmationOverlay(
                    title: "Turn Off Crash Reports?",
                    message: "Pending reports for this server account will be deleted.",
                    confirmTitle: "Turn Off and Delete",
                    cancel: cancelConfirmation,
                    confirm: { confirm(.never) }
                )
                .zIndex(1)
            }
        }
        .focusSection()
        .defaultFocus($focusedAction, .cancel, priority: .userInitiated)
        .onAppear { focusedAction = .cancel }
        .onExitCommand(perform: dismiss.callAsFunction)
    }

    private func select(_ mode: DiagnosticsConsentChoice) {
        Task {
            await model.setConsentMode(mode)
            dismiss()
        }
    }

    private func confirm(_ mode: DiagnosticsConsentChoice) {
        proposedMode = nil
        select(mode)
    }

    private func cancelConfirmation() {
        proposedMode = nil
        Task { @MainActor in
            await Task.yield()
            focusedAction = .cancel
        }
    }

    private enum Action: Hashable {
        case cancel
        case ask
        case always
        case never
    }
}
#endif
