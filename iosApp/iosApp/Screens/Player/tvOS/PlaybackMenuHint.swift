#if os(tvOS)
import Foundation
import SwiftUI

/// The hint at the top of the tvOS player that says Down opens the player
/// menu.
///
/// It shows once per item: the first time the item plays with the controls
/// hidden and nothing else holding the top of the screen, for
/// ``visibleSeconds``. It goes early, for good, when the controls or the menu
/// come up, a hold seek starts, a notice takes its place, or playback leaves
/// the screen. Display-only: it takes no focus and no press, so Down still
/// reaches the press capture, which opens the menu.
@MainActor
@Observable
final class PlaybackMenuHint {
    nonisolated static let visibleSeconds: TimeInterval = 5

    /// What the player shows, as far as the hint cares.
    struct Conditions: Equatable {
        /// The item has shown a frame and is not loading, failed, or behind
        /// the Next Up screen.
        var isPlaybackOnScreen = false
        var isPlaying = false
        /// The controls or the menu are up. Down moves focus inside them
        /// instead of opening the menu, so the hint would be wrong.
        var areControlsUp = false
        /// A hold seek draws its indicator where the hint sits.
        var isHoldSeeking = false
        /// A notice holds the top-centre slot the hint uses.
        var isSlotTaken = false
    }

    private enum Phase {
        /// The item has not shown the hint yet.
        case waiting
        case showing
        /// Shown, or passed over, for this item.
        case done
    }

    private var phase: Phase = .waiting
    @ObservationIgnored private let clock: PlayerPromptClock
    @ObservationIgnored private var timer: PlayerPromptTimer?

    init(clock: PlayerPromptClock? = nil) {
        self.clock = clock ?? LivePlayerPromptClock()
    }

    var isVisible: Bool { phase == .showing }

    /// Another item: it may show the hint once more.
    func reset() {
        finish()
        phase = .waiting
    }

    func update(_ conditions: Conditions) {
        switch phase {
        case .waiting:
            guard conditions.isPlaybackOnScreen else { return }
            if conditions.areControlsUp {
                // The viewer found the controls first. Showing the hint once
                // they hide again would arrive long after playback began.
                phase = .done
            } else if conditions.isPlaying && !conditions.isHoldSeeking && !conditions.isSlotTaken {
                phase = .showing
                timer = clock.schedule(after: Self.visibleSeconds) { [weak self] in
                    self?.finish()
                }
            }
        case .showing:
            if !conditions.isPlaybackOnScreen || conditions.areControlsUp ||
                conditions.isHoldSeeking || conditions.isSlotTaken {
                finish()
            }
        case .done:
            break
        }
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        if phase == .showing { phase = .done }
    }
}

/// The start hint: a quiet glass capsule at the top centre, lighter than a
/// notice card because it reports nothing that went wrong. Fades in and out.
struct PlaybackMenuHintView: View {
    var body: some View {
        Label(.playerControlsPlaybackMenuHint, systemImage: "chevron.down.circle")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .siloPlayerGlass(in: Capsule(), tint: .black.opacity(0.35))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.top, SiloTheme.safePadding)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
#endif
