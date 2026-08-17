#if os(tvOS)
import SwiftUI

/// Horizontal cast rail used on the tvOS item detail screen. Each card is
/// a focus-liftable portrait with the actor's name and character label.
struct TVDetailCastRail: View {
    let cast: [CastMember]
    let onTap: (String) -> Void

    private let photoWidth: CGFloat = 200
    private let photoHeight: CGFloat = 200
    private let cardSpacing: CGFloat = 44
    private let maxEntries = 24
    @FocusState private var focusedCastId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(cast.prefix(maxEntries)) { member in
                    TVCastCard(
                        member: member,
                        photoSize: CGSize(width: photoWidth, height: photoHeight),
                        onTap: onTap
                    )
                    .focused($focusedCastId, equals: member.id)
                }
            }
            .padding(.vertical, 24)
        }
        .focusSection()
        .applyDefaultFocusIfPresent($focusedCastId, id: defaultFocusId)
        .scrollClipDisabled()
    }

    private var defaultFocusId: String? {
        cast.prefix(maxEntries).first?.id
    }
}

private struct TVCastCard: View {
    let member: CastMember
    let photoSize: CGSize
    let onTap: (String) -> Void

    var body: some View {
        Button {
            if let personId = member.personId { onTap(personId) }
        } label: {
            CastCardLabel(member: member, photoSize: photoSize)
        }
        .buttonStyle(CastCardStyle(photoSize: photoSize))
    }
}

/// Card body rendered per-focus-state via `@Environment(\.isFocused)`
/// from the button style's makeBody context.
private struct CastCardLabel: View {
    let member: CastMember
    let photoSize: CGSize

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 16) {
            photo
            VStack(spacing: 4) {
                Text(member.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isFocused ? .siloOnSurface : Color.siloOnSurface.opacity(0.88))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                if let character = member.character, !character.isEmpty {
                    Text(character)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        }
        .frame(width: photoSize.width)
    }

    @ViewBuilder
    private var photo: some View {
        ZStack {
            Color.siloSurfaceElevated
            if let url = member.photoUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: photoSize,
                    contentMode: .fill
                )
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: photoSize.width * 0.4))
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(isFocused ? 0.85 : 0.08), lineWidth: isFocused ? 2 : 1)
        )
    }
}

/// Custom style so the system doesn't paint its default focus halo on
/// top. Scale + shadow only — the portrait ring handles the focus cue.
private struct CastCardStyle: ButtonStyle {
    let photoSize: CGSize

    func makeBody(configuration: Configuration) -> some View {
        CastCardBody(configuration: configuration)
    }
}

private struct CastCardBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(isFocused ? 0.35 : 0.0),
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused ? 1.05 : 1.0
        return configuration.isPressed ? base * 0.97 : base
    }
}
#endif
