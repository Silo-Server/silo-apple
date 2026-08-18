#if !os(tvOS)
import SwiftUI

/// "Cast & Crew" header + rail, as used by every phone detail body.
struct PhoneCastSection: View {
    let cast: [CastMember]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Cast & Crew")
                .padding(.horizontal, SiloTheme.safePadding)
            PhoneCastRail(cast: cast, onTap: onTap)
        }
    }
}

/// Horizontal cast rail for the phone detail page. Round portrait
/// thumbnails with the actor's name and character beneath. Mirrors
/// `TVDetailCastRail` semantics — the same data source, scaled down
/// for touch.
struct PhoneCastRail: View {
    let cast: [CastMember]
    let onTap: (String) -> Void

    private let photoSize: CGFloat = 76
    private let cardWidth: CGFloat = 96
    private let cardSpacing: CGFloat = 14
    private let maxEntries = 24

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(cast.prefix(maxEntries)) { member in
                    Button {
                        if let personId = member.personId { onTap(personId) }
                    } label: {
                        VStack(spacing: 8) {
                            photo(for: member)
                            VStack(spacing: 2) {
                                Text(member.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.siloOnSurface)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.center)
                                if let character = member.character, !character.isEmpty {
                                    Text(character)
                                        .font(.system(size: 11, weight: .regular))
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
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func photo(for member: CastMember) -> some View {
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
