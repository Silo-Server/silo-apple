#if !os(tvOS)
import SwiftUI

/// Settings > Playback > Atmos Speaker Test on iPhone, iPad and Mac.
@available(iOS 26.0, macOS 26.0, *)
struct AtmosSpeakerTestView: View {
    @State private var player = AtmosSpeakerTestPlayer()

    var body: some View {
        Form {
            Section {
                ForEach(AtmosTestSpeaker.floor) { row(for: $0) }
            } header: {
                Text("Floor").foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloSurfaceElevated)

            Section {
                ForEach(AtmosTestSpeaker.height) { row(for: $0) }
            } header: {
                Text("Height").foregroundStyle(Color.siloSecondaryText)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tap a speaker to play pink noise from its position; tap it again to stop. The test uses the same route as TrueHD Atmos playback. With AirPods or the built-in speakers you hear each position in Spatial Audio; through a receiver or soundbar, each burst should come from that one speaker.")
                    if case .failed(let message) = player.state {
                        Text(message).foregroundStyle(Color.siloError)
                    }
                }
                .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloSurfaceElevated)
        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground)
        .navigationTitle("Atmos Speaker Test")
        .siloNavigationTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    private func row(for speaker: AtmosTestSpeaker) -> some View {
        Button {
            player.toggle(speaker)
        } label: {
            HStack {
                Text(speaker.name).foregroundStyle(Color.siloOnSurface)
                Spacer()
                switch player.state {
                case .preparing(speaker):
                    ProgressView()
                case .playing(speaker):
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(Color.siloAccent)
                        .symbolEffect(.variableColor.iterative)
                default:
                    EmptyView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(player.activeSpeaker == speaker ? "Playing" : "")
    }
}
#endif
