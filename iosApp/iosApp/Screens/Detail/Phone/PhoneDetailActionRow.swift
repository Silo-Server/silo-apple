#if !os(tvOS)
import SwiftUI

// MARK: - Shared metrics

/// One place for the named action row's dimensions. `DownloadActionButton`
/// and `SeriesDownloadMenuButton` draw their own state-derived glyphs and
/// captions but must land on the same baseline as their neighbours, so they
/// read these rather than repeating the numbers.
enum PhoneDetailActionMetrics {
    /// Diameter of the glass disc behind each glyph. Five actions have to fit
    /// across a phone's content width, which caps this around 50pt.
    static let glyphDiameter: CGFloat = 50
    static let glyphPointSize: CGFloat = 20
    static let captionSpacing: CGFloat = 7
    static let captionFont = Font.system(size: 10, weight: .medium)
    static let inactiveCaptionTint = Color.continuumOnSurface.opacity(0.6)
}

// MARK: - Primary play

/// Primary play control for the refined detail page.
///
/// Still full-width — on a phone detail page Play *is* the page's job, and
/// both Apple TV and Netflix commit to a wide primary. It now uses the
/// system's prominent Liquid Glass style through `siloPrimaryButton()`, the
/// same routing the rest of the app's primary actions take, so it picks up
/// the platform's own press, tint, and legibility handling instead of a
/// hand-rolled white capsule.
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
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .siloPrimaryButton()
    }
}

// MARK: - Shared glass glyph

/// Chrome for one named action: a glyph on a Liquid Glass disc over a
/// caption.
///
/// The disc is what ties the cluster together — bare glyphs under a
/// full-width Play read as loose ornaments, and the old opaque white-wash
/// circles read as a different species of control from everything else on a
/// 26 page. Glass gives the actions a body that still lets the hero artwork
/// through.
///
/// `glassTint` doubles as the "on" signal: a tinted disc is the state
/// indicator, so the glyph itself can stay white and legible instead of
/// tinting accent-on-accent.
struct PhoneGlassActionLabel<Glyph: View>: View {
    let caption: String
    var captionTint: Color = PhoneDetailActionMetrics.inactiveCaptionTint
    /// Non-nil marks the action as active/engaged and tints its disc.
    var glassTint: Color? = nil
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        VStack(spacing: PhoneDetailActionMetrics.captionSpacing) {
            glyph()
                .frame(
                    width: PhoneDetailActionMetrics.glyphDiameter,
                    height: PhoneDetailActionMetrics.glyphDiameter
                )
                .siloGlass(in: Circle(), tint: glassTint, interactive: true)

            Text(caption)
                .font(PhoneDetailActionMetrics.captionFont)
                .foregroundStyle(captionTint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        // The caption and the gutters around the disc stay tappable, so the
        // target is the whole column rather than just the 50pt disc.
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Labelled secondary action

/// One named secondary action — glyph on glass over a caption.
///
/// Five identical discs would be a guessing game; a heart and a bookmark are
/// not self-evidently different commitments. Naming them costs one line of
/// 10pt text each and removes the guess entirely.
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
            PhoneGlassActionLabel(
                caption: label,
                captionTint: isActive
                    ? Color.continuumAccent
                    : PhoneDetailActionMetrics.inactiveCaptionTint,
                glassTint: isActive ? Color.continuumAccent : nil
            ) {
                Image(systemName: resolvedIcon)
                    .font(.system(size: PhoneDetailActionMetrics.glyphPointSize, weight: .regular))
                    .foregroundStyle(Color.continuumOnSurface)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
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
            PhoneGlassActionLabel(caption: label) {
                Image(systemName: icon)
                    .font(.system(size: PhoneDetailActionMetrics.glyphPointSize, weight: .regular))
                    .foregroundStyle(Color.continuumOnSurface)
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Action row container

/// Evenly distributes the named actions across the content width and rules
/// them off from the overview below, so the cluster reads as one band of
/// controls rather than loose ornaments.
///
/// The `GlassEffectContainer` is what makes the discs sample one shared
/// backdrop instead of each compositing its own; `spacing: 0` keeps them
/// distinct, since merging five differently-labelled actions into one blob
/// would undo the point of naming them.
struct PhoneLabeledActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    content()
                }
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}
#endif
