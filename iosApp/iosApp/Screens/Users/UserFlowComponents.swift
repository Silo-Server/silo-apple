#if !os(tvOS)
import SwiftUI

// The pieces Choose a User, Choose a Server, "Sign in to…", and Manage Users
// share on iPhone, iPad, and Mac.

// MARK: - Page

/// The page Choose a User, Choose a Server, and "Sign in to…" share: Who's
/// Watching's look (brand light under an ambient scrim, a centered headline,
/// utilities at the bottom) in a column that widens on iPad and Mac.
///
/// A pushed page gets a Back button on iPhone and iPad (the Mac toolbar has
/// its own). A root page shows the wordmark, or Cancel when `onCancel` is
/// set. Over the signed-in app, which has no first-run backdrop, the page
/// draws its own.
struct UserFlowPage<Content: View, Footer: View>: View {
    var router: AppRouter
    var onCancel: (() -> Void)?
    /// The column in a wide window: room for two user cards side by side,
    /// or a narrower list of servers.
    var wideColumnWidth: CGFloat = 560
    @ViewBuilder var content: (_ isWide: Bool) -> Content
    @ViewBuilder var footer: () -> Footer

    /// Windows at least this wide (iPad, Mac) get the wide column.
    static var wideThreshold: CGFloat { 700 }

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= Self.wideThreshold
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    content(isWide)
                    Spacer(minLength: 32)
                    footer()
                }
                .frame(maxWidth: isWide ? wideColumnWidth : 440)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MarqueeTopBar {
                leading
            } trailing: {
                EmptyView()
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
        }
        .background { background }
        .marqueeTransparentNavigation()
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            if !router.authState.showsMarqueeBackdrop {
                MarqueeBackdrop()
            }
            MarqueeScrim(style: .ambient)
        }
    }

    @ViewBuilder
    private var leading: some View {
        #if os(iOS)
        if !router.path.isEmpty {
            MarqueeIconButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                router.goBack()
            }
        } else {
            rootLeading
        }
        #else
        if router.path.isEmpty {
            rootLeading
        }
        #endif
    }

    @ViewBuilder
    private var rootLeading: some View {
        if let onCancel {
            UserFlowCancelButton(action: onCancel)
        } else {
            SiloWordmarkView(width: 92)
        }
    }
}

/// Cancel at the top of a sign-in step: back to where the sign-in started.
struct UserFlowCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(ConfirmationCopy.cancelTitle, action: action)
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
            .keyboardShortcut(.cancelAction)
    }
}

/// A small utility under the cards (Manage Users…), styled like Who's
/// Watching's Change server and Sign out.
struct UserFlowUtilityButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.marquee(.plain, fullWidth: false, compact: true))
    }
}

/// The quiet line under a list ("Touch and hold a user…").
struct UserFlowHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.siloOnSurface.opacity(0.45))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Cards

private let userFlowCardCorner: CGFloat = 18

/// A card that is one button: a user, or an "Add …" action.
struct UserFlowCardButtonStyle: ButtonStyle {
    /// The "Add …" cards: a dashed outline instead of a fill.
    var isAddition = false
    /// Fills its grid cell, so cards side by side share a height.
    var fillsHeight = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: userFlowCardCorner, style: .continuous)
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .leading)
            .background {
                if isAddition {
                    shape
                        .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.02))
                        .overlay(
                            shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                                .foregroundStyle(Color.white.opacity(0.28))
                        )
                } else {
                    // Plain translucency, as server setup's Recent list: glass
                    // would lens the headline into the card's edge.
                    shape
                        .fill(Color.white.opacity(configuration.isPressed ? 0.13 : 0.07))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
            }
            .contentShape(shape)
            #if os(iOS)
            .contentShape(.contextMenuPreview, shape)
            #endif
            .opacity(configuration.isPressed ? 0.85 : 1)
            .marqueePressHaptic(configuration.isPressed)
    }
}

/// One user on Choose a User (spec §5.2): stacked avatars of the profiles on
/// the user's last server, the name, the server ("Home Silo" or "2
/// servers"), Last used, and Sign in again when that sign-in expired. At
/// accessibility text sizes the avatars sit above the text.
struct UserCardLabel: View {
    let card: ChooseUserViewModel.Card
    /// The last server's address, for avatars stored as paths on it.
    let serverAddress: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            StackedProfileAvatars(
                profiles: card.avatars,
                fallbackID: card.id,
                fallbackName: card.name,
                serverAddress: serverAddress
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(card.name)
                    .font(.headline)
                    .foregroundStyle(Color.siloOnSurface)
                Text(card.serverLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                if card.needsSignInAgain || card.isLastUsed {
                    HStack(spacing: 8) {
                        if card.needsSignInAgain {
                            UserFlowBadge(text: ChooseUserViewModel.signInAgainLabel, warning: true)
                        }
                        if card.isLastUsed {
                            Text(ChooseUserViewModel.lastUsedLabel)
                                .font(.caption)
                                .foregroundStyle(Color.siloOnSurface.opacity(0.45))
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked {
                UserFlowChevron()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityName)
        .accessibilityValue(card.accessibilityValue)
    }
}

/// An "Add …" card's content: a dashed plus, then the title.
struct UserFlowAdditionLabel: View {
    let title: String
    var systemImage = "plus"

    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.white.opacity(0.35))
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: min(markSize, 56) * 0.4, weight: .medium))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.75))
                }
                .frame(width: min(markSize, 56), height: min(markSize, 56))
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.siloOnSurface.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small status capsule ("Sign in again") that grows with the text size.
struct UserFlowBadge: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(warning ? Color.siloStatusWarning : Color.siloOnSurface.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(warning ? Color.siloStatusWarning.opacity(0.1) : Color.white.opacity(0.08))
                    .overlay(
                        Capsule().strokeBorder(
                            warning ? Color.siloStatusWarning.opacity(0.4) : Color.white.opacity(0.16),
                            lineWidth: 1
                        )
                    )
            )
            .fixedSize()
    }
}

struct UserFlowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.siloOnSurface.opacity(0.4))
            .accessibilityHidden(true)
    }
}

// MARK: - Server list

/// A rounded group of rows, the look of server setup's Recent list.
struct UserFlowRowGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct UserFlowRowDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }
}

/// One server in a user (spec §5.3): its mark and name, the server username
/// when it says something the user's name doesn't, and Active or Sign in
/// again. At accessibility text sizes the status sits under the name.
struct UserServerRowLabel: View {
    let name: String
    let address: String
    let username: String?
    let status: ChooseServerViewModel.Status

    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: stacked ? .top : .center, spacing: 12) {
            MarqueeServerMark(
                name: name,
                imageURL: ServerBrandingCache.branding(for: address)?.markURL,
                size: min(markSize, 56)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.45))
                    .lineLimit(stacked ? nil : 2)
                    .truncationMode(.middle)
                if stacked {
                    statusView
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked {
                statusView
            }
            UserFlowChevron()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, username].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(status.label ?? "")
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .signInAgain:
            UserFlowBadge(text: ChooseServerViewModel.Status.signInAgain.label ?? "", warning: true)
        case .active:
            Text(ChooseServerViewModel.Status.active.label ?? "")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface.opacity(0.72))
        case .none:
            EmptyView()
        }
    }

    /// "sam2 · friend.example", or the host alone when the username isn't
    /// shown.
    private var detail: String {
        let host = ServerBranding.hostLabel(address)
        guard let username else { return host }
        return username + SiloUserNaming.separator + host
    }
}

// MARK: - Avatars

/// Up to four profile avatars, overlapping, the first on top (spec §5.2).
/// Before any profiles are cached for the user, one avatar with the user's
/// initial stands in.
struct StackedProfileAvatars: View {
    let profiles: [SavedSignInProfile]
    let fallbackID: String
    let fallbackName: String
    let serverAddress: String?
    var maxCount = ChooseUserViewModel.maxAvatars

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 40

    var body: some View {
        let size = min(scaledSize, 60)
        let shown = Array(profiles.prefix(maxCount))
        HStack(spacing: -size * 0.38) {
            if shown.isEmpty {
                ProfileAvatar(id: fallbackID, name: fallbackName, avatarEmoji: nil, avatarImageUrl: nil,
                              serverURL: nil, size: size, initialScale: Self.initialScale)
                    .background(Self.separator)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, profile in
                // The user's last server, which needn't be the active one.
                ProfileAvatar(profile: profile, serverURL: serverAddress, size: size,
                              initialScale: Self.initialScale, showsFallbackUntilLoaded: true)
                    .background(Self.separator)
                    .zIndex(Double(shown.count - index))
            }
        }
        .accessibilityHidden(true)
    }

    private static let initialScale: CGFloat = 0.42

    /// Separates overlapping avatars.
    private static var separator: some View {
        Circle().fill(Color.black).padding(-2)
    }
}

#endif
