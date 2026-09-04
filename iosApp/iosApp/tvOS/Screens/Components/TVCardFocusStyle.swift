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
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
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
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }
}
#endif
