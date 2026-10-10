#if !os(tvOS)
import SwiftUI

/// Horizontal cast rail for the phone detail page. Round portrait
/// thumbnails with the actor's name and character beneath. Mirrors
/// `TVDetailCastRail` semantics — the same data source, scaled down
/// for touch.
struct PhoneCastRail: View {
    let cast: [CastMember]
    let onTap: (String) -> Void

    private let cardSpacing: CGFloat = 14
    private let maxEntries = 24

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
                ForEach(cast.prefix(maxEntries)) { member in
                    PhoneCastCard(member: member, onTap: onTap)
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

private struct PhoneCastCard: View {
    let member: CastMember
    let onTap: (String) -> Void

    private let photoSize: CGFloat = 76
    /// Grows with the names beneath the photo so a name keeps its default
    /// words per line instead of breaking inside a word at large text sizes.
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 96

    var body: some View {
        Button {
            if let personId = member.personId { onTap(personId) }
        } label: {
            VStack(spacing: 8) {
                photo
                VStack(spacing: 2) {
                    Text(member.name)
                        .siloScaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.siloOnSurface)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                    if let character = member.character, !character.isEmpty {
                        Text(character)
                            .siloScaledFont(size: 11, relativeTo: .caption2)
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
            if let url = member.photoUrl, !url.isEmpty {
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
