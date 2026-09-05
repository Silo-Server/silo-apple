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
    var focusRequestIsActive = true
    var onFocusRequestFailed: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil

    private let photoWidth: CGFloat = 200
    private let photoHeight: CGFloat = 200
    private let cardSpacing: CGFloat = 60
    private let maxEntries = 24
    @FocusState private var focusedCastId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(cast.prefix(maxEntries)) { member in
                        TVCastCard(
                            member: member,
                            photoSize: CGSize(width: photoWidth, height: photoHeight),
                            onTap: onTap
                        )
                        .focused($focusedCastId, equals: member.id)
                        .id(member.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .focusSection()
            .applyCastRailDefaultFocus(defaultFocusId, binding: $focusedCastId)
            .scrollClipDisabled()
            .task(id: "\(focusRequest):\(focusRequestIsActive)") {
                guard focusRequest > 0, focusRequestIsActive, let defaultFocusId else { return }
                // Disappearing or replacing this task must release its pending
                // handoff. The parent checks the captured generation and request
                // so an old cancellation cannot clear its replacement.
                defer {
                    if Task.isCancelled { onFocusRequestFailed?() }
                }
                // A previously scrolled cast strip may not have its first lazy
                // card mounted. Reveal it before handing focus across the boundary.
                proxy.scrollTo(defaultFocusId, anchor: .leading)
                for _ in 0..<12 {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch { return }
                    guard !Task.isCancelled else { return }
                    if focusedCastId == defaultFocusId { return }
                    focusedCastId = defaultFocusId
                }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch { return }
                guard !Task.isCancelled, focusedCastId != defaultFocusId else { return }
                onFocusRequestFailed?()
            }
            .onChange(of: focusedCastId) { _, id in
                if id != nil { onFocus?() }
            }
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
                    .foregroundColor(isFocused ? .siloOnSurface : Color.siloOnSurface.opacity(0.88))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                if let character = member.character, !character.isEmpty {
                    Text(character)
                        .font(.system(size: 17, weight: .regular))
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
                    thumbhash: member.photoThumbhash,
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

#endif
