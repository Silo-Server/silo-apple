#if os(tvOS)
import SwiftUI

struct TVControlStandbyView: View {
    @Bindable var receiver: TVControlReceiver
    let state: TVControlStandbyState

    @FocusState private var isDisconnectFocused: Bool

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 34) {
                Image(systemName: "appletvremote.gen4")
                    .font(.system(size: 86, weight: .medium))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: 150, height: 150)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }

                VStack(spacing: 12) {
                    Text("Ready for \(state.controllerLabel)")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(Color.siloOnSurface)
                        .multilineTextAlignment(.center)

                    Text(state.serverName ?? "Remote control active")
                        .font(.title3)
                        .foregroundStyle(Color.siloSecondaryText)
                        .multilineTextAlignment(.center)
                }

                Button("Disconnect Remote", systemImage: "tv.slash") {
                    receiver.disconnectRemoteControl()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .focused($isDisconnectFocused)
            }
            .padding(.horizontal, 120)
        }
        .onAppear {
            isDisconnectFocused = true
        }
        .preferredColorScheme(.dark)
    }
}
#endif
