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
                        PhoneCastCrewDivider(label: label)
                    }
                    ForEach(group.entries) { entry in
                        PhoneCastCard(entry: entry, onTap: onTap)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 4)
            .phoneMediaRailBounds()
        }
        .contentMargins(.horizontal, SiloTheme.safePadding, for: .scrollContent)
        .mediaRailScrolling()
        // Cards widen with the text; past AX2 one name would fill the screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private enum PhoneCastCardMetrics {
    static let photoSize: CGFloat = 76
}

private extension View {
    func phoneCastNameFont() -> some View {
        siloScaledFont(size: 12, weight: .semibold, relativeTo: .caption)
    }

    func phoneCastCaptionFont() -> some View {
        siloScaledFont(size: 11, relativeTo: .caption2)
    }
}

private struct PhoneCastCard: View {
    let entry: CastCrewEntry
    let onTap: (String) -> Void

    private let photoSize = PhoneCastCardMetrics.photoSize
    /// Grows with the names beneath the photo so a name keeps its default
    /// words per line instead of breaking inside a word at large text sizes.
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 96

    var body: some View {
        Button {
            if let personId = entry.personId { onTap(personId) }
        } label: {
            VStack(spacing: 8) {
                photo
                VStack(spacing: 2) {
                    Text(entry.name)
                        .phoneCastNameFont()
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                    if let caption = entry.caption, !caption.isEmpty {
                        Text(caption)
                            .phoneCastCaptionFont()
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

    private var photo: some View {
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

/// Thin rule beside the portraits with the group name running up it.
/// The hidden text below reserves the same height as a card's name and
/// caption, so the rule lines up with the portraits whether the rail
/// aligns cards to the top or the centre.
private struct PhoneCastCrewDivider: View {
    let label: String

    private let photoSize = PhoneCastCardMetrics.photoSize

    var body: some View {
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
                Text(" ").phoneCastNameFont().lineLimit(2, reservesSpace: true)
                Text(" ").phoneCastCaptionFont().lineLimit(1)
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif
