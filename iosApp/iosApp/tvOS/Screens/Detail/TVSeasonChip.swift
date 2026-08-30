#if os(tvOS)
import SwiftUI

/// Season chip used on series / season / episode detail pages. It uses the
/// same native Liquid Glass control treatment as the hero actions and
/// playback selectors; a white glass tint distinguishes the active season.
struct TVSeasonChip: View {
    let season: Season
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        TVSeasonChipLabel(
            text: chipLabel,
            isSelected: isSelected,
            isFocused: isFocused
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .contentShape(Capsule())
        .tvDetailGlassSurface(
            in: Capsule(),
            isSelected: isSelected,
            isFocused: isFocused
        )
        .scaleEffect(isFocused ? 1.08 : 1)
        .shadow(
            color: Color.white.opacity(isFocused ? 0.28 : 0),
            radius: isFocused ? 16 : 0,
            y: isFocused ? 5 : 0
        )
        .zIndex(isFocused ? 1 : 0)
        .animation(
            .easeOut(duration: ContinuumTheme.fastDuration),
            value: isFocused
        )
        .accessibilityIdentifier(
            isSelected
                ? "detail.season.selected.\(season.seasonNumber)"
                : "detail.season.\(season.seasonNumber)"
        )
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
    let isFocused: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: isFocused || isSelected ? .semibold : .medium))
            // Selection stays legible as a quiet persistent state. Only live
            // focus inverts against the bright white glass highlight.
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .padding(.horizontal, 6)
    }
}

/// Horizontal scroll of season chips. Auto-centers the selected chip when it
/// changes. Before this row owns focus, only the selected chip is an eligible
/// entry target; once focus lands, every chip becomes eligible for ordinary
/// horizontal navigation.
struct TVSeasonChipRow: View {
    let seasons: [Season]
    let selectedSeasonId: String?
    let onSelect: (Season) -> Void
    var onFocusedSeasonChange: ((Season?) -> Void)? = nil

    @Namespace private var seasonFocusScope
    @FocusState private var focusedSeasonId: String?
    /// Stays true across tvOS's transient `pill -> nil -> pill` handoff so a
    /// horizontal move never changes every pill's eligibility at once.
    @State private var rowOwnsFocus = false
    @State private var focusExitTask: Task<Void, Never>?
    /// Entry preference is intentionally separate from server-driven
    /// selection updates. A direct Select press advances this preference
    /// synchronously, before the episode rail changes beneath the row.
    @State private var defaultFocusSeasonId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Keep each pill's native glass surface independent. A shared
                // GlassEffectContainer couples their rendering when the
                // focused pill scales and changes tint, which makes the whole
                // row flash during a horizontal focus handoff on Apple TV.
                HStack(spacing: 14) {
                    ForEach(seasons) { season in
                        TVSeasonChip(
                            season: season,
                            isSelected: selectedSeasonId == season.id,
                            isFocused: focusedSeasonId == season.id
                        )
                        .id(season.id)
                        // This composite is the pill's only focus and
                        // activation owner. There is no nested Button whose
                        // action can be intercepted by the eligibility gate.
                        .focusable(canReceiveEntryFocus(season))
                        .focused($focusedSeasonId, equals: season.id)
                        .onTapGesture { selectSeason(season) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectSeason(season) }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .focusSection()
            // Evaluate the selected-season preference only when focus enters
            // this row. A page-wide preference can lose to geometric proximity
            // or compete with Play while the detail page is appearing.
            .focusScope(seasonFocusScope)
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
                // Keep entry from either direction aligned with the model,
                // including selection changes that did not originate from a
                // pill press. This preference does not move active focus; it
                // is evaluated the next time focus enters this scope.
                defaultFocusSeasonId = newId
                // A focused chip is already visible and is the source of this
                // selection. Re-centering its ScrollView here can briefly
                // invalidate that native focus while the episode rail below
                // is also changing size, allowing the outer Play default to
                // win. Only programmatic, off-row selections need centering.
                guard focusedSeasonId == nil else { return }
                withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onChange(of: focusedSeasonId) { oldId, newId in
                focusExitTask?.cancel()
                focusExitTask = nil
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
                if let newId {
                    setRowOwnsFocus(true)
                    onFocusedSeasonChange?(
                        seasons.first(where: { $0.id == newId })
                    )
                } else {
                    // Focus commonly passes through nil for one frame between
                    // adjacent native Buttons. Do not collapse eligibility or
                    // notify the parent until nil persists long enough to be
                    // an actual row exit; either action rebuilds every glass
                    // pill and creates a visible row-wide flash.
                    focusExitTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled, focusedSeasonId == nil else {
                            return
                        }
                        setRowOwnsFocus(false)
                        defaultFocusSeasonId = selectedSeasonId
                        onFocusedSeasonChange?(nil)
                    }
                }
            }
            .onDisappear {
                focusExitTask?.cancel()
                focusExitTask = nil
                onFocusedSeasonChange?(nil)
            }
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

    private func selectSeason(_ season: Season) {
        // Establish the fallback before the selection mutates the surrounding
        // page. If tvOS reevaluates focus while the rail reloads, this pill is
        // already the row's preferred target.
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

    private func canReceiveEntryFocus(_ season: Season) -> Bool {
        guard let selectedSeasonId else { return true }
        return rowOwnsFocus || season.id == selectedSeasonId
    }

    private func setRowOwnsFocus(_ ownsFocus: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rowOwnsFocus = ownsFocus
        }
    }

    private func seasonNumber(for id: String?) -> String {
        guard let id else { return "none" }
        return seasons.first(where: { $0.id == id })
            .map { String($0.seasonNumber) } ?? "unknown"
    }
}

private extension View {
    /// Fallback for focus-scope reevaluation. Directional entry is guaranteed
    /// separately by `canReceiveEntryFocus(_:)` because tvOS does not consult
    /// this preference on every move into the row.
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
