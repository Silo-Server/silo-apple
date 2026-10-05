#if !os(tvOS)
import SwiftUI

/// Horizontal scroll of season chips for the phone series detail page.
/// Selected = filled white capsule with dark text; unselected =
/// outlined transparent capsule. The Mac shows each season as a poster card
/// with its name and episode count, the selected one outlined.
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
                HStack(alignment: .top, spacing: Self.itemSpacing) {
                    ForEach(seasons) { season in
                        #if os(macOS)
                        posterCard(for: season)
                            .id(season.id)
                        #else
                        chip(for: season)
                            .id(season.id)
                        #endif
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

    private static var itemSpacing: CGFloat {
        #if os(macOS)
        SiloTheme.spacing
        #else
        8
        #endif
    }

    @ViewBuilder
    private func watchedMenu(for season: Season) -> some View {
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

    #if os(macOS)
    private func posterCard(for season: Season) -> some View {
        let isSelected = selected?.id == season.id
        let width = SiloTheme.macSeasonCardWidth
        let size = CGSize(width: width, height: width * 1.5)
        let shape = RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
        return Button {
            onSelect(season)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let url = season.posterUrl, !url.isEmpty {
                        AsyncImageView(
                            url: url,
                            thumbhash: season.posterThumbhash,
                            targetSize: size,
                            contentMode: .fill
                        )
                    } else {
                        Color.siloSurfaceElevated
                            .overlay {
                                Image(systemName: "tv")
                                    .font(.title2)
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(
                        isSelected ? Color.siloPrimary : Color.clear,
                        lineWidth: SiloTheme.macHeroSelectionRingWidth
                    )
                }
                .overlay(alignment: .topTrailing) {
                    if season.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.8))
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }

                Text(label(for: season))
                    .font(.siloCardTitle)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                Text(season.episodeCount == 1 ? "1 episode" : "\(season.episodeCount) episodes")
                    .font(.siloCardMetadata)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: size.width, alignment: .leading)
            .opacity(isSelected ? 1 : SiloTheme.macSeasonUnselectedOpacity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.siloFlat)
        .accessibilityLabel(label(for: season))
        .accessibilityValue(season.userData?.played == true ? "Watched" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { watchedMenu(for: season) }
    }
    #endif

    private func chip(for season: Season) -> some View {
        let isSelected = selected?.id == season.id
        return Button {
            onSelect(season)
        } label: {
            Text(label(for: season))
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { watchedMenu(for: season) }
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
            .padding(.vertical, 4)
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
