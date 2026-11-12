#if os(iOS)
import SwiftUI

struct SiloControlModeButton: View {
    let controller: SiloControlClient
    let onChooseTarget: () -> Void

    var body: some View {
        if controller.remotePlaybackEngaged {
            Menu {
                Button { controller.showRemoteControl() } label: {
                    Label(.castPickerRemoteControl, systemImage: "slider.horizontal.3")
                }
                Button { onChooseTarget() } label: {
                    Label(.remoteChooseTv, systemImage: "tv")
                }
                Divider()
                Button(role: .destructive) { controller.disconnect() } label: {
                    Label(.remoteTurnOffControlMode, systemImage: "tv.slash")
                }
            } label: {
                buttonLabel(isActive: true)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(Text(.remoteControlMode))
            .accessibilityValue(Text(.remoteControlModeActive))
        } else {
            Button(action: onChooseTarget) {
                buttonLabel(isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.castPickerRemoteControl))
        }
    }

    private func buttonLabel(isActive: Bool) -> some View {
        Image(systemName: isActive ? "appletvremote.gen4.fill" : "appletvremote.gen4")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.siloOnSurface)
            .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
            .contentShape(Rectangle())
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
