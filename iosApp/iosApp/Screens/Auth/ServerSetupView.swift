import SwiftUI

#if !os(tvOS)
/// First screen when no server is configured: the address field over the
/// brand light, recent servers below it, and protocol and port under
/// "Advanced options". On iPhone the phone *is* the companion, so there is no
/// pairing card here (it overlays from `ContentView` when a TV is nearby).
struct ServerSetupView: View {
    var router: AppRouter
    @State private var viewModel = ServerSetupViewModel()
    @State private var discovery = ServerDiscovery()
    @FocusState private var focusedField: Field?
    @Environment(\.locale) private var locale
    /// Whether Continue was pressed with the keyboard up. Recents stay hidden
    /// for that attempt so they don't pop in as the screen fades to sign-in.
    @State private var submittedWithKeyboard = false

    private enum Field: Hashable { case host, port }

    private var recentServers: [ServerEntry] {
        ServerRegistry.shared.entries
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        // With a saved account to go back to ("Add a server" from the
        // picker), setup can be left again.
        MarqueeStage(scrim: .bottom, frostStart: 0.30,
                     onBack: router.canReturnToPicker && !viewModel.isLoading ? { router.returnToPicker() } : nil) {
            MarqueeTopBar {
                if router.canReturnToPicker {
                    MarqueeIconButton(systemImage: "chevron.left", accessibilityLabel: AppLanguage.string(.commonBack)) {
                        router.returnToPicker()
                    }
                    .disabled(viewModel.isLoading)
                } else {
                    SiloWordmarkView(width: 92)
                }
            } trailing: { EmptyView() }
        } content: {
            MarqueeHeadline(title: AppLanguage.string(.setupConnectHeadline), lead: AppLanguage.string(.setupBody))

            MarqueeTextField(
                systemImage: "globe",
                placeholder: AppLanguage.string(.setupPlaceholder),
                text: $viewModel.host,
                focus: $focusedField,
                equals: .host,
                content: .url,
                showsClearButton: true,
                isError: viewModel.error != nil,
                // Not disabled while connecting: a disabled field drops the
                // keyboard, which shifts the whole column mid-transition.
                submitLabel: .go,
                onSubmit: connect
            )
            .padding(.top, 20)

            if let error = viewModel.error {
                MarqueeErrorText(error.message)
                    .padding(.top, 10)
                    .padding(.leading, 4)
            }

            advancedOptions
                .padding(.top, 12)

            // Found servers and recents are for picking before typing; while
            // the address field has the keyboard, the field and Continue need
            // the room.
            if focusedField == nil, !(viewModel.isLoading && submittedWithKeyboard) {
                DiscoveredServerList(
                    servers: discovery.servers,
                    isConnecting: viewModel.isLoading,
                    connectingID: viewModel.connectingServerID
                ) { server in
                    // A keyboard submit that failed earlier must not hide the
                    // lists while this connect runs.
                    submittedWithKeyboard = false
                    Task { await viewModel.connect(to: server, router: router) }
                }
                .padding(.top, 22)
                if let error = viewModel.discoveryError {
                    MarqueeErrorText(error.message)
                        .padding(.top, 10)
                        .padding(.leading, 4)
                }
            }

            if !recentServers.isEmpty, focusedField == nil, !(viewModel.isLoading && submittedWithKeyboard) {
                Text(.setupRecent)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .padding(.top, 22)
                    .padding(.leading, 2)
                    .padding(.bottom, 10)
                recentList
                    .disabled(viewModel.isLoading)
            }

            Button(action: connect) {
                Text(viewModel.isLoading ? LocalizedStringResource.setupConnecting : .setupContinue)
            }
            .buttonStyle(.marquee(.primary, isLoading: viewModel.isLoading))
            .disabled(viewModel.isLoading)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 22)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .animation(.easeInOut(duration: 0.2), value: viewModel.discoveryError)
        .animation(SiloTheme.springAnimation, value: viewModel.showsAdvancedOptions)
        .animation(.easeOut(duration: 0.25), value: focusedField)
        .animation(.easeInOut(duration: 0.2), value: discovery.servers)
        .sensoryFeedback(.error, trigger: viewModel.error) { _, error in error != nil }
        .sensoryFeedback(.error, trigger: viewModel.discoveryError) { _, error in error != nil }
        .serverInsecurePromptAlert(viewModel, router: router)
        .onAppear {
            MarqueeScene.shared.showGeneric()
            discovery.start()
            // A TV sign-in link for a server this app lacks lands here with
            // that server's address filled in.
            if let prefill = router.consumeServerSetupPrefill() { viewModel.host = prefill }
        }
        .onDisappear { discovery.stop() }
        .marqueeTransparentNavigation()
        .keepsSubmittedServerInputs(viewModel)
    }

    /// The keyboard stays up while connecting: dismissing it would shift the
    /// whole column just before the screen changes, and on an error the
    /// address is ready to edit.
    private func connect() {
        guard !viewModel.isLoading else { return }
        submittedWithKeyboard = focusedField != nil
        Task { await viewModel.connect(router: router) }
    }

    // MARK: - Advanced options

    @ViewBuilder
    private var advancedOptions: some View {
        Button {
            viewModel.showsAdvancedOptions.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape")
                Text(.setupAdvancedShow)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
            .padding(.leading, 4)
            .frame(minHeight: 32)
        }
        .buttonStyle(.marqueePressable)
        .disabled(viewModel.isLoading)
        .accessibilityValue(viewModel.showsAdvancedOptions ? LocalizedStringResource.setupAdvancedExpanded : .setupAdvancedCollapsed)

        if viewModel.showsAdvancedOptions {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    HStack {
                        Text(.setupProtocolField)
                        Spacer()
                        Picker(.setupProtocolField, selection: $viewModel.selectedScheme) {
                            ForEach(ServerSetupScheme.allCases) { scheme in
                                Text(scheme.label).tag(scheme)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: MarqueeMetrics.fieldHeight)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    HStack {
                        Text(.setupPortField)
                        Spacer()
                        TextField(text: $viewModel.port, prompt: Text(.setupPortAuto)) { Text(.setupPortAuto) }
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .port)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .frame(width: 120)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: MarqueeMetrics.fieldHeight)
                }
                .font(.system(size: MarqueeMetrics.fieldFont))
                .foregroundStyle(Color.siloOnSurface)
                .background(
                    RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
                Text(.setupAdvancedHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                    .padding(.leading, 4)
            }
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Recent servers

    private var recentList: some View {
        ServerPickerList(recentServers) { server in
            ServerPickerRow(
                name: server.displayName,
                markName: server.fetchedName,
                markURL: ServerBrandingCache.branding(for: server.url)?.markURL,
                detail: ServerBranding.hostLabel(server.url)
            ) {
                viewModel.useRecent(server.url)
                connect()
            }
        }
    }
}
#endif
