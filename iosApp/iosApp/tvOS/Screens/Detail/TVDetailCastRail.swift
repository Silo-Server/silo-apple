#if os(tvOS)
import SwiftUI

/// Horizontal "Cast & Crew" rail used on the tvOS item detail screen. Each
/// card is a focus-liftable portrait with the person's name and role or
/// character label. Groups after the first are separated by a thin,
/// non-focusable divider with a small vertical label, so focus moves
/// straight from one card to the next across groups.
struct TVDetailCastRail: View {
    let groups: [CastCrewGroup]
    let onTap: (String) -> Void
    /// Non-zero changes explicitly hand focus into the first card from
    /// the composite Series episode carousel.
    var focusRequest = 0
    var onFocusChange: ((Bool) -> Void)? = nil

    private let photoWidth: CGFloat = 200
    private let photoHeight: CGFloat = 200
    private let cardSpacing: CGFloat = 60
    @FocusState private var focusedEntryId: String?

    init(
        groups: [CastCrewGroup],
        onTap: @escaping (String) -> Void,
        focusRequest: Int = 0,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.groups = groups
        self.onTap = onTap
        self.focusRequest = focusRequest
        self.onFocusChange = onFocusChange
    }

    /// Cast-only rail in server order, used by season and episode pages.
    init(
        cast: [CastMember],
        onTap: @escaping (String) -> Void,
        focusRequest: Int = 0,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.init(
            groups: CastCrewGroups.castOnly(cast),
            onTap: onTap,
            focusRequest: focusRequest,
            onFocusChange: onFocusChange
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(groups) { group in
                    if let label = group.dividerLabel {
                        TVCastCrewDivider(label: label, photoHeight: photoHeight)
                    }
                    ForEach(group.entries) { entry in
                        TVCastCard(
                            entry: entry,
                            photoSize: CGSize(width: photoWidth, height: photoHeight),
                            onTap: onTap
                        )
                        .focused($focusedEntryId, equals: entry.id)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .focusSection()
        .applyCastRailDefaultFocus(defaultFocusId, binding: $focusedEntryId)
        .scrollClipDisabled()
        .onChange(of: focusedEntryId != nil) { _, focused in
            onFocusChange?(focused)
        }
        .onChange(of: focusRequest) { _, request in
            guard request > 0, let defaultFocusId else { return }
            focusedEntryId = defaultFocusId
        }
    }

    private var defaultFocusId: String? {
        groups.first?.entries.first?.id
    }
}

private extension View {
    /// When focus enters the cast/crew rail, land on the first person rather
    /// than letting tvOS choose a geometrically-nearest card.
    @ViewBuilder
    func applyCastRailDefaultFocus(
        _ firstEntryId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let firstEntryId {
            self.defaultFocus(binding, firstEntryId, priority: .userInitiated)
        } else {
            self
        }
    }
}

private struct TVCastCard: View {
    let entry: CastCrewEntry
    let photoSize: CGSize
    let onTap: (String) -> Void

    var body: some View {
        Button {
            if let personId = entry.personId { onTap(personId) }
        } label: {
            CastCardLabel(entry: entry, photoSize: photoSize)
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
    let entry: CastCrewEntry
    let photoSize: CGSize

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: TVCastCardMetrics.photoToTextSpacing) {
            photo
            VStack(spacing: TVCastCardMetrics.nameToCaptionSpacing) {
                Text(entry.name)
                    .font(TVCastCardMetrics.nameFont)
                    .foregroundColor(isFocused ? .siloOnSurface : Color.siloOnSurface.opacity(0.88))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                if let caption = entry.caption, !caption.isEmpty {
                    Text(caption)
                        .font(TVCastCardMetrics.captionFont)
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
            if let url = entry.photoUrl, !url.isEmpty {
                CachedAsyncImage(
                    url: url,
                    targetSize: photoSize,
                    thumbhash: entry.photoThumbhash,
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

private enum TVCastCardMetrics {
    static let nameFont = Font.system(size: 20, weight: .semibold)
    static let captionFont = Font.system(size: 17, weight: .regular)
    static let photoToTextSpacing: CGFloat = 12
    static let nameToCaptionSpacing: CGFloat = 4
}

/// Thin rule between card groups with the group name running up it. It has
/// no focusable content, so the focus engine skips it. The hidden text
/// below reserves the same height as a card's name and caption, so the rule
/// lines up with the portraits under the rail's centre alignment.
private struct TVCastCrewDivider: View {
    let label: String
    let photoHeight: CGFloat

    var body: some View {
        VStack(spacing: TVCastCardMetrics.photoToTextSpacing) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 2, height: photoHeight)
                Text(label.uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .tracking(2.0)
                    .foregroundColor(.siloSecondaryText)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: photoHeight)
            }
            VStack(spacing: TVCastCardMetrics.nameToCaptionSpacing) {
                Text(" ").font(TVCastCardMetrics.nameFont).lineLimit(2, reservesSpace: true)
                Text(" ").font(TVCastCardMetrics.captionFont).lineLimit(1)
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
