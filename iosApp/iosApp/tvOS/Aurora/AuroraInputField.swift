#if os(tvOS)
import SwiftUI
import UIKit

// MARK: - First-run text field
//
// A controlled field so we own the placeholder contrast and focus treatment
// in both states. On tvOS a focused TextField gets a light system platter, so
// the focused state deliberately mirrors that high-contrast treatment.

struct AuroraInputField<F: Hashable>: View {
    @Binding var text: String
    var placeholder: String
    var inputTitle: String? = nil
    var focus: FocusState<F?>.Binding
    var equals: F
    var isSecure: Bool = false
    var height: CGFloat = AuroraControl.height
    var contentType: UITextContentType? = nil
    var keyboard: UIKeyboardType = .default

    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        ZStack(alignment: .leading) {
            // Visible, fully-controlled content so the field reads as a clean
            // square in every state.
            Text(displayString)
                .foregroundStyle(displayColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

            // The real field drives focus + the on-screen keyboard, but is
            // rendered nearly invisible so the tvOS focus platter — the rounded
            // "pill" that sat inside our square box, and that neither
            // .focusEffectDisabled() nor .textFieldStyle(.plain) can remove —
            // never shows.
            fieldView
                .textFieldStyle(.plain)
                .focused(focus, equals: equals)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel(inputTitle ?? placeholder)
        }
        .font(.system(size: 26))
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .fill(isFocused ? AuroraControl.activeFill : Color.siloSurfaceElevated.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16),
                        lineWidth: isFocused ? 3 : 1)
        )
        .shadow(color: isFocused ? Color.auroraAccent.opacity(0.28) : .clear,
                radius: isFocused ? 16 : 0, y: 0)
        .animation(SiloTheme.springAnimation, value: isFocused)
    }

    private var displayString: String {
        if text.isEmpty { return placeholder }
        return isSecure ? String(repeating: "•", count: text.count) : text
    }

    private var displayColor: Color {
        if text.isEmpty {
            return isFocused ? AuroraControl.activePlaceholder : Color.auroraInkTertiary
        }
        return isFocused ? AuroraControl.activeInk : Color.auroraInk
    }

    @ViewBuilder
    private var fieldView: some View {
        if isSecure {
            SecureField(inputTitle ?? placeholder, text: $text)
        } else {
            TextField(inputTitle ?? placeholder, text: $text)
        }
    }
}
#endif
