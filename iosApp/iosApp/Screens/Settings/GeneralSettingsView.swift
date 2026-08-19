#if !os(tvOS)
import SwiftUI

/// Device-local startup preferences that do not belong to playback or
/// interface customization.
struct GeneralSettingsView: View {
    @State private var launchPreferences = ProfileLaunchPreferences.shared

    var body: some View {
        List {
            SettingsPageHeader(
                title: "General",
                subtitle: "Choose what happens when you open Silo on this device.",
                systemImage: "gearshape.fill",
                tint: .purple
            )
            .settingsPageHeaderRow()

            profileSection
        }
        .settingsListChrome()
        .navigationTitle("")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }

    private var profileSection: some View {
        Section {
            Picker("Profile Selection", selection: $launchPreferences.behavior) {
                ForEach(ProfileLaunchBehavior.allCases) { behavior in
                    Text(behavior.title)
                        .accessibilityHint(behavior.standardDescription)
                        .tag(behavior)
                }
            }
            .siloSettingsPicker()
            .accessibilityValue(launchPreferences.behavior.title)
            .accessibilityHint(launchPreferences.behavior.standardDescription)
        } header: {
            Text("Profiles")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(launchPreferences.behavior.standardDescription)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloSurfaceElevated)
    }
}
#endif
