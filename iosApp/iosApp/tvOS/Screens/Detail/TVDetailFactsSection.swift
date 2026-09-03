#if os(tvOS)
import SwiftUI

/// "Details" block under the hero on tvOS — lists directors, writers,
/// studios/networks, countries, and release date in a key/value grid.
///
/// Data is pulled from `detail.crew`, `detail.studios`, etc. The section
/// hides cleanly when no facts are available.
struct TVDetailFactsSection: View {
    let detail: ItemDetail

    private let columnGap: CGFloat = 64
    private let rowGap: CGFloat = 20
    private let maxCreditNames = 3

    // The facts grid is pure text with no actionable child, so nothing here
    // is a native focus target. On tvOS the scroll view can only bring a
    // *focusable* view into view, so without this the Details block is
    // unreachable — pressing Down from the Cast rail finds no target below
    // and the section never scrolls on-screen. Making the whole block one
    // passive focus target (Select is a no-op) lets the engine land on it
    // and scroll it fully into view, matching the other passive detail rows
    // for single-option pills.
    @FocusState private var isFocused: Bool

    var body: some View {
        let facts = assembleFacts()
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
                            .foregroundColor(.continuumOnSurface.opacity(0.5))
                            .frame(width: 260, alignment: .leading)
                        Text(fact.value)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.continuumOnSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 22)
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            // Focus highlight bleeds outward via negative padding so the
            // facts text stays aligned with the "Details" header above it.
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.06 : 0))
                    .padding(.horizontal, -28)
                    .padding(.vertical, -14)
            )
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        }
    }

    private struct Fact {
        let label: String
        let value: String
    }

    private func assembleFacts() -> [Fact] {
        var facts: [Fact] = []

        if let directors = creditNames(forJobs: ["Director"]), !directors.isEmpty {
            facts.append(Fact(label: "Director", value: directors))
        }
        if let writers = creditNames(forJobs: ["Writer", "Screenplay", "Story"]), !writers.isEmpty {
            facts.append(Fact(label: writerLabel, value: writers))
        }

        if let studios = detail.studios, !studios.isEmpty {
            facts.append(Fact(label: "Studio", value: studios.prefix(3).joined(separator: ", ")))
        }
        if let networks = detail.networks, !networks.isEmpty {
            facts.append(Fact(label: "Network", value: networks.prefix(3).joined(separator: ", ")))
        }
        if let countries = detail.countries, !countries.isEmpty {
            facts.append(Fact(label: "Country", value: countries.prefix(3).joined(separator: ", ")))
        }
        if let airDate = DetailDateFormatting.longDate(detail.airDate) {
            facts.append(Fact(label: "Aired", value: airDate))
        }
        if let releaseDate = DetailDateFormatting.longDate(detail.releaseDate) {
            facts.append(Fact(label: "Released", value: releaseDate))
        }
        if let firstAired = DetailDateFormatting.longDate(detail.firstAirDate) {
            facts.append(Fact(label: "First Aired", value: firstAired))
        }
        if let lastAired = DetailDateFormatting.longDate(detail.lastAirDate) {
            facts.append(Fact(label: "Last Aired", value: lastAired))
        }
        return facts
    }

    private var writerLabel: String {
        let hasScreenplay = detail.crew?.contains { $0.job?.lowercased() == "screenplay" } ?? false
        return hasScreenplay ? "Writer" : "Written by"
    }

    private func creditNames(forJobs jobs: [String]) -> String? {
        guard let crew = detail.crew else { return nil }
        let lowered = jobs.map { $0.lowercased() }
        let names = crew
            .filter { member in
                guard let job = member.job?.lowercased() else { return false }
                return lowered.contains(job)
            }
            .map(\.name)
        if names.isEmpty { return nil }
        let trimmed = Array(Set(names)).sorted()
        let joined = trimmed.prefix(maxCreditNames).joined(separator: ", ")
        return trimmed.count > maxCreditNames ? "\(joined), …" : joined
    }
}
#endif
