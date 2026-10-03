#if os(tvOS)
import SwiftUI

/// First-run server setup on tvOS. The screen advertises on the LAN the
/// moment it appears, so the lead path is a nearby phone or tablet setting this TV up
/// with nothing to type. Typing the address is one button away. When a phone
/// connects, the same screen swaps in place to the pairing screens.
struct TVServerSetupView: View {
    var router: AppRouter
    /// The route this screen was built for. Nearby advertising stops once the
    /// app leaves it (see `TVPairingAdvertiser.advertise`).
    private let route: AppRouter.AuthState

    init(router: AppRouter) {
        self.router = router
        route = router.authState
    }

    @State private var viewModel = ServerSetupViewModel()
    @State private var advertiser = TVPairingAdvertiser()
    @State private var coordinator = ReceiverPairingCoordinator()
    @State private var discovery = ServerDiscovery()
    @State private var isEnteringAddress = false
    @FocusState private var focusedField: Field?
    /// Where focus goes once the system keyboard closes after Done.
    @State private var focusAfterKeyboard: Field?

    private enum Field: Hashable {
        case enterAddress
        case host
        case advanced
        case scheme(ServerSetupScheme)
        case port
        case connect
        case back
    }

    /// True once a phone is on the line; the screen hands over to the pairing screens.
    private var isPairing: Bool {
        if case .idle = coordinator.state { return false }
        return true
    }

    private static var tvName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "Apple TV" : name
    }

    var body: some View {
        ZStack {
            if isPairing {
                TVPairingReceiverView(coordinator: coordinator, advance: {
                    router.skipsSingleProfilePicker = true
                    router.showProfileSelection()
                })
                    .transition(.opacity)
            } else if isEnteringAddress {
                manualEntry
                    .transition(.opacity)
            } else {
                phoneFirst
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.32), value: isPairing)
        .animation(.easeOut(duration: 0.32), value: isEnteringAddress)
        .onAppear {
            MarqueeScene.shared.showGeneric()
            discovery.start()
        }
        .task { await advertise() }
        .onChange(of: coordinator.state) { _, state in
            // Only accept a new phone once the panel is back to the idle
            // chooser. Releasing on terminal states (completed/failed) would
            // let a second phone connect and clobber the summary the user is
            // still reading.
            if case .idle = state { advertiser.release() }
        }
        .onDisappear {
            discovery.stop()
            advertiser.stop()
            Task { await coordinator.cancel() }
        }
        .alert(
            "Connect without encryption?",
            isPresented: Binding(
                get: { viewModel.insecurePrompt != nil },
                set: { if !$0 { viewModel.dismissInsecurePrompt() } }
            ),
            presenting: viewModel.insecurePrompt
        ) { prompt in
            Button("Connect") { Task { await viewModel.confirmInsecure(prompt, router: router) } }
            Button("Cancel", role: .cancel) { viewModel.cancelInsecure() }
        } message: { prompt in
            Text("Your password and what you watch will be sent unencrypted to \(prompt.address). Only do this on a network you trust.")
        }
    }

    // MARK: - Set up with a phone (default)

    private var phoneFirst: some View {
        MarqueeTVScreen {
            MarqueeTVStatusChip(text: Self.tvName, systemImage: "appletv")
        } copy: {
            MarqueeTVStatusChip(text: "Looking for a phone or tablet…", showsSpinner: true)
                .padding(.bottom, 36)
            Text("Set up with\nyour phone")
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-2)
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityAddTraits(.isHeader)
            MarqueeTVBody("It's the easiest way. There's nothing to type with the remote.", size: 32)
                .padding(.top, 28)
            Text("No phone nearby?")
                .font(.system(size: 26))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .padding(.top, 64)
            // Servers found on this network or the tailnet connect with one
            // press, above the way to type an address.
            DiscoveredServerList(servers: discovery.servers, isConnecting: viewModel.isLoading) { server in
                Task { await viewModel.connect(to: server, router: router) }
            }
            .padding(.top, 18)
            if let error = viewModel.error?.message {
                MarqueeErrorText(error)
                    .frame(width: 760, alignment: .leading)
                    .padding(.top, 16)
            }
            HStack {
                Button {
                    viewModel.clearError()
                    isEnteringAddress = true
                } label: {
                    Label("Enter server address", systemImage: "globe")
                }
                .buttonStyle(.marquee(.glass, fullWidth: false))
                .focused($focusedField, equals: .enterAddress)
            }
            .padding(.top, 18)
        } card: {
            MarqueeTVSetupSteps()
        }
        .defaultFocus($focusedField, .enterAddress, priority: .userInitiated)
        .marqueeTVSeedFocus($focusedField, .enterAddress)
        .animation(.easeOut(duration: 0.32), value: discovery.servers)
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
    }

    // MARK: - Enter the address

    private var manualEntry: some View {
        MarqueeTVScreen {
            MarqueeTVStatusChip(text: Self.tvName, systemImage: "appletv")
        } copy: {
            Text("Enter your\nserver address")
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-2)
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityAddTraits(.isHeader)
            MarqueeTVBody("Type the address you use for Silo.")
                .padding(.top, 22)

            MarqueeTVField(
                systemImage: "globe",
                placeholder: "media.example.com",
                text: $viewModel.host,
                focus: $focusedField,
                equals: .host,
                content: .url,
                isError: viewModel.error != nil
            )
            .frame(width: 760)
            .padding(.top, 40)
            .onSubmit { focusAfterKeyboard = .connect }

            if let error = viewModel.error?.message {
                MarqueeErrorText(error)
                    .frame(width: 760, alignment: .leading)
                    .padding(.top, 16)
            }

            Button {
                viewModel.showsAdvancedOptions.toggle()
            } label: {
                Label(viewModel.showsAdvancedOptions ? "Hide advanced options" : "Advanced options", systemImage: "gearshape")
            }
            .buttonStyle(.marquee(.plain, fullWidth: false, compact: true))
            .focused($focusedField, equals: .advanced)
            // Full width, so Up from the port field lands here rather than
            // skipping to the address.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .padding(.top, 18)

            if viewModel.showsAdvancedOptions {
                HStack(spacing: 14) {
                    ForEach(ServerSetupScheme.allCases) { scheme in
                        Button {
                            viewModel.selectedScheme = scheme
                        } label: {
                            HStack(spacing: 8) {
                                if viewModel.selectedScheme == scheme {
                                    Image(systemName: "checkmark")
                                }
                                Text(scheme.rawValue)
                            }
                        }
                        .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
                        .focused($focusedField, equals: .scheme(scheme))
                    }
                    MarqueeTVField(
                        systemImage: "number",
                        placeholder: "Port: auto",
                        text: $viewModel.port,
                        focus: $focusedField,
                        equals: .port,
                        content: .number
                    )
                    .frame(width: 250)
                    .onSubmit { focusAfterKeyboard = .connect }
                }
                .padding(.top, 14)
                .focusSection()
                // Entering the row lands on the chosen protocol, not whichever
                // button sits under the toggle.
                .defaultFocus($focusedField, .scheme(viewModel.selectedScheme), priority: .userInitiated)
            }

            HStack(spacing: 22) {
                Button {
                    connect()
                } label: {
                    Text(viewModel.isLoading ? "Connecting…" : "Connect")
                }
                .buttonStyle(.marquee(.primary, fullWidth: false, isLoading: viewModel.isLoading))
                .focused($focusedField, equals: .connect)

                Button {
                    viewModel.clearError()
                    isEnteringAddress = false
                } label: {
                    Text("Back")
                }
                .buttonStyle(.marquee(.plain, fullWidth: false))
                .focused($focusedField, equals: .back)
                .disabled(viewModel.isLoading)
            }
            // Full width, so Down from the port field at the far end of the
            // row above still reaches the row; entering it lands on Connect.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 40)
            .focusSection()
            .defaultFocus($focusedField, .connect, priority: .userInitiated)
        } card: {
            MarqueeTVCard {
                MarqueeTVCardSymbol(systemImage: "iphone")
                Text("Type on your phone")
                    .font(.system(size: 40, weight: .bold))
                    .padding(.top, 34)
                Text("When you select a field, a keyboard notification appears on nearby iPhones and iPads. Type there instead of with the remote.")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .padding(.top, 14)
            }
        }
        .defaultFocus($focusedField, .host, priority: .userInitiated)
        .marqueeTVFocusAfterKeyboard($focusedField, pending: $focusAfterKeyboard)
        // Leaving mid-probe would let a late connect pull the app on, so
        // the way back waits for it.
        .onExitCommand {
            if !viewModel.isLoading { isEnteringAddress = false }
        }
        .animation(SiloTheme.springAnimation, value: viewModel.showsAdvancedOptions)
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .keepsSubmittedServerInputs(viewModel)
    }

    private func connect() {
        guard !viewModel.isLoading else { return }
        Task { await viewModel.connect(router: router) }
    }

    // MARK: - Advertiser lifecycle

    private func advertise() async {
        let route = route
        await advertiser.advertise(while: { router.authState == route }) { session, stream in
            Task {
                await coordinator.run(session: session, stream: stream)
                // If the session ended back at the idle chooser, accept a new
                // phone immediately. Terminal states release via onChange once
                // the user leaves them.
                if case .idle = coordinator.state { advertiser.release() }
            }
        }
    }
}

#endif
