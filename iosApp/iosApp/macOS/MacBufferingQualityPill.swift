#if os(macOS)
import SwiftUI

/// The macOS buffering pill: "Playback keeps buffering" with **Lower quality**
/// and **Keep quality**, or "Quality lowered to stop buffering" with **Restore
/// quality**, in a notice card at the top of the player.
///
/// Pointer rules, like the intro pill: click is Select, Return selects the
/// primary action while the pill is up, and Escape is Back (both routed by
/// ``PlayerView``'s command capture). The buttons are the intro pill's
/// capsules, with the countdown on the primary.
struct MacBufferingQualityPill: View {
    let pill: BufferingQualityController.Pill
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        PlayerBufferingPillCard(kind: pill.kind) {
            HStack(spacing: 10) {
                MacPlayerPillButton(title: pill.kind.primaryAction, pill: pill, action: onPrimary)
                if let secondary = pill.kind.secondaryAction {
                    MacPlayerPillButton(title: secondary, pill: nil, action: onSecondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Prompt") {
    MacBufferingQualityPill(pill: .preview(.prompt), onPrimary: {}, onSecondary: {})
        .padding(40)
        .frame(width: 900)
        .background(Color.gray)
}

#Preview("Undo") {
    MacBufferingQualityPill(pill: .preview(.undo), onPrimary: {}, onSecondary: {})
        .padding(40)
        .frame(width: 900)
        .background(Color.gray)
}
#endif
#endif
