#if !os(tvOS)
import SwiftUI

/// Horizontal "Cast & Crew" rail for the phone, iPad and Mac detail page.
/// Round portrait thumbnails with the person's name and role or character
/// beneath. Mirrors `TVDetailCastRail` semantics: the same data source,
/// scaled down for touch. Groups after the first are separated by a thin
/// divider with a small vertical label.
struct PhoneCastRail: View {
    let groups: [CastCrewGroup]
    let onTap: (String) -> Void

    private let photoSize: CGFloat = 76
    private let cardWidth: CGFloat = 96
    private let cardSpacing: CGFloat = 14

    init(groups: [CastCrewGroup], onTap: @escaping (String) -> Void) {
        self.groups = groups
        self.onTap = onTap
    }

    /// Cast-only rail in server order, used by season and episode pages.
    init(cast: [CastMember], onTap: @escaping (String) -> Void) {
        self.init(groups: CastCrewGroups.castOnly(cast), onTap: onTap)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
                ForEach(groups) { group in
                    if let label = group.dividerLabel {
                        groupDivider(label: label)
                    }
                    ForEach(group.entries) { entry in
                        card(for: entry)
                    }
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.vertical, 4)
            .phoneMediaRailBounds()
        }
    }

    private func card(for entry: CastCrewEntry) -> some View {
        Button {
            if let personId = entry.personId { onTap(personId) }
        } label: {
            VStack(spacing: 8) {
                photo(for: entry)
                VStack(spacing: 2) {
                    Text(entry.name)
                        .font(nameFont)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                    if let caption = entry.caption, !caption.isEmpty {
                        Text(caption)
                            .font(captionFont)
                            .foregroundColor(.siloSecondaryText)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(width: cardWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nameFont: Font { .system(size: 12, weight: .semibold) }
    private var captionFont: Font { .system(size: 11, weight: .regular) }

    /// Thin rule beside the portraits with the group name running up it.
    /// The hidden text below reserves the same height as a card's name and
    /// caption, so the rule lines up with the portraits whether the rail
    /// aligns cards to the top or the centre.
    private func groupDivider(label: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1, height: photoSize)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.siloSecondaryText)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12, height: photoSize)
            }
            VStack(spacing: 2) {
                Text(" ").font(nameFont).lineLimit(2, reservesSpace: true)
                Text(" ").font(captionFont).lineLimit(1)
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func photo(for entry: CastCrewEntry) -> some View {
        ZStack {
            Color.siloSurfaceElevated
            if let url = entry.photoUrl, !url.isEmpty {
                AsyncImageView(url: url, contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: photoSize * 0.4))
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: photoSize, height: photoSize)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
#endif
