#if os(tvOS)
import SwiftUI

// Option model and modal picker dialog used by the `TVPlayerInfoHUD` panes
// and the subtitle appearance dialog. Extracted from TVPlayerInfoHUD.swift;
// behavior unchanged.

struct HUDDropdownOption: Identifiable, Hashable {
    let id: String
    let label: String
    var colorHex: String? = nil
}

enum HUDPickerOptions {
    static func boolLabel(_ value: Bool) -> String {
        value ? "On" : "Off"
    }

    static func delayLabel(_ milliseconds: Int) -> String {
        PlayerTimeFormatter.formatSubtitleDelay(milliseconds)
    }

    static func delayOptions(
        from lowerBound: Int,
        through upperBound: Int,
        by step: Int,
        including currentValue: Int
    ) -> [HUDDropdownOption] {
        var values = Array(stride(from: lowerBound, through: upperBound, by: step))
        values.append(currentValue)
        return Set(values)
            .sorted()
            .map { .init(id: String($0), label: delayLabel($0)) }
    }
}

struct HUDPickerPresentation: Identifiable {
    let id = UUID()
    let title: String
    let options: [HUDDropdownOption]
    let selection: String
    let onSelect: (String) -> Void
}

/// Modal option list over a dimmed, `.disabled` pane — disabling the
/// background is what keeps focus contained in here. Movement and
/// keep-visible scrolling are native; focus is seeded onto the current
/// selection when the dialog appears.
struct HUDPickerDialog: View {
    let title: String
    let options: [HUDDropdownOption]
    let selection: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focusedOptionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: options.count > 7) {
                    VStack(spacing: 4) {
                        ForEach(options) { option in
                            HUDPickerOptionRow(
                                option: option,
                                isSelected: isSelected(option)
                            ) {
                                onSelect(option.id)
                                onClose()
                            }
                            .focused($focusedOptionID, equals: option.id)
                            .id(option.id)
                        }
                    }
                }
                .frame(maxHeight: 520)
                .onAppear {
                    if let initialFocusID {
                        proxy.scrollTo(initialFocusID, anchor: .center)
                        focusedOptionID = initialFocusID
                    }
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .frame(width: 620, alignment: .topLeading)
        .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.62), radius: 26, y: 14)
        .focusSection()
        .defaultFocus($focusedOptionID, initialFocusID)
        .onExitCommand(perform: onClose)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func isSelected(_ option: HUDDropdownOption) -> Bool {
        option.id.caseInsensitiveCompare(selection) == .orderedSame
    }

    private var initialFocusID: String? {
        options.first(where: isSelected)?.id ?? options.first?.id
    }

}

struct HUDPickerOptionRow: View {
    let option: HUDDropdownOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HUDPickerOptionLabel(option: option, isSelected: isSelected)
        }
        .buttonStyle(HUDRowButtonStyle(isSelected: isSelected))
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

struct HUDPickerOptionLabel: View {
    let option: HUDDropdownOption
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            if let colorHex = option.colorHex {
                ColorSwatch(hex: colorHex)
            }
            Text(option.label)
                .font(.system(size: 24, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

struct ColorSwatch: View {
    let hex: String

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
    }
}
#endif
