#if os(iOS)
import SwiftUI

struct SiloControlModeButton: View {
    @Bindable var controller: SiloControlClient
    var usesGlassCircle = false
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

    @ViewBuilder
    private func buttonLabel(isActive: Bool) -> some View {
        let icon = Image(systemName: "appletvremote.gen4")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isActive ? Color.continuumBackground : Color.continuumOnSurface)
            .frame(width: ContinuumTheme.topBarIconHitSize, height: ContinuumTheme.topBarIconHitSize)
            .contentShape(Circle())

        if isActive {
            icon.background {
                Circle().fill(Color.continuumOnSurface)
            }
        } else if usesGlassCircle {
            icon.siloGlass(
                in: Circle(),
                tint: Color.black.opacity(0.18),
                interactive: true
            )
        } else {
            icon
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
