#if !os(tvOS)
import SwiftUI

extension View {
    func settingsListChrome() -> some View {
        #if os(macOS)
        // A desktop window is far wider than a settings row needs: an
        // unconstrained list puts each label and its control at opposite
        // edges. Keep settings in a centred column, and give forms the
        // grouped style so their rows lay out as labelled cards.
        siloGroupedListStyle()
            .formStyle(.grouped)
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
