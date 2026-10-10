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
