#if os(iOS)
import SwiftUI

/// Stats over the picture on a dark plate: the playback-health summary
/// first, and `PlaybackStats.compactRows` one tap away ("All details").
///
/// Two properties matter and are easy to break:
///
/// - It is inert apart from its two buttons. `allowsHitTesting(false)` on
///   the text and the plate means a tap in its footprint still reaches the
///   transport and the gesture layer underneath — the overlay must never
///   cost the user a play/pause. That rules out scrolling, which is why it
///   renders the compact row set and not the full one the tvOS pane pages
///   through.
/// - It takes turns with the controls. `MobilePlayerControls` shows it while
///   the transport is hidden and hides it while the transport shows, so the
///   two never draw over each other. Turned off from its close button or
///   where it was turned on (settings sheet → Stats).
struct MobilePlaybackStatsOverlay: View {
    let stats: PlaybackStats
    /// Turns the overlay off (the same switch as in Settings).
    let onClose: () -> Void

    /// Clears the control overlay's top strip so the two never collide.
    private static let topInset: CGFloat = 60

    @State private var showsDetails = false

    var body: some View {
        // The plate hugs its rows, which on a phone held upright are wider
        // than the screen. The reader takes the player's size whatever the
        // plate wants, so a long row can't widen the layer the controls
        // share and push them off both edges.
        GeometryReader { _ in
            plate
                // A visible way out: without it the overlay could only be
                // turned off from Settings.
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.black.opacity(0.75)))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(.playerStatsA11YHide))
                    .offset(x: 18, y: -18)
                }
                .padding(.leading, 16)
                .padding(.top, Self.topInset)
        }
    }

    private var plate: some View {
        // Gated on the compact set, not `hasRows`: early snapshots can carry
        // only rows this overlay filters out, which would draw a blank plate.
        let hasStats = !stats.compactRows.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if !hasStats {
                    Text(.playerStatsAppearOnceStarted)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                } else if showsDetails {
                    PlaybackStatsPanel(stats: stats, layout: .plain)
                } else {
                    PlaybackStatsSummaryView(summary: stats.summary, scale: .phone)
                }
            }
            .allowsHitTesting(false)
            if hasStats, !showsDetails {
                detailsToggle
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // A solid dark panel rather than a material: a blur reads as a
        // window, and the picture showing through competed with the rows.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.86))
                .allowsHitTesting(false)
        )
        // The details fill the phone's height, so their way back sits in the
        // corner their short top rows leave free, clear of the close button.
        .overlay(alignment: .topTrailing) {
            if hasStats, showsDetails {
                detailsToggle
                    .padding(.top, 2)
                    .padding(.trailing, 32)
            }
        }
        // Hug the rows so the plate never spans the player.
        .fixedSize()
    }

    private var detailsToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { showsDetails.toggle() }
        } label: {
            HStack(spacing: 4) {
                if showsDetails {
                    Image(systemName: "chevron.backward")
                    Text(.playerStatsSummaryButton)
                } else {
                    Text(.playerStatsAllDetails)
                    Image(systemName: "chevron.forward")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(showsDetails
            ? LocalizedStringResource.playerStatsA11YShowSummary
            : .playerStatsA11YShowAll))
    }
}
#endif
