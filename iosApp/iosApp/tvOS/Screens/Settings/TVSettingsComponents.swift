#if os(tvOS)
import SwiftUI

// MARK: - Option model

/// Option model shared by picker rows and their selection sheets.
struct TVSettingsOption: Identifiable, Hashable {
    let id: String
    let label: String
    var detail: String? = nil
    var previewFontName: String? = nil
}

/// Canonical option sets shared by the tvOS settings sub-screens.
enum TVSettingsOptions {
    /// Tag for the "stored pair matches no preset" entry. Not a preset id, so
    /// selecting it is a no-op rather than a write.
    static let customQualityId = "__custom__"

    static let profileLaunch: [TVSettingsOption] =
        ProfileLaunchBehavior.allCases.map {
            .init(id: $0.rawValue, label: $0.title, detail: $0.tvDescription)
        }

    /// The shared cross-client quality presets, optionally led by a
    /// description of a stored pair no preset covers.
    ///
    /// These are the settings vocabulary, not the in-player switcher's finer
    /// ladder: what is stored is a (resolution, bitrate) pair, so the two
    /// tables can label it differently without either reinterpreting it.
    static func quality(including customLabel: String? = nil) -> [TVSettingsOption] {
        let presets = SiloQualityPresets.all.map {
            TVSettingsOption(id: $0.id, label: $0.label)
        }
        guard let customLabel else { return presets }
        return [.init(id: customQualityId, label: customLabel)] + presets
    }

    static func audioLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            key: .playbackAudioLanguage,
            unsetID: "",
            fallbackUnsetLabel: "No preference"
        )
    }

    static let bufferAhead: [TVSettingsOption] =
        BufferAheadMode.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let deinterlaceMode: [TVSettingsOption] =
        DeinterlacePreference.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let deinterlaceFieldRate: [TVSettingsOption] =
        DeinterlaceFieldRatePreference.allCases.map { .init(id: $0.rawValue, label: $0.label) }

    static let nextUpPrompt: [TVSettingsOption] = [
        .init(id: "0", label: "At end"),
        .init(id: "10", label: "10 seconds before end"),
        .init(id: "30", label: "30 seconds before end"),
        .init(id: "60", label: "1 minute before end"),
        .init(id: "120", label: "2 minutes before end"),
    ]

    static func subtitleLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            key: .playbackSubtitleLanguage,
            unsetID: PlaybackPrefSentinel.none,
            fallbackUnsetLabel: "None"
        )
    }

    static func metadataLanguage(_ languages: [PlaybackLanguageOption]) -> [TVSettingsOption] {
        languageOptions(
            languages,
            key: .catalogMetadataLanguage,
            unsetID: PlaybackPrefSentinel.none,
            fallbackUnsetLabel: "Library default"
        )
    }

    private static func languageOptions(
        _ languages: [PlaybackLanguageOption],
        key: SettingKey,
        unsetID: String,
        fallbackUnsetLabel: String
    ) -> [TVSettingsOption] {
        let unsetLabel = SettingPresentationMetadata.definitions[key]?.unsetLabel
            ?? fallbackUnsetLabel
        return [.init(id: unsetID, label: unsetLabel)]
            + languages.map { .init(id: $0.code, label: $0.label) }
    }

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
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.continuumAccent)
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .opacity(isSelected && !isFocused ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.012 : 1))
            .shadow(
                color: isFocused ? Color.continuumAccent.opacity(0.14) : .clear,
                radius: 18
            )
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
        if isSelected { return .continuumSurfaceElevated.opacity(0.92) }
        return .clear
    }
}

// MARK: - Pane row style

/// Detail-pane row: faint glass fill with a hairline at rest, white
/// platter with dark content on focus.
struct TVSettingsPaneRowStyle: ButtonStyle {
    var isDestructive: Bool = false
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TVSettingsPaneRowBody(
            configuration: configuration,
            isDestructive: isDestructive,
            isSelected: isSelected
        )
    }
}

private struct TVSettingsPaneRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isDestructive: Bool
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 24)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(foreground)
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
            .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.012 : 1))
            .shadow(
                color: isFocused ? Color.continuumAccent.opacity(0.16) : .clear,
                radius: 18
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }

    private var foreground: Color {
        if isDestructive {
            return isFocused ? Color(hex: "#D22F3F") : .continuumError
        }
        return isFocused ? .continuumBackground : .continuumOnSurface
    }

    private var backgroundFill: Color {
        if isFocused { return .continuumOnSurface }
        if isSelected { return .continuumChromeSelectedFill }
        return .continuumSurfaceElevated.opacity(0.84)
    }

    private var borderColor: Color {
        if isFocused { return .clear }
        if isSelected { return .continuumChromeSelectedBorder }
        return .continuumChromeRestingBorder
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
                .fill(Color.continuumSurfaceElevated.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
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
            .foregroundStyle(Color.continuumAccent.opacity(0.86))
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

/// Semantic warning caption used for server and persistence failures.
struct TVSettingsWarningFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.body)
        .foregroundColor(.continuumError)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(text)")
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

// MARK: - Privacy policy handoff

/// Apple TV has no general-purpose web browser, so HTTPS links have no system
/// destination. Present the public policy URL as a QR handoff instead.
struct TVPrivacyPolicyOverlay: View {
    let dismiss: () -> Void

    @FocusState private var isDoneFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.76)
                .ignoresSafeArea()

            HStack(spacing: 54) {
                QRCodeView(
                    content: SiloLegalLinks.privacyPolicy.absoluteString,
                    size: 320
                )
                .padding(22)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color.continuumAccent)
                        .accessibilityHidden(true)

                    Text("Privacy Policy")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color.continuumOnSurface)

                    Text("Scan this code with your phone or tablet to read Silo's privacy policy.")
                        .font(.system(size: 23))
                        .foregroundStyle(Color.continuumSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(SiloLegalLinks.privacyPolicy.absoluteString)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.continuumAccent)
                        .accessibilityLabel("Privacy policy URL")
                        .accessibilityValue(SiloLegalLinks.privacyPolicy.absoluteString)

                    Button(action: dismiss) {
                        Text("Done")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($isDoneFocused)
                }
                .frame(width: 560, alignment: .leading)
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 52)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color.continuumSurfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
            }
            .focusSection()
            .defaultFocus($isDoneFocused, true, priority: .userInitiated)
        }
        .onAppear { isDoneFocused = true }
        .onExitCommand(perform: dismiss)
    }
}

// MARK: - Picker sheet

/// Compact modal option menu mounted by the root Settings view.
/// The menu stays compact while a full-screen scrim cleanly separates it
/// from the disabled two-pane settings focus graph beneath it.
/// Selecting an option updates the binding and dismisses; Menu cancels.
struct TVSettingsPickerSheet: View {
    let title: String
    let options: [TVSettingsOption]
    @Binding var selection: String
    var subtitlePreviewAppearance: SubtitleAppearance? = nil
    var allowsSelection = true
    var disabledMessage: String? = nil
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pickerFocusScope
    @FocusState private var focusedOptionID: String?
    @State private var isClosing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.continuumBackground.opacity(0.88)
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        Color.continuumAccent.opacity(0.08),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 40,
                    endRadius: 680
                )
                .ignoresSafeArea()

                pickerCard(
                    width: min(760, geometry.size.width - 240),
                    height: min(
                        max(preferredCardHeight, 390),
                        min(760, geometry.size.height - 160)
                    )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .focusScope(pickerFocusScope)
        .focusSection()
        .onExitCommand(perform: close)
        .onDisappear { isClosing = true }
        .onChange(of: focusedOptionID) { _, value in
            if allowsSelection, value == nil, !isClosing {
                claimFocus()
            }
        }
    }

    private func pickerCard(width: CGFloat, height: CGFloat) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color.continuumOnSurface)
                        .accessibilityAddTraits(.isHeader)

                    Text("Choose an option")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.continuumSecondaryText)
                }

                Spacer(minLength: 12)

                Label("Menu to close", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.continuumSecondaryText)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.055), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.continuumChromeRestingBorder, lineWidth: 1)
                }
            }

            if let disabledMessage {
                TVSettingsFooter(disabledMessage)
            }

            if let subtitlePreviewAppearance {
                TVSettingsSubtitlePreview(
                    appearance: previewAppearance(from: subtitlePreviewAppearance)
                )
            }

            Rectangle()
                .fill(Color.continuumChromeRestingBorder)
                .frame(height: 1)

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
                                close()
                            }
                            .id(option.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
                .contentMargins(.vertical, 8, for: .scrollContent)
                .scrollIndicators(options.count > 7 ? .automatic : .hidden)
                // Picker rows scale and cast a small shadow on focus. Keep
                // those layers inside the list viewport so scrolling cannot
                // paint over the header or beyond the card.
                .clipped()
                .onAppear {
                    guard allowsSelection else {
                        focusedOptionID = nil
                        return
                    }
                    claimFocus()
                    scrollToFocusedOption(with: proxy, animated: false)
                }
                .onChange(of: allowsSelection) { _, enabled in
                    guard enabled else {
                        focusedOptionID = nil
                        return
                    }
                    claimFocus()
                    scrollToFocusedOption(with: proxy, animated: false)
                }
                .onChange(of: focusedOptionID) { _, _ in
                    scrollToFocusedOption(with: proxy)
                }
                .onChange(of: selection) { _, _ in
                    scrollToFocusedOption(with: proxy)
                }
            }
            .disabled(!allowsSelection)
        }
        .padding(30)
        .frame(width: width, height: height, alignment: .top)
        .background(cardShape.fill(Color.continuumSurfaceElevated.opacity(0.98)))
        // Clip child layers first, then add the border and outer card shadow.
        // This preserves the floating dialog while containing scroll content.
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(
                Color.continuumChromeSelectedBorder.opacity(0.9),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.58), radius: 48, y: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) options")
    }

    private var preferredCardHeight: CGFloat {
        let chromeHeight: CGFloat = subtitlePreviewAppearance == nil ? 158 : 344
        let disabledMessageHeight: CGFloat = disabledMessage == nil ? 0 : 72
        let rowsHeight = options.reduce(CGFloat(0)) { $0 + estimatedRowHeight(for: $1) }
        return chromeHeight + disabledMessageHeight + rowsHeight
    }

    /// Per-row height estimate including the list gap. Detail text wraps at
    /// the card's fixed ~590pt text column, roughly 54 characters of 20pt
    /// system text per line; rounding lines up leaves breathing room below
    /// the last row instead of clipping a wrapped description.
    private func estimatedRowHeight(for option: TVSettingsOption) -> CGFloat {
        if let detail = option.detail {
            let detailLines = max(1.0, (Double(detail.count) / 54).rounded(.up))
            return 88 + CGFloat(detailLines) * 26
        }
        return option.previewFontName != nil ? 88 : 72
    }

    private func focusSelection() {
        focusedOptionID = options.first { $0.id == selection }?.id ?? options.first?.id
    }

    private func claimFocus() {
        guard allowsSelection, !isClosing else { return }
        focusSelection()
        Task { @MainActor in
            await Task.yield()
            guard allowsSelection, !isClosing else { return }
            resetFocus(in: pickerFocusScope)
            focusSelection()
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
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
        guard allowsSelection else { return }
        let targetID = focusedOptionID ?? options.first { $0.id == selection }?.id ?? options.first?.id
        guard let targetID else { return }
        if animated, !reduceMotion {
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

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.system(size: 27, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)

                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 20))
                            .opacity(0.72)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
        }
        .buttonStyle(TVSettingsPaneRowStyle(isSelected: isSelected))
        .focused($focusedOptionID, equals: option.id)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.detail ?? "")
        .accessibilityValue(isSelected ? "Selected" : "")
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
