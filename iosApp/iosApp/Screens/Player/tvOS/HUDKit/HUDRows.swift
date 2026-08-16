#if os(tvOS)
import SwiftUI

// Interactive row kit for `TVPlayerInfoHUD`: the shared button chrome plus
// the setting, toggle, chapter, and track rows built on it. Extracted from
// TVPlayerInfoHUD.swift; behavior unchanged.

// MARK: - Row chrome

/// Shared row chrome for every interactive HUD row: white fill when focused,
/// optional faint wash when it represents the current selection. Owns all
/// focus appearance via `@Environment(\.isFocused)` and suppresses the system
/// halo — same idiom as `TVPillButtonStyle`.
struct HUDRowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        HUDRowButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            isSelected: isSelected
        )
    }
}

struct HUDRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var background: Color {
        if isFocused { return .white }
        if isSelected { return .white.opacity(0.14) }
        return .clear
    }
}

/// Chevron row that opens a picker dialog. Label/value colors invert when
/// the row is focused; movement and Select handling are native.
struct HUDSettingRow: View {
    let label: String
    let value: String
    /// Optional secondary line under the label. Used to explain a disabled
    /// row ("Not set up on this server") — the trailing `value` slot is only
    /// ~165pt wide at 22pt semibold, which truncates any real sentence.
    var detail: String? = nil
    var colorHex: String? = nil
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDSettingRowLabel(
                label: label,
                value: value,
                detail: detail,
                colorHex: colorHex,
                systemImage: systemImage,
                showsChevron: true
            )
        }
        .buttonStyle(HUDRowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Boolean row that flips on Select — one press instead of the previous
/// open-dialog → pick → close round-trip.
struct HUDToggleRow: View {
    let label: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button { onToggle(!isOn) } label: {
            HUDSettingRowLabel(
                label: label,
                value: HUDPickerOptions.boolLabel(isOn),
                showsChevron: false
            )
        }
        .buttonStyle(HUDRowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(HUDPickerOptions.boolLabel(isOn))
        .accessibilityAddTraits(.isToggle)
    }
}

struct HUDSettingRowLabel: View {
    let label: String
    let value: String
    var detail: String? = nil
    var colorHex: String? = nil
    var systemImage: String? = nil
    let showsChevron: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
            }
            // Second line mirrors `HUDTrackRowLabel`'s attributes line: 17pt,
            // dimmed, focus-inverted. Only rendered when a `detail` is given,
            // so ordinary rows keep their exact single-line metrics.
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 22, weight: .medium))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 17))
                        .foregroundStyle(isFocused ? .black.opacity(0.62) : .white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 18)
            HStack(spacing: 10) {
                if let colorHex {
                    ColorSwatch(hex: colorHex)
                }
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isFocused ? .black.opacity(0.78) : .white.opacity(0.72))
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.45))
                }
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
    }
}

struct HUDChapterRow: View {
    let number: Int
    let title: String
    let time: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDChapterRowLabel(number: number, title: title, time: time, isCurrent: isCurrent)
        }
        .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
        .accessibilityLabel(title)
        .accessibilityValue(isCurrent ? "Currently playing" : "")
    }
}

struct HUDChapterRowLabel: View {
    let number: Int
    let title: String
    let time: String
    let isCurrent: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", number))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(isFocused ? .black.opacity(0.55) : .white.opacity(0.55))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Text(title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isFocused ? .black : .white)
                .lineLimit(1)

            Spacer(minLength: 12)

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFocused ? .black.opacity(0.8) : .white.opacity(0.8))
            }

            Text(time)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isFocused ? .black.opacity(0.65) : .white.opacity(0.65))
                .monospacedDigit()
        }
    }
}

// MARK: - Track row (shared by Audio + Subtitle panes)

struct HUDTrackRow: View {
    let name: String
    let attributes: String?
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HUDTrackRowLabel(name: name, attributes: attributes, isSelected: isSelected)
        }
        .buttonStyle(HUDRowButtonStyle(cornerRadius: 8))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1.0)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

struct HUDTrackRowLabel: View {
    let name: String
    let attributes: String?
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .lineLimit(1)
                if let attributes {
                    Text(attributes)
                        .font(.system(size: 17))
                        .foregroundStyle(isFocused ? .black.opacity(0.62) : .white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
            }
        }
    }
}
#endif
