#if !os(tvOS)
import SwiftUI

extension View {
    func settingsListChrome() -> some View {
        siloGroupedListStyle()
            .siloScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
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
