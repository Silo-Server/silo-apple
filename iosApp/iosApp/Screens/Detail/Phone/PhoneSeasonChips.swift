#if !os(tvOS)
import SwiftUI

/// Horizontal scroll of season chips for the phone series detail page.
/// Selected = filled white capsule with dark text; unselected =
/// outlined transparent capsule. Mirrors `TVSeasonChip` semantics in a
/// touch-sized form.
struct PhoneSeasonChips: View {
    let seasons: [Season]
    let selected: Season?
    let onSelect: (Season) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        chip(for: season)
                            .id(season.id)
                    }
                }
                .padding(.horizontal, ContinuumTheme.safePadding)
                .padding(.vertical, 4)
            }
            .onAppear {
                scrollToSelection(selected?.id, using: proxy, animated: false)
            }
            .onChange(of: selected?.id) { _, newId in
                scrollToSelection(newId, using: proxy, animated: !reduceMotion)
            }
        }
    }

    private func scrollToSelection(
        _ id: String?,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let id else { return }
        if animated {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func chip(for season: Season) -> some View {
        let isSelected = selected?.id == season.id
        return Button {
            onSelect(season)
        } label: {
            Text(label(for: season))
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                // Selected stays an opaque white capsule: against a row of
                // glass siblings that contrast is what marks the current
                // season, and glass-on-glass would make selection ambiguous.
                .background(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.clear), in: Capsule())
                .siloGlass(in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func label(for season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return "Specials" }
        return "Season \(season.seasonNumber)"
    }
}
#endif
