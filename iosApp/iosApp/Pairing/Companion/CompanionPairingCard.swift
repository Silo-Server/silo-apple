#if os(iOS)
import SwiftUI

/// The native-style companion pairing card: rises from the bottom over a dimmed
/// app and runs the whole flow for one discovered TV — discovery, server
/// selection, match-code confirm, progress, result — beneath a consistent
/// header. Pure presentation: the coordinator owns the transport
/// (`CompanionPairingCoordinator.connect(to:)`).
struct CompanionPairingCard: View {
    let tv: DiscoveredTV
    /// A sign-in TV's own server; nil for a setup TV (the user chooses).
    var server: ServerEntry? = nil
    /// Any exit — Not Now, Cancel mid-flow, Done, Close. The modifier records
    /// a per-setup-session dismissal so the card doesn't immediately re-latch;
    /// mid-flow retry lives INSIDE the card ("Try Again" on the error step).
    var onDismiss: () -> Void
    /// The TV no longer advertises what this card offers (it left the
    /// sign-in or setup screen, or started a new session). An offer the user
    /// hasn't acted on is withdrawn; a flow already under way keeps running
    /// and reports its own result.
    var offerWithdrawn: Bool = false

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
        .onChange(of: offerWithdrawn) { _, withdrawn in
            if withdrawn, !started { dismiss() }
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
        .sensoryFeedback(trigger: coordinator?.state) { _, state in
            switch state {
            case let .finished(signedIn, failed):
                if signedIn.isEmpty { return .error }
                return failed.isEmpty ? .success : .warning
            case .error: return .error
            default: return nil
            }
        }
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
                    .onAppear { preselectActiveServer(in: servers) }
            case let .confirmMatch(_, serverName, serverHost, accountName, code, matchWords):
                confirm(serverName: serverName, serverHost: serverHost, accountName: accountName,
                        code: code, matchWords: matchWords)
            case let .working(progress):
                progressStep(title: server == nil ? "Setting up…" : "Signing in…", subtitle: progress)
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
            if let server {
                Text("Sign in \(tv.name) to \(server.displayName)?")
                    .font(.siloTitle)
                    .multilineTextAlignment(.center)
                // Unauthenticated Bonjour: the name and state are the TV's
                // claim, checked against its code on the next step.
                Text(Self.signInOfferBody(tvName: tv.name))
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                primaryButton("Sign In") { setUp() }.padding(.top, 22)
            } else {
                Text("Set Up \(tv.name)")
                    .font(.siloTitle)
                    .multilineTextAlignment(.center)
                Text("Sign \(tv.name) in to your servers from this \(UIDevice.current.model).")
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                primaryButton("Set Up") { setUp() }.padding(.top, 22)
            }
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
                    .background(Color.siloIconTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName)
                        .font(.siloBody)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(server.url)
                        .font(.siloCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Color.siloOnSurface : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isOn ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// The sign-in offer's body. It reports what the TV says, not a fact.
    private static func signInOfferBody(tvName: String) -> String {
        "A TV nearby named “\(tvName)” says it's on its sign-in screen. You'll check its code before approving."
    }

    /// The same content model as `TVApprovalCard`, the web `/activate` card
    /// and Android: the code, which server and account, what approving
    /// grants, and the warning.
    private func confirm(serverName: String, serverHost: String, accountName: String?,
                         code: String, matchWords: String?) -> some View {
        VStack(spacing: 0) {
            Text("Check that \(tv.name) shows")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
            Text(DeviceUserCode.display(code))
                .font(.siloPIN)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
                .accessibilityLabel(Text(DeviceUserCode.spokenCharacters(code)).speechSpellsOutCharacters())
            // Rollout fallback: TVs released before user codes show only the
            // match words. Remove together with Android's
            // CompanionPairingBottomOverlay line, the web /activate card's
            // "Older TV apps show ..." line and the Apple TV pairing panel's
            // "Older phones show ..." line.
            if let olderTVLine = Self.olderTVLine(matchWords: matchWords) {
                Text(olderTVLine)
                    .font(.siloCaption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            Text(TVApprovalCard.signInLine(serverName: serverName, serverHost: serverHost, accountName: accountName))
                .font(.siloBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Text(TVApprovalCard.profilesLine)
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(TVApprovalCard.onlyApproveInFrontLine)
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            primaryButton("Yes, this matches") { Task { await coordinator?.confirmMatch() } }
                .padding(.top, 22)
            tertiaryButton("Doesn’t match") { Task { await coordinator?.declineMatch() } }
                .padding(.top, 4)
        }
    }

    /// The line under the code naming what TVs released before user codes
    /// show instead; the same wording as Android and the web `/activate` card.
    static func olderTVLine(matchWords: String?) -> String? {
        guard let words = matchWords?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        return "Older TV apps show \(words.uppercased()) instead."
    }

    private func finished(signedIn: [String], failed: [CompanionPairingCoordinator.FailedServer]) -> some View {
        VStack(spacing: 0) {
            Image(systemName: signedIn.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(signedIn.isEmpty ? Color.yellow : Color.green)
                .padding(.bottom, 12)
            Text(signedIn.isEmpty
                ? (server == nil ? "Setup didn’t finish" : "Sign-in didn’t finish")
                : (server == nil ? "Set up \(signedIn.joined(separator: ", "))" : "\(tv.name) is signed in"))
                .font(.siloHeadline)
                .multilineTextAlignment(.center)
            ForEach(failed, id: \.name) { failure in
                Text(failure.summary)
                    .font(.siloCaption)
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
                .font(.siloBody)
                .multilineTextAlignment(.center)
            primaryButton("Try Again") { retry() }.padding(.top, 22)
            tertiaryButton("Close") { dismiss() }.padding(.top, 4)
        }
    }

    // MARK: - Header & building blocks

    private var heroGlyph: some View {
        Image(systemName: "tv")
            .font(.system(size: 56))
            .foregroundStyle(.primary)
            .frame(width: 104, height: 104)
    }

    private func compactHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tv").font(.system(size: 22)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.siloHeadline)
                Text(subtitle).font(.siloCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func progressStep(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.siloHeadline)
            Text(subtitle)
                .font(.siloCaption)
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
            Text(title).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .pairingPrimaryButton()
    }

    private func tertiaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.siloBody).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.siloSecondaryText)
    }

    private func cancelButton() -> some View {
        // `dismiss()` cancels the coordinator.
        tertiaryButton("Cancel") { dismiss() }
    }

    // MARK: - Actions

    private func setUp() {
        started = true
        startupTask?.cancel()
        startupTask = Task {
            let coordinator = await CompanionPairingCoordinator.connect(to: tv, server: server)
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

    /// The chooser starts with the server this device is using; the user
    /// can add or remove others.
    private func preselectActiveServer(in servers: [ServerEntry]) {
        guard selection.isEmpty, let active = ServerRegistry.shared.activeServerId,
              servers.contains(where: { $0.id == active }) else { return }
        selection.insert(active)
    }
}

extension View {
    /// Large white-filled button with dark text, like the app's other
    /// primary buttons. Shared by the pairing and TV approval cards.
    func pairingPrimaryButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.siloOnSurface)
            .foregroundStyle(Color.siloBackground)
    }
}
#endif
