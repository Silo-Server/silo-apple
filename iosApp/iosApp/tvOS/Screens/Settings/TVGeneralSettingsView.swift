#if os(tvOS)
import SwiftUI

/// General pane of tvOS Settings, rendered inline in the right pane of
/// the two-pane `TVSettingsView`.
///
/// Home for app-level preferences that aren't playback or subtitles. Today
/// that's the opt-in Audiobooks tab, and it's the natural place any future
/// top-menu / header customization would live.
struct TVGeneralSettingsPane: View {
    @State private var navPrefs = TVNavPreferences.shared
    let detailFocus: FocusState<TVSettingsDetailFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsSectionHeader("TOP MENU")

            // Bound straight to the local store (not the settings view model):
            // this is a device-local, per-profile preference, not one of the
            // server-synced device settings the view model owns.
            TVSettingsToggleRow(
                title: "Show Audiobooks",
                isOn: navPrefs.showAudiobooks
            ) {
                navPrefs.setShowAudiobooks(!navPrefs.showAudiobooks)
            }
            .focused(detailFocus, equals: .top)

            TVSettingsFooter("Adds an Audiobooks tab to the top menu when your server has an audiobook library. Hidden by default.")
        }
    }
}
#endif
