#if os(tvOS)
import SwiftUI

// MARK: - Option model

/// Option model shared by picker rows and their selection sheets.
struct TVSettingsOption: Identifiable, Hashable {
    let id: String
    let label: String
    var previewFontName: String? = nil
}

/// Canonical option sets shared by the tvOS settings sub-screens.
enum TVSettingsOptions {
    static let quality: [TVSettingsOption] =
        ApplePlaybackQuality.settingsOptions.map { option in
            .init(id: option.id, label: option.labelWithBitrate)
        }

    static let audioLanguage: [TVSettingsOption] = [
        .init(id: "", label: "Default"),
        .init(id: "en", label: "English"),
        .init(id: "es", label: "Spanish"),
        .init(id: "fr", label: "French"),
        .init(id: "de", label: "German"),
        .init(id: "it", label: "Italian"),
        .init(id: "pt", label: "Portuguese"),
        .init(id: "ja", label: "Japanese"),
        .init(id: "ko", label: "Korean"),
    ]

    static let nextUpPrompt: [TVSettingsOption] = [
        .init(id: "0", label: "At end"),
        .init(id: "10", label: "10 seconds before end"),
        .init(id: "30", label: "30 seconds before end"),
        .init(id: "60", label: "1 minute before end"),
        .init(id: "120", label: "2 minutes before end"),
    ]

    static let subtitleLanguage: [TVSettingsOption] =
        [.init(id: PlaybackPrefSentinel.none, label: "None")]
            + PlaybackLanguageOption.all.map { .init(id: $0.code, label: $0.label) }

    static let metadataLanguage: [TVSettingsOption] =
        [.init(id: PlaybackPrefSentinel.none, label: "Library Default")]
            + PlaybackLanguageOption.all.map { .init(id: $0.code, label: $0.label) }

    static let subtitleMode: [TVSettingsOption] =
        SubtitleMode.allCases.map { .init(id: $0.rawValue, label: $0.displayLabel) }

    static let subtitleSize: [TVSettingsOption] = [
        .init(id: "small",   label: "Small"),
        .init(id: "medium",  label: "Medium"),
        .init(id: "large",   label: "Large"),
        .init(id: "xlarge",  label: "X-Large"),
        .init(id: "xxlarge", label: "XX-Large"),
    ]

    static let fontFamily: [TVSettingsOption] =
        SubtitleFontFamilyPreset.allCases.map {
            .init(id: $0.rawValue, label: $0.label, previewFontName: $0.assFontName)
        }

    static let fontColor: [TVSettingsOption] =
        SubtitleAppearance.fontColors.map { .init(id: $0.hex, label: $0.label) }

    static let outlineColor: [TVSettingsOption] =
        SubtitleAppearance.outlineColors.map { .init(id: $0.hex, label: $0.label) }

    static let backgroundStyle: [TVSettingsOption] =
        SubtitleBackgroundStylePreset.selectableCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let backgroundOpacity: [TVSettingsOption] =
        stride(from: 0, through: 100, by: 5).map { .init(id: String($0), label: "\($0)%") }

    static let backgroundColor: [TVSettingsOption] =
        SubtitleAppearance.backgroundColors.map { .init(id: $0.hex, label: $0.label) }

    static let position: [TVSettingsOption] =
        SubtitlePositionPreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static func label(for id: String, in options: [TVSettingsOption]) -> String {
        options.first(where: { $0.id == id })?.label ?? "—"
    }
}

// MARK: - Rail row style

/// Left-rail row: quiet at rest, `chrome.selected` fill when it is the
/// active category, white platter with dark content on focus. Matches the
/// Skyline panel-row grammar (`TVBrowsePanelRowStyle`) with a selected
/// state added.
struct TVSettingsRailRowStyle: ButtonStyle {
    var isSelected: Bool = false
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVSettingsRailRowBody(
            configuration: configuration,
            isSelected: isSelected,
            isDestructive: isDestructive
        )
    }
}

private struct TVSettingsRailRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let isDestructive: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected && !isFocused
                            ? Color.continuumChromeSelectedBorder
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        if isDestructive {
            return isFocused ? .white : .continuumError
        }
        return isFocused ? .continuumBackground : .continuumOnSurface
    }

    private var fill: Color {
        if isDestructive && isFocused { return .continuumError }
        if isFocused { return .continuumOnSurface }
        if isSelected { return .continuumChromeSelectedFill }
        return .clear
    }
}

// MARK: - Pane row style

/// Detail-pane row: faint glass fill with a hairline at rest, white
/// platter with dark content on focus.
struct TVSettingsPaneRowStyle: ButtonStyle {
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVSettingsPaneRowBody(configuration: configuration, isDestructive: isDestructive)
    }
}

private struct TVSettingsPaneRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isDestructive: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.continuumOnSurface : Color.continuumChromeRestingFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.clear : Color.continuumChromeRestingBorder,
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        if isDestructive {
            return isFocused ? Color(hex: "#D22F3F") : .continuumError
        }
        return isFocused ? .continuumBackground : .continuumOnSurface
    }
}

// MARK: - Pane rows

/// Picker row: title, current value, chevron. Activating it presents the
/// option sheet.
struct TVSettingsPickerRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 26))
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(value)
                    .font(.system(size: 24))
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
    }
}

/// One-press boolean row in the system-Settings idiom: click flips the
/// value, the trailing text reads On / Off. (Same pattern as the player
/// info HUD — no `Toggle`, whose system chrome fights the custom layout.)
struct TVSettingsToggleRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 26))
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 24, weight: isOn ? .semibold : .regular))
                    .opacity(isOn ? 0.9 : 0.55)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Visually groups controls owned by a parent setting. Inactive groups
/// stay in the focus graph so their values remain inspectable, but the
/// owner is responsible for ignoring edits until `enabled` is true.
struct TVSettingsNestedGroup<Content: View>: View {
    let enabled: Bool
    let content: Content

    init(enabled: Bool, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .padding(.leading, 24)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityHint(enabled ? "" : "Turn on the parent setting to make changes")
    }
}

/// Read-only fact row (server name, version). It is deliberately not a
/// focus target; focus should land only on actionable settings rows.
struct TVSettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 26))
                .lineLimit(1)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 24))
                .opacity(0.68)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(.continuumOnSurface)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.continuumChromeRestingFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
        )
    }
}

// MARK: - Section header / footer

/// Mono uppercase section eyebrow, matching the Skyline dropdown and
/// filter-panel header grammar.
struct TVSettingsSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundColor(.continuumSecondaryText)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 6)
    }
}

/// Explanatory caption under a section's rows.
struct TVSettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 19))
            .foregroundColor(.continuumSecondaryText)
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Confirmation overlay

/// Settings-styled destructive confirmation used instead of the native tvOS
/// alert, whose app-wide tint can leave focused Cancel text without contrast.
struct TVSettingsConfirmationOverlay: View {
    let title: String
    let message: String
    let confirmTitle: String
    var additionalDestructiveTitle: String? = nil
    let cancel: () -> Void
    let confirm: () -> Void
    var additionalDestructiveAction: (() -> Void)? = nil

    @FocusState private var focusedAction: Action?

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)

            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.continuumOnSurface)

                    Text(message)
                        .font(.system(size: 22))
                        .foregroundColor(.continuumSecondaryText)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button(action: cancel) {
                        Text("Cancel")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .cancel)

                    Button(action: confirm) {
                        Text(confirmTitle)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .confirm)

                    if let additionalDestructiveTitle,
                       let additionalDestructiveAction {
                        Button(action: additionalDestructiveAction) {
                            Text(additionalDestructiveTitle)
                                .font(.system(size: 24, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                        .frame(width: buttonWidth)
                        .focused($focusedAction, equals: .additionalDestructive)
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 42)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.continuumSurfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
            )
            .focusSection()
            .defaultFocus($focusedAction, .cancel, priority: .userInitiated)
            .onExitCommand(perform: cancel)
        }
        .onAppear { focusedAction = .cancel }
    }

    private enum Action: Hashable {
        case cancel
        case confirm
        case additionalDestructive
    }

    private var buttonWidth: CGFloat {
        additionalDestructiveTitle == nil ? 260 : 320
    }
}

// MARK: - Picker sheet

/// Modal option picker presented by `.fullScreenCover(item:)` (tvOS 26
/// renders plain sheets as narrow centered cards that clip content).
/// Contains its own `NavigationStack` so it has a title regardless of
/// where it was presented from. Selecting an option updates the
/// binding and dismisses.
struct TVSettingsPickerSheet: View {
    let title: String
    let options: [TVSettingsOption]
    @Binding var selection: String
    var subtitlePreviewAppearance: SubtitleAppearance? = nil

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedOptionID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let subtitlePreviewAppearance {
                    TVSettingsSubtitlePreview(
                        appearance: previewAppearance(from: subtitlePreviewAppearance)
                    )
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(options) { option in
                                TVSettingsPickerOptionRow(
                                    option: option,
                                    isSelected: option.id == selection,
                                    focusedOptionID: $focusedOptionID
                                ) {
                                    selection = option.id
                                    dismiss()
                                }
                                .id(option.id)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .scrollIndicators(options.count > 8 ? .automatic : .hidden)
                    .onAppear {
                        focusSelection()
                        scrollToFocusedOption(with: proxy, animated: false)
                    }
                    .onChange(of: focusedOptionID) { _, _ in
                        scrollToFocusedOption(with: proxy)
                    }
                    .onChange(of: selection) { _, _ in
                        scrollToFocusedOption(with: proxy)
                    }
                }
            }
            .frame(maxWidth: 960)
            .navigationTitle(title)
            .safeAreaPadding(.vertical, ContinuumTheme.safePadding / 2)
            .background(Color.continuumBackground.ignoresSafeArea())
        }
        .focusSection()
        .onChange(of: focusedOptionID) { _, value in
            if value == nil {
                focusSelection()
            }
        }
    }

    private func focusSelection() {
        focusedOptionID = options.first { $0.id == selection }?.id ?? options.first?.id
    }

    private func previewAppearance(from base: SubtitleAppearance) -> SubtitleAppearance {
        let previewID = focusedOptionID ?? selection
        guard let fontFamily = SubtitleFontFamilyPreset(rawValue: previewID) else {
            return base
        }
        var copy = base
        copy.fontFamily = fontFamily
        return copy
    }

    private func scrollToFocusedOption(with proxy: ScrollViewProxy, animated: Bool = true) {
        let targetID = focusedOptionID ?? options.first { $0.id == selection }?.id ?? options.first?.id
        guard let targetID else { return }
        if animated {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        } else {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }
}

private struct TVSettingsPickerOptionRow: View {
    let option: TVSettingsOption
    let isSelected: Bool
    @FocusState.Binding var focusedOptionID: String?
    let onSelect: () -> Void

    private var isFocused: Bool { focusedOptionID == option.id }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(.system(size: 28, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                if let previewFontName = option.previewFontName {
                    Text("Subtitle sample")
                        .font(.custom(previewFontName, size: 22))
                        .lineLimit(1)
                        .opacity(0.72)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .opacity(isSelected ? 1 : 0)
        }
        .foregroundStyle(isFocused ? Color.continuumBackground : .continuumOnSurface)
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    borderColor,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .focusable(true)
        .focused($focusedOptionID, equals: option.id)
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var backgroundFill: Color {
        if isFocused { return .continuumOnSurface }
        if isSelected { return .continuumChromeSelectedFill }
        return .continuumChromeRestingFill
    }

    private var borderColor: Color {
        if isFocused { return .clear }
        if isSelected { return .continuumChromeSelectedBorder }
        return .continuumChromeRestingBorder
    }
}

// MARK: - Subtitle preview

/// Thin wrapper over the shared cross-platform preview so tvOS settings
/// screens keep the Skyline rounded-card look. (The old bespoke preview
/// drew "outline" as a stroked rectangle around the caption block, which
/// is not what the setting does to glyphs.)
struct TVSettingsSubtitlePreview: View {
    let appearance: SubtitleAppearance

    var body: some View {
        SubtitleAppearancePreview(appearance: appearance)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
#endif
