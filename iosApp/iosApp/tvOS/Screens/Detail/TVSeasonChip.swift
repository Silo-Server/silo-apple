#if os(tvOS)
import SwiftUI

/// Season chip used on series / season / episode detail pages. It uses the
/// same native Liquid Glass control treatment as the hero actions and
/// playback selectors; a white glass tint distinguishes the active season.
struct TVSeasonChip: View {
    let season: Season
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            TVSeasonChipLabel(text: chipLabel, isSelected: isSelected)
        }
        .tvDetailGlassControl(shape: .capsule, isSelected: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var chipLabel: String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return "Specials" }
        return "Season \(season.seasonNumber)"
    }
}

private struct TVSeasonChipLabel: View {
    let text: String
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let usesInvertedLabel = isFocused || isSelected
        Text(text)
            .font(.system(size: 22, weight: usesInvertedLabel ? .semibold : .medium))
            .foregroundStyle(usesInvertedLabel ? Color.black : Color.white)
            .padding(.horizontal, 6)
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
    var onFocusedSeasonChange: ((Season?) -> Void)? = nil

    @FocusState private var focusedSeasonId: String?
    /// Entry preference is intentionally separate from server-driven
    /// selection updates. A direct Select press advances this preference
    /// synchronously, before the episode rail changes beneath the row.
    @State private var defaultFocusSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: 14) {
                        ForEach(seasons) { season in
                            TVSeasonChip(
                                season: season,
                                isSelected: selectedSeasonId == season.id,
                                onSelect: {
                                    // Establish the fallback before the
                                    // selection mutates the surrounding page.
                                    // If tvOS reevaluates focus while the rail
                                    // reloads, the pill the person selected is
                                    // already this row's preferred target.
                                    defaultFocusSeasonId = season.id
                                    TVDetailFocusDiagnostics.record(
                                        "season.select",
                                        target: "seasonPill",
                                        action: "select",
                                        state: focusState(
                                            selectedId: selectedSeasonId,
                                            focusedId: focusedSeasonId,
                                            preferredId: season.id
                                        ),
                                        essential: true
                                    )
                                    onSelect(season)
                                }
                            )
                            .id(season.id)
                            .focused($focusedSeasonId, equals: season.id)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .focusSection()
            .applyChipRowDefaultFocus(defaultFocusSeasonId, binding: $focusedSeasonId)
            .onChange(of: selectedSeasonId) { oldId, newId in
                guard let newId else { return }
                TVDetailFocusDiagnostics.record(
                    "season.selectionChanged",
                    target: "seasonPill",
                    action: "selectionChanged",
                    state: "from=\(seasonNumber(for: oldId)) to=\(seasonNumber(for: newId)) "
                        + focusState(
                            selectedId: newId,
                            focusedId: focusedSeasonId,
                            preferredId: defaultFocusSeasonId
                        ),
                    essential: true
                )
                // A focused chip is already visible and is the source of this
                // selection. Re-centering its ScrollView here can briefly
                // invalidate that native focus while the episode rail below
                // is also changing size, allowing the outer Play default to
                // win. Only programmatic, off-row selections need centering.
                guard focusedSeasonId == nil else { return }
                defaultFocusSeasonId = newId
                withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onChange(of: focusedSeasonId) { oldId, newId in
                TVDetailFocusDiagnostics.record(
                    "season.focusChanged",
                    target: "seasonPill",
                    action: newId == nil ? "lost" : "focused",
                    state: "from=\(seasonNumber(for: oldId)) to=\(seasonNumber(for: newId)) "
                        + focusState(
                            selectedId: selectedSeasonId,
                            focusedId: newId,
                            preferredId: defaultFocusSeasonId
                        ),
                    essential: newId == nil
                )
                if newId == nil {
                    defaultFocusSeasonId = selectedSeasonId
                }
                onFocusedSeasonChange?(
                    newId.flatMap { id in seasons.first(where: { $0.id == id }) }
                )
            }
            .onDisappear { onFocusedSeasonChange?(nil) }
            .onAppear {
                // Center the selected chip on first paint too. Without this a
                // high-numbered season (e.g. Season 8) opens with the row
                // scrolled to Season 1 and the selected chip clipped off-screen
                // until the user d-pads into it. The HStack is non-lazy, so the
                // target chip is already laid out — no dispatch hop needed.
                guard let selectedSeasonId else { return }
                defaultFocusSeasonId = selectedSeasonId
                TVDetailFocusDiagnostics.record(
                    "season.rowAppeared",
                    target: "seasonRow",
                    action: "appear",
                    state: focusState(
                        selectedId: selectedSeasonId,
                        focusedId: focusedSeasonId,
                        preferredId: selectedSeasonId
                    )
                )
                proxy.scrollTo(selectedSeasonId, anchor: .center)
            }
        }
    }

    private func focusState(
        selectedId: String?,
        focusedId: String?,
        preferredId: String?
    ) -> String {
        "selected=\(seasonNumber(for: selectedId)) "
            + "focused=\(seasonNumber(for: focusedId)) "
            + "preferred=\(seasonNumber(for: preferredId))"
    }

    private func seasonNumber(for id: String?) -> String {
        guard let id else { return "none" }
        return seasons.first(where: { $0.id == id })
            .map { String($0.seasonNumber) } ?? "unknown"
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
