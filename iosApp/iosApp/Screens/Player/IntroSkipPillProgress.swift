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

/// A pill with a timer the countdown fill can draw: the intro-skip pill and
/// the buffering-quality pills.
protocol PlayerTimedPill {
    /// When the timer runs out; nil while a pause holds it.
    var deadline: Date? { get }
    /// Seconds left as of the last arm or freeze.
    var remaining: TimeInterval { get }
    /// Where a fresh timer starts, for drawing progress against it.
    var total: TimeInterval { get }
    /// How far the fill has crept, 0 when the pill appears and 1 when the
    /// timer runs out.
    func progress(at now: Date) -> Double
}

extension PlayerTimedPill {
    func progress(at now: Date) -> Double {
        guard total > 0 else { return 1 }
        let left = deadline.map { $0.timeIntervalSince(now) } ?? remaining
        return min(max(1 - left / total, 0), 1)
    }
}

extension IntroSkipPrompt.Pill: PlayerTimedPill {}
extension BufferingQualityController.Pill: PlayerTimedPill {}

/// The fill that creeps left to right behind the pill's label and lands full
/// exactly when the pill's timer runs out.
///
/// Drawn from the pill's own wall-clock deadline on every display frame, so the
/// bar and the action share one clock and no animation setting can make the
/// bar disagree with when the action fires. While a pause holds the timer the
/// timeline pauses too and the bar sits at the frozen fraction.
struct PlayerPillProgress: View {
    let pill: any PlayerTimedPill
    let color: Color
    /// Draws the time left instead, full when the pill appears and empty when
    /// its timer runs out.
    var drains = false

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: pill.deadline == nil)) { context in
            GeometryReader { proxy in
                let progress = pill.progress(at: context.date)
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * (drains ? 1 - progress : progress))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The buffering card's countdown: a thin track along the card's bottom edge
/// whose bar drains as the timer runs out, so no fill ever sits behind a
/// button's label.
struct PlayerPillCountdownTrack: View {
    let pill: any PlayerTimedPill

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.12))
            PlayerPillProgress(pill: pill, color: .white.opacity(0.8), drains: true)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
