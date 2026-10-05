#if !os(tvOS)
import SwiftUI

#if os(macOS)
/// A settings switch with its label on the leading side and the switch on
/// the trailing side, the same shape as a pop-up row. The Mac's default
/// checkbox made toggle rows shorter than the rows around them.
private struct MacSettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        } label: {
            configuration.label
        }
    }
}
#endif

extension View {
    func settingsListChrome() -> some View {
        #if os(macOS)
        // A desktop window is far wider than a settings row needs: an
        // unconstrained list puts each label and its control at opposite
        // edges. Keep settings in a centred column, and give forms the
        // grouped style so their rows lay out as labelled cards.
        // The list itself is narrowed: a Mac list ignores content margins,
        // so insetting only its content is not an option.
        siloGroupedListStyle()
            .formStyle(.grouped)
            .toggleStyle(MacSettingsToggleStyle())
            .siloScrollContentBackgroundHidden()
            .frame(maxWidth: SiloTheme.macSettingsColumnWidth)
            .frame(maxWidth: .infinity)
            .background(SettingsBackdrop())
        #else
        siloGroupedListStyle()
            .siloScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
        #endif
    }

    /// Settings pickers open as a menu on macOS and push a choice list on iOS.
    func settingsPickerStyle() -> some View {
        #if os(macOS)
        return pickerStyle(.menu)
        #else
        return pickerStyle(.navigationLink)
        #endif
    }
}
#endif
