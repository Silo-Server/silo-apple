#if os(tvOS)
import SwiftUI

/// Shared presentation for provider search and AI subtitle creation.
struct TVSubtitleDialog<Content: View>: View {
    let title: String
    let subtitle: String
    let backHint: String
    var statusHint: String = ""
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)

                Divider().overlay(.white.opacity(0.12))
                content()
                Divider().overlay(.white.opacity(0.12))

                HStack {
                    Label(backHint, systemImage: "chevron.backward.circle")
                    Spacer()
                    Text(statusHint)
                }
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
            }
            .padding(34)
            .frame(width: 1280, height: 800)
            .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 26, y: 14)
        }
    }
}

/// Native button with the player HUD's white focus fill and inverted label.
struct TVSubtitleMenuRow<Content: View>: View {
    let rowID: String
    var isDisabled: Bool = false
    @FocusState.Binding var focusedID: String?
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 18) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVSubtitleMenuRowStyle(isFocused: focusedID == rowID))
        .focusEffectDisabled()
        .focused($focusedID, equals: rowID)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct TVSubtitleMenuRowStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
#endif
