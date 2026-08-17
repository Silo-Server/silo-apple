#if !os(tvOS)
import SwiftUI

/// "Details" key/value list rendered below the hero. Mirrors
/// `TVDetailFactsSection` — same data sources (crew, studios, networks,
/// dates) — but laid out as a phone-friendly inset list with thin
/// dividers and tight rows.
struct PhoneDetailFactsSection: View {
    let detail: ItemDetail

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
                    HStack(alignment: .top, spacing: 16) {
                        Text(fact.label.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundColor(.siloOnSurface.opacity(0.5))
                            .frame(width: 100, alignment: .leading)
                        Text(fact.value)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.siloOnSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
