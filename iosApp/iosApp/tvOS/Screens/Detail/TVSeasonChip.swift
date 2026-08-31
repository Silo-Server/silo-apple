#if os(tvOS)
import SwiftUI

/// Season chip used on series / season / episode detail pages. Selected
/// reads as a filled white pill; focused fades in a translucent fill;
/// idle is outline only. The style owns its focus rendering so tvOS
/// doesn't stack a system halo on top.
struct TVSeasonChip: View {
    let season: Season
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(chipLabel)
                .font(.system(size: 20, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .buttonStyle(TVSeasonChipStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var chipLabel: String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return "Specials" }
        return "Season \(season.seasonNumber)"
    }
}

private struct TVSeasonChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVSeasonChipBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct TVSeasonChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(foregroundColor)
            .background(background)
            .scaleEffect(scale)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused ? 1.04 : 1.0
        return configuration.isPressed ? base * 0.97 : base
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            Capsule().fill(Color.white)
        } else if isFocused {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .overlay(Capsule().stroke(Color.white.opacity(0.78), lineWidth: 2))
        } else {
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1.5))
        }
    }

    private var foregroundColor: Color {
        if isSelected { return .black }
        return .white
    }
}

/// Horizontal scroll of season chips. Auto-centers the selected chip
/// when it changes, and lands focus on the selected chip when the user
/// d-pads down into the row — so on a "Season 4" page, the row opens on
/// Season 4 rather than whichever chip the focus engine picks
/// geometrically.
struct TVSeasonChipRow: View {
    let seasons: [Season]
    let selectedSeasonId: String?
    let onSelect: (Season) -> Void

    @FocusState private var focusedSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(seasons) { season in
                        TVSeasonChip(
                            season: season,
                            isSelected: selectedSeasonId == season.id,
                            onSelect: { onSelect(season) }
                        )
                        .id(season.id)
                        .focused($focusedSeasonId, equals: season.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .focusSection()
            .applyChipRowDefaultFocus(selectedSeasonId, binding: $focusedSeasonId)
            .onChange(of: selectedSeasonId) { _, newId in
                guard let newId else { return }
                withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onAppear {
                // Center the selected chip on first paint too. Without this a
                // high-numbered season (e.g. Season 8) opens with the row
                // scrolled to Season 1 and the selected chip clipped off-screen
                // until the user d-pads into it. The HStack is non-lazy, so the
                // target chip is already laid out — no dispatch hop needed.
                guard let selectedSeasonId else { return }
                proxy.scrollTo(selectedSeasonId, anchor: .center)
            }
        }
    }
}

private extension View {
    /// See `TVEpisodeRail.applyRailDefaultFocus` for the rationale —
    /// `.userInitiated` priority is what makes `defaultFocus` win over
    /// tvOS's geometric proximity logic on d-pad entry.
    @ViewBuilder
    func applyChipRowDefaultFocus(
        _ selectedSeasonId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let selectedSeasonId {
            self.defaultFocus(binding, selectedSeasonId, priority: .userInitiated)
        } else {
            self
        }
    }
}
#endif
