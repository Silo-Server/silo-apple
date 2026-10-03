#if os(tvOS)
import SwiftUI

/// Full-screen speaker test presented from Settings > Playback. A native focus graph: every
/// speaker is a real `Button`; Select starts or stops its burst, Menu closes the screen.
@available(tvOS 26.0, *)
struct TVAtmosSpeakerTestView: View {
    let dismiss: () -> Void

    @State private var player = AtmosSpeakerTestPlayer()
    @FocusState private var focused: AtmosTestSpeaker?
    private let output = AetherObjectAudioPolicy.currentOutput()

    var body: some View {
        ZStack {
            Color.siloBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PLAYBACK")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.siloAccent)
                    Text("Atmos Speaker Test")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface)
                    Text(outputSummary)
                        .font(.system(size: 21))
                        .foregroundStyle(Color.siloSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 48) {
                    column(title: "FLOOR", speakers: AtmosTestSpeaker.floor)
                    column(title: "HEIGHT", speakers: AtmosTestSpeaker.height)
                }
                .focusSection()

                if case .failed(let message) = player.state {
                    TVSettingsWarningFooter(message)
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .defaultFocus($focused, .frontLeft)
        .onExitCommand {
            player.stop()
            dismiss()
        }
        .onDisappear { player.stop() }
    }

    private var outputSummary: String {
        let route = switch output {
        case .atmos:
            "This Apple TV reports a Dolby Atmos output, so each burst should come from that one speaker."
        case .channelsOnly:
            "This Apple TV does not report a Dolby Atmos output. Height bursts will be folded into the floor speakers."
        case .unknown:
            "This Apple TV has not reported its audio format yet."
        }
        return "Select a speaker to play pink noise from it; select it again to stop. "
            + "The test uses the same route as TrueHD Atmos playback. " + route
    }

    private func column(title: String, speakers: [AtmosTestSpeaker]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader(title)
            ForEach(speakers) { speaker in
                Button {
                    player.toggle(speaker)
                } label: {
                    HStack(spacing: 16) {
                        Text(speaker.name)
                            .font(.system(size: 26))
                            .lineLimit(1)
                        Spacer(minLength: 16)
                        status(for: speaker)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle(isSelected: player.activeSpeaker == speaker))
                .focused($focused, equals: speaker)
                .accessibilityValue(player.activeSpeaker == speaker ? "Playing" : "")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func status(for speaker: AtmosTestSpeaker) -> some View {
        switch player.state {
        case .preparing(speaker):
            ProgressView()
        case .playing(speaker):
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 22, weight: .semibold))
                .symbolEffect(.variableColor.iterative)
        default:
            EmptyView()
        }
    }
}
#endif
