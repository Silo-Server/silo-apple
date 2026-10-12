#if os(tvOS)
import SwiftUI

struct TVCardFocusButtonStyle: ButtonStyle {
    var scale: CGFloat = 1.05
    var focusedShadowOpacity: Double = 0.45
    var focusedShadowRadius: CGFloat = 18
    var focusedShadowY: CGFloat = 8
    var unfocusedShadowOpacity: Double = 0.3
    var unfocusedShadowRadius: CGFloat = 8
    var unfocusedShadowY: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        TVCardFocusButtonStyleBody(
            configuration: configuration,
            focusedScale: scale,
            focusedShadowOpacity: focusedShadowOpacity,
            focusedShadowRadius: focusedShadowRadius,
            focusedShadowY: focusedShadowY,
            unfocusedShadowOpacity: unfocusedShadowOpacity,
            unfocusedShadowRadius: unfocusedShadowRadius,
            unfocusedShadowY: unfocusedShadowY
        )
    }
}

private struct TVCardFocusButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let focusedScale: CGFloat
    let focusedShadowOpacity: Double
    let focusedShadowRadius: CGFloat
    let focusedShadowY: CGFloat
    let unfocusedShadowOpacity: Double
    let unfocusedShadowRadius: CGFloat
    let unfocusedShadowY: CGFloat

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(currentScale)
            .shadow(
                color: .black.opacity(isFocused ? focusedShadowOpacity : unfocusedShadowOpacity),
                radius: isFocused ? focusedShadowRadius : unfocusedShadowRadius,
                y: isFocused ? focusedShadowY : unfocusedShadowY
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var currentScale: CGFloat {
        guard !reduceMotion else { return 1 }
        let base = isFocused ? focusedScale : 1
        return configuration.isPressed ? base * 0.97 : base
    }
}

enum TVCardCaption {
    /// tvOS's `.card` lift grows artwork by a near-constant ~38pt in height
    /// at every card size, so it overhangs its bottom edge by about 19pt.
    static let cardLiftOverhang: CGFloat = 19
    /// Visible space kept between a focused poster and its title.
    static let focusedClearance: CGFloat = 8
    /// Unfocused captions dim well back so the focused one stands out.
    static let unfocusedTitleOpacity: Double = 0.45
    static let unfocusedSubtitleOpacity: Double = 0.32
}

/// With Reduce Motion on, the caption still drops clear of the lifted poster
/// but snaps there instead of sliding; the glow keeps its fade.
private struct TVCardCaptionFocusModifier: ViewModifier {
    let isFocused: Bool
    let drop: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .shadow(color: .white.opacity(isFocused ? 0.45 : 0), radius: 10)
            .shadow(color: .white.opacity(isFocused ? 0.25 : 0), radius: 3)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .offset(y: isFocused ? drop : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }
}

extension View {
    func tvFocusRing(
        isFocused: Bool,
        cornerRadius: CGFloat,
        lineWidth: CGFloat = 3
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.white.opacity(isFocused ? 0.9 : 0),
                    lineWidth: isFocused ? lineWidth : 0
                )
        )
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }

    /// Focused card title: brighter and heavier than its dimmed neighbours.
    /// Pair with `tvCardSubtitleFocus` and `tvCardCaptionFocus` so the whole
    /// caption highlights as one block.
    func tvCardTitleFocus(isFocused: Bool) -> some View {
        fontWeight(isFocused ? .semibold : nil)
            .foregroundStyle(
                isFocused
                    ? Color.white
                    : Color.siloOnSurface.opacity(TVCardCaption.unfocusedTitleOpacity)
            )
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }

    /// A card's second caption line (year, count, episode) follows the
    /// title's highlight.
    func tvCardSubtitleFocus(isFocused: Bool) -> some View {
        fontWeight(isFocused ? .medium : nil)
            .foregroundStyle(
                isFocused
                    ? Color.white.opacity(0.92)
                    : Color.siloOnSurface.opacity(TVCardCaption.unfocusedSubtitleOpacity)
            )
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }

    /// Highlights a focused card's whole caption block with a soft glow and
    /// drops it clear of the grown artwork so it never touches the poster.
    /// `posterOverhang` is how far the focused artwork extends below its
    /// layout frame; `spacing` is the card's poster-to-caption gap. Resting
    /// layout is unchanged. Don't clip the caption, or the glow is cut off.
    func tvCardCaptionFocus(
        isFocused: Bool,
        posterOverhang: CGFloat = TVCardCaption.cardLiftOverhang,
        spacing: CGFloat
    ) -> some View {
        modifier(TVCardCaptionFocusModifier(
            isFocused: isFocused,
            drop: max(0, posterOverhang + TVCardCaption.focusedClearance - spacing)
        ))
    }

    /// Lands d-pad entry into a rail on `id` instead of the geometrically
    /// nearest card; `.userInitiated` priority is what lets `defaultFocus`
    /// win over proximity. No-op while `id` is nil (loading or empty).
    @ViewBuilder
    func tvDefaultFocus(_ id: String?, in binding: FocusState<String?>.Binding) -> some View {
        if let id {
            defaultFocus(binding, id, priority: .userInitiated)
        } else {
            self
        }
    }

    /// Binds a card to its parent's `@FocusState` when the parent supplies
    /// one, so the parent can route default focus onto it.
    @ViewBuilder
    func tvFocused(_ binding: FocusState<String?>.Binding?, equals id: String?) -> some View {
        if let binding, let id {
            focused(binding, equals: id)
        } else {
            self
        }
    }
}
#endif
