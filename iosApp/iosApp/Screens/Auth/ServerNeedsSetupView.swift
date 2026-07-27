import SwiftUI

#if os(macOS)
import AppKit
#endif

#if !os(tvOS)
/// Shown when the chosen server has no account yet (`/api/v1/auth/setup`
/// reports `needsSetup`). iOS no longer creates the admin account in-app —
/// that happens in the server's web UI — so we point the user there and offer
/// a retry that re-probes the server.
struct ServerNeedsSetupView: View {
    var router: AppRouter
    @Environment(\.openURL) private var openURL
    @State private var isChecking = false
    @State private var didCopy = false
    @State private var error: String?

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            SiloWordmarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)

            AuroraJourneyProgress(currentStep: 1)
                .frame(maxWidth: 330)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)

            AuroraEyebrow(text: "Server setup", centered: true)
                .padding(.bottom, 16)

            ZStack {
                Circle().fill(Color.auroraAccent.opacity(0.14))
                Circle().stroke(Color.auroraAccent.opacity(0.34), lineWidth: 1)
                Image(systemName: "gearshape.2")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.auroraAccent)
            }
            .frame(width: 78, height: 78)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            VStack(spacing: 12) {
                Text("Your server needs one last step")
                    .font(.continuumTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text("Open the server in a browser and create its first account. When you're done, return here and check again.")
                    .font(.continuumBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 22)

            VStack(spacing: 16) {
                if let setupURL {
                    Button(action: copyURL) {
                        HStack(spacing: 10) {
                            Text(setupURL)
                                .font(.system(size: 15, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.auroraInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.continuumCaption)
                                .foregroundStyle(didCopy ? Color.continuumSuccess : Color.auroraInkSecondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: AuroraControl.height)
                        .background(
                            RoundedRectangle(cornerRadius: AuroraControl.corner)
                                .fill(Color.continuumSurfaceElevated.opacity(0.82))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AuroraControl.corner)
                                .stroke(Color.continuumOutline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let error {
                    AuroraErrorLabel(error)
                }

                Button(action: openSetup) {
                    Label("Open in browser", systemImage: "safari")
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .disabled(setupURL == nil)

                Button(action: retry) {
                    Text(isChecking ? "Checking…" : "Check again")
                }
                .buttonStyle(AuroraGhostButtonStyle())
                .disabled(isChecking)

                Button("Change server") { router.resetToServerSetup() }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: error)
        }
        .navigationBarBackButtonHidden()
    }

    private var setupURL: String? {
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    private func copyURL() {
        guard let setupURL else { return }
        #if os(iOS)
        UIPasteboard.general.string = setupURL
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupURL, forType: .string)
        #endif
        didCopy = true
    }

    private func openSetup() {
        guard let setupURL,
              let url = URL(string: setupURL) else { return }
        openURL(url)
    }

    /// Re-probe the current server. If it's now set up, pop back to the login
    /// screen (this view sits on top of `LoginView` in the `.needsLogin`
    /// stack). Otherwise surface a gentle nudge.
    private func retry() {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        Task {
            do {
                let status = try await AuthService.shared.checkServer(url: AuthService.shared.serverUrl)
                await MainActor.run {
                    isChecking = false
                    if status.needsSetup {
                        error = "This server still needs to be set up in a browser."
                    } else {
                        router.goBack()
                    }
                }
            } catch {
                await MainActor.run {
                    isChecking = false
                    self.error = "Couldn't reach the server. Check it's running and try again."
                }
            }
        }
    }
}
#endif
