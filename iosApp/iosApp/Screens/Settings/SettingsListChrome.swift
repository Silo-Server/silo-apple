#if !os(tvOS)
import SwiftUI

extension View {
    func settingsListChrome() -> some View {
        siloGroupedListStyle()
            .siloScrollContentBackgroundHidden()
            .background(SettingsBackdrop())
    }
}
#endif
