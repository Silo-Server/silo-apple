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
    /// Optional long-press action. When set, every chip offers
    /// "Mark <Season> Watched/Unwatched" for its own season. Returns false
    /// when the server rejected the change so the chip drops its optimistic
    /// state.
    var onSetWatched: ((Season, Bool) async -> Bool)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playedOverrides: [String: Bool] = [:]

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
            .onChange(of: seasons) { _, _ in
                // Refreshed payloads carry the server's answer; drop any
                // optimistic chip state so a rejected change cannot linger.
                playedOverrides = [:]
            }
        }
    }

    private func isPlayed(_ season: Season) -> Bool {
        playedOverrides[season.id] ?? (season.userData?.played ?? false)
    }

    @ViewBuilder
    private func contextActions(for season: Season) -> some View {
        if let onSetWatched {
            Button {
                let played = !isPlayed(season)
                playedOverrides[season.id] = played
                Task { @MainActor in
                    if await onSetWatched(season, played) == false {
                        playedOverrides[season.id] = nil
                    }
                }
            } label: {
                // Always say "Season N" here even when the chip shows a custom
                // title such as "Series 2"; the action names the watched target.
                Label(
                    isPlayed(season)
                        ? "Mark \(season.downloadDisplayName) as Unwatched"
                        : "Mark \(season.downloadDisplayName) as Watched",
                    systemImage: isPlayed(season) ? "circle" : "checkmark.circle"
                )
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

    @ViewBuilder
    private func chip(for season: Season) -> some View {
        if onSetWatched != nil {
            chipButton(for: season)
                .contextMenu { contextActions(for: season) }
        } else {
            chipButton(for: season)
        }
    }

    private func chipButton(for season: Season) -> some View {
        let isSelected = selected?.id == season.id
        return Button {
            onSelect(season)
        } label: {
            Text(label(for: season))
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 36)
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
                )
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
