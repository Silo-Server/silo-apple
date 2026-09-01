#if os(iOS)
import SwiftUI

struct SiloControlModeButton: View {
    @Bindable var controller: SiloControlClient
    var usesGlass = false
    let onChooseTarget: () -> Void

    var body: some View {
        if controller.hasActiveSession {
            Menu {
                Button { controller.showRemoteControl() } label: {
                    Label("Remote Control", systemImage: "slider.horizontal.3")
                }
                Button { onChooseTarget() } label: {
                    Label("Choose TV", systemImage: "tv")
                }
                Divider()
                Button(role: .destructive) { controller.turnOffControlMode() } label: {
                    Label("Turn Off Control Mode", systemImage: "tv.slash")
                }
            } label: {
                buttonLabel(isActive: true)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("TV control mode")
        } else {
            Button(action: onChooseTarget) {
                buttonLabel(isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remote Control")
        }
    }

    private func buttonLabel(isActive: Bool) -> some View {
        Image(systemName: "appletvremote.gen4")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.continuumOnSurface)
            .frame(width: ContinuumTheme.topBarIconHitSize, height: ContinuumTheme.topBarIconHitSize)
            .modifier(ControlModeGlass(enabled: usesGlass, isActive: isActive))
            .contentShape(Circle())
    }
}

private struct ControlModeGlass: ViewModifier {
    let enabled: Bool
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.siloGlass(
                in: Circle(),
                tint: isActive ? Color.white.opacity(0.18) : nil,
                interactive: true
            )
        } else {
            content.background {
                if isActive {
                    Circle()
                        .fill(Color.continuumOnSurface)
                        .frame(width: 36, height: 36)
                }
            }
            .foregroundStyle(isActive ? Color.continuumBackground : Color.continuumOnSurface)
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 20) {
        SiloControlModeButton(controller: SiloControlClient(), onChooseTarget: {})
    }
    .padding()
    .background(Color.continuumBackground)
}
#endif
#endif
