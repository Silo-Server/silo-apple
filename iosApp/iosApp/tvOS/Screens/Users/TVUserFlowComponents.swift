#if os(tvOS)
import SwiftUI

// Pieces shared by the Apple TV account screens (spec §5.2–§5.7): Choose an
// Account's cards, the server rows of "Sign in to…", their status badges,
// and where focus goes after a card or row disappears.

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

/// Up to four of an account's profiles, overlapping left to right (spec
/// §5.2). An account without cached profiles shows a person glyph.
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
                        // The card's own server, which needn't be the active one.
                        ProfileAvatar(profile: profile, serverURL: serverURL, size: size, initialScale: 0.44)
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
        /// This Apple TV user's account (Choose an Account).
        case lastUsed
        /// The account open now (Settings › Account and Server).
        case current
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
        case .lastUsed: return ChooseAccountViewModel.lastUsedLabel
        case .current: return AccountsSettingsViewModel.currentLabel
        case .signInAgain: return ChooseAccountViewModel.signInAgainLabel
        }
    }

    private var symbol: String? {
        switch kind {
        case .lastUsed: return nil
        case .current: return "checkmark"
        case .signInAgain: return "exclamationmark.circle.fill"
        }
    }

    private var ink: Color {
        kind == .signInAgain ? .black : Color.siloOnSurface
    }

    private var fill: Color {
        switch kind {
        case .signInAgain: return Color.siloStatusWarning
        case .current, .lastUsed: return Color(white: 0.16)
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
    /// Room for the username, the email, and the server.
    static let height: CGFloat = 352
    static let spacing: CGFloat = 56
    /// Four per row: 4 × 360 + 3 × 56 = 1608, which leaves room for the
    /// focus ring and lift inside the 1740 pt safe width.
    static let maxColumns = 4
}

// MARK: - Server rows

/// The row look of "Sign in to…": glass at rest,
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
