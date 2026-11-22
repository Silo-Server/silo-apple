#if os(tvOS)
import SwiftUI

/// "Details" block under the hero on tvOS — lists directors, writers,
/// studios/networks, countries, and release date in a key/value grid.
///
/// Data is pulled from `detail.crew`, `detail.studios`, etc. The section
/// hides cleanly when no facts are available.
struct TVDetailFactsSection: View {
    let detail: ItemDetail
    /// Series shows the episode synopsis in the hero, so the series overview
    /// lives permanently at the top of the Details block instead.
    var showsOverview = false

    private let columnGap: CGFloat = 64

    // The facts grid is pure text with no actionable child, so nothing here
    // is a native focus target. On tvOS the scroll view can only bring a
    // *focusable* view into view, so without this the Details block is
    // unreachable — pressing Down from the Cast rail finds no target below
    // and the section never scrolls on-screen. Making the whole block one
    // passive focus target (Select is a no-op) lets the engine land on it
    // and scroll it fully into view, the same idiom the other passive detail
    // rows use.
    @FocusState private var isFocused: Bool
    @Environment(\.locale) private var locale

    private var trimmedOverview: String? {
        guard showsOverview,
              let text = detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    var body: some View {
        let facts = DetailFacts(detail: detail).assembleFacts(locale: locale)
        let overview = trimmedOverview
        if overview != nil || !facts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let overview {
                    Text(overview)
                        .font(.system(size: 24, weight: .regular))
                        .lineSpacing(6)
                        .foregroundColor(.siloOnSurface.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .padding(.bottom, facts.isEmpty ? 8 : 26)
                    if !facts.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                }
                // Labels are translated text, so they can't serve as identity.
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                    HStack(alignment: .top, spacing: columnGap) {
                        Text(fact.label.uppercased(with: locale))
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
