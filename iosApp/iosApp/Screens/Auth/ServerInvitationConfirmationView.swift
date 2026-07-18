#if os(iOS)
import SwiftUI

struct ServerInvitationConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let invitation: ServerInvitation
    let coordinator: ServerInvitationCoordinator
    let router: AppRouter

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text(invitation.hostname)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Text(invitation.serverURL.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } header: {
                    Text("Proposed Silo server")
                }

                if invitation.usesPlainHTTP {
                    Section {
                        Label {
                            Text("This server uses plain HTTP. Credentials and media traffic may be visible to others on the network.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Text("Silo will verify the server only after you continue. It will not sign you in or submit a signup automatically.")
                        .foregroundStyle(.secondary)
                    if invitation.action == .signup, invitation.inviteCode != nil {
                        Label("An invite code will be carried into signup.", systemImage: "ticket")
                    }
                }

                if let error = coordinator.connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Open Invitation?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.cancel()
                        dismiss()
                    }
                    .disabled(coordinator.isConnecting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(coordinator.isConnecting ? "Checking…" : "Continue") {
                        Task {
                            if await coordinator.confirm(router: router) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(coordinator.isConnecting)
                }
            }
            .interactiveDismissDisabled(coordinator.isConnecting)
        }
        .onDisappear {
            if coordinator.pendingInvitation?.id == invitation.id,
               !coordinator.isConnecting {
                coordinator.cancel()
            }
        }
    }
}
#endif
