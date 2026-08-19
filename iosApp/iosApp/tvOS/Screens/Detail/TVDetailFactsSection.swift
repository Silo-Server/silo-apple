#if os(tvOS)
import SwiftUI

/// "Details" header + facts grid, as the movie / series / season detail
/// screens render it below the fold.
struct TVDetailsSection: View {
    let detail: ItemDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSectionHeader(title: "Details")
            TVDetailFactsSection(detail: detail)
        }
    }
}

/// "Details" block under the hero on tvOS — lists directors, writers,
/// studios/networks, countries, and release date in a key/value grid.
///
/// Data is pulled from `detail.crew`, `detail.studios`, etc. The section
/// hides cleanly when no facts are available.
struct TVDetailFactsSection: View {
    let detail: ItemDetail

    private let columnGap: CGFloat = 64

    // The facts grid is pure text with no actionable child, so nothing here
    // is a native focus target. On tvOS the scroll view can only bring a
    // *focusable* view into view, so without this the Details block is
    // unreachable — pressing Down from the Cast rail finds no target below
    // and the section never scrolls on-screen. Making the whole block one
    // passive focus target (Select is a no-op) lets the engine land on it
    // and scroll it fully into view, the same idiom `TVSelectorValue` uses
    // for single-option pills.
    @FocusState private var isFocused: Bool

    var body: some View {
        let facts = DetailFacts.assemble(from: detail)
        if !facts.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.element.label) { index, fact in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                    HStack(alignment: .top, spacing: columnGap) {
                        Text(fact.label.uppercased())
                            .font(.system(size: 18, weight: .bold))
                            .tracking(2.0)
                            .foregroundColor(.siloOnSurface.opacity(0.5))
                            .frame(width: 260, alignment: .leading)
                        Text(fact.value)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.siloOnSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 22)
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            // Focus highlight bleeds outward via negative padding so the
            // facts text stays aligned with the "Details" header above it.
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.06 : 0))
                    .padding(.horizontal, -28)
                    .padding(.vertical, -14)
            )
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        }
    }
}
#endif
