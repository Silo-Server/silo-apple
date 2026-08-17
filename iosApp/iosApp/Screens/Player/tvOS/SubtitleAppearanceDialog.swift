#if os(tvOS)
import SwiftUI

// Full-screen subtitle appearance editor presented over the Subtitles pane
// of `TVPlayerInfoHUD`. Extracted from TVPlayerInfoHUD.swift; behavior
// unchanged. This is the tvOS counterpart to iOS's
// `PlayerSettingsSheet.subtitleAppearancePage`.

struct SubtitleAppearanceDialog: View {
    let viewModel: PlayerViewModel
    let onClose: () -> Void

    @State private var activePicker: HUDPickerPresentation?
    @State private var pickerReturnField: Field?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case close
        case matchSystem
        case style
        case font
        case size
        case textColor
        case outlineToggle
        case outlineColor
        case backgroundColor
        case opacity
        case position
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUBTITLE APPEARANCE")
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.55))
                        Text("Style and colors")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    closeButton
                }

                ScrollView(showsIndicators: true) {
                    VStack(spacing: 2) {
                        HUDToggleRow(
                            label: "Use device settings",
                            isOn: viewModel.settings.subtitleMatchesSystemAppearance
                        ) { enabled in
                            viewModel.setSubtitleMatchesSystemAppearance(enabled)
                        }
                        .focused($focusedField, equals: .matchSystem)
                        .id(Field.matchSystem)

                        HUDSettingRow(
                            label: "Style",
                            value: viewModel.settings.subtitleAppearance.backgroundStyle.label
                        ) {
                            presentPicker(
                                for: .style,
                                HUDPickerPresentation(
                                    title: "Subtitle Style",
                                    options: Self.backgroundStyleOptions,
                                    selection: viewModel.settings.subtitleAppearance.backgroundStyle.rawValue,
                                    onSelect: { value in
                                        if let style = SubtitleBackgroundStylePreset(rawValue: value) {
                                            updateAppearance {
                                                $0.backgroundStyle = style
                                                if style == .box && $0.backgroundOpacity == 0 {
                                                    $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                                                }
                                            }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .style)
                        .id(Field.style)

                        HUDSettingRow(
                            label: "Font",
                            value: viewModel.settings.subtitleAppearance.fontFamily.label
                        ) {
                            presentPicker(
                                for: .font,
                                HUDPickerPresentation(
                                    title: "Subtitle Font",
                                    options: Self.fontFamilyOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontFamily.rawValue,
                                    onSelect: { value in
                                        if let font = SubtitleFontFamilyPreset(rawValue: value) {
                                            updateAppearance { $0.fontFamily = font }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .font)
                        .id(Field.font)

                        HUDSettingRow(
                            label: "Size",
                            value: viewModel.settings.subtitleAppearance.fontSize.label
                        ) {
                            presentPicker(
                                for: .size,
                                HUDPickerPresentation(
                                    title: "Subtitle Size",
                                    options: Self.sizeOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontSize.rawValue,
                                    onSelect: { value in
                                        if let size = SubtitleFontSizePreset(rawValue: value) {
                                            updateAppearance { $0.fontSize = size }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .size)
                        .id(Field.size)

                        HUDSettingRow(
                            label: "Text",
                            value: label(for: viewModel.settings.subtitleAppearance.fontColor, in: Self.fontColorOptions),
                            colorHex: viewModel.settings.subtitleAppearance.fontColor
                        ) {
                            presentPicker(
                                for: .textColor,
                                HUDPickerPresentation(
                                    title: "Text Color",
                                    options: Self.fontColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.fontColor,
                                    onSelect: { value in
                                        updateAppearance { $0.fontColor = value }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .textColor)
                        .id(Field.textColor)

                        HUDToggleRow(
                            label: "Text outline",
                            isOn: viewModel.settings.subtitleAppearance.textOutline
                        ) { enabled in
                            updateAppearance { $0.textOutline = enabled }
                        }
                        .focused($focusedField, equals: .outlineToggle)
                        .id(Field.outlineToggle)

                        HUDSettingRow(
                            label: "Outline",
                            value: viewModel.settings.subtitleAppearance.textOutline
                                ? label(for: viewModel.settings.subtitleAppearance.textOutlineColor, in: Self.outlineColorOptions)
                                : "—",
                            colorHex: viewModel.settings.subtitleAppearance.textOutline
                                ? viewModel.settings.subtitleAppearance.textOutlineColor
                                : nil
                        ) {
                            presentPicker(
                                for: .outlineColor,
                                HUDPickerPresentation(
                                    title: "Outline Color",
                                    options: Self.outlineColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.textOutlineColor,
                                    onSelect: { value in
                                        // Picking a color turns the outline on.
                                        updateAppearance {
                                            $0.textOutlineColor = value
                                            $0.textOutline = true
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .outlineColor)
                        .id(Field.outlineColor)

                        HUDSettingRow(
                            label: "Background",
                            value: viewModel.settings.subtitleAppearance.backgroundStyle == .box
                                ? label(for: viewModel.settings.subtitleAppearance.backgroundColor, in: Self.backgroundColorOptions)
                                : "—",
                            colorHex: viewModel.settings.subtitleAppearance.backgroundStyle == .box
                                ? viewModel.settings.subtitleAppearance.backgroundColor
                                : nil
                        ) {
                            presentPicker(
                                for: .backgroundColor,
                                HUDPickerPresentation(
                                    title: "Background Color",
                                    options: Self.backgroundColorOptions,
                                    selection: viewModel.settings.subtitleAppearance.backgroundColor,
                                    onSelect: { value in
                                        // Picking a color switches the style to Box.
                                        updateAppearance {
                                            $0.backgroundColor = value
                                            $0.backgroundStyle = .box
                                            if $0.backgroundOpacity == 0 {
                                                $0.backgroundOpacity = SubtitleAppearance.default.backgroundOpacity
                                            }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .backgroundColor)
                        .id(Field.backgroundColor)

                        HUDSettingRow(label: "Opacity", value: opacityLabel) {
                            presentPicker(
                                for: .opacity,
                                HUDPickerPresentation(
                                    title: "Background Opacity",
                                    options: Self.opacityOptions,
                                    selection: String(viewModel.settings.subtitleAppearance.backgroundOpacity),
                                    onSelect: { value in
                                        if let opacity = Int(value) {
                                            updateAppearance {
                                                $0.backgroundOpacity = opacity
                                                if opacity > 0 {
                                                    $0.backgroundStyle = .box
                                                }
                                            }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .opacity)
                        .id(Field.opacity)

                        HUDSettingRow(
                            label: "Position",
                            value: viewModel.settings.subtitleAppearance.position.label
                        ) {
                            presentPicker(
                                for: .position,
                                HUDPickerPresentation(
                                    title: "Subtitle Position",
                                    options: Self.positionOptions,
                                    selection: viewModel.settings.subtitleAppearance.position.rawValue,
                                    onSelect: { value in
                                        if let position = SubtitlePositionPreset(rawValue: value) {
                                            updateAppearance { $0.position = position }
                                        }
                                    }
                                )
                            )
                        }
                        .focused($focusedField, equals: .position)
                        .id(Field.position)
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: 560)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(width: 720, alignment: .topLeading)
            .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 26, y: 14)
            .focusSection()
            .defaultFocus($focusedField, .style)
            .disabled(activePicker != nil)
            .opacity(activePicker != nil ? 0.28 : 1)

            if let activePicker {
                HUDPickerDialog(
                    title: activePicker.title,
                    options: activePicker.options,
                    selection: activePicker.selection,
                    onSelect: activePicker.onSelect,
                    onClose: closePicker
                )
            }
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: activePicker?.id)
        // Defensive: the picker's own exit handler consumes Menu while it has
        // focus, but if focus ever escapes it we still want Menu to close the
        // picker, not tear down the whole dialog.
        .onExitCommand(perform: activePicker == nil ? onClose : closePicker)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            HUDCloseButtonLabel()
        }
        .buttonStyle(HUDCircleButtonStyle())
        .focused($focusedField, equals: .close)
        .accessibilityLabel("Close subtitle appearance")
    }

    private func presentPicker(for field: Field, _ presentation: HUDPickerPresentation) {
        pickerReturnField = field
        activePicker = presentation
    }

    private func closePicker() {
        let field = pickerReturnField
        activePicker = nil
        if let field {
            focusedField = field
        }
    }

    private func updateAppearance(_ mutate: @escaping (inout SubtitleAppearance) -> Void) {
        var next = viewModel.settings.subtitleAppearance
        mutate(&next)
        Task { await viewModel.setSubtitleAppearance(next) }
    }

    private var opacityLabel: String {
        guard viewModel.settings.subtitleAppearance.backgroundStyle == .box,
              viewModel.settings.subtitleAppearance.backgroundOpacity > 0 else {
            return "Off"
        }
        return "\(viewModel.settings.subtitleAppearance.backgroundOpacity)%"
    }

    private func label(for id: String, in options: [HUDDropdownOption]) -> String {
        options.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.label ?? id
    }

    private static let backgroundStyleOptions: [HUDDropdownOption] =
        SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let fontFamilyOptions: [HUDDropdownOption] =
        SubtitleFontFamilyPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    /// Also used by the HUD's Subtitles pane, which offers the same two rows.
    static let sizeOptions: [HUDDropdownOption] =
        SubtitleFontSizePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let positionOptions: [HUDDropdownOption] =
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    private static let opacityOptions: [HUDDropdownOption] =
        stride(from: 0, through: 100, by: 25).map { .init(id: String($0), label: $0 == 0 ? "Off" : "\($0)%") }

    private static let fontColorOptions: [HUDDropdownOption] =
        SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }

    private static let outlineColorOptions: [HUDDropdownOption] =
        SubtitleAppearance.outlineColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }

    private static let backgroundColorOptions: [HUDDropdownOption] =
        SubtitleAppearance.backgroundColors.map { .init(id: $0.hex, label: $0.label, colorHex: $0.hex) }
}
#endif
