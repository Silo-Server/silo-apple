import SwiftUI

extension IntroSkipPrompt.Kind {
    /// The pill's action, fixed by the cross-platform spec.
    var actionTitle: String {
        switch self {
        case .skip: return "Skip Intro"
        case .undo: return "Watch Intro"
        }
    }

    /// The muted confirmation above `always`'s undo. It stays a separate line
    /// so the confirmation and the action never read as one instruction.
    var caption: String? {
        switch self {
        case .skip: return nil
        case .undo: return "Intro skipped"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .skip: return "Skip Intro"
        case .undo: return "Intro skipped. Watch Intro"
        }
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
