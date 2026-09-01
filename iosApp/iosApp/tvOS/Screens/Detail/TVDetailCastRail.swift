#if os(tvOS)
import SwiftUI

/// Horizontal cast rail used on the tvOS item detail screen. Each card is
/// a focus-liftable portrait with the actor's name and character label.
struct TVDetailCastRail: View {
    let cast: [CastMember]
    let onTap: (String) -> Void
    /// Non-zero changes explicitly hand focus into the first cast card from
    /// the composite Series episode carousel.
    var focusRequest = 0

    private let photoWidth: CGFloat = 200
    private let photoHeight: CGFloat = 200
    private let cardSpacing: CGFloat = 60
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
            .padding(.vertical, 12)
        }
        .focusSection()
        .applyCastRailDefaultFocus(defaultFocusId, binding: $focusedCastId)
        .scrollClipDisabled()
        .onChange(of: focusRequest) { _, request in
            guard request > 0, let defaultFocusId else { return }
            focusedCastId = defaultFocusId
        }
    }

    private var defaultFocusId: String? {
        cast.prefix(maxEntries).first?.id
    }
}

private extension View {
    /// When focus enters the cast/crew rail, land on the first person rather
    /// than letting tvOS choose a geometrically-nearest card.
    @ViewBuilder
    func applyCastRailDefaultFocus(
        _ firstCastId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let firstCastId {
            self.defaultFocus(binding, firstCastId, priority: .userInitiated)
        } else {
            self
        }
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
        .buttonStyle(
            TVCardFocusButtonStyle(
                scale: 1.05,
                focusedShadowOpacity: 0.35,
                focusedShadowRadius: 14,
                focusedShadowY: 6,
                unfocusedShadowOpacity: 0,
                unfocusedShadowRadius: 0,
                unfocusedShadowY: 0
            )
        )
    }
}

/// Card body rendered per-focus-state via `@Environment(\.isFocused)`
/// from the button style's makeBody context.
private struct CastCardLabel: View {
    let member: CastMember
    let photoSize: CGSize

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 12) {
            photo
            VStack(spacing: 4) {
                Text(member.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isFocused ? .continuumOnSurface : Color.continuumOnSurface.opacity(0.88))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                if let character = member.character, !character.isEmpty {
                    Text(character)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.continuumSecondaryText)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        }
        .frame(width: photoSize.width)
    }

    @ViewBuilder
    private var photo: some View {
        ZStack {
            Color.continuumSurfaceElevated
            if let url = member.photoUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: photoSize,
                    thumbhash: member.photoThumbhash,
                    contentMode: .fill
                )
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: photoSize.width * 0.4))
                    .foregroundColor(.continuumSecondaryText)
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

#endif
