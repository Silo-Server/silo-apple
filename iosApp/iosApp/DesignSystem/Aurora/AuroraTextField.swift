#if !os(tvOS)
import SwiftUI

// MARK: - Field content classification (platform-neutral)

/// Mirrors the small enum pattern in the old Silo forms so the shared
/// component carries no UIKit types in its signature — macOS has no
/// `UITextContentType`.
enum AuroraFieldContentType { case username, password, email, oneTimeCode, url }
enum AuroraFieldKeyboard { case `default`, url, email, number }

// MARK: - Field label

struct AuroraFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Color.auroraInkTertiary)
    }
}

// MARK: - Inline error row

struct AuroraErrorLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.siloCaption)
        .foregroundStyle(Color.requestRose)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(text)")
    }
}

// MARK: - Editable first-run field (iOS/macOS)
//
// The placeholder is a controlled overlay so its contrast remains predictable;
// the live `TextField`/`SecureField` owns caret, selection, and keyboard.

struct AuroraTextField<F: Hashable>: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var focus: FocusState<F?>.Binding
    var equals: F
    var isSecure: Bool = false
    var showsRevealToggle: Bool = false
    var contentType: AuroraFieldContentType? = nil
    var keyboard: AuroraFieldKeyboard = .default
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @State private var reveal = false
    private var isFocused: Bool { focus.wrappedValue == equals }
    private var effectiveSecure: Bool { isSecure && !reveal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AuroraFieldLabel(label)
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(isFocused ? AuroraControl.activePlaceholder : Color.auroraInkTertiary)
                            .allowsHitTesting(false)
                    }
                    inputField
                        .accessibilityLabel(Text(label))
                        .focused(focus, equals: equals)
                        .foregroundStyle(isFocused ? AuroraControl.activeInk : Color.auroraInk)
                        .tint(isFocused ? AuroraControl.activeInk : Color.auroraAccent)
                        .submitLabel(submitLabel)
                        .onSubmit(onSubmit)
                        #if !os(macOS)
                        .textContentType(uiContentType)
                        .keyboardType(uiKeyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                if showsRevealToggle {
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(isFocused ? AuroraControl.activeInk.opacity(0.7) : Color.auroraInkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(height: AuroraControl.height)
            .background(
                    RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .fill(isFocused ? AuroraControl.activeFill : Color.siloSurfaceElevated.opacity(0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .stroke(isFocused ? Color.auroraAccent : Color.white.opacity(0.16),
                            lineWidth: isFocused ? 2 : 1)
            )
            .shadow(color: isFocused ? Color.auroraAccent.opacity(0.22) : .clear,
                    radius: isFocused ? 12 : 0)
            .animation(SiloTheme.springAnimation, value: isFocused)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if effectiveSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }

    #if !os(macOS)
    private var uiContentType: UITextContentType? {
        switch contentType {
        case .username: .username
        case .password: .password
        case .email: .emailAddress
        case .oneTimeCode: .oneTimeCode
        case .url: .URL
        case .none: nil
        }
    }
    private var uiKeyboard: UIKeyboardType {
        switch keyboard {
        case .default: .default
        case .url: .URL
        case .email: .emailAddress
        case .number: .numberPad
        }
    }
    #endif
}

// MARK: - Screen scaffold

/// Silo backdrop + a vertically scrollable, keyboard-friendly column capped
/// to a comfortable reading width. Callers supply the wordmark + content.
struct AuroraScreen<Content: View>: View {
    var variant: AuroraVariant
    var scrim: AuroraScrim = .soft
    var maxContentWidth: CGFloat = 480
    @ViewBuilder var content: () -> Content

    init(variant: AuroraVariant,
         scrim: AuroraScrim = .soft,
         maxContentWidth: CGFloat = 480,
         @ViewBuilder content: @escaping () -> Content) {
        self.variant = variant
        self.scrim = scrim
        self.maxContentWidth = maxContentWidth
        self.content = content
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(variant: variant, scrim: scrim)
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) { content() }
                        .frame(maxWidth: maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                        .frame(minHeight: geo.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
