#if !os(tvOS)
import SwiftUI

/// Horizontal scroll of season chips for the phone series detail page.
/// Selected = filled white capsule with dark text; unselected =
/// outlined transparent capsule.
struct PhoneSeasonChips: View {
    let seasons: [Season]
    let selected: Season?
    let onSelect: (Season) -> Void
    var onSetWatched: ((Season, Bool) -> Void)? = nil
    var isUpdatingWatched = false

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
                .padding(.horizontal, SiloTheme.safePadding)
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
            withAnimation(.easeOut(duration: SiloTheme.fastDuration)) {
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
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let onSetWatched {
                Button {
                    onSetWatched(season, !(season.userData?.played ?? false))
                } label: {
                    Label(
                        season.userData?.played == true ? "Mark Season Unwatched" : "Mark Season Watched",
                        systemImage: season.userData?.played == true ? "circle" : "checkmark.circle"
                    )
                }
                .disabled(isUpdatingWatched || season.episodeCount == 0)
            }
        }
        .foregroundStyle(isSelected ? Color.black : Color.white)
        .background(
            Group {
                if isSelected {
                    Capsule().fill(Color.white)
                } else {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                }
            }
            .frame(height: 36)
        )
        .buttonStyle(.plain)
    }

    private func label(for season: Season) -> String {
        if let title = season.title, !title.isEmpty { return title }
        if season.seasonNumber == 0 { return "Specials" }
        return "Season \(season.seasonNumber)"
    }
}
#endif
