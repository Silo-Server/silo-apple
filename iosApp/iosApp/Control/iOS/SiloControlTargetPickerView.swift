#if os(iOS)
import SwiftUI

struct SiloControlTargetPickerView: View {
    let request: SiloControlPlaybackRequest?
    @Bindable var controller: SiloControlClient

    @State private var browser = SiloControlBrowser()
    @State private var searchTimedOut = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if !displayedTargets.isEmpty {
                    foundList
                } else if searchTimedOut {
                    emptyState
                } else {
                    searchingState
                }
            }
            .background(Color.continuumBackground.ignoresSafeArea())
            .navigationTitle("Remote Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                browser.start()
                try? await Task.sleep(for: .seconds(8))
                searchTimedOut = true
            }
            .onDisappear { browser.stop() }
        }
        .preferredColorScheme(.dark)
        .presentationDetents(displayedTargets.count > 3 ? [.medium, .large] : [.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    private var searchingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Searching for Silo TVs…")
                .font(.headline)
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Silo TVs Found",
            systemImage: "tv",
            description: Text("Foreground Apple TVs on this server appear here.")
        )
    }

    private var foundList: some View {
        List(displayedTargets) { target in
            Button {
                Task {
                    if let request {
                        await controller.play(on: target, request: request)
                    } else {
                        await controller.connect(to: target)
                    }
                    dismiss()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tv")
                        .font(.title3)
                        .foregroundStyle(Color.continuumOnSurface)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.continuumChromeRestingFill))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name).font(.headline)
                        if request != nil, target.protocolVersion < 2 {
                            Text("Update Silo on this TV to use your profile")
                                .font(.subheadline)
                                .foregroundStyle(Color.continuumSecondaryText)
                        } else if target.isPlaying {
                            Text("Playing now")
                                .font(.subheadline)
                                .foregroundStyle(Color.continuumPrimary)
                        } else if let serverName = target.serverName {
                            Text(ServerRegistry.serverIdsMatch(
                                target.serverId,
                                ServerRegistry.shared.activeServerId
                            )
                                 ? serverName
                                 : "Will temporarily use your server")
                                .font(.subheadline)
                                .foregroundStyle(Color.continuumSecondaryText)
                        }
                    }

                    Spacer()

                    if controller.isConnecting && controller.activeTarget?.id == target.id {
                        ProgressView().accessibilityLabel("Connecting")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(request != nil && target.protocolVersion < 2)
            .listRowBackground(Color.continuumSurface)
        }
        .scrollContentBackground(.hidden)
    }

    private var displayedTargets: [SiloControlTarget] {
        guard request == nil else { return browser.found }
        guard let activeServerId = ServerRegistry.shared.activeServerId else { return [] }
        return browser.found.filter {
            ServerRegistry.serverIdsMatch($0.serverId, activeServerId)
        }
    }
}

#if DEBUG
#Preview("Searching") {
    SiloControlTargetPickerView(request: nil, controller: SiloControlClient())
}
#endif
#endif
