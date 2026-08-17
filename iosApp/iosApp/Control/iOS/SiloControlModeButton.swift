#if os(iOS)
import SwiftUI

struct SiloControlModeButton: View {
    @Bindable var controller: SiloControlClient
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
            .foregroundStyle(isActive ? Color.siloBackground : Color.siloOnSurface)
            .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
            .background {
                // Chrome-free at rest (Plex-style); a filled disc appears only
                // while actively controlling a TV so the state stays obvious.
                if isActive {
                    Circle()
                        .fill(Color.siloOnSurface)
                        .frame(width: 36, height: 36)
                }
            }
            .contentShape(Circle())
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 20) {
        SiloControlModeButton(controller: SiloControlClient(), onChooseTarget: {})
    }
    .padding()
    .background(Color.siloBackground)
}
#endif
#endif
