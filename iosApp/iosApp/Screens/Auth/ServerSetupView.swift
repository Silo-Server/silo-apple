import SwiftUI

#if !os(tvOS)
/// First screen when no server is configured. A single centered glass form —
/// no phone-pairing card, because on iPhone the
/// phone *is* the companion (the pairing card auto-overlays from `ContentView`
/// when a TV is nearby). Protocol + port stay tucked under "Advanced options".
struct ServerSetupView: View {
    var router: AppRouter
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case host, port }

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            SiloWordmarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

            AuroraJourneyProgress(currentStep: 1)
                .frame(maxWidth: 330)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 30)

            VStack(spacing: 10) {
                AuroraEyebrow(text: "Connect", centered: true)
                Text("Where is your Silo server?")
                    .font(.siloTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text("Enter the address you use to open Silo in a browser.")
                    .font(.siloBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                AuroraTextField(
                    label: "Server address",
                    text: $viewModel.host,
                    placeholder: "silo.example.com",
                    focus: $focusedField,
                    equals: .host,
                    contentType: .url,
                    keyboard: .url,
                    submitLabel: .go,
                    onSubmit: { connect() }
                )

                Label("Silo tries secure HTTPS automatically.", systemImage: "lock.shield")
                    .font(.siloCaption)
                    .foregroundStyle(Color.auroraInkSecondary)

                advancedDisclosure

                if let error = viewModel.error {
                    AuroraErrorLabel(error)
                }

                Button {
                    connect()
                } label: {
                    Text(viewModel.isLoading ? "Connecting…" : "Connect")
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
                .disabled(viewModel.isLoading)
                .padding(.top, 4)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        }
    }

    private func connect() {
        guard !viewModel.isLoading else { return }
        Task { await viewModel.connect(router: router) }
    }

    @ViewBuilder
    private var advancedDisclosure: some View {
        Button {
            withAnimation(SiloTheme.springAnimation) {
                viewModel.showsAdvancedOptions.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Text("Protocol and port")
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuroraGhostButtonStyle())

        if viewModel.showsAdvancedOptions {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    AuroraFieldLabel("Protocol")
                    HStack(spacing: 8) {
                        ForEach(ServerSetupScheme.allCases) { scheme in
                            Button {
                                viewModel.selectedScheme = scheme
                            } label: {
                                AuroraSegment(
                                    title: scheme.rawValue,
                                    isSelected: viewModel.selectedScheme == scheme,
                                    isFocused: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                AuroraTextField(
                    label: "Port",
                    text: $viewModel.port,
                    placeholder: "8096",
                    focus: $focusedField,
                    equals: .port,
                    keyboard: .number
                )
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
#endif
