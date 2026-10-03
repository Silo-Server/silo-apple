import SwiftUI

#if !os(tvOS)
/// First screen when no server is configured: the address field over the
/// brand light, recent servers below it, and protocol and port under
/// "Advanced options". On iPhone the phone *is* the companion, so there is no
/// pairing card here (it overlays from `ContentView` when a TV is nearby).
struct ServerSetupView: View {
    var router: AppRouter
    @State private var viewModel = ServerSetupViewModel()
    @FocusState private var focusedField: Field?
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
        MarqueeStage(scrim: .bottom, frostStart: 0.30) {
            MarqueeTopBar {
                SiloWordmarkView(width: 92)
            } trailing: { EmptyView() }
        } content: {
            MarqueeHeadline(title: "Connect to\nyour server", lead: "Type the address you use for Silo.")

            MarqueeTextField(
                systemImage: "globe",
                placeholder: "media.example.com",
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

            // Recents are for picking before typing; while the address field
            // has the keyboard, the field and Continue need the room.
            if !recentServers.isEmpty, focusedField == nil, !(viewModel.isLoading && submittedWithKeyboard) {
                Text("Recent")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .padding(.top, 22)
                    .padding(.leading, 2)
                    .padding(.bottom, 10)
                recentList
                    .disabled(viewModel.isLoading)
            }

            Button(action: connect) {
                Text(viewModel.isLoading ? "Connecting…" : "Continue")
            }
            .buttonStyle(.marquee(.primary, isLoading: viewModel.isLoading))
            .disabled(viewModel.isLoading)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 22)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .animation(SiloTheme.springAnimation, value: viewModel.showsAdvancedOptions)
        .animation(.easeOut(duration: 0.25), value: focusedField)
        .sensoryFeedback(.error, trigger: viewModel.error) { _, error in error != nil }
        .alert(
            "Connect without encryption?",
            isPresented: Binding(
                get: { viewModel.insecurePrompt != nil },
                set: { if !$0, viewModel.insecurePrompt != nil { viewModel.cancelInsecure() } }
            ),
            presenting: viewModel.insecurePrompt
        ) { _ in
            Button("Cancel", role: .cancel) { viewModel.cancelInsecure() }
            Button("Connect") {
                Task { await viewModel.confirmInsecure(router: router) }
            }
        } message: { prompt in
            Text("Your password and what you watch will be sent unencrypted to \(prompt.address). Only do this on a network you trust.")
        }
        .onAppear {
            MarqueeScene.shared.showGeneric()
            // A TV sign-in link for a server this app lacks lands here with
            // that server's address filled in.
            if let prefill = router.consumeServerSetupPrefill() { viewModel.host = prefill }
        }
        .marqueeTransparentNavigation()
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
                Text("Advanced options")
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
        .accessibilityValue(viewModel.showsAdvancedOptions ? "Expanded" : "Collapsed")

        if viewModel.showsAdvancedOptions {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Protocol")
                        Spacer()
                        Picker("Protocol", selection: $viewModel.selectedScheme) {
                            ForEach(ServerSetupScheme.allCases) { scheme in
                                Text(scheme.rawValue).tag(scheme)
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
                        Text("Port")
                        Spacer()
                        TextField("Auto", text: $viewModel.port)
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
                Text("Auto tries HTTPS first, then HTTP, then Silo's port 8090.")
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
        VStack(spacing: 0) {
            ForEach(Array(recentServers.enumerated()), id: \.element.id) { index, server in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
                Button {
                    viewModel.host = server.url
                    connect()
                } label: {
                    HStack(spacing: 12) {
                        MarqueeServerMark(
                            name: server.fetchedName,
                            imageURL: ServerBrandingCache.branding(for: server.url)?.markURL,
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.siloOnSurface)
                                .lineLimit(1)
                            Text(Self.hostLabel(server.url))
                                .font(.system(size: 13))
                                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.marqueePressable)
                .accessibilityLabel("\(server.displayName), \(Self.hostLabel(server.url))")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
    }

    static func hostLabel(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }
}
#endif
