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
                Text("Send Reports To")
                    .font(.largeTitle.bold())
                Text("Silo Diagnostics is the default and does not require diagnostics storage on your own server.")
                    .font(.title2)
                    .foregroundStyle(Color.siloSecondaryText)

                Button("Silo Diagnostics") {
                    select(.hosted)
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedDestination, equals: .hosted)

                Button("My Silo Server") {
                    select(.selfHosted)
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused($focusedDestination, equals: .selfHosted)

                Button("Cancel", action: dismiss.callAsFunction)
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
