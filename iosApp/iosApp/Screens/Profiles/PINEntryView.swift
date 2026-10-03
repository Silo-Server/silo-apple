import SwiftUI

/// Full-screen PIN prompt over the brand light: the person's avatar,
/// four dots, and a keypad laid out like the system passcode screen. A wrong
/// PIN keeps the prompt open, turns the dots red, and clears for another try.
struct PINEntryView: View {
    let profile: UserProfile
    let onComplete: (String) -> Void
    let onCancel: (() -> Void)?
    /// Set by the caller after the server rejects a PIN.
    var errorMessage: String?
    /// Bumped on each rejection so the dots shake and the entry clears.
    var errorCount: Int = 0
    var isVerifying: Bool = false

    @State private var pin: String = ""
    @FocusState private var focusedPadKey: String?
    @Environment(\.dismiss) private var dismiss

    private let maxDigits = 4

    init(
        profile: UserProfile,
        errorMessage: String? = nil,
        errorCount: Int = 0,
        isVerifying: Bool = false,
        onCancel: (() -> Void)? = nil,
        onComplete: @escaping (String) -> Void
    ) {
        self.profile = profile
        self.errorMessage = errorMessage
        self.errorCount = errorCount
        self.isVerifying = isVerifying
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            MarqueeScrim(style: .ambient)
            Color.black.opacity(0.35).ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            phoneBody
                #if os(iOS)
                .marqueeSwipeBack(isVerifying ? nil : cancel)
                #endif
            #endif
        }
        .onChange(of: errorCount) { _, _ in pin = "" }
    }

    #if !os(tvOS)
    private var phoneBody: some View {
        VStack(spacing: 0) {
            HStack {
                MarqueeIconButton(systemImage: "chevron.left", accessibilityLabel: "Back", action: cancel)
                    .disabled(isVerifying)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Spacer(minLength: 12)

            header(avatarSize: 88)
            pinDots(dotSize: 14, spacing: 16)
                .padding(.top, 22)
            statusLine
                .frame(height: 22)
                .padding(.top, 14)

            numberPad
                .padding(.top, 28)

            Spacer(minLength: 12)

            Text("Forgot your PIN? The account admin can reset it.")
                .font(.system(size: 13))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: 440)
    }
    #endif

    #if os(tvOS)
    private var tvOSBody: some View {
        VStack(spacing: 0) {
            header(avatarSize: 160)
            pinDots(dotSize: 26, spacing: 28)
                .padding(.top, 34)
            statusLine
                .frame(height: 34)
                .padding(.top, 18)
            numberPad
                .padding(.top, 30)
                .focusSection()
            Button("Cancel", action: cancel)
                .buttonStyle(.marquee(.plain, fullWidth: false, compact: true))
                .disabled(isVerifying)
                .padding(.top, 30)
        }
        .onExitCommand(perform: handleExit)
        .task {
            // The profile grid is disabled in the same update that inserts
            // this overlay. Wait for it to relinquish focus, then hand the
            // single native keypad graph to its center key.
            await Task.yield()
            focusedPadKey = "5"
        }
    }
    #endif

    private func header(avatarSize: CGFloat) -> some View {
        VStack(spacing: 6) {
            ProfileAvatarView(
                avatar: profile.avatarEmoji,
                imageUrl: profile.avatarImageUrl,
                name: profile.name,
                size: avatarSize
            )
            .padding(.bottom, 8)

            Text(profile.name)
                .font(.system(size: nameFont, weight: .bold))
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Enter PIN for \(profile.name)")
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.system(size: statusFont))
                .foregroundStyle(Color(hex: "#FF6961"))
                .transition(.opacity)
        } else if isVerifying {
            ProgressView()
        } else {
            Text("Enter your PIN")
                .font(.system(size: statusFont))
                .foregroundStyle(Color.siloOnSurface.opacity(0.62))
        }
    }

    private func pinDots(dotSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<maxDigits, id: \.self) { index in
                let filled = index < pin.count || (errorMessage != nil && pin.isEmpty)
                Circle()
                    .fill(filled ? dotColor : Color.clear)
                    .overlay(Circle().strokeBorder(dotColor.opacity(filled ? 1 : 0.7), lineWidth: dotSize * 0.11))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .modifier(MarqueeShake(trigger: errorCount))
        .accessibilityLabel("\(pin.count) of \(maxDigits) digits entered")
    }

    private var dotColor: Color {
        errorMessage != nil && pin.isEmpty ? Color(hex: "#FF6961") : Color.siloOnSurface
    }

    private var numberPad: some View {
        Grid(horizontalSpacing: padHSpacing, verticalSpacing: padVSpacing) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(1...3, id: \.self) { column in
                        let digit = row * 3 + column
                        NumberPadButton(
                            label: "\(digit)",
                            letters: Self.letters[digit],
                            focus: $focusedPadKey,
                            focusValue: "\(digit)"
                        ) {
                            appendDigit("\(digit)")
                        }
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: NumberPadButton.size, height: NumberPadButton.size)
                NumberPadButton(label: "0", focus: $focusedPadKey, focusValue: "0") {
                    appendDigit("0")
                }
                NumberPadButton(
                    label: "delete.backward",
                    isSystemImage: true,
                    focus: $focusedPadKey,
                    focusValue: "delete"
                ) {
                    deleteDigit()
                }
            }
        }
        .disabled(isVerifying)
    }

    private static let letters: [Int: String] = [
        2: "ABC", 3: "DEF", 4: "GHI", 5: "JKL", 6: "MNO", 7: "PQRS", 8: "TUV", 9: "WXYZ",
    ]

    #if os(tvOS)
    private let nameFont: CGFloat = 38
    private let statusFont: CGFloat = 26
    private let padHSpacing: CGFloat = 24
    private let padVSpacing: CGFloat = 20
    #else
    private let nameFont: CGFloat = 22
    private let statusFont: CGFloat = 15
    private let padHSpacing: CGFloat = 26
    private let padVSpacing: CGFloat = 16
    #endif

    /// Leaving while the server checks the PIN would let the answer act on a
    /// prompt that's gone (open Home or Create Profile), so it waits.
    private func cancel() {
        guard !isVerifying else { return }
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    private func handleExit() {
        if pin.isEmpty {
            cancel()
        } else {
            deleteDigit()
        }
    }

    private func appendDigit(_ digit: String) {
        guard pin.count < maxDigits, !isVerifying else { return }
        pin += digit

        if pin.count == maxDigits {
            onComplete(pin)
        }
    }

    private func deleteDigit() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }
}

// MARK: - Number Pad Button

private struct NumberPadButton: View {
    let label: String
    var letters: String? = nil
    var isSystemImage: Bool = false
    var focus: FocusState<String?>.Binding? = nil
    var focusValue: String? = nil
    let action: () -> Void
    static var size: CGFloat {
        #if os(tvOS)
        100
        #else
        76
        #endif
    }

    @ViewBuilder
    var body: some View {
        if let focus, let focusValue {
            button
                .focused(focus, equals: focusValue)
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            if isSystemImage {
                Image(systemName: label)
                    .font(.system(size: symbolSize, weight: .semibold))
            } else {
                VStack(spacing: 1) {
                    Text(label)
                        .font(.system(size: digitSize, weight: .regular))
                    if let letters {
                        Text(letters)
                            .font(.system(size: digitSize * 0.28, weight: .bold))
                            .kerning(1.5)
                            .opacity(0.62)
                    }
                }
            }
        }
        .buttonStyle(NumberPadButtonStyle(isFocused: isFocused))
    }

    private var isFocused: Bool {
        guard let focusValue else { return false }
        return focus?.wrappedValue == focusValue
    }

    private var symbolSize: CGFloat {
        #if os(tvOS)
        34
        #else
        22
        #endif
    }

    private var digitSize: CGFloat {
        #if os(tvOS)
        44
        #else
        34
        #endif
    }
}

private struct NumberPadButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        NumberPadButtonBody(configuration: configuration, isFocused: isFocused)
    }
}

private struct NumberPadButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isFocused: Bool

    var body: some View {
        configuration.label
            .foregroundColor(isFocused ? .siloBackground : .siloOnSurface)
            .frame(width: NumberPadButton.size, height: NumberPadButton.size)
            .background(background)
            .overlay(border)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .marqueePressHaptic(configuration.isPressed, .impact(flexibility: .rigid, intensity: 0.7))
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }

    @ViewBuilder
    private var background: some View {
        Circle()
            .fill(isFocused ? Color.siloOnSurface : Color.white.opacity(0.13))
    }

    @ViewBuilder
    private var border: some View {
        Circle()
            .strokeBorder(isFocused ? Color.clear : Color.white.opacity(0.10), lineWidth: 1)
    }
}
