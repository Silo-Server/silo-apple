#if !os(tvOS)
import SwiftUI

// MARK: - Primary play

/// Primary play control for the refined detail page.
///
/// Still full-width — on a phone detail page Play *is* the page's job, and
/// both Apple TV and Netflix commit to a wide primary. What made the shipping
/// version read as a web CTA was everything around it: 52pt of pure white with
/// a row of naked, unlabelled circles floating underneath and a ragged grid of
/// form fields below that. Trimmed to 50pt with a slightly quieter label, it
/// anchors the stack instead of shouting over it.
struct PhoneRefinedPlayButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Labelled secondary action

/// One named secondary action — a filled circle with no outline, over a
/// caption. This mirrors the approved detail treatment: the icon remains a
/// generous touch target while the caption removes any guesswork.
///
/// The shipping page gives favourite, watchlist, watched, download, and the
/// overflow menu the same 44pt circular silhouette, centred under Play with
/// nothing tying them to it. Five identical circles is a guessing game; a
/// heart and a bookmark are not self-evidently different commitments. Naming
/// them costs one line of 10pt text each and removes the guess entirely.
struct PhoneLabeledAction: View {
    let icon: String
    var iconActive: String? = nil
    var isActive: Bool = false
    let label: String
    /// Spoken instead of `label` when set, so VoiceOver can say "Remove from
    /// Favorites" where the visual only changes tint and fill. A caption that
    /// reads the same in both states tells a VoiceOver user neither what is
    /// true now nor what activating will do.
    var accessibilityLabelOverride: String? = nil
    let action: () -> Void

    private var resolvedIcon: String {
        if isActive, let iconActive { return iconActive }
        return icon
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: resolvedIcon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.continuumOnSurface)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(Color.white.opacity(isActive ? 0.18 : 0.10))
                    )
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))

                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.continuumOnSurface.opacity(isActive ? 0.92 : 0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabelOverride ?? label)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// Menu-backed peer of `PhoneLabeledAction`, for the overflow entry.
struct PhoneLabeledMenu<MenuContent: View>: View {
    var icon: String = "ellipsis"
    let label: String
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.continuumOnSurface)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Action row container

/// Evenly distributes the named actions across the content width and rules
/// them off from the overview below, so the cluster reads as one band of
/// controls rather than loose ornaments.
struct PhoneLabeledActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}
#endif
