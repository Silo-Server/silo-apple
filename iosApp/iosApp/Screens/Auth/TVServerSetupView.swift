#if os(tvOS)
import SwiftUI

/// First-run server entry on tvOS (Aurora). The screen advertises on the LAN the
/// moment it appears, so a nearby iPhone can set this TV up hands-off. Two paths
/// sit side by side over the aurora backdrop: a live "Set up with iPhone" status
/// card and a fully functional manual-entry card (the emphasized, default-focused
/// path). When a phone connects, the same screen swaps *in place* to the pairing
/// panel — no cover, so nothing ever bleeds through behind it.
struct TVServerSetupView: View {
    var router: AppRouter

    @State private var viewModel = ServerSetupViewModel()
    @State private var advertiser = TVPairingAdvertiser()
    @State private var coordinator = ReceiverPairingCoordinator()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case advanced
        case scheme(ServerSetupScheme)
        case port
        case connect
    }

    /// True once a phone is on the line; the screen hands over to the pairing panel.
    private var isPairing: Bool {
        if case .idle = coordinator.state { return false }
        return true
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: .server, scrim: .soft)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                body(for: coordinator.state)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .ignoresSafeArea()
        .animation(ContinuumTheme.springAnimation, value: isPairing)
        .task { startAdvertising() }
        .onChange(of: coordinator.state) { _, state in
            // Only accept a new phone once the panel is back to the idle
            // chooser. Releasing on terminal states (completed/failed) would
            // let a second phone connect and clobber the summary the user is
            // still reading.
            if case .idle = state { advertiser.release() }
        }
        .onDisappear {
            advertiser.stop()
            Task { await coordinator.cancel() }
        }
    }

    @ViewBuilder
    private func body(for state: ReceiverPairingCoordinator.State) -> some View {
        if case .idle = state {
            connectChooser
                .transition(.opacity)
        } else {
            TVPairingReceiverView(coordinator: coordinator, router: router)
                .transition(.opacity)
        }
    }

    // MARK: - Advertiser lifecycle

    private func startAdvertising() {
        advertiser.start { session, stream in
            Task {
                await coordinator.run(session: session, stream: stream)
                // If the session ended back at the idle chooser, accept a new
                // phone immediately. Terminal states release via onChange once
                // the user leaves them.
                if case .idle = coordinator.state { advertiser.release() }
            }
        }
    }

    // MARK: - Idle chooser (phone status + manual entry)

    private var connectChooser: some View {
        // Header is pinned near the top while the two cards are vertically
        // centered in the remaining space, so they sit around screen center
        // rather than being pushed low as part of a single centered block.
        ZStack(alignment: .top) {
            HStack(alignment: .center, spacing: 0) {
                phoneCard
                    .frame(width: 600)
                orDivider
                    .frame(width: 84)
                manualCard
                    .frame(width: 600)
                    .focusSection()
            }
            .frame(height: 580)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            VStack(spacing: 14) {
                AuroraEyebrow(text: "Step 01 — Connect", centered: true)
                Text("Add your server")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
            }
        }
        .frame(maxHeight: .infinity)
        .defaultFocus($focusedField, .host, priority: .userInitiated)
    }

    private var topBar: some View {
        HStack {
            SiloWordmarkView(width: 132)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Phone handoff card (live status — we are advertising)

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            phoneSetupPill
            Spacer(minLength: 20)
            SearchingBeacon()
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 20)
            Text("Looking for your iPhone…")
                .font(.continuumHeadline)
                .foregroundStyle(Color.auroraInk)
            Text("Open Silo on your iPhone on the same Wi-Fi. It’ll offer to set up this Apple TV — the address and your account come across automatically.")
                .font(.continuumBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .auroraGlass(cornerRadius: 28)
    }

    private var phoneSetupPill: some View {
        Text("SET UP WITH IPHONE")
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color.auroraInkSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    // MARK: - OR divider

    private var orDivider: some View {
        VStack(spacing: 16) {
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            Text("OR")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Color.auroraInkTertiary)
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Manual entry card (active)

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Enter it here")
                .font(.continuumHeadline)
                .foregroundStyle(Color.auroraInk)

            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Server address")
                AuroraInputField(
                    text: $viewModel.host,
                    placeholder: "media.example.com",
                    focus: $focusedField,
                    equals: .host,
                    contentType: .URL,
                    keyboard: .URL
                )
            }

            Button {
                withAnimation(ContinuumTheme.springAnimation) {
                    viewModel.showsAdvancedOptions.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text("Advanced options")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(viewModel.showsAdvancedOptions ? 180 : 0))
                }
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focusedField, equals: .advanced)

            if viewModel.showsAdvancedOptions {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Protocol")
                        protocolSegments
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Port")
                        AuroraInputField(
                            text: $viewModel.port,
                            placeholder: "8096",
                            focus: $focusedField,
                            equals: .port,
                            keyboard: .numberPad
                        )
                    }
                    .frame(width: 190)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = viewModel.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.continuumError)
                    Text(error)
                        .font(.continuumCaption)
                        .foregroundStyle(Color.continuumError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            Button {
                guard !viewModel.isLoading else { return }
                Task { await viewModel.connect(router: router) }
            } label: {
                Text(viewModel.isLoading ? "Connecting…" : "Connect")
            }
            .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
            .focused($focusedField, equals: .connect)
        }
        .padding(46)
        .frame(maxHeight: .infinity, alignment: .top)
        .auroraGlass(cornerRadius: 28, emphasized: true)
        .animation(.easeInOut(duration: 0.2), value: viewModel.error)
        .animation(ContinuumTheme.springAnimation, value: viewModel.showsAdvancedOptions)
    }

    private var protocolSegments: some View {
        HStack(spacing: 8) {
            ForEach(ServerSetupScheme.allCases) { scheme in
                Button {
                    viewModel.selectedScheme = scheme
                } label: {
                    AuroraSegment(
                        title: scheme.rawValue,
                        isSelected: viewModel.selectedScheme == scheme,
                        isFocused: focusedField == .scheme(scheme)
                    )
                }
                .buttonStyle(.continuumFlat)
                .focused($focusedField, equals: .scheme(scheme))
            }
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(Color.auroraInkTertiary)
    }
}

// MARK: - Searching beacon (pulsing rings behind the phone glyph)

private struct SearchingBeacon: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.auroraAccent.opacity(0.5), lineWidth: 2)
                    .frame(width: 120, height: 120)
                    .scaleEffect(animate ? 1.7 : 0.6)
                    .opacity(animate ? 0 : 0.55)
                    .animation(
                        reduceMotion ? nil :
                            .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                        value: animate)
            }
            Image(systemName: "iphone.gen3")
                .font(.system(size: 76, weight: .ultraLight))
                .foregroundStyle(Color.auroraInk)
        }
        .frame(width: 200, height: 200)
        .onAppear { animate = true }
    }
}

#endif
