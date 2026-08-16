#if os(tvOS)
import SwiftUI

// Tab-bar pill for `TVPlayerInfoHUD`'s header. Extracted from
// TVPlayerInfoHUD.swift; behavior unchanged.

// MARK: - Tab pill

struct TabPill: View {
    let title: String
    let isSelected: Bool
    @FocusState.Binding var focusedTab: TVPlayerInfoHUD.Tab?
    let tab: TVPlayerInfoHUD.Tab
    let onSelect: () -> Void

    private var isFocused: Bool { focusedTab == tab }

    var body: some View {
        Button(action: onSelect) {
            Text(title)
        }
        .buttonStyle(HUDTabPillStyle(isSelected: isSelected))
        .focused($focusedTab, equals: tab)
        // Focus-driven selection: moving the remote across tabs swaps
        // the pane below without requiring a Select press. Matches the
        // native Apple TV segmented-control idiom.
        .onChange(of: isFocused) { _, focused in
            if focused { onSelect() }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct HUDTabPillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HUDTabPillBody(configuration: configuration, isSelected: isSelected)
    }
}

struct HUDTabPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).stroke(strokeColor, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isSelected)
    }

    private var foreground: Color {
        (isSelected || isFocused) ? .black : .white
    }

    private var background: Color {
        if isSelected { return .white }
        if isFocused  { return .white.opacity(0.9) }
        return .black.opacity(0.45)
    }

    private var strokeColor: Color {
        (isSelected || isFocused) ? .clear : .white.opacity(0.18)
    }
}
#endif
