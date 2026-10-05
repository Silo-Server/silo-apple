import SwiftUI

extension IntroSkipPrompt.Pill {
    /// The pill's action. The intro labels are fixed by the cross-platform
    /// spec; "Skip Recap" matches the web player.
    var actionTitle: String {
        switch (marker, kind) {
        case (.intro, .skip): return "Skip Intro"
        case (.intro, .undo): return "Watch Intro"
        case (.recap, .skip): return "Skip Recap"
        case (.recap, .undo): return "Watch Recap"
        }
    }

    /// The muted confirmation above `always`'s undo. It stays a separate line
    /// so the confirmation and the action never read as one instruction.
    var caption: String? {
        switch (marker, kind) {
        case (_, .skip): return nil
        case (.intro, .undo): return "Intro skipped"
        case (.recap, .undo): return "Recap skipped"
        }
    }

    var accessibilityLabel: String {
        guard let caption else { return actionTitle }
        return "\(caption). \(actionTitle)"
    }
}

/// The fill that creeps left to right behind the pill's label and lands full
/// exactly when the pill's timer runs out.
///
/// Drawn from the pill's own wall-clock deadline on every display frame, so the
/// bar and the action share one clock and no animation setting can make the
/// bar disagree with when the action fires. While a pause holds the timer the
/// timeline pauses too and the bar sits at the frozen fraction.
struct IntroSkipPillProgress: View {
    let pill: IntroSkipPrompt.Pill
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: pill.deadline == nil)) { context in
            GeometryReader { proxy in
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * pill.progress(at: context.date))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
