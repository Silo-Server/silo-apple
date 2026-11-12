#if os(iOS)
import SwiftUI

struct SiloControlTargetPickerView: View {
    let request: SiloControlPlaybackRequest?
    let controller: SiloControlClient

    @State private var browser = SiloControlBrowser()
    @State private var searchTimedOut = false
    /// Read once: the picker lives for one search.
    @State private var rememberedRoku = SiloControlClient.rememberedRoku
    private let pairingKeys = SiloControlPairingKeys()
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
            .siloSheetBackground()
            .statusColumnSheetWidth()
            .navigationTitle(Text(.castPickerRemoteControl))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonDone) { dismiss() }
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
    }

    private var searchingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(.castPickerSearching)
                .font(.headline)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(.castPickerNoneFound, systemImage: "tv")
        } description: {
            Text(missingRokuHint ?? LocalizedStringResource.remotePickerNoneFoundHint)
        }
    }

    /// The phone can't open Silo on a Roku, so when the Roku it last
    /// controlled hasn't turned up by the end of the search, the picker says
    /// how to bring it back.
    private var missingRokuHint: LocalizedStringResource? {
        guard searchTimedOut, let roku = rememberedRoku, !browser.found.contains(where: { $0.id == roku.id }) else { return nil }
        return .remotePickerRokuMissing(roku.name)
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
                        .foregroundStyle(Color.siloOnSurface)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.siloChromeRestingFill))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name).font(.headline)
                        if target.transport == .sealed, pairingKeys.key(for: target) == nil {
                            Text(.remotePickerScanPairing)
                                .font(.subheadline)
                                .foregroundStyle(Color.siloSecondaryText)
                        } else if request != nil, target.protocolVersion < 2 {
                            Text(.castPickerUpdateTv)
                                .font(.subheadline)
                                .foregroundStyle(Color.siloSecondaryText)
                        } else if target.isPlaying {
                            Text(.castPickerPlayingNow)
                                .font(.subheadline)
                                .foregroundStyle(Color.siloPrimary)
                        } else if let serverName = target.serverName {
                            (target.targetsActiveServer
                             ? Text(serverName)
                             : Text(.castPickerTemporaryServer))
                                .font(.subheadline)
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                    }

                    Spacer()

                    if controller.isConnecting && controller.activeTarget?.id == target.id {
                        ProgressView().accessibilityLabel(Text(.remotePickerConnecting))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(request != nil && target.protocolVersion < 2)
            .listRowBackground(Color.siloSurface)
        }
        .safeAreaInset(edge: .bottom) {
            if let missingRokuHint {
                Text(missingRokuHint)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                    .padding(.bottom, 12)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var displayedTargets: [SiloControlTarget] {
        guard request == nil else { return browser.found }
        guard ServerRegistry.shared.activeServer != nil else { return [] }
        return browser.found.filter(\.targetsActiveServer)
    }
}

#if DEBUG
#Preview("Searching") {
    SiloControlTargetPickerView(request: nil, controller: SiloControlClient())
}
#endif
#endif
