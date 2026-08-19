import SwiftUI

/// The player's one and only loading/buffering indicator: a small top-right
/// capsule holding a spinner and the word "Buffering".
///
/// Mirrors the Android TV client's buffering chip, where the same capsule is
/// likewise the sole buffering surface — ExoPlayer's own centered wheel is
/// switched off there (`SHOW_BUFFERING_NEVER`) precisely so two indicators
/// can never draw at once. Apple used to run a full-screen loading wheel for
/// the start and a separate in-transport spinner for rebuffers; the hand-off
/// between the two could not be choreographed cleanly across the tvOS Dolby
/// Vision HDMI transition, so both were replaced by this.
///
/// Mounted by the player shells (`Screens/Player/PlayerView` for iOS/tvOS,
/// `macOS/PlayerView`) rather than by the transport overlays, so it covers a
/// start with no controls on screen, a mid-play rebuffer with the controls
/// hidden, and a quality switch with the tvOS HUD open. The shells suppress
/// it only for the error view; it deliberately survives the Up Next panel,
/// where video keeps playing in the mini-player and the panel has no loading
/// state of its own (the Android chip makes the same call).
///
/// The view positions itself (top-trailing, inside the safe area, clear of
/// whatever each platform parks in that corner) so every shell agrees on
/// placement. It is inert: no focus target on tvOS, no hit testing anywhere.
struct PlayerBufferingCapsule: View {
    var body: some View {
        HStack(spacing: contentSpacing) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(spinnerScale)
            Text("Buffering")
                .font(.siloSmall.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .siloPlayerGlass(in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.top, topInset)
        .padding(.trailing, trailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel("Buffering")
    }

    private var contentSpacing: CGFloat {
        #if os(tvOS)
        8
        #else
        7
        #endif
    }

    private var spinnerScale: CGFloat {
        #if os(tvOS)
        0.9
        #else
        0.8
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    private var verticalPadding: CGFloat { 6 }

    /// Enough drop to clear whatever else owns the top edge while the capsule
    /// is up: nothing on tvOS above the idle overlay's status column, the
    /// 44pt round buttons of the iOS top strip, and the always-mounted macOS
    /// title bar (macOS keeps its controls through the load).
    private var topInset: CGFloat {
        #if os(tvOS)
        64
        #elseif os(macOS)
        88
        #else
        68
        #endif
    }

    private var trailingInset: CGFloat {
        #if os(tvOS)
        80
        #elseif os(macOS)
        20
        #else
        16
        #endif
    }
}
