#if os(tvOS)
import SwiftUI

struct TVDiagnosticsDestinationScreen: View {
    @Bindable var model: DiagnosticsViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedDestination: DiagnosticsDestinationChoice?

    var body: some View {
        ZStack {
            SettingsBackdrop()

            VStack(alignment: .leading, spacing: 24) {
                Text(.diagnosticsRowSendReportsTo)
                    .font(.largeTitle.bold())
                Text(.diagnosticsDestinationHostedDefaultDescription)
                    .font(.title2)
                    .foregroundStyle(Color.siloSecondaryText)

                Button(.diagnosticsDestinationHosted) {
                    select(.hosted)
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedDestination, equals: .hosted)

                Button(.diagnosticsDestinationMyServer) {
                    select(.selfHosted)
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedDestination, equals: .selfHosted)

                Button(.commonCancel, action: dismiss.callAsFunction)
                    .buttonStyle(TVSettingsPaneRowStyle())
            }
            .frame(maxWidth: 950, alignment: .leading)
        }
        .focusSection()
        .defaultFocus($focusedDestination, model.selectedDestination, priority: .userInitiated)
        .onAppear { focusedDestination = model.selectedDestination }
        .onExitCommand(perform: dismiss.callAsFunction)
    }

    private func select(_ destination: DiagnosticsDestinationChoice) {
        Task {
            await model.setDestination(destination)
            dismiss()
        }
    }
}
#endif
