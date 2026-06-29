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
        SubtitleBackgroundStylePreset.allCases.map { .init(id: $0.rawValue, label: $0.label) }

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
                        appearance: previewAppearance(from: subtitlePreviewAppearance),
                        text: "This is how subtitles will look."
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
            .navigationTitle(title)
            .safeAreaPadding(.horizontal, ContinuumTheme.safePadding)
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
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(.system(size: 30, weight: .medium))
                    .lineLimit(1)

                if let previewFontName = option.previewFontName {
                    Text("Subtitle sample")
                        .font(.custom(previewFontName, size: 22))
                        .lineLimit(1)
                        .opacity(0.72)
                }
            }
            .foregroundStyle(isFocused ? Color.continuumBackground : .continuumOnSurface)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.continuumBackground : .continuumOnSurface)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? Color.white : Color.continuumSurfaceElevated.opacity(0.74))
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
}

// MARK: - Subtitle preview

struct TVSettingsSubtitlePreview: View {
    let appearance: SubtitleAppearance
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.72))
            Text(text)
                .font(.custom(appearance.fontFamily.assFontName, size: 34))
                .foregroundStyle(Color(hex: appearance.fontColor))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26)
                .padding(.vertical, 18)
                .background(background)
                .overlay(outline)
                .shadow(
                    color: appearance.backgroundStyle == .shadow ? .black.opacity(0.72) : .clear,
                    radius: 2,
                    x: 0,
                    y: 2
                )
        }
        .frame(height: 150)
        .accessibilityLabel("Subtitle preview")
        .accessibilityValue(text)
    }

    @ViewBuilder
    private var background: some View {
        if appearance.backgroundStyle == .box {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: appearance.backgroundColor)
                    .opacity(Double(appearance.backgroundOpacity) / 100.0))
        }
    }

    @ViewBuilder
    private var outline: some View {
        if appearance.textOutline || appearance.backgroundStyle == .outline {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: appearance.textOutlineColor), lineWidth: 2)
        }
    }
}

// MARK: - Focus-aware row primitives

/// Label-style row (icon + title) that flips to a dark foreground when
/// the enclosing Button gains focus, so text stays legible against the
/// light focus platter despite the app-wide white tint.
struct FocusAwareLabel: View {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(foreground)
    }

    private var foreground: Color {
        if isFocused { return .continuumBackground }
        return isDestructive ? .continuumError : .continuumOnSurface
    }
}

/// Title + trailing value row for drill-in and picker rows. Flips both
/// pieces dark on focus, matching `FocusAwareLabel`.
struct FocusAwareValueRow: View {
    let title: String
    let value: String

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(valueColor)
        } label: {
            Text(title).foregroundStyle(titleColor)
        }
    }

    private var titleColor: Color {
        isFocused ? .continuumBackground : .continuumOnSurface
    }

    private var valueColor: Color {
        (isFocused ? Color.continuumBackground : Color.continuumOnSurface).opacity(0.6)
    }
}

/// Focus-aware text label for icon-less Form rows (`Toggle`s and plain
/// action buttons). Destructive rows flip from red to the dark platter
/// color on focus, exactly like `FocusAwareLabel`.
struct FocusAwareRowLabel: View {
    let title: String
    var isDestructive: Bool = false

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(title)
            .foregroundStyle(foreground)
    }

    private var foreground: Color {
        if isFocused { return .continuumBackground }
        return isDestructive ? .continuumError : .continuumOnSurface
    }
}

/// Tappable account row at the top of Settings. Switches profile on
/// activation and flips foreground colors on focus like every other
/// row in the Form.
struct FocusAwareAccountRow: View {
    let name: String
    let subtitle: String
    let avatar: String?

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 20) {
            ProfileAvatarView(
                avatar: avatar,
                name: name,
                size: 72,
                backgroundColor: isFocused
                    ? Color.continuumBackground.opacity(0.15)
                    : .continuumSurfaceElevated,
                textColor: isFocused ? .continuumBackground : .continuumOnSurface
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(primaryColor)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(secondaryColor)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(secondaryColor)
        }
        .padding(.vertical, 4)
    }

    private var primaryColor: Color {
        isFocused ? .continuumBackground : .continuumOnSurface
    }

    private var secondaryColor: Color {
        (isFocused ? Color.continuumBackground : Color.continuumOnSurface).opacity(0.6)
    }
}
#endif
