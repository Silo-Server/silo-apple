import SwiftUI

/// The app's own dialog: a card over the dimmed screen, used instead of a
/// system alert or action sheet where the choice matters (spec §4.1, §4.4).
/// A system dialog chose its own default button; this one leaves that to
/// its content, which makes Cancel the default.
///
/// Tapping outside the card or pressing Escape (Menu on Apple TV) cancels.
/// On iPhone the card rises from the bottom like a sheet; elsewhere it is
/// centered.
struct MarqueeDialog<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        ZStack(alignment: placement) {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(padding)
            .frame(maxWidth: maxWidth)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.siloSurfaceElevated.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .siloGlass(in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .padding(outerPadding)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            #if os(tvOS)
            .focusSection()
            .onExitCommand(perform: onCancel)
            #elseif os(macOS)
            .onExitCommand(perform: onCancel)
            #else
            .background {
                // Escape on a hardware keyboard.
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            #endif
        }
    }

    private var placement: Alignment {
        #if os(iOS)
        sizeClass == .compact ? .bottom : .center
        #else
        .center
        #endif
    }

    #if os(tvOS)
    private let padding: CGFloat = 48
    private let maxWidth: CGFloat = 860
    private let corner: CGFloat = 36
    private let outerPadding: CGFloat = 80
    #elseif os(macOS)
    private let padding: CGFloat = 22
    private let maxWidth: CGFloat = 400
    private let corner: CGFloat = 20
    private let outerPadding: CGFloat = 24
    #else
    private let padding: CGFloat = 22
    private let maxWidth: CGFloat = 440
    private let corner: CGFloat = 28
    private let outerPadding: CGFloat = 12
    #endif
}

/// A dialog's title and message.
struct MarqueeDialogHeader: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: titleFont, weight: .bold))
                .foregroundStyle(Color.siloOnSurface)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: messageFont))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(tvOS)
    private let titleFont: CGFloat = 38
    private let messageFont: CGFloat = 24
    #elseif os(macOS)
    private let titleFont: CGFloat = 17
    private let messageFont: CGFloat = 13
    #else
    private let titleFont: CGFloat = 20
    private let messageFont: CGFloat = 15
    #endif
}
