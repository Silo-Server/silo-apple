#if os(iOS)
import SwiftUI

/// The native-style companion pairing card: rises from the bottom over a dimmed
/// app and runs the whole flow for one discovered TV — discovery, server
/// selection, match-code confirm, progress, result — beneath a consistent
/// header. Pure presentation: the coordinator owns the transport
/// (`CompanionPairingCoordinator.connect(to:)`).
struct CompanionPairingCard: View {
    let tv: DiscoveredTV
    /// Any exit — Not Now, Cancel mid-flow, Done, Close. The modifier records
    /// a per-setup-session dismissal so the card doesn't immediately re-latch;
    /// mid-flow retry lives INSIDE the card ("Try Again" on the error step).
    var onDismiss: () -> Void

    /// System blue matches the native pairing look; the app's global tint is
    /// near-white, which would wash out the primary button.
    private let accent = Color.blue

    @State private var coordinator: CompanionPairingCoordinator?
    @State private var startupTask: Task<Void, Never>?
    @State private var selection: Set<String> = []
    @State private var started = false
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(appeared ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !started { dismiss() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Dismiss")
                .accessibilityHidden(started)

            card
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .offset(y: appeared ? 0 : 700)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { appeared = true }
        }
        .onDisappear {
            startupTask?.cancel()
            startupTask = nil
            Task { [coordinator] in await coordinator?.cancel() }
        }
    }

    // MARK: - Card shell

    private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)
            stepContent
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: coordinator?.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: started)
    }

    @ViewBuilder private var stepContent: some View {
        if !started {
            discovery
        } else {
            switch coordinator?.state ?? .connecting {
            case .connecting:
                progressStep(title: "Connecting…", subtitle: tv.name)
            case let .pickServers(_, servers):
                serverPicker(servers)
            case let .confirmMatch(_, serverName, matchCode):
                confirm(serverName: serverName, matchCode: matchCode)
            case let .working(progress):
                progressStep(title: "Setting up…", subtitle: progress)
            case let .finished(signedIn, failed):
                finished(signedIn: signedIn, failed: failed)
            case let .error(message):
                errorState(message)
            }
        }
    }

    // MARK: - Steps

    private var discovery: some View {
        VStack(spacing: 0) {
            heroGlyph.padding(.bottom, 16)
            Text("Set Up \(tv.name)")
                .font(.continuumTitle)
                .multilineTextAlignment(.center)
            Text("Sign \(tv.name) in to your servers from this \(UIDevice.current.model).")
                .font(.continuumCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            primaryButton("Set Up") { setUp() }.padding(.top, 22)
            tertiaryButton("Not Now") { dismiss() }.padding(.top, 4)
        }
    }

    private func serverPicker(_ servers: [ServerEntry]) -> some View {
        VStack(spacing: 0) {
            compactHeader(title: "Choose servers", subtitle: "Sign \(tv.name) in to…")
            VStack(spacing: 8) {
                ForEach(servers) { server in serverRow(server) }
            }
            primaryButton("Continue") {
                let chosen = servers.filter { selection.contains($0.id) }
                Task { await coordinator?.pushSelected(chosen) }
            }
            .disabled(selection.isEmpty)
            .opacity(selection.isEmpty ? 0.5 : 1)
            .padding(.top, 18)
            cancelButton().padding(.top, 4)
        }
    }

    private func serverRow(_ server: ServerEntry) -> some View {
        let isOn = selection.contains(server.id)
        return Button {
            if isOn { selection.remove(server.id) } else { selection.insert(server.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(.white)
                Text(server.displayName)
                    .font(.continuumBody)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? accent : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isOn ? Color.continuumChromeSelectedFill : Color.continuumChromeRestingFill,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func confirm(serverName: String, matchCode: String) -> some View {
        VStack(spacing: 0) {
            Text("Make sure your TV shows")
                .font(.continuumCaption)
                .foregroundStyle(.secondary)
            Text(matchCode)
                .font(.continuumPIN)
                .textCase(.uppercase)
                .tracking(8)
                .padding(.top, 8)
                .accessibilityLabel(Self.spelledOut(matchCode))
            Text("for \(serverName)")
                .font(.continuumCaption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            primaryButton("Yes, this matches") { Task { await coordinator?.confirmMatch() } }
                .padding(.top, 22)
            tertiaryButton("Doesn’t match") { Task { await coordinator?.declineMatch() } }
                .padding(.top, 4)
        }
    }

    private func finished(signedIn: [String], failed: [String]) -> some View {
        VStack(spacing: 0) {
            Image(systemName: signedIn.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(signedIn.isEmpty ? Color.yellow : Color.green)
                .padding(.bottom, 12)
            Text(signedIn.isEmpty ? "Setup didn’t finish" : "Set up \(signedIn.joined(separator: ", "))")
                .font(.continuumHeadline)
                .multilineTextAlignment(.center)
            if !failed.isEmpty {
                Text("Couldn’t sign in to \(failed.joined(separator: ", ")).")
                    .font(.continuumCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            if signedIn.isEmpty {
                primaryButton("Try Again") { retry() }.padding(.top, 22)
                tertiaryButton("Close") { dismiss() }.padding(.top, 4)
            } else {
                primaryButton("Done") { dismiss() }.padding(.top, 22)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .padding(.bottom, 12)
            Text(message)
                .font(.continuumBody)
                .multilineTextAlignment(.center)
            primaryButton("Try Again") { retry() }.padding(.top, 22)
            tertiaryButton("Close") { dismiss() }.padding(.top, 4)
        }
    }

    // MARK: - Header & building blocks

    private var heroGlyph: some View {
        Image(systemName: "appletv.fill")
            .font(.system(size: 56))
            .foregroundStyle(.primary)
            .frame(width: 104, height: 104)
    }

    private func compactHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "appletv.fill").font(.system(size: 22)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.continuumHeadline)
                Text(subtitle).font(.continuumCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func progressStep(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.continuumHeadline)
            Text(subtitle)
                .font(.continuumCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView().padding(.top, 4)
            // Every non-terminal step needs an exit: without one, a wedged TV
            // leaves the user trapped behind the scrim (which stops dismissing
            // once the flow starts).
            cancelButton().padding(.top, 10)
        }
        .padding(.vertical, 8)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.continuumHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(accent)
    }

    private func tertiaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.continuumBody).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
    }

    private func cancelButton() -> some View {
        tertiaryButton("Cancel") {
            Task { [coordinator] in await coordinator?.cancel() }
            dismiss()
        }
    }

    // MARK: - Actions

    private func setUp() {
        started = true
        startupTask?.cancel()
        startupTask = Task {
            let coordinator = await CompanionPairingCoordinator.connect(to: tv)
            guard !Task.isCancelled else {
                await coordinator.cancel()
                return
            }
            self.coordinator = coordinator
        }
    }

    /// Start the flow over with a fresh session against the same TV. Server
    /// selection is intentionally kept.
    private func retry() {
        Task { [coordinator] in await coordinator?.cancel() }
        coordinator = nil
        setUp()
    }

    private func dismiss() {
        startupTask?.cancel()
        startupTask = nil
        Task { [coordinator] in await coordinator?.cancel() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            appeared = false
        } completion: {
            onDismiss()
        }
    }

    /// VoiceOver-friendly match code: read character by character, never as a
    /// word — a blind user must be able to compare codes across two screens.
    static func spelledOut(_ code: String) -> String {
        code.uppercased().map(String.init).joined(separator: ", ")
    }
}
#endif
