import SwiftUI

/// Field semantics without UIKit types, so macOS can share the component.
enum MarqueeFieldContent { case username, password, newPassword, url, number }

#if !os(tvOS)

// MARK: - iOS / macOS field

/// Frosted text field with a leading icon. Inside `MarqueeFieldGroup` it drops
/// its own background so the group draws one rounded block with separators.
struct MarqueeTextField<F: Hashable>: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<F?>.Binding
    var equals: F
    var content: MarqueeFieldContent? = nil
    var isSecure: Bool = false
    var showsClearButton: Bool = false
    var isError: Bool = false
    var isDisabled: Bool = false
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @Environment(\.marqueeFieldGrouped) private var grouped
    @State private var reveal = false

    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: MarqueeMetrics.fieldFont - 2))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .frame(width: 20)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                field
                    .focused(focus, equals: equals)
                    .foregroundStyle(Color.siloOnSurface)
                    .tint(Color(hex: "#0A84FF"))
                    .submitLabel(submitLabel)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(Text(placeholder))
                    .disabled(isDisabled)
                    #if os(iOS)
                    .textContentType(uiContentType)
                    .keyboardType(uiKeyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #else
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #endif
            }

            if isSecure {
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                }
                .buttonStyle(.marqueePressable)
                .accessibilityLabel(reveal ? "Hide password" : "Show password")
            } else if showsClearButton, !text.isEmpty, !isDisabled {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.siloOnSurface.opacity(0.3))
                }
                .buttonStyle(.marqueePressable)
                .accessibilityLabel("Clear")
            }
        }
        .font(.system(size: MarqueeMetrics.fieldFont))
        .padding(.horizontal, 16)
        .frame(height: MarqueeMetrics.fieldHeight)
        .background {
            if !grouped {
                RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                            .strokeBorder(stroke, lineWidth: 1)
                    )
            } else if isError {
                Color(hex: "#FF6961").opacity(0.08)
            }
        }
        .opacity(isDisabled ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = equals }
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: isError)
    }

    @ViewBuilder
    private var field: some View {
        if isSecure && !reveal {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }

    private var fill: Color {
        if isError { return Color(hex: "#FF6961").opacity(0.08) }
        return Color.white.opacity(isFocused ? 0.10 : 0.07)
    }

    private var stroke: Color {
        if isError { return Color(hex: "#FF6961").opacity(0.65) }
        return Color.white.opacity(isFocused ? 0.45 : 0.12)
    }

    #if os(iOS)
    private var uiContentType: UITextContentType? {
        switch content {
        case .username: .username
        case .password: .password
        case .newPassword: .newPassword
        case .url: .URL
        case .number, .none: nil
        }
    }

    private var uiKeyboard: UIKeyboardType {
        switch content {
        case .url: .URL
        case .number: .numberPad
        default: .default
        }
    }
    #endif
}

private struct MarqueeFieldGroupedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var marqueeFieldGrouped: Bool {
        get { self[MarqueeFieldGroupedKey.self] }
        set { self[MarqueeFieldGroupedKey.self] = newValue }
    }
}

/// Username + password as one block, like iOS grouped fields.
struct MarqueeFieldGroup<Content: View>: View {
    var isError: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    }
                    subview
                }
            }
        }
        .environment(\.marqueeFieldGrouped, true)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                .strokeBorder(isError ? Color(hex: "#FF6961").opacity(0.65) : Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

#else

// MARK: - tvOS field

/// tvOS text field: our own rendering over a nearly invisible system field,
/// so the system focus platter never shows. Focus fills it white.
struct MarqueeTVField<F: Hashable>: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<F?>.Binding
    var equals: F
    var content: MarqueeFieldContent? = nil
    var isSecure: Bool = false
    var isError: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isFocused: Bool { focus.wrappedValue == equals }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 18) {
                Image(systemName: systemImage)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.45) : Color.siloOnSurface.opacity(0.4))
                Text(displayString)
                    .foregroundStyle(displayColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            field
                .textFieldStyle(.plain)
                .focused(focus, equals: equals)
                .textContentType(uiContentType)
                .keyboardType(content == .url ? .URL : content == .number ? .numberPad : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tint(.clear)
                .opacity(0.02)
                .accessibilityLabel(placeholder)
        }
        .font(.system(size: MarqueeMetrics.fieldFont))
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MarqueeMetrics.fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                .fill(isFocused ? Color.siloOnSurface : Color.white.opacity(isError ? 0.06 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MarqueeMetrics.fieldCorner, style: .continuous)
                .strokeBorder(
                    isError ? Color(hex: "#FF6961").opacity(0.75) : (isFocused ? .clear : Color.white.opacity(0.12)),
                    lineWidth: isError ? 3 : 1
                )
        )
        .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 24, y: 14)
        .animation(SiloTheme.springAnimation, value: isFocused)
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private var displayString: String {
        if text.isEmpty { return placeholder }
        return isSecure ? String(repeating: "•", count: text.count) : text
    }

    private var displayColor: Color {
        if text.isEmpty { return isFocused ? Color.black.opacity(0.4) : Color.siloOnSurface.opacity(0.4) }
        return isFocused ? .black : Color.siloOnSurface
    }

    private var uiContentType: UITextContentType? {
        switch content {
        case .username: .username
        case .password: .password
        case .newPassword: .newPassword
        case .url: .URL
        case .number, .none: nil
        }
    }
}

#endif
