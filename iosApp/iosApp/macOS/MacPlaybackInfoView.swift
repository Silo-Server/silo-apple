#if os(macOS)
import SwiftUI

/// Playback Info, in a popover from the control bar (⌘I): the shared stats
/// rows (Playback, Stream, Engine) as a grouped form like a Mac inspector.
/// Values can be selected and copied for a bug report.
struct MacPlaybackInfoView: View {
    let viewModel: PlayerViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stats = viewModel.playbackStats
        Form {
            section(.playerHudPlayback, rows: stats.playbackRows)
            section(.playerHudStream, rows: stats.streamRows)
            section(.playerStatsSectionEngine, rows: stats.engineRows)
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 480)
        // Once the popover takes key focus (selecting a value), the player's
        // keys no longer reach it; ⌘I still closes it from here.
        .background {
            Button("Close Playback Info") { dismiss() }
                .keyboardShortcut("i", modifiers: .command)
                .hidden()
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, rows: [PlaybackStats.Row]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    // A row with no label continues the one above it.
                    LabeledContent {
                        Text(row.value)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } label: {
                        Text(verbatim: row.label)
                    }
                }
            } header: {
                Text(title)
            }
        }
    }
}
#endif
