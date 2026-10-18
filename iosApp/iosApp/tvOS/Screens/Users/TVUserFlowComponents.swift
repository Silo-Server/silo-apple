#if os(tvOS)
import SwiftUI

// Pieces shared by the Apple TV user screens (spec §5.2–§5.7): Choose a
// User's cards, the server rows of Choose a Server and "Sign in to…", their
// status badges, and where focus goes after a card or row disappears.

// MARK: - Focus after a removal

/// Where focus goes when the item that held it disappears: the item that
/// took its place, else the one before it. Apple's guidelines allow moving
/// focus without the person only in this case (docs/tvos-focus.md).
enum TVFocusNeighbor {
    /// `removed` was at its index in `before`; `after` is what shows now.
    /// Nil when `removed` is still there, or nothing is left to focus.
    static func replacement<ID: Hashable>(for removed: ID, before: [ID], after: [ID]) -> ID? {
        guard !after.contains(removed), let index = before.firstIndex(of: removed) else { return nil }
        let survivors = before.filter { after.contains($0) }
        guard !survivors.isEmpty else { return nil }
        // Items before the removed one keep their order, so the one that now
        // sits at its index is the next survivor.
        let survivorsBefore = before[..<index].filter { after.contains($0) }.count
        return survivorsBefore < survivors.count ? survivors[survivorsBefore] : survivors[survivors.count - 1]
    }
}

// MARK: - Avatars

/// One profile's round avatar as Who's Watching draws it (`ProfileTile`): the
/// profile's tint as a lit sphere, with its picture, emoji, or initial. A user
/// card shows profiles from a server that may not be the active one, so a
/// server-relative picture resolves against that card's server.
struct TVUserAvatar: View {
    let profile: SavedSignInProfile
    /// The address of the server the profile belongs to.
    var serverURL: String?
    var size: CGFloat

    private var tint: Color { ProfileTilePalette.tint(for: profile.id) }

    var body: some View {
        ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [tint.mix(with: .white, by: 0.35), tint, tint.mix(with: .black, by: 0.45)],
                    center: UnitPoint(x: 0.3, y: 0.25),
                    startRadius: 0,
                    endRadius: size * 0.8
                )
            )
            content
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let url = TVUserAvatarSource.imageURL(for: profile, serverURL: serverURL) {
            AsyncImageView(url: url, contentMode: .fill)
                .frame(width: size, height: size)
        } else if let emoji = TVUserAvatarSource.emoji(for: profile) {
            Text(emoji)
                .font(.system(size: size * 0.5))
        } else {
            Text(TVUserAvatarSource.initial(for: profile))
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

/// Where a cached profile's avatar comes from (`ProfileAvatarResolver`'s
/// rules, with a server-relative path resolved against the profile's own
/// server rather than the active one).
enum TVUserAvatarSource {
    static func imageURL(for profile: SavedSignInProfile, serverURL: String?) -> String? {
        if let raw = trimmed(profile.avatarImageUrl) {
            if raw.hasPrefix("/") {
                if !isVector(raw), let resolved = resolve(raw, against: serverURL) { return resolved }
            } else if let resolved = ProfileAvatarResolver.serverResolvedImageURL(raw) {
                return resolved
            }
        }
        guard let avatar = trimmed(profile.avatarEmoji), ProfileAvatarResolver.isImage(avatar) else { return nil }
        if avatar.hasPrefix("/") { return resolve(avatar, against: serverURL) }
        return ProfileAvatarResolver.imageURL(for: avatar)
    }

    /// The emoji drawn when there is no picture. An `upload:` reference only
    /// loads through `avatar_url`.
    static func emoji(for profile: SavedSignInProfile) -> String? {
        guard let avatar = trimmed(profile.avatarEmoji),
              !ProfileAvatarResolver.isImage(avatar),
              !avatar.lowercased().hasPrefix("upload:") else { return nil }
        return avatar
    }

    static func initial(for profile: SavedSignInProfile) -> String {
        trimmed(profile.name).map { String($0.prefix(1)).uppercased() } ?? "?"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The image pipeline has no SVG decoder (`ProfileAvatarResolver`).
    private static func isVector(_ path: String) -> Bool {
        let bare = path.lowercased().split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return bare.hasSuffix(".svg") || bare.hasSuffix("/svg")
    }

    private static func resolve(_ path: String, against serverURL: String?) -> String? {
        guard let base = trimmed(serverURL)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !base.isEmpty else { return nil }
        return base + path
    }
}

/// Up to four profiles of a user's last-used server, overlapping left to
/// right (spec §5.2). A user without cached profiles shows a person glyph.
struct TVUserAvatarStack: View {
    let profiles: [SavedSignInProfile]
    var serverURL: String?
    var size: CGFloat = 104

    /// How much of each avatar shows before the next one covers it.
    private var step: CGFloat { size * 0.6 }

    var body: some View {
        Group {
            if profiles.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            } else {
                ZStack(alignment: .leading) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        TVUserAvatar(profile: profile, serverURL: serverURL, size: size)
                            // A dark ring keeps each avatar's edge readable
                            // where it overlaps the one before it.
                            .background(Circle().fill(Color.black).padding(-4))
                            .padding(.leading, CGFloat(index) * step)
                            .zIndex(Double(profiles.count - index))
                    }
                }
            }
        }
        .frame(height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Badges

/// A status on a card or row. Each has text, so the state never depends on
/// colour or focus alone; the fills are solid so they read on the resting
/// glass and on the white focused platter.
struct TVUserStatusBadge: View {
    enum Kind {
        /// This Apple TV user's Silo user (Choose a User).
        case lastUsed
        /// The server open now (Choose a Server).
        case active
        /// The saved sign-in expired.
        case signInAgain
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
            }
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    var title: String {
        switch kind {
        case .lastUsed: return ChooseUserViewModel.lastUsedLabel
        case .active: return ChooseServerViewModel.Status.active.label ?? "Active"
        case .signInAgain: return ChooseUserViewModel.signInAgainLabel
        }
    }

    private var symbol: String? {
        switch kind {
        case .lastUsed: return nil
        case .active: return "checkmark"
        case .signInAgain: return "exclamationmark.circle.fill"
        }
    }

    private var ink: Color {
        kind == .signInAgain ? .black : Color.siloOnSurface
    }

    private var fill: Color {
        switch kind {
        case .signInAgain: return Color.siloStatusWarning
        case .active, .lastUsed: return Color(white: 0.16)
        }
    }

    private var border: Color {
        kind == .signInAgain ? .clear : Color.white.opacity(0.18)
    }
}

// MARK: - User card

/// A user card's focus look, in Who's Watching's language: glass at rest; on
/// focus it lifts and gains the white ring profile tiles use.
struct TVUserCardStyle: ButtonStyle {
    var isDashed = false

    func makeBody(configuration: Configuration) -> some View {
        TVUserCardBody(configuration: configuration, isDashed: isDashed)
    }
}

private struct TVUserCardBody: View {
    let configuration: ButtonStyleConfiguration
    let isDashed: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)

    var body: some View {
        configuration.label
            .frame(width: TVUserCardMetrics.width, height: TVUserCardMetrics.height)
            .background { background }
            .background {
                shape
                    .strokeBorder(Color.siloOnSurface, lineWidth: 6)
                    .padding(-12)
                    .opacity(isFocused ? 1 : 0)
            }
            .scaleEffect(isFocused && !reduceMotion ? 1.08 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 30 : 0, y: isFocused ? 20 : 0)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .focusEffectDisabled()
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
    }

    @ViewBuilder
    private var background: some View {
        if isDashed {
            shape
                .fill(Color.white.opacity(isFocused ? 0.14 : 0))
                .overlay {
                    shape
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                        .foregroundStyle(Color.white.opacity(isFocused ? 0.7 : 0.25))
                }
        } else {
            // A flat fill: glass under a card that scales on focus draws
            // its own edge highlights inside the ring.
            shape
                .fill(Color(white: isFocused ? 0.2 : 0.12).opacity(isFocused ? 0.92 : 0.72))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
    }
}

enum TVUserCardMetrics {
    static let width: CGFloat = 360
    static let height: CGFloat = 320
    static let spacing: CGFloat = 56
    /// Four per row: 4 × 360 + 3 × 56 = 1608, which leaves room for the
    /// focus ring and lift inside the 1740 pt safe width.
    static let maxColumns = 4
}

// MARK: - Server rows

/// The row look shared by Choose a Server and "Sign in to…": glass at rest,
/// a white platter with dark ink on focus, like the first-run buttons.
struct TVServerRowStyle: ButtonStyle {
    var isDashed = false

    func makeBody(configuration: Configuration) -> some View {
        TVServerRowBody(configuration: configuration, isDashed: isDashed)
    }
}

private struct TVServerRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isDashed: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.siloOnSurface)
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background { background }
            .contentShape(shape)
            .scaleEffect(isFocused && !reduceMotion ? 1.03 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 24, y: 14)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
    }

    @ViewBuilder
    private var background: some View {
        if isFocused {
            shape.fill(Color.siloOnSurface)
        } else if isDashed {
            shape
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                .foregroundStyle(Color.white.opacity(0.28))
        } else {
            shape
                .fill(Color.white.opacity(0.07))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .siloGlass(in: shape)
        }
    }
}

/// A server in a row: its mark, its name, a detail line, and a badge.
struct TVServerRowLabel: View {
    let name: String
    let detail: String?
    let address: String
    var badge: TVUserStatusBadge.Kind?

    var body: some View {
        HStack(spacing: 22) {
            MarqueeServerMark(
                name: name,
                imageURL: ServerBrandingCache.branding(for: address)?.markURL,
                size: 64
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 22))
                        .opacity(0.62)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 16)
            if let badge {
                TVUserStatusBadge(kind: badge)
            }
        }
        .padding(.vertical, 18)
    }
}

/// "Add Server", "Add a New Server": a plus in place of the mark.
struct TVAddRowLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 64, height: 64)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
    }
}

// MARK: - Page chrome

/// The hold-for-more hint in a chooser's bottom-right corner.
struct TVHoldHint: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "hand.tap")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.siloOnSurface.opacity(0.45))
            .accessibilityHidden(true)
    }
}

/// A chooser's title, set like Who's Watching's.
struct TVChooserTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 64, weight: .heavy))
            .kerning(-1.6)
            .foregroundStyle(Color.siloOnSurface)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The background of a user screen: the first-run screens draw over the
/// shared brand light; inside the app (Settings, the top menu) there is
/// none, so the screen brings the plain canvas.
struct TVUserFlowBackground: View {
    let showsBrandLight: Bool

    var body: some View {
        if showsBrandLight {
            MarqueeScrim(style: .ambient)
        } else {
            ZStack {
                Color.siloBackground
                MarqueeScrim(style: .ambient)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
