#if os(tvOS)
import SwiftUI

// Circular icon-button chrome used by the HUD's dialog close control.
// Extracted from TVPlayerInfoHUD.swift; behavior unchanged.

struct HUDCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HUDCircleButtonBody(configuration: configuration)
    }
}

struct HUDCircleButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .frame(width: 46, height: 46)
            .background(Circle().fill(isFocused ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }
}

struct HUDCloseButtonLabel: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}
#endif
